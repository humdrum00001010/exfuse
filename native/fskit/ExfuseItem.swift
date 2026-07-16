import FSKit
import Foundation

final class ExfuseItem: FSItem {
    var path: String
    var name: FSFileName
    var attributes: FSItem.Attributes
    var deleted = false

    // FSKit reports one aggregate open lifecycle per item: open supplies the
    // desired access and close supplies the access that remains afterwards.
    // Keep the backend handle for that whole lifecycle so reads, writes, and
    // the final release address the same Exfuse handle. The lock also keeps a
    // close/truncate from overlapping an in-flight item I/O callback.
    private let ioLock = NSLock()
    private var openState = ExfuseOpenState()

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

    func openBackend(
        modes: FSVolume.OpenModes,
        perform: (String, UInt32) throws -> UInt64?
    ) rethrows {
        try withOpenState { state in
            if state.isOpen {
                state.addRetainedModes(modes)
            } else {
                let handle = try perform(path, UInt32(modes.rawValue))
                state.opened(handle: handle, modes: modes)
            }
        }
    }

    func adoptCreatedBackendHandle(_ handle: UInt64?, modes: FSVolume.OpenModes) {
        withOpenState { state in
            state.opened(handle: handle, modes: modes)
        }
    }

    func withBackendHandle<Result>(
        _ perform: (String, UInt64) throws -> Result
    ) rethrows -> Result {
        try withOpenState { state in
            try perform(path, state.currentHandle)
        }
    }

    func closeBackend(
        keeping modes: FSVolume.OpenModes,
        perform: (String, UInt32, UInt64) throws -> Void
    ) rethrows {
        try withOpenState { state in
            state.keepModes(modes)

            guard let handle = state.handleForRelease else {
                return
            }

            try perform(path, UInt32(modes.rawValue), handle)
            state.closed()
        }
    }

    private func withOpenState<Result>(
        _ perform: (inout ExfuseOpenState) throws -> Result
    ) rethrows -> Result {
        ioLock.lock()
        defer { ioLock.unlock() }
        return try perform(&openState)
    }

    static func root() -> ExfuseItem {
        let attrs = FSItem.Attributes()
        attrs.type = .directory
        attrs.mode = UInt32(S_IFDIR | 0o755)
        attrs.linkCount = 2
        attrs.fileID = .rootDirectory
        attrs.parentID = .parentOfRoot
        attrs.flags = 0
        attrs.size = 0
        attrs.allocSize = 0
        attrs.modifyTime = currentTimespec()
        attrs.changeTime = attrs.modifyTime
        attrs.accessTime = attrs.modifyTime
        attrs.birthTime = attrs.modifyTime

        return ExfuseItem(path: "/", name: FSFileName(string: "/"), attributes: attrs)
    }
}

struct ExfuseOpenState {
    private(set) var isOpen = false
    private(set) var handle: UInt64 = 0
    private(set) var retainedModes: FSVolume.OpenModes = []

    var currentHandle: UInt64 {
        isOpen ? handle : 0
    }

    var handleForRelease: UInt64? {
        isOpen && retainedModes.isEmpty ? handle : nil
    }

    mutating func opened(handle: UInt64?, modes: FSVolume.OpenModes) {
        self.handle = handle ?? 0
        retainedModes = modes
        isOpen = true
    }

    mutating func addRetainedModes(_ modes: FSVolume.OpenModes) {
        retainedModes.formUnion(modes)
    }

    mutating func keepModes(_ modes: FSVolume.OpenModes) {
        retainedModes = modes
    }

    mutating func closed() {
        isOpen = false
        handle = 0
        retainedModes = []
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
