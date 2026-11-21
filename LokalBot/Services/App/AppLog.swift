import Foundation
import Logging

enum AppLog {
    private static let bootstrapLock = NSLock()
    private nonisolated(unsafe) static var didBootstrap = false

    static func bootstrap() {
        bootstrapLock.lock()
        defer { bootstrapLock.unlock() }
        guard !didBootstrap else { return }
        didBootstrap = true

        let sink = FileLogSink(fileURL: debugLogURL())
        LoggingSystem.bootstrap { label in
            MultiplexLogHandler([
                StreamLogHandler.standardOutput(label: label),
                FileLogHandler(label: label, sink: sink),
            ])
        }
    }

    static func category(_ name: String) -> Logging.Logger {
        Logging.Logger(label: "\(AppIdentifiers.bundleID).\(name)")
    }

    static func line(_ message: String) {
        category("app").info("\(message)")
    }

    static func debugLogURL() -> URL {
        AppDirectories.libraryRoot.appendingPathComponent("debug.log", isDirectory: false)
    }
}
