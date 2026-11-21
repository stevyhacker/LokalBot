import Foundation

enum MeetingNotes {

    static let fileName = "notes.md"

    static func load(from folder: URL) -> String? {
        let url = folder.appendingPathComponent(fileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

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

    static func promptContext(in folder: URL) -> [String] {
        guard let notes = load(from: folder) else { return [] }
        return ["Notes the user typed during this meeting — high-signal, incorporate and prioritize them:\n\(notes)"]
    }
}
