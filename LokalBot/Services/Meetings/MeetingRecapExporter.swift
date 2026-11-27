import Foundation

enum MeetingRecapExporter {
    static let websiteURL = "https://www.lokalbot.com/"
    static let attributionToggleLabel = "Include 'Captured locally with LokalBot (no meeting bot)'"
    static let plainAttributionLine = "Notes captured locally with LokalBot (no meeting bot) · \(websiteURL)"

    static func followUpCopyText(
        subject: String,
        body: String,
        includeAttribution: Bool = false
    ) -> String {
        let base = "Subject: \(subject)\n\n\(body)"
        guard includeAttribution else { return base }
        return "\(base)\n\n\(plainAttributionLine)"
    }

    static func slackOrEmailRecap(
        meeting: Meeting,
        summary: String?,
        projection: MeetingOutcomeProjection?,
        includeAttribution: Bool = false
    ) -> String {
        var blocks: [String] = []
        let dateText = MeetingDetailPresentation.dateText(meeting.startedAt)
        var header = "*\(meeting.displayTitle)* — \(dateText) · \(meeting.displayDuration)"
        if !meeting.isMergedMeeting, !meeting.appName.isEmpty {
            header += " · \(meeting.appName)"
        }
        blocks.append(header)

        let decisions = projection?.outcomes.decisionRecords.map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        if !decisions.isEmpty {
            let lines = decisions.map { "• \($0)" }.joined(separator: "\n")
            blocks.append("*Decisions*\n\(lines)")
        }

        let openActions = (projection?.actionReferences ?? []).filter { $0.status != .done }
        if !openActions.isEmpty {
            let lines = openActions.map { action -> String in
                var line = "• [ ] \(action.text)"
                var meta: [String] = []
                if let owner = action.owner?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty {
                    meta.append(owner)
                }
                if let due = action.due?.trimmingCharacters(in: .whitespacesAndNewlines), !due.isEmpty {
                    meta.append("due \(due)")
                }
                if !meta.isEmpty { line += " (\(meta.joined(separator: ", ")))" }
                return line
            }.joined(separator: "\n")
            blocks.append("*Action items*\n\(lines)")
        }

        let openQuestions = (projection?.outcomes.openQuestions ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !openQuestions.isEmpty {
            let lines = openQuestions.map { "• \($0)" }.joined(separator: "\n")
            blocks.append("*Open questions*\n\(lines)")
        }

        if let trimmedSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedSummary.isEmpty {
            let cleaned = cleanMarkdownForPlainRecap(trimmedSummary)
            if !cleaned.isEmpty {
                blocks.append("*Notes*\n\(cleaned)")
            }
        }

        if includeAttribution {
            blocks.append("_Notes captured locally with LokalBot (no meeting bot) · \(websiteURL)_")
        }

        return blocks.joined(separator: "\n\n")
    }

    static func staticHTML(
        meeting: Meeting,
        summary: String?,
        projection: MeetingOutcomeProjection?,
        transcript: Transcript?
    ) -> String {
        let title = escapeHTML(meeting.displayTitle)
        let dateText = escapeHTML(MeetingDetailPresentation.dateText(meeting.startedAt))
        let duration = escapeHTML(meeting.displayDuration)
        var metaParts = [dateText, duration]
        if !meeting.isMergedMeeting, !meeting.appName.isEmpty {
            metaParts.append(escapeHTML(meeting.appName))
        }
        let metaLine = metaParts.joined(separator: " &middot; ")

        var sections: [String] = []

        let decisions = projection?.outcomes.decisionRecords.map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        if !decisions.isEmpty {
            let items = decisions.map { "<li>\(escapeHTML($0))</li>" }.joined(separator: "\n")
            sections.append("""
            <section class="card">
              <h2>Decisions</h2>
              <ul class="clean-list">
                \(items)
              </ul>
            </section>
            """)
        }

        let actions = projection?.actionReferences ?? []
        if !actions.isEmpty {
            let items = actions.map { action -> String in
                let done = action.status == .done
                let marker = done ? "&#x2611;" : "&#x2610;"
                var badges: [String] = []
                if let owner = action.owner?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty {
                    badges.append("<span class=\"pill\">\(escapeHTML(owner))</span>")
                }
                if let due = action.due?.trimmingCharacters(in: .whitespacesAndNewlines), !due.isEmpty {
                    badges.append("<span class=\"pill pill-due\">\(escapeHTML(due))</span>")
                }
                let badgeHTML = badges.isEmpty ? "" : " <span class=\"pills\">\(badges.joined(separator: " "))</span>"
                let cls = done ? " class=\"done\"" : ""
                return "<li\(cls)><span class=\"box\" aria-hidden=\"true\">\(marker)</span><span>\(escapeHTML(action.text))\(badgeHTML)</span></li>"
            }.joined(separator: "\n")
            sections.append("""
            <section class="card">
              <h2>Action items</h2>
              <ul class="action-list">
                \(items)
              </ul>
            </section>
            """)
        }

        if let trimmedSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedSummary.isEmpty {
            sections.append("""
            <section class="card prose">
              <h2>Summary</h2>
              \(renderSimpleMarkdownHTML(trimmedSummary))
            </section>
            """)
        }

        let openQuestions = (projection?.outcomes.openQuestions ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !openQuestions.isEmpty {
            let items = openQuestions.map { "<li>\(escapeHTML($0))</li>" }.joined(separator: "\n")
            sections.append("""
            <section class="card">
              <h2>Open questions</h2>
              <ul class="clean-list">
                \(items)
              </ul>
            </section>
            """)
        }

        if let segments = transcript?.segments, !segments.isEmpty {
            let rows = segments.map { segment -> String in
                let stamp = escapeHTML(Transcript.stamp(segment.start))
                let speaker = escapeHTML(segment.speaker)
                let body = escapeHTML(segment.text)
                return "<div class=\"turn\"><span class=\"stamp\">\(stamp)</span><span class=\"speaker\">\(speaker)</span><span class=\"utterance\">\(body)</span></div>"
            }.joined(separator: "\n")
            sections.append("""
            <details class="card transcript">
              <summary>Full transcript (\(segments.count) segments)</summary>
              <div class="turns">
                \(rows)
              </div>
            </details>
            """)
        }

        let bodyContent = sections.isEmpty
            ? "<section class=\"card\"><p class=\"muted\">No notes or transcript were recorded for this meeting yet.</p></section>"
            : sections.joined(separator: "\n")

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title) — Meeting Recap</title>
        <style>
          :root {
            color-scheme: light dark;
            --bg: #f6f8fa;
            --surface: #ffffff;
            --border: #dfe6ec;
            --text: #111827;
            --dim: #4b5563;
            --accent: #0f9d8a;
            --pill-bg: #eef4f7;
            --due-bg: #fef3c7;
            --due-fg: #92400e;
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --bg: #080d14;
              --surface: #0e1621;
              --border: #1e2c3c;
              --text: #ecf3f7;
              --dim: #9db0bf;
              --accent: #23c4ae;
              --pill-bg: #162230;
              --due-bg: #32240d;
              --due-fg: #fbbf24;
            }
          }
          * { box-sizing: border-box; }
          body { margin: 0; background: var(--bg); color: var(--text); font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
          main { max-width: 780px; margin: 0 auto; padding: 36px 20px 64px; }
          header { margin-bottom: 24px; }
          h1 { margin: 0 0 6px; font-size: 28px; line-height: 1.2; letter-spacing: -0.02em; }
          .meta { color: var(--dim); font-size: 14px; margin: 0; }
          .card { background: var(--surface); border: 1px solid var(--border); border-radius: 12px; padding: 20px 22px; margin-bottom: 16px; }
          .card h2 { margin: 0 0 12px; font-size: 14px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--accent); }
          .clean-list, .action-list { margin: 0; padding-left: 20px; }
          .action-list { list-style: none; padding-left: 0; }
          .action-list li { display: flex; gap: 10px; align-items: baseline; margin: 8px 0; }
          .action-list li.done { opacity: 0.6; text-decoration: line-through; }
          .box { font-family: ui-monospace, Menlo, monospace; color: var(--accent); }
          .pills { display: inline-flex; flex-wrap: wrap; gap: 6px; margin-left: 6px; }
          .pill { font-size: 12px; padding: 2px 8px; border-radius: 999px; background: var(--pill-bg); color: var(--dim); }
          .pill-due { background: var(--due-bg); color: var(--due-fg); }
          .prose h3 { margin: 16px 0 6px; font-size: 16px; }
          .prose p { margin: 0 0 10px; }
          .prose ul { margin: 0 0 10px; padding-left: 20px; }
          .transcript summary { cursor: pointer; font-weight: 600; color: var(--text); }
          .turns { margin-top: 14px; display: grid; gap: 10px; font-size: 14px; }
          .turn { display: grid; grid-template-columns: 56px 110px 1fr; gap: 10px; align-items: baseline; }
          @media (max-width: 600px) { .turn { grid-template-columns: 1fr; gap: 2px; } }
          .stamp { font-family: ui-monospace, Menlo, monospace; font-size: 12px; color: var(--dim); }
          .speaker { font-weight: 600; color: var(--accent); overflow-wrap: anywhere; }
          .muted { color: var(--dim); margin: 0; }
          footer { margin-top: 28px; padding-top: 16px; border-top: 1px solid var(--border); font-size: 13px; color: var(--dim); }
          footer a { color: var(--accent); text-decoration: none; }
          footer a:hover { text-decoration: underline; }
        </style>
        </head>
        <body>
        <main>
          <header>
            <h1>\(title)</h1>
            <p class="meta">\(metaLine)</p>
          </header>
          \(bodyContent)
          <footer>
            Captured locally with <a href="\(websiteURL)">LokalBot</a> — no meeting bot joined this call.
          </footer>
        </main>
        </body>
        </html>
        """
    }

    static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func cleanMarkdownForPlainRecap(_ markdown: String) -> String {
        markdown
            .components(separatedBy: .newlines)
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("### ") { return "*\(trimmed.dropFirst(4))*" }
                if trimmed.hasPrefix("## ") { return "*\(trimmed.dropFirst(3))*" }
                if trimmed.hasPrefix("# ") { return "*\(trimmed.dropFirst(2))*" }
                if trimmed.hasPrefix("- ") { return "• \(trimmed.dropFirst(2))" }
                return line
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func renderSimpleMarkdownHTML(_ markdown: String) -> String {
        var html: [String] = []
        var inList = false
        for rawLine in markdown.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if inList { html.append("</ul>"); inList = false }
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                if !inList { html.append("<ul>"); inList = true }
                html.append("<li>\(escapeHTML(String(trimmed.dropFirst(2))))</li>")
            } else if trimmed.hasPrefix("#") {
                if inList { html.append("</ul>"); inList = false }
                let heading = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty { html.append("<h3>\(escapeHTML(heading))</h3>") }
            } else {
                if inList { html.append("</ul>"); inList = false }
                html.append("<p>\(escapeHTML(trimmed))</p>")
            }
        }
        if inList { html.append("</ul>") }
        return html.joined(separator: "\n")
    }
}
