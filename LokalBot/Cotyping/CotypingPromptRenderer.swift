// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

import Foundation

enum CotypingPromptRenderer {
    struct RenderedPrompt: Equatable, Sendable {
        let prompt: String
        let conditioningPreface: String?
    }

    static let maxPrefaceCharacters = 900
    static let maxClipboardLineCharacters = 180
    static let maxLearnedExampleCharacters = 120
    static let windowLabel = "Visible in this window:"

    static func prompt(
        prefixText: String,
        surfaceLines: [String] = [],
        userName: String? = nil,
        styleNote: String? = nil,
        languageHint: String? = nil,
        extendedContext: String? = nil,
        clipboardContext: String? = nil,
        memoryContext: String? = nil,
        visibleContext: String? = nil,
        windowContext: String? = nil,
        learnedExamples: [String] = []
    ) -> String {
        render(
            prefixText: prefixText,
            surfaceLines: surfaceLines,
            userName: userName,
            styleNote: styleNote,
            languageHint: languageHint,
            extendedContext: extendedContext,
            clipboardContext: clipboardContext,
            memoryContext: memoryContext,
            visibleContext: visibleContext,
            windowContext: windowContext,
            learnedExamples: learnedExamples).prompt
    }

    static func render(
        prefixText: String,
        surfaceLines: [String] = [],
        userName: String? = nil,
        styleNote: String? = nil,
        languageHint: String? = nil,
        extendedContext: String? = nil,
        clipboardContext: String? = nil,
        memoryContext: String? = nil,
        visibleContext: String? = nil,
        windowContext: String? = nil,
        learnedExamples: [String] = []
    ) -> RenderedPrompt {
        let prefix = prefixText

        let window = nonEmpty(windowContext).map {
            "\(windowLabel)\n\(PromptContextSanitizer.sanitize($0, maxCharacters: CotypingWindowText.maximumCharacters))"
        }
        var leading: [String] = []
        let memoryLimit: Int
        if window != nil {
            leading = surfaceLines
            memoryLimit = 180
        } else if let visible = nonEmpty(visibleContext) {
            leading.append("Current visible text above the field: \(PromptContextSanitizer.sanitize(visible, maxCharacters: 420))")
            leading.append(contentsOf: surfaceLines)
            memoryLimit = 180
        } else {
            leading = surfaceLines
            memoryLimit = 360
        }
        var profile: [String] = []
        if let persona = personaLine(userName) { profile.append(persona) }
        if let style = styleLine(styleNote) { profile.append(style) }
        if let language = nonEmpty(languageHint) { profile.append(language) }
        if let notes = nonEmpty(extendedContext) {
            profile.append("Notes the writer keeps in mind: \(String(notes.prefix(300)))")
        }
        let memoryLine = nonEmpty(memoryContext).map {
            "Relevant saved facts: \(PromptContextSanitizer.sanitize($0, maxCharacters: memoryLimit))"
        }
        var trailing: [String] = []
        for example in learnedExamples {
            if let example = nonEmpty(example) {
                trailing.append("Previously accepted completion: \(String(example.prefix(maxLearnedExampleCharacters)))")
            }
        }
        if let clip = nonEmpty(clipboardContext) {
            trailing.append("On the clipboard: \(String(clip.prefix(maxClipboardLineCharacters)))")
        }

        let hasPreface = !leading.isEmpty || !profile.isEmpty || memoryLine != nil || !trailing.isEmpty
        guard window != nil || hasPreface else {
            return RenderedPrompt(prompt: prefix, conditioningPreface: nil)
        }

        var prefaceText = boundedPreface(leading: leading, profile: profile, memory: memoryLine, trailing: trailing)
        if let window {
            prefaceText = prefaceText.isEmpty ? window : window + "\n\n" + prefaceText
        }
        return RenderedPrompt(
            prompt: prefaceText + "\n\n" + prefix,
            conditioningPreface: prefaceText)
    }

    private static func boundedPreface(
        leading: [String],
        profile: [String],
        memory: String?,
        trailing: [String]
    ) -> String {
        let all = leading + profile + (memory.map { [$0] } ?? []) + trailing
        let joined = all.joined(separator: "\n")
        guard joined.count > maxPrefaceCharacters, let memory else {
            return String(joined.prefix(maxPrefaceCharacters))
        }
        let leadingText = leading.joined(separator: "\n")
        let profileText = profile.joined(separator: "\n")
        let reserved = (leadingText.isEmpty ? 0 : leadingText.count + 1) + memory.count
        var parts: [String] = []
        if !leadingText.isEmpty { parts.append(leadingText) }
        if !profileText.isEmpty, reserved < maxPrefaceCharacters {
            let profileBudget = maxPrefaceCharacters - reserved - 1
            if profileBudget > 0 {
                parts.append(String(profileText.prefix(profileBudget)))
            }
        }
        parts.append(memory)
        let core = parts.joined(separator: "\n")
        if core.count >= maxPrefaceCharacters || trailing.isEmpty {
            return String(core.prefix(maxPrefaceCharacters))
        }
        let trailingText = trailing.joined(separator: "\n")
        let remaining = maxPrefaceCharacters - core.count - 1
        guard remaining > 0 else { return core }
        return core + "\n" + String(trailingText.prefix(remaining))
    }

    private static func personaLine(_ userName: String?) -> String? {
        guard let name = nonEmpty(userName) else { return nil }
        return "Written by \(name)."
    }

    private static func styleLine(_ note: String?) -> String? {
        guard let note = nonEmpty(note) else { return nil }
        return "Writing style: \(note)."
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func trimmingTrailingWhitespace(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let prev = text.index(before: end)
            if text[prev].isWhitespace { end = prev } else { break }
        }
        return String(text[text.startIndex..<end])
    }
}
