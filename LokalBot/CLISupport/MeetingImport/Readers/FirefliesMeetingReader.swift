import Foundation

/// Reads Fireflies meetings. Not implemented yet: see Docs/development/meeting-import.md.
enum FirefliesMeetingReader: ExternalMeetingReader {
    static let source = ExternalMeetingSource.fireflies
    static let exportHint = "Importing from Fireflies isn't available yet."
    static let defaultLocations: [String] = []

    static func recognizes(_ url: URL) -> Bool { false }

    static func read(_ url: URL) throws -> ExternalImportScan {
        throw ExternalImportError.notImplemented(source)
    }
}
