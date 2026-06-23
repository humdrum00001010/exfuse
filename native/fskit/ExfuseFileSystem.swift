import FSKit
import Foundation
import os

final class ExfuseFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    static let shared = ExfuseFileSystem()

    private let log = Logger(subsystem: "ExfuseFSKit", category: "FileSystem")

    private override init() {
        super.init()
        ExfuseWireClient.shared.configure(port: Bundle.main.exfuseBackendPort)
    }

    func probeResource(
        resource: FSResource,
        replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void
    ) {
        log.debug("probeResource")
        let volumeID = FSContainerIdentifier(uuid: Bundle.main.exfuseVolumeUUID)
        replyHandler(FSProbeResult.usable(name: "exfuse", containerID: volumeID), nil)
    }

    func loadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler: @escaping (FSVolume?, (any Error)?) -> Void
    ) {
        log.debug("loadResource")
        containerStatus = .ready
        replyHandler(ExfuseVolume(), nil)
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

