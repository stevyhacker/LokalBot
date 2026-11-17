import Foundation

/// Reads Otter meetings. Not implemented yet: see Docs/development/meeting-import.md.
enum OtterMeetingReader: ExternalMeetingReader {
    static let source = ExternalMeetingSource.otter
    static let exportHint = "Importing from Otter isn't available yet."
    static let defaultLocations: [String] = []

    static func recognizes(_ url: URL) -> Bool { false }

    static func read(_ url: URL) throws -> ExternalImportScan {
        throw ExternalImportError.notImplemented(source)
    }
}
