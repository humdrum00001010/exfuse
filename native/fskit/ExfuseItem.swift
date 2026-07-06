import FSKit
import Foundation

final class ExfuseItem: FSItem {
    var path: String
    var name: FSFileName
    var attributes: FSItem.Attributes

    // Assigned once at first sight and kept for the item's lifetime, even
    // across renames: FSKit correlates FSItem instances with kernel state, so
    // an item's identifier must never change while the kernel still holds it.
    let id: FSItem.Identifier

    init(path: String, name: FSFileName, attributes: FSItem.Attributes) {
        self.path = path
        self.name = name
        self.attributes = attributes
        self.id = attributes.fileID
        super.init()
    }

    static func root() -> ExfuseItem {
        let attrs = FSItem.Attributes()
        attrs.type = .directory
        attrs.mode = UInt32(S_IFDIR | 0o755)
        attrs.linkCount = 2
        attrs.fileID = .rootDirectory
        attrs.parentID = .parentOfRoot
        attrs.uid = getuid()
        attrs.gid = getgid()
        attrs.size = 0
        attrs.allocSize = 0
        attrs.modifyTime = currentTimespec()
        attrs.changeTime = attrs.modifyTime
        attrs.accessTime = attrs.modifyTime
        attrs.birthTime = attrs.modifyTime

        return ExfuseItem(path: "/", name: FSFileName(string: "/"), attributes: attrs)
    }
}

func currentTimespec() -> timespec {
    var value = timespec()
    timespec_get(&value, TIME_UTC)
    return value
}

func itemID(for path: String) -> FSItem.Identifier {
    if path == "/" {
        return .rootDirectory
    }

    var hash: UInt64 = 0xcbf29ce484222325
    for byte in path.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x100000001b3
    }

    let reservedFloor = FSItem.Identifier.rootDirectory.rawValue + 1
    let value = max(hash, reservedFloor)
    return FSItem.Identifier(rawValue: value) ?? .invalid
}

func parentID(for path: String) -> FSItem.Identifier {
    if path == "/" {
        return .parentOfRoot
    }

    return itemID(for: parentPath(path))
}

func parentPath(_ path: String) -> String {
    let normalized = normalizePath(path)
    if normalized == "/" {
        return "/"
    }

    let url = URL(fileURLWithPath: normalized)
    let parent = url.deletingLastPathComponent().path
    return parent.isEmpty ? "/" : parent
}

func childPath(directory: ExfuseItem, name: FSFileName) throws -> String {
    guard let component = name.string, !component.isEmpty, component != ".", component != ".." else {
        throw posixError(EINVAL)
    }

    if directory.path == "/" {
        return "/" + component
    }

    return normalizePath(directory.path + "/" + component)
}

func normalizePath(_ path: String) -> String {
    if path.isEmpty || path == "/" {
        return "/"
    }

    var components: [String] = []
    for component in path.split(separator: "/", omittingEmptySubsequences: true) {
        if component == "." {
            continue
        }
        if component == ".." {
            _ = components.popLast()
        } else {
            components.append(String(component))
        }
    }

    return "/" + components.joined(separator: "/")
}

func fileName(for path: String) -> FSFileName {
    if path == "/" {
        return FSFileName(string: "/")
    }

    return FSFileName(string: URL(fileURLWithPath: path).lastPathComponent)
}

func posixError(_ code: Int32) -> any Error {
    fs_errorForPOSIXError(code)
}
