import FSKit
import Foundation

@main
struct ExfuseFSKitExtension: UnaryFileSystemExtension {
    var fileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {
        ExfuseFileSystem.shared
    }
}

