import Foundation

enum DownloadFileRescuer {
    static func install(stashed: URL, to destination: URL, fileManager: FileManager = .default) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: stashed)
        } else {
            try fileManager.moveItem(at: stashed, to: destination)
        }
    }

    static func cleanup(_ stashed: URL, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: stashed)
    }
}
