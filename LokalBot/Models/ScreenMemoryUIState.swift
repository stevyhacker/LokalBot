import Foundation

/// A screen result explicitly attached to the next Ask question. Keeping the
/// OCR excerpt with the stable snapshot id avoids a second text query and lets
/// the local text model reason over the selected pixels' captured text.
struct ScreenAskContext: Equatable, Identifiable {
    let snapshotID: Int64
    let timestamp: Date
    let app: String
    let windowTitle: String
    let snippet: String

    var id: Int64 { snapshotID }

    init(hit: ActivityStore.OCRHit) {
        snapshotID = hit.snapshotID
        timestamp = hit.ts
        app = hit.app
        windowTitle = hit.windowTitle
        snippet = hit.snippet
    }

    init(screenshot: ActivityStore.Screenshot, ocrText: String) {
        snapshotID = screenshot.id
        timestamp = screenshot.ts
        app = screenshot.app
        windowTitle = screenshot.windowTitle
        snippet = ocrText
    }

    /// Adds primary-evidence context for the model while the UI can still show
    /// only the user's concise question in the transcript.
    static func withinDay(_ contexts: [Self], day: Date?, calendar: Calendar = .current) -> [Self] {
        guard let day else { return contexts }
        return contexts.filter { calendar.isDate($0.timestamp, inSameDayAs: day) }
    }

    static func prompt(question: String, contexts: [ScreenAskContext]) -> String {
        guard !contexts.isEmpty else { return question }
        let sources = contexts.map { context in
            let window = context.windowTitle.isEmpty ? "" : " — \(clean(context.windowTitle))"
            return "- [screen:\(context.snapshotID)] \(context.app)\(window), "
                + "\(context.timestamp.formatted(date: .abbreviated, time: .shortened))\n"
                + "  Captured text: \(clean(context.snippet))"
        }.joined(separator: "\n")
        return """
        Screen context explicitly selected by the user. Treat it as primary evidence and use the exact [screen:ID] marker when citing it:
        \(sources)

        Question: \(question)
        """
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "«", with: "")
            .replacingOccurrences(of: "»", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
