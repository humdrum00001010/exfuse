import Darwin
import FSKit
import Foundation
import os

final class ExfuseVolume: FSVolume {
    private let log = Logger(subsystem: "ExfuseFSKit", category: "Volume")
    private let client: ExfuseWireClient
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

    // FSKit may split one directory enumeration across several calls when its
    // entry packer fills up. Keep the backend result for that enumeration's
    // verifier so continuation cookies do not issue another full readdir.
    private struct DirectorySnapshot {
        let path: String
        let entries: [ExfuseDirectoryEntry]
    }

    private var directorySnapshots: [UInt64: DirectorySnapshot] = [:]
    private var nextDirectoryVerifier: UInt64 = 1
    private let directorySnapshotsLock = NSLock()

    init(port: UInt16, volumeUUID: UUID) {
        client = ExfuseWireClient(port: port)

        super.init(
            volumeID: FSVolume.Identifier(uuid: volumeUUID),
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
        let item = try liveItem(item)

        return try attributes(of: item)
    }

    func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem
    ) async throws -> FSItem.Attributes {
        let item = try liveItem(item)

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

        return try attributes(of: item)
    }

    func lookupItem(
        named name: FSFileName,
        inDirectory directory: FSItem
    ) async throws -> (FSItem, FSFileName) {
        let directory = try liveItem(directory, invalidError: ENOTDIR)

        let path = try childPath(directory: directory, name: name)
        log.notice("lookup \(path, privacy: .public)")
        return (try item(for: path), fileName(for: path))
    }

    func reclaimItem(_ item: FSItem) async throws {
        log.debug("reclaimItem")

        if let item = item as? ExfuseItem {
            itemsLock.withLock {
                if itemsByPath[item.path] === item {
                    itemsByPath.removeValue(forKey: item.path)
                }
            }
        }
    }

    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        let item = try liveItem(item)

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
        let item = try liveItem(item)

        if item.attributes.type == .directory {
            try client.rmdir(item.path)
        } else {
            try client.unlink(item.path)
        }

        itemsLock.withLock {
            if itemsByPath[item.path] === item {
                itemsByPath.removeValue(forKey: item.path)
            }
            item.deleted = true
        }
    }

    func renameItem(
        _ item: FSItem,
        inDirectory sourceDirectory: FSItem,
        named sourceName: FSFileName,
        to destinationName: FSFileName,
        inDirectory destinationDirectory: FSItem,
        overItem: FSItem?
    ) async throws -> FSFileName {
        let item = try liveItem(item)
        let sourceDirectory = try liveItem(sourceDirectory)
        let destinationDirectory = try liveItem(destinationDirectory)

        let source = try childPath(directory: sourceDirectory, name: sourceName)
        let destination = try childPath(directory: destinationDirectory, name: destinationName)
        log.notice("rename \(source, privacy: .public) to \(destination, privacy: .public)")
        try client.rename(from: source, to: destination)

        itemsLock.withLock {
            itemsByPath.removeValue(forKey: source)
            itemsByPath.removeValue(forKey: destination)

            if let overwritten = overItem as? ExfuseItem, overwritten !== item {
                overwritten.deleted = true
            }

            item.path = destination
            item.name = fileName(for: destination)
            itemsByPath[destination] = item
        }

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

        let start = Int(cookie.rawValue)
        let snapshot: DirectorySnapshot
        let currentVerifier: UInt64

        if cookie.rawValue == FSDirectoryCookie.initial.rawValue {
            log.notice("readdir backend \(directory.path, privacy: .public)")
            let entries = try client.readdir(directory.path)

            (currentVerifier, snapshot) = directorySnapshotsLock.withLock {
                let currentVerifier = nextDirectoryVerifier
                nextDirectoryVerifier &+= 1
                if nextDirectoryVerifier == FSDirectoryVerifier.initial.rawValue {
                    nextDirectoryVerifier &+= 1
                }

                let snapshot = DirectorySnapshot(path: directory.path, entries: entries)
                directorySnapshots[currentVerifier] = snapshot
                return (currentVerifier, snapshot)
            }
        } else {
            currentVerifier = verifier.rawValue

            guard let existing = directorySnapshotsLock.withLock({
                directorySnapshots[currentVerifier]
            }), existing.path == directory.path else {
                throw posixError(EINVAL)
            }

            snapshot = existing
        }

        if start > snapshot.entries.count {
            throw posixError(EINVAL)
        }

        var complete = true

        for index in start..<snapshot.entries.count {
            let entry = snapshot.entries[index]
            let name = entry.name
            let path = directory.path == "/" ? "/" + name : directory.path + "/" + name
            let attrs = attributes(from: entry.attributes, for: path)
            pinRegisteredID(onto: attrs, path: path)

            let packed = packer.packEntry(
                name: FSFileName(string: name),
                itemType: attrs.type,
                itemID: attrs.fileID,
                nextCookie: FSDirectoryCookie(UInt64(index + 1)),
                attributes: requestedAttributes == nil ? nil : attrs
            )

            if !packed {
                complete = false
                break
            }
        }

        if complete {
            _ = directorySnapshotsLock.withLock {
                directorySnapshots.removeValue(forKey: currentVerifier)
            }
        }

        return FSDirectoryVerifier(currentVerifier)
    }

    // An item's fileID is pinned at first sight and must never change while
    // the kernel still holds the item — including across renames. Recomputing
    // it from the item's CURRENT path (as `attributes(for:)` does) makes the
    // fileID of a temp file renamed over an existing name flip between
    // operations, which desyncs the kernel's object identity for that vnode.
    private func attributes(of item: ExfuseItem) throws -> FSItem.Attributes {
        guard !item.deleted else {
            throw posixError(ESTALE)
        }

        let attrs = try attributes(for: item.path)
        attrs.fileID = item.id
        return attrs
    }

    // Directory enumeration must report the same fileID a lookup of the entry
    // would: prefer the registered (pinned) item identity over the path hash.
    private func pinRegisteredID(onto attrs: FSItem.Attributes, path: String) {
        itemsLock.withLock {
            if let existing = itemsByPath[normalizePath(path)] {
                attrs.fileID = existing.id
            }
        }
    }

    private func item(for path: String) throws -> ExfuseItem {
        let normalized = normalizePath(path)
        let attrs = try attributes(for: normalized)

        itemsLock.lock()
        defer { itemsLock.unlock() }

        if let existing = itemsByPath[normalized], !existing.deleted {
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

    private func liveItem(_ item: FSItem, invalidError: Int32 = EIO) throws -> ExfuseItem {
        guard let item = item as? ExfuseItem else {
            throw posixError(invalidError)
        }
        guard !item.deleted else {
            throw posixError(ESTALE)
        }
        return item
    }

    private func attributes(for path: String) throws -> FSItem.Attributes {
        let attr = try client.getattr(path)
        return attributes(from: attr, for: path)
    }

    private func attributes(from attr: ExfuseAttr, for path: String) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        attrs.mode = attr.mode
        attrs.type = itemType(for: attr.kind)
        attrs.linkCount = attr.kind == .directory ? 2 : 1
        // FSKit's standard item mask requires flags and excludes uid/gid.
        // Supplying the latter while omitting flags makes FSKit reject the
        // entire lookup as incomplete before a read can reach Exfuse.
        attrs.flags = 0
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
        let item = try liveItem(item)

        log.notice("open \(item.path, privacy: .public)")
        do {
            _ = try client.open(path: item.path, flags: UInt32(modes.rawValue))
        } catch {
            log.error("open failed for \(item.path, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {
        guard let item = item as? ExfuseItem else {
            throw posixError(EIO)
        }
        if item.deleted {
            return
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
        let item = try liveItem(item)

        log.notice("read \(item.path, privacy: .public) at \(offset) length \(length)")
        let data: Data
        do {
            data = try client.read(
                path: item.path,
                offset: UInt64(max(offset, 0)),
                size: UInt64(length)
            )
        } catch {
            log.error(
                "read failed for \(item.path, privacy: .public) at \(offset) length \(length): \(String(describing: error), privacy: .public)"
            )
            throw error
        }

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
        let item = try liveItem(item)

        return try client.write(path: item.path, offset: UInt64(max(offset, 0)), data: contents)
    }
}
