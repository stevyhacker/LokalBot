import Foundation

/// Reads Zoom meetings. Not implemented yet: see Docs/development/meeting-import.md.
enum ZoomMeetingReader: ExternalMeetingReader {
    static let source = ExternalMeetingSource.zoom
    static let exportHint = "Importing from Zoom isn't available yet."
    static let defaultLocations: [String] = []

    static func recognizes(_ url: URL) -> Bool { false }

    static func read(_ url: URL) throws -> ExternalImportScan {
        throw ExternalImportError.notImplemented(source)
    }
}
