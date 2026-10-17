import Foundation

/// Keeps outcome sections in `summary.md` aligned with the grounded artifact
/// used by the Decisions and Action items cards. The narrative model still
/// owns the recap, but it cannot independently invent or omit outcomes.
enum MeetingSummaryOutcomeSynchronizer {
    private static let decisionsHeading = "## Decisions"
    private static let actionItemsHeading = "## Action items"

    private struct MarkdownBlock {
        var heading: String?
        var lines: [String]
    }

    /// A failed regeneration may still produce verified outcomes. Keep an
    /// earlier recap aligned with the cards, but never manufacture a completed
    /// summary when only the independent outcomes pass succeeded.
    static func synchronizeExisting(in folder: URL, outcomes: MeetingOutcomes, template: NoteTemplate) throws {
        let url = folder.appendingPathComponent("summary.md")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let previous = try String(contentsOf: url, encoding: .utf8)
        let updated = synchronize(previous, outcomes: outcomes, template: template)
        try Data(updated.utf8).write(to: url, options: .atomic)
    }

    /// A correction to an action's owner, text, or due date changes only the
    /// action list. A summary rendered from claims keeps the rest: each line
    /// is reported speech whose speaker comes from the transcript, which a
    /// correction leaves unchanged. Returns false when the saved summary has
    /// no claims behind it, so its prose may still name the old owner.
    static func applyActionCorrections(in folder: URL, outcomes: MeetingOutcomes) throws -> Bool {
        let url = folder.appendingPathComponent("summary.md")
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("summary-claims.json").path),
              let previous = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let updated = synchronize(previous, outcomes: outcomes, controlling: [actionItemsHeading])
        if updated != previous { try Data(updated.utf8).write(to: url, options: .atomic) }
        return true
    }

    static func synchronize(
        _ summary: String,
        outcomes: MeetingOutcomes,
        template: NoteTemplate
    ) -> String {
        synchronize(
            summary,
            outcomes: outcomes,
            controlling: template == .meeting ? [decisionsHeading, actionItemsHeading] : [actionItemsHeading])
    }

    /// The summary with its action list replaced by `lines`. Meeting note
    /// exports use it to show corrections and completed actions, which
    /// `summary.md` does not record.
    static func replacingActionItems(in summary: String, with lines: [String]) -> String {
        replacing([MarkdownBlock(heading: actionItemsHeading, lines: [actionItemsHeading, ""] + lines)],
                  in: summary)
    }

    private static func synchronize(
        _ summary: String,
        outcomes: MeetingOutcomes,
        controlling controlledHeadings: [String]
    ) -> String {
        replacing(controlledHeadings.map { heading in
            MarkdownBlock(
                heading: heading,
                lines: renderSection(heading, outcomes: outcomes))
        }, in: summary)
    }

    /// Puts `rendered` where the first of its sections was, dropping the
    /// summary's own copies; sections the summary lacks are appended.
    private static func replacing(_ rendered: [MarkdownBlock], in summary: String) -> String {
        let controlledSet = Set(rendered.compactMap(\.heading))
        let sourceBlocks = parseBlocks(summary)
        var result: [MarkdownBlock] = []
        var inserted = false
        for block in sourceBlocks {
            if let heading = block.heading, controlledSet.contains(heading) {
                if !inserted {
                    result.append(contentsOf: rendered)
                    inserted = true
                }
                continue
            }
            result.append(block)
        }
        if !inserted {
            result.append(contentsOf: rendered)
        }

        return result
            .map { trimmedTrailingBlankLines($0.lines).joined(separator: "\n") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
            + "\n"
    }

    private static func parseBlocks(_ markdown: String) -> [MarkdownBlock] {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var blocks: [MarkdownBlock] = []
        var current = MarkdownBlock(heading: nil, lines: [])

        for line in lines {
            let heading = canonicalLevelTwoHeading(line)
            if let heading {
                if !current.lines.isEmpty {
                    blocks.append(current)
                }
                current = MarkdownBlock(heading: heading, lines: [heading])
            } else {
                current.lines.append(line)
            }
        }
        if !current.lines.isEmpty {
            blocks.append(current)
        }
        return blocks
    }

    private static func canonicalLevelTwoHeading(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("## "), !trimmed.hasPrefix("### ") else { return nil }
        return trimmed
    }

    private static func renderSection(
        _ heading: String,
        outcomes: MeetingOutcomes
    ) -> [String] {
        switch heading {
        case decisionsHeading:
            return [heading, ""] + listLines(
                outcomes.decisionRecords.map { decision in
                    "- \(singleLine(decision.displayText))\(citationSuffix(decision.citations))"
                })
        case actionItemsHeading:
            return [heading, "", "### Me"]
                + actionLines(outcomes.userActionItems, includeOwner: false)
                + ["", "### Others"]
                + actionLines(outcomes.otherActionItems, includeOwner: true)
                + (outcomes.unresolvedActionItems.isEmpty ? []
                    : ["", "### Owner unclear"] + actionLines(outcomes.unresolvedActionItems, includeOwner: false))
        default:
            return [heading]
        }
    }

    private static func actionLines(
        _ actions: [MeetingOutcomes.ActionItem],
        includeOwner: Bool
    ) -> [String] {
        listLines(actions.map { action in
            let owner: String
            if includeOwner {
                owner = "\(singleLine(action.owner ?? "Owner not stated")): "
            } else {
                owner = ""
            }
            let due = action.due.map { " — due \(singleLine($0))" } ?? ""
            return "- [ ] \(owner)\(singleLine(action.displayText))\(due)"
                + citationSuffix(action.citations)
        })
    }

    private static func listLines(_ lines: [String]) -> [String] {
        lines.isEmpty ? ["None"] : lines
    }

    private static func citationSuffix(_ citations: [OutcomeSourceCitation]) -> String {
        guard let earliest = citations.min(by: { $0.start < $1.start }) else { return "" }
        return " — [\(Transcript.stamp(earliest.start))]"
    }

    private static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimmedTrailingBlankLines(_ lines: [String]) -> [String] {
        var lines = lines
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        return lines
    }
}
