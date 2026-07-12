import FSKit
import Foundation
import os

final class ExfuseFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    static let shared = ExfuseFileSystem()

    private let log = Logger(subsystem: "ExfuseFSKit", category: "FileSystem")

    private override init() {
        super.init()
    }

    func probeResource(
        resource: FSResource,
        replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void
    ) {
        log.debug("probeResource")
        let volumeID = FSContainerIdentifier(uuid: resourceUUID(resource))
        replyHandler(FSProbeResult.usable(name: "exfuse", containerID: volumeID), nil)
    }

    func loadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler: @escaping (FSVolume?, (any Error)?) -> Void
    ) {
        log.debug("loadResource")
        containerStatus = .ready
        replyHandler(
            ExfuseVolume(port: wirePort(from: resource), volumeUUID: resourceUUID(resource)),
            nil
        )
    }

    // The default mount resource is `exfuse://127.0.0.1:<port>` — the wire
    // listener address travels in the URL. Block-device mounts keep the
    // Info.plist port.
    private func wirePort(from resource: FSResource) -> UInt16 {
        guard
            let urlResource = resource as? FSGenericURLResource,
            let port = urlResource.url.port,
            port > 0, port <= 65_535
        else {
            return Bundle.main.exfuseBackendPort
        }

        return UInt16(port)
    }

    private func resourceUUID(_ resource: FSResource) -> UUID {
        guard let urlResource = resource as? FSGenericURLResource else {
            return Bundle.main.exfuseVolumeUUID
        }

        let bytes = Array(urlResource.url.absoluteString.utf8)
        let first = fnv1a(bytes, seed: 0xcbf29ce484222325)
        let second = fnv1a(bytes.reversed(), seed: 0x84222325cbf29ce4)

        return UUID(uuid: (
            UInt8(truncatingIfNeeded: first >> 56), UInt8(truncatingIfNeeded: first >> 48),
            UInt8(truncatingIfNeeded: first >> 40), UInt8(truncatingIfNeeded: first >> 32),
            UInt8(truncatingIfNeeded: first >> 24), UInt8(truncatingIfNeeded: first >> 16),
            UInt8(truncatingIfNeeded: first >> 8), UInt8(truncatingIfNeeded: first),
            UInt8(truncatingIfNeeded: second >> 56), UInt8(truncatingIfNeeded: second >> 48),
            UInt8(truncatingIfNeeded: second >> 40), UInt8(truncatingIfNeeded: second >> 32),
            UInt8(truncatingIfNeeded: second >> 24), UInt8(truncatingIfNeeded: second >> 16),
            UInt8(truncatingIfNeeded: second >> 8), UInt8(truncatingIfNeeded: second)
        ))
    }

    private func fnv1a<S: Sequence>(_ bytes: S, seed: UInt64) -> UInt64 where S.Element == UInt8 {
        var hash = seed
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    func unloadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler: @escaping ((any Error)?) -> Void
    ) {
        log.debug("unloadResource")
        replyHandler(nil)
    }

    func didFinishLoading() {
        log.debug("didFinishLoading")
    }
}

extension Bundle {
    var exfuseBackendPort: UInt16 {
        guard
            let config = infoDictionary?["Configuration"] as? [String: Any],
            let raw = config["backendPort"]
        else {
            return 35368
        }

        let value: Int?
        if let number = raw as? NSNumber {
            value = number.intValue
        } else if let string = raw as? String {
            value = Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            value = nil
        }

        guard let port = value, port > 0, port <= 65_535 else {
            return 35368
        }

        return UInt16(port)
    }

    var exfuseVolumeUUID: UUID {
        if
            let config = infoDictionary?["Configuration"] as? [String: Any],
            let raw = config["volumeUUID"] as? String,
            let uuid = UUID(uuidString: raw)
        {
            return uuid
        }

        return UUID(uuidString: "A9367419-7557-4CA7-B671-95B28F7DA15B")!
    }
}
