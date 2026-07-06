import ExtensionFoundation
import FSKit
import Foundation
import os

@main
struct ExfuseFSKitExtension: UnaryFileSystemExtension {
    var fileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {
        ExfuseFileSystem.shared
    }

    // `AppExtension.main()` throws; the synthesized @main shim would swallow the
    // error into the appex's invisible stderr and exit "voluntarily". Shadow it
    // so a launch failure lands in the unified log instead.
    static func main() {
        let log = Logger(subsystem: "ExfuseFSKit", category: "Main")
        log.notice("extension main starting")

        do {
            try runAppExtensionMain(Self.self)
            log.notice("extension main returned")
        } catch {
            log.error("extension main threw: \(String(describing: error), privacy: .public)")
        }
    }
}

// Generic funnel: inside a generic context the protocol-extension `main()` is
// statically dispatched, so this reaches ExtensionFoundation's implementation
// even though the concrete type shadows it.
private func runAppExtensionMain<T: AppExtension>(_ type: T.Type) throws {
    try type.main()
}
