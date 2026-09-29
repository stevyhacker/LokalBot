import Foundation

/// The agenda part of a calendar invitation, with joining instructions,
/// links, phone numbers, email addresses, and markup removed. Only kept
/// when the user turns on agenda use; otherwise it is never persisted.
enum CalendarAgenda {
    static let maximumCharacters = 1_200

    static func sanitize(_ notes: String?) -> String? {
        guard var text = notes, !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: #"<br\s*/?>|</p>|</li>"#, with: "\n",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
        let lines = text.components(separatedBy: .newlines).compactMap { raw -> String? in
            var line = raw.replacingOccurrences(of: #"https?://\S+|www\.\S+"#, with: "",
                                                options: [.regularExpression, .caseInsensitive])
            line = line.replacingOccurrences(of: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, with: "",
                                             options: [.regularExpression, .caseInsensitive])
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !isJoiningBoilerplate(line) else { return nil }
            guard line.rangeOfCharacter(from: .letters) != nil else { return nil }
            return line.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        }
        let joined = lines.joined(separator: "\n")
        guard joined.count >= 12 else { return nil }
        return joined.count > maximumCharacters ? String(joined.prefix(maximumCharacters)) + "…" : joined
    }

    private static func isJoiningBoilerplate(_ line: String) -> Bool {
        let lower = line.lowercased()
        let markers = [
            "join zoom", "join the meeting", "join meeting", "join with google meet", "join by phone",
            "click here to join", "microsoft teams meeting", "meeting id", "passcode", "password:",
            "dial-in", "dial in", "one tap mobile", "find your local number", "pin:", "phone numbers",
            "google meet", "zoom meeting", "teams meeting", "learn more about", "meeting options",
            "join on your computer", "for organizers", "sip:", "h.323", "webex", "-::~:~::",
            "do not delete or change", "invitation from google calendar", "reply for",
            "you are receiving this", "forwarding this invitation", "view all guest info",
        ]
        if markers.contains(where: { lower.contains($0) }) { return true }
        // Separator rules and bare phone numbers.
        if line.allSatisfy({ "-_=~─━.:*#".contains($0) || $0.isWhitespace }) { return true }
        let digits = line.filter(\.isNumber).count
        return digits >= 7 && Double(digits) / Double(max(1, line.count)) > 0.35
    }
}

/// Secondary, source-labeled context for meeting notes: the calendar title,
/// invited participants by name, the optional agenda, and titles of
/// documents on screen during the call. The transcript stays the only
/// evidence for claims, decisions, actions, and ownership.
enum MeetingGenerationContext {
    static let maximumCharacters = 2_400

    struct Options: Equatable, Sendable {
        var includeCalendar = true
        var includeAgenda = false
        var includeScreenTitles = true
    }

    static func block(for meeting: Meeting, screenTitles: [String], options: Options) -> String? {
        var lines: [String] = []
        if options.includeCalendar {
            if let title = clean(meeting.calendarTitle) {
                lines.append("Scheduled title: \(title)")
            }
            let names = meeting.resolvedCalendarParticipantIdentities.compactMap(\.name)
                .compactMap(clean)
            if !names.isEmpty {
                lines.append("Invited participants (names from the calendar; they may not all have spoken): "
                    + names.prefix(20).joined(separator: ", "))
            }
        }
        if options.includeAgenda, let agenda = CalendarAgenda.sanitize(meeting.calendarAgenda) {
            lines.append("Agenda from the calendar invitation:\n" + agenda)
        }
        if options.includeScreenTitles, !screenTitles.isEmpty {
            lines.append("Documents and pages on the user's screen during the meeting (titles only): "
                + screenTitles.prefix(8).compactMap(clean).joined(separator: "; "))
        }
        guard !lines.isEmpty else { return nil }
        let header = "Meeting context (secondary). Use it to spell names and to relate the discussion to "
            + "its agenda and materials. Never create decisions, actions, owners, or claims from this block; "
            + "the transcript is the only evidence."
        let body = PromptContextSanitizer.sanitize(lines.joined(separator: "\n"),
                                                   maxCharacters: maximumCharacters)
        return header + "\n" + body
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }
}
