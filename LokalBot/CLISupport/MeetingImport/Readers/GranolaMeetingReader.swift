import Foundation

/// Reads Granola meetings. Not implemented yet: see Docs/development/meeting-import.md.
enum GranolaMeetingReader: ExternalMeetingReader {
    static let source = ExternalMeetingSource.granola
    static let exportHint = "Importing from Granola isn't available yet."
    static let defaultLocations: [String] = []

    static func recognizes(_ url: URL) -> Bool { false }

    static func read(_ url: URL) throws -> ExternalImportScan {
        throw ExternalImportError.notImplemented(source)
    }
}
