import Darwin
import Foundation

private let exfuseMagic: UInt32 = 0xC021_55AC
private let exfuseProtocolV3: UInt32 = 0x7633_0003

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

struct ExfuseDirectoryEntry {
    let name: String
    let attributes: ExfuseAttr
}

private final class ExfuseWireConnection {
    let lock = NSLock()
    var descriptor: Int32 = -1

    func invalidate() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    deinit {
        invalidate()
    }
}

final class ExfuseWireClient {
    // FSKit may invoke operations concurrently. A small fixed pool preserves
    // that parallelism while reusing localhost connections instead of putting
    // one ephemeral client port into TIME_WAIT for every filesystem callback.
    private static let connectionPoolSize = 16
    private let idLock = NSLock()
    private var nextRequestID: UInt64 = 1
    private let connections = (0..<connectionPoolSize).map { _ in ExfuseWireConnection() }
    private let poolCondition = NSCondition()
    private lazy var availableConnections = connections
    private let port: UInt16

    init(port: UInt16) {
        self.port = port
    }

    func getattr(_ path: String) throws -> ExfuseAttr {
        let response = try request(.getattr, payload: Data(path.utf8))
        return try decodeAttr(response)
    }

    func readdir(_ path: String) throws -> [ExfuseDirectoryEntry] {
        let response = try request(.readdir, payload: Data(path.utf8))
        guard response.count >= 4 else { throw posixError(EIO) }

        let count = Int(response.readUInt32(at: 0))
        var offset = 4
        var entries: [ExfuseDirectoryEntry] = []
        entries.reserveCapacity(count)

        for _ in 0..<count {
            let nameData = try takeLengthPrefixed(response, offset: &offset)
            let attrData = try takeLengthPrefixed(response, offset: &offset)

            guard let name = String(data: nameData, encoding: .utf8),
                  !name.isEmpty, name != ".", name != "..",
                  !name.contains("/"), !name.utf8.contains(0)
            else {
                throw posixError(EIO)
            }

            entries.append(ExfuseDirectoryEntry(name: name, attributes: try decodeAttr(attrData)))
        }

        guard offset == response.count else { throw posixError(EIO) }
        return entries
    }

    private func decodeAttr(_ response: Data) throws -> ExfuseAttr {
        guard response.count == 16 || response.count == 24 else {
            throw posixError(EIO)
        }

        let mode = response.readUInt32(at: 0)
        let kindValue = response.readUInt32(at: 4)
        let size = response.readUInt64(at: 8)
        let mtime = response.count == 24 ? response.readUInt64(at: 16) : nil

        guard let kind = ExfuseNodeKind(rawValue: kindValue) else {
            throw posixError(EIO)
        }

        return ExfuseAttr(mode: mode, kind: kind, size: size, mtime: mtime)
    }

    private func takeLengthPrefixed(_ data: Data, offset: inout Int) throws -> Data {
        guard offset + 4 <= data.count else { throw posixError(EIO) }
        let length = Int(data.readUInt32(at: offset))
        offset += 4
        guard length >= 0, offset + length <= data.count else { throw posixError(EIO) }
        defer { offset += length }
        return data.subdata(in: offset..<(offset + length))
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
        let requestID = allocateRequestID()
        let connection = checkoutConnection()
        defer { checkinConnection(connection) }

        var frame = Data()
        frame.appendUInt32(exfuseMagic)
        frame.appendUInt32(exfuseProtocolV3)
        frame.appendUInt32(request.rawValue)
        frame.appendUInt64(requestID)
        frame.appendUInt32(UInt32(getuid()))
        frame.appendUInt32(UInt32(getgid()))
        frame.appendUInt32(UInt32(getpid()))
        frame.appendUInt32(0)
        frame.append(payload)

        connection.lock.lock()
        defer { connection.lock.unlock() }

        let response: Data
        do {
            if connection.descriptor < 0 {
                connection.descriptor = try connect()
            }
            try writeFrame(frame, to: connection.descriptor)
            response = try readFrame(from: connection.descriptor)
        } catch {
            // Do not retry here: a stateful operation may have reached the
            // backend before the connection failed. The next callback will
            // reconnect this pool slot safely.
            connection.invalidate()
            throw error
        }

        guard response.count >= 24,
              response.readUInt32(at: 0) == exfuseMagic,
              response.readUInt32(at: 4) == exfuseProtocolV3,
              response.readUInt32(at: 8) == request.rawValue,
              response.readUInt64(at: 12) == requestID
        else {
            connection.invalidate()
            throw posixError(EIO)
        }

        let errno = response.readUInt32(at: 20)
        if errno != 0 {
            throw posixError(Int32(errno))
        }

        return response.subdata(in: 24..<response.count)
    }

    private func allocateRequestID() -> UInt64 {
        idLock.lock()
        defer { idLock.unlock() }

        let requestID = nextRequestID
        nextRequestID &+= 1
        return requestID
    }

    private func checkoutConnection() -> ExfuseWireConnection {
        poolCondition.lock()
        defer { poolCondition.unlock() }
        while availableConnections.isEmpty { poolCondition.wait() }
        return availableConnections.removeLast()
    }

    private func checkinConnection(_ connection: ExfuseWireConnection) {
        poolCondition.lock()
        availableConnections.append(connection)
        poolCondition.signal()
        poolCondition.unlock()
    }

    // A backend that accepts the connection but never replies (protocol-skewed
    // host, wedged listener) must fail bounded and loud, not block this thread
    // forever while the kernel turns the stall into EIO/EINVAL after its own
    // deadline. Generous enough for heavy projection renders.
    private static let receiveTimeout = timeval(tv_sec: 30, tv_usec: 0)
    private static let sendTimeout = timeval(tv_sec: 10, tv_usec: 0)

    private func connect() throws -> Int32 {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw posixError(errno)
        }

        var receiveTimeout = Self.receiveTimeout
        _ = setsockopt(
            socketFD, SOL_SOCKET, SO_RCVTIMEO,
            &receiveTimeout, socklen_t(MemoryLayout<timeval>.size)
        )
        var sendTimeout = Self.sendTimeout
        _ = setsockopt(
            socketFD, SOL_SOCKET, SO_SNDTIMEO,
            &sendTimeout, socklen_t(MemoryLayout<timeval>.size)
        )
        var noSigPipe: Int32 = 1
        _ = setsockopt(
            socketFD, SOL_SOCKET, SO_NOSIGPIPE,
            &noSigPipe, socklen_t(MemoryLayout<Int32>.size)
        )

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

        return socketFD
    }

    private func writeFrame(_ payload: Data, to fd: Int32) throws {
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
                    throw ioError(errno)
                }
                written += result
            }
        }
    }

    private func readFrame(from fd: Int32) throws -> Data {
        let header = try readExactly(4, from: fd)
        let length = Int(header.readUInt32(at: 0))
        if length < 0 || length > 128 * 1024 * 1024 {
            throw posixError(EIO)
        }
        return try readExactly(length, from: fd)
    }

    private func readExactly(_ count: Int, from fd: Int32) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else {
                return
            }

            var readCount = 0
            while readCount < count {
                let result = Darwin.read(fd, base.advanced(by: readCount), count - readCount)
                if result <= 0 {
                    throw ioError(errno)
                }
                readCount += result
            }
        }
        return data
    }

    // SO_RCVTIMEO/SO_SNDTIMEO expirations surface as EAGAIN; report them as
    // ETIMEDOUT so a silent backend is distinguishable from flow control.
    private func ioError(_ code: Int32) -> any Error {
        switch code {
        case EAGAIN, EWOULDBLOCK:
            return posixError(ETIMEDOUT)
        case 0:
            return posixError(EIO)
        default:
            return posixError(code)
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
