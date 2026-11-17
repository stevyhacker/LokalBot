import Foundation

/// Reads Screenpipe meetings. Not implemented yet: see Docs/development/meeting-import.md.
enum ScreenpipeMeetingReader: ExternalMeetingReader {
    static let source = ExternalMeetingSource.screenpipe
    static let exportHint = "Importing from Screenpipe isn't available yet."
    static let defaultLocations: [String] = []

    static func recognizes(_ url: URL) -> Bool { false }

    static func read(_ url: URL) throws -> ExternalImportScan {
        throw ExternalImportError.notImplemented(source)
    }
}
