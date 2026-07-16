import Darwin
import Dispatch
import FSKit
import Foundation

enum LifecycleTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw LifecycleTestFailure.failed(message)
    }
}

final class FakeWireServer: @unchecked Sendable {
    private static let magic: UInt32 = 0xC021_55AC
    private static let protocolV3: UInt32 = 0x7633_0003

    let port: UInt16

    private let listenDescriptor: Int32
    private let expectedRequests: Int
    private let completion = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var serverError: String?
    private var openCount = 0
    private var writeHandles: [UInt64] = []
    private var releaseHandles: [UInt64] = []

    init(expectedRequests: Int) throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw LifecycleTestFailure.failed("fake wire socket failed: \(errno)")
        }

        var reuse: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0, Darwin.listen(descriptor, 1) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw LifecycleTestFailure.failed("fake wire bind/listen failed: \(code)")
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.getsockname(descriptor, socketAddress, &boundLength)
            }
        }

        guard nameResult == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw LifecycleTestFailure.failed("fake wire getsockname failed: \(code)")
        }

        listenDescriptor = descriptor
        port = UInt16(bigEndian: boundAddress.sin_port)
        self.expectedRequests = expectedRequests

        DispatchQueue.global().async { [self] in
            serve()
        }
    }

    func wait() throws {
        guard completion.wait(timeout: .now() + 5) == .success else {
            throw LifecycleTestFailure.failed("fake wire server timed out")
        }

        if let serverError = stateLock.withLock({ serverError }) {
            throw LifecycleTestFailure.failed(serverError)
        }
    }

    func snapshot() -> (opens: Int, writes: [UInt64], releases: [UInt64]) {
        stateLock.withLock {
            (openCount, writeHandles, releaseHandles)
        }
    }

    private func serve() {
        var clientDescriptor: Int32 = -1

        do {
            clientDescriptor = Darwin.accept(listenDescriptor, nil, nil)
            guard clientDescriptor >= 0 else {
                throw LifecycleTestFailure.failed("fake wire accept failed: \(errno)")
            }

            for _ in 0..<expectedRequests {
                let request = try readFrame(from: clientDescriptor)
                let response = try response(for: request)
                try writeFrame(response, to: clientDescriptor)
            }
        } catch {
            stateLock.withLock {
                serverError = "fake wire server failed: \(error)"
            }
        }

        if clientDescriptor >= 0 {
            Darwin.close(clientDescriptor)
        }
        Darwin.close(listenDescriptor)
        completion.signal()
    }

    private func response(for request: Data) throws -> Data {
        guard request.count >= 36,
              request.readUInt32(at: 0) == Self.magic,
              request.readUInt32(at: 4) == Self.protocolV3
        else {
            throw LifecycleTestFailure.failed("fake wire received an invalid request header")
        }

        let operation = request.readUInt32(at: 8)
        let requestID = request.readUInt64(at: 12)
        var payload = Data()

        switch operation {
        case ExfuseRequest.open.rawValue:
            stateLock.withLock {
                openCount += 1
            }
            payload.appendUInt64(41)

        case ExfuseRequest.write.rawValue:
            guard request.count >= 56 else {
                throw LifecycleTestFailure.failed("fake wire received a short write request")
            }

            let handle = request.readUInt64(at: 36)
            let pathLength = Int(request.readUInt32(at: 52))
            let dataOffset = 56 + pathLength
            guard dataOffset <= request.count else {
                throw LifecycleTestFailure.failed("fake wire received an invalid write path")
            }

            stateLock.withLock {
                writeHandles.append(handle)
            }
            payload.appendUInt32(UInt32(request.count - dataOffset))

        case ExfuseRequest.release.rawValue:
            guard request.count >= 48 else {
                throw LifecycleTestFailure.failed("fake wire received a short release request")
            }

            let handle = request.readUInt64(at: 40)
            stateLock.withLock {
                releaseHandles.append(handle)
            }

        default:
            throw LifecycleTestFailure.failed("fake wire received unexpected operation \(operation)")
        }

        var response = Data()
        response.appendUInt32(Self.magic)
        response.appendUInt32(Self.protocolV3)
        response.appendUInt32(operation)
        response.appendUInt64(requestID)
        response.appendUInt32(0)
        response.append(payload)
        return response
    }

    private func readFrame(from descriptor: Int32) throws -> Data {
        let header = try readExactly(4, from: descriptor)
        return try readExactly(Int(header.readUInt32(at: 0)), from: descriptor)
    }

    private func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else {
                return
            }

            var readCount = 0
            while readCount < count {
                let result = Darwin.read(descriptor, base.advanced(by: readCount), count - readCount)
                guard result > 0 else {
                    throw LifecycleTestFailure.failed("fake wire read failed: \(errno)")
                }
                readCount += result
            }
        }
        return data
    }

    private func writeFrame(_ payload: Data, to descriptor: Int32) throws {
        var frame = Data()
        frame.appendUInt32(UInt32(payload.count))
        frame.append(payload)

        try frame.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else {
                return
            }

            var written = 0
            while written < buffer.count {
                let result = Darwin.write(descriptor, base.advanced(by: written), buffer.count - written)
                guard result > 0 else {
                    throw LifecycleTestFailure.failed("fake wire write failed: \(errno)")
                }
                written += result
            }
        }
    }
}

@main
struct FSKitHandleLifecycleTest {
    static func main() async throws {
        try await volumePropagatesHandleOverWire()
        try retainedCloseKeepsOneHandle()
        try createdHandleIsPropagated()
        try handlelessBackendKeepsPathFallback()
    }

    private static func volumePropagatesHandleOverWire() async throws {
        let server = try FakeWireServer(expectedRequests: 4)
        let volume = ExfuseVolume(port: server.port, volumeUUID: UUID())
        let item = ExfuseItem.root()

        try await volume.openItem(item, modes: [.read])
        try await volume.openItem(item, modes: [.write])
        _ = try await volume.write(contents: Data("first".utf8), to: item, at: 0)
        try await volume.closeItem(item, modes: [.write])
        _ = try await volume.write(contents: Data("second".utf8), to: item, at: 5)
        try await volume.closeItem(item, modes: [])

        try server.wait()
        let snapshot = server.snapshot()
        try expect(snapshot.opens == 1, "FSKit volume opened more than one backend handle")
        try expect(snapshot.writes == [41, 41], "FSKit volume did not propagate the opened handle to writes")
        try expect(snapshot.releases == [41], "FSKit volume did not release the opened handle exactly once")
    }

    private static func retainedCloseKeepsOneHandle() throws {
        let item = ExfuseItem.root()
        var opens: [(UInt32, UInt64)] = []
        var releases: [(UInt32, UInt64)] = []

        item.openBackend(modes: [.read]) { _, flags in
            opens.append((flags, 41))
            return 41
        }

        try item.openBackend(modes: [.write]) { _, _ in
            throw LifecycleTestFailure.failed("an already-open item reopened its backend handle")
        }

        try expect(opens.count == 1, "the aggregate FSKit open lifecycle created multiple handles")
        try expect(item.withBackendHandle { _, handle in handle } == 41, "read/write did not see the opened handle")

        item.closeBackend(keeping: [.write]) { _, flags, handle in
            releases.append((flags, handle))
        }

        try expect(releases.isEmpty, "a partial close released the retained backend handle")
        try expect(item.withBackendHandle { _, handle in handle } == 41, "a partial close cleared the retained handle")

        item.closeBackend(keeping: []) { _, flags, handle in
            releases.append((flags, handle))
        }

        try expect(releases.count == 1, "the full close did not release exactly once")
        try expect(releases[0].0 == 0, "the full close sent nonempty retained modes as release flags")
        try expect(releases[0].1 == 41, "the full close released the wrong handle")
        try expect(item.withBackendHandle { _, handle in handle } == 0, "the full close retained a stale handle")
    }

    private static func createdHandleIsPropagated() throws {
        let item = ExfuseItem.root()
        var released: UInt64?

        item.adoptCreatedBackendHandle(84, modes: [.read, .write])
        try expect(item.withBackendHandle { _, handle in handle } == 84, "create did not install its returned handle")

        item.closeBackend(keeping: [.read]) { _, _, handle in
            released = handle
        }
        try expect(released == nil, "create handle was released while read access remained")

        item.closeBackend(keeping: []) { _, _, handle in
            released = handle
        }
        try expect(released == 84, "create handle was not propagated to final release")
    }

    private static func handlelessBackendKeepsPathFallback() throws {
        let item = ExfuseItem.root()
        var released: UInt64?

        item.openBackend(modes: [.read]) { _, _ in nil }
        try expect(item.withBackendHandle { _, handle in handle } == 0, "handleless open did not use path handle zero")

        item.closeBackend(keeping: []) { _, _, handle in
            released = handle
        }
        try expect(released == 0, "handleless open was not paired with a path-based release")
    }
}
