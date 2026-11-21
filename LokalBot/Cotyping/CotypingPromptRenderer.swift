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
        var preface: [String] = []
        if window != nil {
            preface = surfaceLines
            if let memory = nonEmpty(memoryContext) {
                preface.append("Relevant saved facts: \(PromptContextSanitizer.sanitize(memory, maxCharacters: 180))")
            }
        } else if let visible = nonEmpty(visibleContext) {
            preface.append("Current visible text above the field: \(PromptContextSanitizer.sanitize(visible, maxCharacters: 420))")
            preface.append(contentsOf: surfaceLines)
            if let memory = nonEmpty(memoryContext) {
                preface.append("Relevant saved facts: \(PromptContextSanitizer.sanitize(memory, maxCharacters: 180))")
            }
        } else {
            preface = surfaceLines
            if let memory = nonEmpty(memoryContext) {
                preface.append("Relevant saved facts: \(PromptContextSanitizer.sanitize(memory, maxCharacters: 360))")
            }
        }
        if let persona = personaLine(userName) { preface.append(persona) }
        if let style = styleLine(styleNote) { preface.append(style) }
        if let language = nonEmpty(languageHint) { preface.append(language) }
        if let notes = nonEmpty(extendedContext) {
            preface.append("Notes the writer keeps in mind: \(String(notes.prefix(300)))")
        }
        for example in learnedExamples {
            if let example = nonEmpty(example) {
                preface.append("Previously accepted completion: \(String(example.prefix(maxLearnedExampleCharacters)))")
            }
        }
        if let clip = nonEmpty(clipboardContext) {
            preface.append("On the clipboard: \(String(clip.prefix(maxClipboardLineCharacters)))")
        }

        guard window != nil || !preface.isEmpty else {
            return RenderedPrompt(prompt: prefix, conditioningPreface: nil)
        }

        var prefaceText = preface.joined(separator: "\n")
        if prefaceText.count > maxPrefaceCharacters {
            prefaceText = String(prefaceText.prefix(maxPrefaceCharacters))
        }
        if let window {
            prefaceText = prefaceText.isEmpty ? window : window + "\n\n" + prefaceText
        }
        return RenderedPrompt(
            prompt: prefaceText + "\n\n" + prefix,
            conditioningPreface: prefaceText)
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
