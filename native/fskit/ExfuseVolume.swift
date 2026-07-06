import Darwin
import FSKit
import Foundation
import os

final class ExfuseVolume: FSVolume {
    private let log = Logger(subsystem: "ExfuseFSKit", category: "Volume")
    private let client = ExfuseWireClient.shared
    private let root = ExfuseItem.root()

    // Item timestamps must be STABLE across getattr calls: a fresh
    // currentTimespec() per call makes the kernel's rename/lookup
    // revalidation spin forever (attributes never settle) and the rename
    // fails without ever reaching the backend.
    private let mountEpoch = timespec(tv_sec: time(nil), tv_nsec: 0)

    // FSKit correlates volume state by FSItem object identity, so every
    // lookup of the same path must return the SAME instance. Returning a
    // fresh FSItem per lookup breaks rename-over-existing (ENOENT before
    // renameItem is ever called) because fskitd cannot match the destination
    // item it already holds.
    private var itemsByPath: [String: ExfuseItem] = [:]
    private let itemsLock = NSLock()

    init() {
        super.init(
            volumeID: FSVolume.Identifier(uuid: Bundle.main.exfuseVolumeUUID),
            volumeName: FSFileName(string: "exfuse")
        )
    }
}

extension ExfuseVolume: FSVolume.PathConfOperations {
    var maximumLinkCount: Int { -1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { false }
    var truncatesLongNames: Bool { false }
    var maximumFileSize: UInt64 { UInt64.max }
}

extension ExfuseVolume: FSVolume.Operations {
    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let capabilities = FSVolume.SupportedCapabilities()
        capabilities.supportsPersistentObjectIDs = true
        capabilities.supportsSymbolicLinks = true
        capabilities.supports64BitObjectIDs = true
        capabilities.doesNotSupportVolumeSizes = true
        capabilities.doesNotSupportImmutableFiles = true
        capabilities.caseFormat = .sensitive
        return capabilities
    }

    var volumeStatistics: FSStatFSResult {
        let stats = FSStatFSResult(fileSystemTypeName: "exfuse")
        stats.blockSize = 4096
        stats.ioSize = 4096
        stats.totalFiles = 1_000_000
        stats.freeFiles = 1_000_000
        return stats
    }

    func activate(options: FSTaskOptions) async throws -> FSItem {
        log.debug("activate")
        return root
    }

    func deactivate(options: FSDeactivateOptions = []) async throws {
        log.debug("deactivate")
    }

    func mount(options: FSTaskOptions) async throws {
        log.debug("mount")
    }

    func unmount() async {
        log.debug("unmount")
    }

    func synchronize(flags: FSSyncFlags) async throws {
        log.debug("synchronize")
        try client.fsync(path: "/")
    }

    func attributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of item: FSItem
    ) async throws -> FSItem.Attributes {
        guard let item = item as? ExfuseItem else {
            throw posixError(EIO)
        }

        return try attributes(for: item.path)
    }

    func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem
    ) async throws -> FSItem.Attributes {
        guard let item = item as? ExfuseItem else {
            throw posixError(EIO)
        }

        if newAttributes.isValid(.size) {
            try client.truncate(path: item.path, size: newAttributes.size)
            newAttributes.consumedAttributes.insert(.size)
        }

        if newAttributes.isValid(.mode) {
            try client.chmod(path: item.path, mode: newAttributes.mode)
            newAttributes.consumedAttributes.insert(.mode)
        }

        if newAttributes.isValid(.uid) || newAttributes.isValid(.gid) {
            try client.chown(
                path: item.path,
                uid: newAttributes.isValid(.uid) ? newAttributes.uid : UInt32.max,
                gid: newAttributes.isValid(.gid) ? newAttributes.gid : UInt32.max
            )

            if newAttributes.isValid(.uid) {
                newAttributes.consumedAttributes.insert(.uid)
            }
            if newAttributes.isValid(.gid) {
                newAttributes.consumedAttributes.insert(.gid)
            }
        }

        return try attributes(for: item.path)
    }

    func lookupItem(
        named name: FSFileName,
        inDirectory directory: FSItem
    ) async throws -> (FSItem, FSFileName) {
        guard let directory = directory as? ExfuseItem else {
            throw posixError(ENOTDIR)
        }

        let path = try childPath(directory: directory, name: name)
        return (try item(for: path), fileName(for: path))
    }

    func reclaimItem(_ item: FSItem) async throws {
        log.debug("reclaimItem")

        if let item = item as? ExfuseItem {
            itemsLock.lock()
            if itemsByPath[item.path] === item {
                itemsByPath.removeValue(forKey: item.path)
            }
            itemsLock.unlock()
        }
    }

    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        guard let item = item as? ExfuseItem else {
            throw posixError(EIO)
        }

        return FSFileName(string: try client.readlink(item.path))
    }

    func createItem(
        named name: FSFileName,
        type: FSItem.ItemType,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest
    ) async throws -> (FSItem, FSFileName) {
        guard let directory = directory as? ExfuseItem else {
            throw posixError(ENOTDIR)
        }

        let path = try childPath(directory: directory, name: name)
        let mode = newAttributes.isValid(.mode) ? newAttributes.mode : UInt32(0o644)

        switch type {
        case .directory:
            try client.mkdir(path: path, mode: mode)
        case .file:
            _ = try client.create(path: path, mode: mode, flags: UInt32(O_CREAT | O_RDWR))
        default:
            throw posixError(ENOTSUP)
        }

        return (try item(for: path), fileName(for: path))
    }

    func createSymbolicLink(
        named name: FSFileName,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        linkContents contents: FSFileName
    ) async throws -> (FSItem, FSFileName) {
        throw posixError(ENOTSUP)
    }

    func createLink(
        to item: FSItem,
        named name: FSFileName,
        inDirectory directory: FSItem
    ) async throws -> FSFileName {
        throw posixError(ENOTSUP)
    }

    func removeItem(
        _ item: FSItem,
        named name: FSFileName,
        fromDirectory directory: FSItem
    ) async throws {
        guard let item = item as? ExfuseItem else {
            throw posixError(EIO)
        }

        if item.attributes.type == .directory {
            try client.rmdir(item.path)
        } else {
            try client.unlink(item.path)
        }

        itemsLock.lock()
        if itemsByPath[item.path] === item {
            itemsByPath.removeValue(forKey: item.path)
        }
        itemsLock.unlock()
    }

    func renameItem(
        _ item: FSItem,
        inDirectory sourceDirectory: FSItem,
        named sourceName: FSFileName,
        to destinationName: FSFileName,
        inDirectory destinationDirectory: FSItem,
        overItem: FSItem?
    ) async throws -> FSFileName {
        guard
            let sourceDirectory = sourceDirectory as? ExfuseItem,
            let destinationDirectory = destinationDirectory as? ExfuseItem
        else {
            throw posixError(EIO)
        }

        let source = try childPath(directory: sourceDirectory, name: sourceName)
        let destination = try childPath(directory: destinationDirectory, name: destinationName)
        try client.rename(from: source, to: destination)

        itemsLock.lock()
        itemsByPath.removeValue(forKey: source)
        itemsByPath.removeValue(forKey: destination)

        if let item = item as? ExfuseItem {
            item.path = destination
            item.name = fileName(for: destination)
            itemsByPath[destination] = item
        }

        itemsLock.unlock()

        return fileName(for: destination)
    }

    func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes requestedAttributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker
    ) async throws -> FSDirectoryVerifier {
        guard let directory = directory as? ExfuseItem else {
            throw posixError(ENOTDIR)
        }

        let entries = try client.readdir(directory.path)
        let start = Int(cookie.rawValue)

        if start > entries.count {
            throw posixError(EINVAL)
        }

        for index in start..<entries.count {
            let name = entries[index]
            let path = directory.path == "/" ? "/" + name : directory.path + "/" + name
            let attrs = try attributes(for: path)

            let packed = packer.packEntry(
                name: FSFileName(string: name),
                itemType: attrs.type,
                itemID: attrs.fileID,
                nextCookie: FSDirectoryCookie(UInt64(index + 1)),
                attributes: requestedAttributes == nil ? nil : attrs
            )

            if !packed {
                break
            }
        }

        return FSDirectoryVerifier(1)
    }

    private func item(for path: String) throws -> ExfuseItem {
        let normalized = normalizePath(path)
        let attrs = try attributes(for: normalized)

        itemsLock.lock()
        defer { itemsLock.unlock() }

        if let existing = itemsByPath[normalized] {
            attrs.fileID = existing.id
            existing.attributes = attrs
            return existing
        }

        let item = ExfuseItem(
            path: normalized,
            name: fileName(for: normalized),
            attributes: attrs
        )

        itemsByPath[normalized] = item
        return item
    }

    private func attributes(for path: String) throws -> FSItem.Attributes {
        let attr = try client.getattr(path)
        let attrs = FSItem.Attributes()
        attrs.mode = attr.mode
        attrs.type = itemType(for: attr.kind)
        attrs.linkCount = attr.kind == .directory ? 2 : 1
        attrs.uid = getuid()
        attrs.gid = getgid()
        attrs.size = attr.size
        attrs.allocSize = attr.size
        attrs.fileID = itemID(for: path)
        attrs.parentID = parentID(for: path)
        // Backend mtime (when supplied) tracks content changes; otherwise the
        // stable mount epoch keeps kernel revalidation from spinning.
        let stamp = attr.mtime.map { timespec(tv_sec: time_t($0), tv_nsec: 0) } ?? mountEpoch
        attrs.modifyTime = stamp
        attrs.changeTime = stamp
        attrs.accessTime = stamp
        attrs.birthTime = mountEpoch
        return attrs
    }

    private func itemType(for kind: ExfuseNodeKind) -> FSItem.ItemType {
        switch kind {
        case .directory:
            return .directory
        case .file:
            return .file
        case .symlink:
            return .symlink
        }
    }
}

extension ExfuseVolume: FSVolume.OpenCloseOperations {
    func openItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {
        guard let item = item as? ExfuseItem else {
            throw posixError(EIO)
        }

        _ = try client.open(path: item.path, flags: UInt32(modes.rawValue))
    }

    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {
        guard let item = item as? ExfuseItem else {
            throw posixError(EIO)
        }

        try client.release(path: item.path, flags: UInt32(modes.rawValue))
    }
}

extension ExfuseVolume: FSVolume.ReadWriteOperations {
    func read(
        from item: FSItem,
        at offset: off_t,
        length: Int,
        into buffer: FSMutableFileDataBuffer
    ) async throws -> Int {
        guard let item = item as? ExfuseItem else {
            throw posixError(EIO)
        }

        let data = try client.read(
            path: item.path,
            offset: UInt64(max(offset, 0)),
            size: UInt64(length)
        )

        return data.withUnsafeBytes { source in
            buffer.withUnsafeMutableBytes { destination in
                let count = min(source.count, destination.count)
                if count > 0, let sourceBase = source.baseAddress, let destinationBase = destination.baseAddress {
                    memcpy(destinationBase, sourceBase, count)
                }
                return count
            }
        }
    }

    func write(contents: Data, to item: FSItem, at offset: off_t) async throws -> Int {
        guard let item = item as? ExfuseItem else {
            throw posixError(EIO)
        }

        return try client.write(path: item.path, offset: UInt64(max(offset, 0)), data: contents)
    }
}
