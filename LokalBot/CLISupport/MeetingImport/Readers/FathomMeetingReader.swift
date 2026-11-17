import Foundation

/// Reads Fathom meetings. Not implemented yet: see Docs/development/meeting-import.md.
enum FathomMeetingReader: ExternalMeetingReader {
    static let source = ExternalMeetingSource.fathom
    static let exportHint = "Importing from Fathom isn't available yet."
    static let defaultLocations: [String] = []

    static func recognizes(_ url: URL) -> Bool { false }

    static func read(_ url: URL) throws -> ExternalImportScan {
        throw ExternalImportError.notImplemented(source)
    }
}
