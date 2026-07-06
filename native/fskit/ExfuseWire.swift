import Darwin
import Foundation

private let exfuseMagic: UInt32 = 0xC021_55AC

enum ExfuseRequest: UInt32 {
    case readdir = 3
    case getattr = 4
    case readlink = 5
    case read = 6
    case write = 7
    case open = 8
    case create = 9
    case truncate = 10
    case unlink = 11
    case rename = 12
    case mkdir = 13
    case rmdir = 14
    case chmod = 15
    case chown = 16
    case flush = 17
    case release = 18
    case fsync = 19
}

enum ExfuseNodeKind: UInt32 {
    case directory = 1
    case file = 2
    case symlink = 3
}

struct ExfuseAttr {
    let mode: UInt32
    let kind: ExfuseNodeKind
    let size: UInt64

    // Optional extended form: a backend-supplied mtime that changes when the
    // (projected) content changes, so the kernel revalidates cached data.
    let mtime: UInt64?
}

final class ExfuseWireClient {
    static let shared = ExfuseWireClient()

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var port: UInt16 = 35368

    func configure(port: UInt16) {
        lock.lock()
        defer { lock.unlock() }

        self.port = port
        closeLocked()
    }

    func getattr(_ path: String) throws -> ExfuseAttr {
        let response = try request(.getattr, payload: Data(path.utf8))
        guard response.count == 12 || response.count == 20 else {
            throw posixError(EIO)
        }

        let mode = response.readUInt32(at: 0)
        let kindValue = response.readUInt32(at: 4)
        let size = UInt64(response.readUInt32(at: 8))
        let mtime = response.count == 20 ? response.readUInt64(at: 12) : nil

        guard let kind = ExfuseNodeKind(rawValue: kindValue) else {
            throw posixError(EIO)
        }

        return ExfuseAttr(mode: mode, kind: kind, size: size, mtime: mtime)
    }

    func readdir(_ path: String) throws -> [String] {
        let response = try request(.readdir, payload: Data(path.utf8))

        return response.split(separator: 0)
            .filter { !$0.isEmpty }
            .map { String(decoding: $0, as: UTF8.self) }
    }

    func readlink(_ path: String) throws -> String {
        var response = try request(.readlink, payload: Data(path.utf8))
        if response.last == 0 {
            response.removeLast()
        }
        return String(decoding: response, as: UTF8.self)
    }

    func read(path: String, flags: UInt32 = 0, handle: UInt64 = 0, offset: UInt64, size: UInt64) throws -> Data {
        var payload = Data()
        payload.appendUInt32(flags)
        payload.appendUInt64(handle)
        payload.appendUInt64(offset)
        payload.appendUInt64(size)
        payload.appendPath(path)
        return try request(.read, payload: payload)
    }

    func write(path: String, handle: UInt64 = 0, offset: UInt64, data: Data) throws -> Int {
        var payload = Data()
        payload.appendUInt64(handle)
        payload.appendUInt64(offset)
        payload.appendPath(path)
        payload.append(data)

        let response = try request(.write, payload: payload)
        guard response.count == 4 else {
            throw posixError(EIO)
        }
        return Int(response.readUInt32(at: 0))
    }

    func open(path: String, flags: UInt32) throws -> UInt64? {
        try optionalHandle(.open, path: path, firstValue: flags)
    }

    func create(path: String, mode: UInt32, flags: UInt32) throws -> UInt64? {
        var payload = Data()
        payload.appendUInt32(mode)
        payload.appendUInt32(flags)
        payload.appendPath(path)
        let response = try request(.create, payload: payload)
        return try parseOptionalHandle(response)
    }

    func truncate(path: String, size: UInt64) throws {
        var payload = Data()
        payload.appendUInt64(size)
        payload.appendPath(path)
        try empty(.truncate, payload: payload)
    }

    func unlink(_ path: String) throws {
        try empty(.unlink, payload: Data(path.utf8))
    }

    func rmdir(_ path: String) throws {
        try empty(.rmdir, payload: Data(path.utf8))
    }

    func rename(from: String, to: String) throws {
        var payload = Data()
        payload.appendUInt32(0)
        payload.appendPath(from)
        payload.appendPath(to)
        try empty(.rename, payload: payload)
    }

    func mkdir(path: String, mode: UInt32) throws {
        try pathUInt32(.mkdir, path: path, value: mode)
    }

    func chmod(path: String, mode: UInt32) throws {
        try pathUInt32(.chmod, path: path, value: mode)
    }

    func chown(path: String, uid: UInt32, gid: UInt32) throws {
        var payload = Data()
        payload.appendUInt32(uid)
        payload.appendUInt32(gid)
        payload.appendPath(path)
        try empty(.chown, payload: payload)
    }

    func flush(path: String, flags: UInt32 = 0, handle: UInt64 = 0) throws {
        try pathHandle(.flush, path: path, flags: flags, handle: handle)
    }

    func release(path: String, flags: UInt32 = 0, handle: UInt64 = 0) throws {
        try pathHandle(.release, path: path, flags: flags, handle: handle)
    }

    func fsync(path: String, datasync: Bool = false, flags: UInt32 = 0, handle: UInt64 = 0) throws {
        var payload = Data()
        payload.appendUInt32(datasync ? 1 : 0)
        payload.appendUInt32(flags)
        payload.appendUInt64(handle)
        payload.appendPath(path)
        try empty(.fsync, payload: payload)
    }

    private func optionalHandle(_ request: ExfuseRequest, path: String, firstValue: UInt32) throws -> UInt64? {
        var payload = Data()
        payload.appendUInt32(firstValue)
        payload.appendPath(path)
        return try parseOptionalHandle(try self.request(request, payload: payload))
    }

    private func parseOptionalHandle(_ response: Data) throws -> UInt64? {
        if response.isEmpty {
            return nil
        }
        guard response.count == 8 else {
            throw posixError(EIO)
        }
        return response.readUInt64(at: 0)
    }

    private func pathUInt32(_ request: ExfuseRequest, path: String, value: UInt32) throws {
        var payload = Data()
        payload.appendUInt32(value)
        payload.appendPath(path)
        try empty(request, payload: payload)
    }

    private func pathHandle(_ request: ExfuseRequest, path: String, flags: UInt32, handle: UInt64) throws {
        var payload = Data()
        payload.appendUInt32(flags)
        payload.appendUInt64(handle)
        payload.appendPath(path)
        try empty(request, payload: payload)
    }

    private func empty(_ request: ExfuseRequest, payload: Data) throws {
        let response = try self.request(request, payload: payload)
        if !response.isEmpty {
            throw posixError(EIO)
        }
    }

    private func request(_ request: ExfuseRequest, payload: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        try connectLocked()

        var frame = Data()
        frame.appendUInt32(exfuseMagic)
        frame.appendUInt32(request.rawValue)
        frame.appendUInt32(UInt32(getuid()))
        frame.appendUInt32(UInt32(getgid()))
        frame.appendUInt32(UInt32(getpid()))
        frame.appendUInt32(0)
        frame.append(payload)

        try writeFrameLocked(frame)
        let response = try readFrameLocked()

        guard response.count >= 12,
              response.readUInt32(at: 0) == exfuseMagic,
              response.readUInt32(at: 4) == request.rawValue
        else {
            throw posixError(EIO)
        }

        let errno = response.readUInt32(at: 8)
        if errno != 0 {
            throw posixError(Int32(errno))
        }

        return response.subdata(in: 12..<response.count)
    }

    private func connectLocked() throws {
        if fd >= 0 {
            return
        }

        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw posixError(errno)
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if result != 0 {
            let code = errno
            close(socketFD)
            throw posixError(code)
        }

        fd = socketFD
    }

    private func writeFrameLocked(_ payload: Data) throws {
        var frame = Data()
        frame.appendUInt32(UInt32(payload.count))
        frame.append(payload)
        try frame.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else {
                return
            }

            var written = 0
            while written < buffer.count {
                let result = Darwin.write(fd, base.advanced(by: written), buffer.count - written)
                if result <= 0 {
                    let code = errno
                    closeLocked()
                    throw posixError(code == 0 ? EIO : code)
                }
                written += result
            }
        }
    }

    private func readFrameLocked() throws -> Data {
        let header = try readExactlyLocked(4)
        let length = Int(header.readUInt32(at: 0))
        if length < 0 || length > 128 * 1024 * 1024 {
            closeLocked()
            throw posixError(EIO)
        }
        return try readExactlyLocked(length)
    }

    private func readExactlyLocked(_ count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else {
                return
            }

            var readCount = 0
            while readCount < count {
                let result = Darwin.read(fd, base.advanced(by: readCount), count - readCount)
                if result <= 0 {
                    let code = errno
                    closeLocked()
                    throw posixError(code == 0 ? EIO : code)
                }
                readCount += result
            }
        }
        return data
    }

    private func closeLocked() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }
}

extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    mutating func appendUInt64(_ value: UInt64) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    mutating func appendPath(_ path: String) {
        let data = Data(path.utf8)
        appendUInt32(UInt32(data.count))
        append(data)
    }

    func readUInt32(at offset: Int) -> UInt32 {
        precondition(offset + 4 <= count)
        var value: UInt32 = 0
        for byte in self[offset..<(offset + 4)] {
            value = (value << 8) | UInt32(byte)
        }
        return value
    }

    func readUInt64(at offset: Int) -> UInt64 {
        precondition(offset + 8 <= count)
        var value: UInt64 = 0
        for byte in self[offset..<(offset + 8)] {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }
}
