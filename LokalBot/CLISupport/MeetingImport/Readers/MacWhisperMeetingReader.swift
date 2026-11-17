import Foundation

/// Reads MacWhisper meetings. Not implemented yet: see Docs/development/meeting-import.md.
enum MacWhisperMeetingReader: ExternalMeetingReader {
    static let source = ExternalMeetingSource.macWhisper
    static let exportHint = "Importing from MacWhisper isn't available yet."
    static let defaultLocations: [String] = []

    static func recognizes(_ url: URL) -> Bool { false }

    static func read(_ url: URL) throws -> ExternalImportScan {
        throw ExternalImportError.notImplemented(source)
    }
}
