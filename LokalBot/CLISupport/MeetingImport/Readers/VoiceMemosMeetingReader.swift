import Foundation

/// Reads Voice Memos meetings. Not implemented yet: see Docs/development/meeting-import.md.
enum VoiceMemosMeetingReader: ExternalMeetingReader {
    static let source = ExternalMeetingSource.voiceMemos
    static let exportHint = "Importing from Voice Memos isn't available yet."
    static let defaultLocations: [String] = []

    static func recognizes(_ url: URL) -> Bool { false }

    static func read(_ url: URL) throws -> ExternalImportScan {
        throw ExternalImportError.notImplemented(source)
    }
}
