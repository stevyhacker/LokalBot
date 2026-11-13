import Foundation

/// The user's own quick notes taken during a meeting — a plain `notes.md`
/// beside the audio in the meeting folder. Written live by the recording
/// panel and folded into the summary + outcomes prompts as high-signal
/// context (the user typed it; the model should trust it over its own
/// paraphrase of the transcript).
enum MeetingNotes {

    static let fileName = "notes.md"

    /// The saved notes, or nil when there are none (missing file or blank).
    static func load(from folder: URL) -> String? {
        let url = folder.appendingPathComponent(fileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Best-effort save; clearing the text removes the file so empty notes
    /// never haunt the summary prompt.
    static func write(_ text: String, to folder: URL) {
        do { try writeChecked(text, to: folder) } catch { lokalbotLog("Meeting notes could not be saved: \(error.localizedDescription)") }
    }

    static func writeChecked(_ text: String, to folder: URL) throws {
        let url = folder.appendingPathComponent(fileName)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        } else {
            try Data(text.utf8).write(to: url, options: .atomic)
        }
    }

    /// Generation-context block for the summary/outcomes prompts; empty when
    /// the meeting has no notes.
    static func promptContext(in folder: URL) -> [String] {
        guard let notes = load(from: folder) else { return [] }
        return ["Notes the user typed during this meeting — high-signal, incorporate and prioritize them:\n\(notes)"]
    }
}
