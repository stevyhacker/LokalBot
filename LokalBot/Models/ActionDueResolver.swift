import Foundation

/// Deterministically turns a spoken due phrase into a local calendar day,
/// using the day the phrase was said as the reference. It never asks a model
/// and never guesses: phrases outside the supported grammar stay unresolved.
///
/// Ranges resolve to their last day ("next week" is the Friday of next week,
/// "end of Q3" is September 30), so an action is not reported overdue while
/// the stated window is still open. The original phrase is always shown
/// beside the resolved date, and a user's due correction replaces both.
enum ActionDueResolver {
    static func resolve(_ phrase: String?, spokenAt: Date,
                        calendar: Calendar = .current) -> Date? {
        guard let phrase else { return nil }
        let text = normalized(phrase)
        guard !text.isEmpty, text.count <= 80 else { return nil }
        if let iso = isoDate(text, calendar: calendar) { return iso }
        let spokenDay = calendar.startOfDay(for: spokenAt)

        if matches(text, #"^(?:(?:by|before|until|till) )?(?:the )?(?:today|tonight|end of (?:the )?day|eod|close of business|cob|danas|do kraja dana)$"#) {
            return spokenDay
        }
        if matches(text, #"^(?:(?:by|before|until|till) )?(?:tomorrow|sutra)(?: (?:morning|afternoon|evening|eod))?$"#) {
            return calendar.date(byAdding: .day, value: 1, to: spokenDay)
        }
        if matches(text, #"^(?:(?:by|before|until|till) )?(?:the )?(?:end of (?:the |this )?week|eow|this week|later this week|do kraja nedelje|ove nedelje)$"#) {
            return endOfWorkWeek(containing: spokenDay, calendar: calendar)
        }
        if matches(text, #"^(?:(?:by|before|until|till|during|sometime) )?(?:the )?(?:end of )?next week$|^(?:sledece|sledeće) nedelje$"#) {
            guard let next = calendar.date(byAdding: .weekOfYear, value: 1, to: spokenDay) else { return nil }
            return endOfWorkWeek(containing: next, calendar: calendar)
        }
        if matches(text, #"^(?:(?:by|before|until|till) )?(?:the )?(?:end of (?:the |this )?month|eom|this month|do kraja meseca)$"#) {
            return lastDayOfMonth(containing: spokenDay, calendar: calendar)
        }
        if matches(text, #"^(?:(?:by|before|until|till|during) )?(?:the )?(?:end of )?next month$"#) {
            guard let next = calendar.date(byAdding: .month, value: 1, to: spokenDay) else { return nil }
            return lastDayOfMonth(containing: next, calendar: calendar)
        }
        if let relative = relativeOffset(text, from: spokenDay, calendar: calendar) { return relative }
        if let weekday = weekday(text, from: spokenDay, calendar: calendar) { return weekday }
        if let quarter = quarter(text, from: spokenDay, calendar: calendar) { return quarter }
        if let monthDay = monthDay(text, from: spokenDay, calendar: calendar) { return monthDay }
        return nil
    }

    // MARK: - Grammar

    private static let leading = #"^(?:(?:by|before|until|till|on|due|this|do|u) )?(?:the )?"#

    private static let weekdayNames: [(Int, [String])] = [
        (1, ["sunday", "sun", "nedelja", "nedelju", "nedelje"]),
        (2, ["monday", "mon", "ponedeljak", "ponedeljka"]),
        (3, ["tuesday", "tue", "tues", "utorak", "utorka"]),
        (4, ["wednesday", "wed", "sreda", "sredu", "srede"]),
        (5, ["thursday", "thu", "thur", "thurs", "cetvrtak", "četvrtak", "cetvrtka", "četvrtka"]),
        (6, ["friday", "fri", "petak", "petka"]),
        (7, ["saturday", "sat", "subota", "subotu", "subote"]),
    ]

    private static let monthNames: [(Int, [String])] = [
        (1, ["january", "jan", "januar"]), (2, ["february", "feb", "februar"]),
        (3, ["march", "mar", "mart"]), (4, ["april", "apr"]), (5, ["may", "maj"]),
        (6, ["june", "jun"]), (7, ["july", "jul"]), (8, ["august", "aug", "avgust"]),
        (9, ["september", "sep", "sept", "septembar"]), (10, ["october", "oct", "oktobar"]),
        (11, ["november", "nov", "novembar"]), (12, ["december", "dec", "decembar"]),
    ]

    private static let numberWords: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "couple of": 2,
    ]

    private static func weekday(_ text: String, from day: Date, calendar: Calendar) -> Date? {
        let names = weekdayNames.flatMap(\.1).joined(separator: "|")
        let pattern = #"^(?:(?:by|before|until|till|on|due|do|u) )?(?:the )?(this |next |sledeci |sledeći )?("#
            + names + #")(?: (?:morning|afternoon|evening|eod|end of day))?$"#
        guard let groups = captures(text, pattern), groups.count == 2,
              let target = weekdayNames.first(where: { $0.1.contains(groups[1]) })?.0 else { return nil }
        let current = calendar.component(.weekday, from: day)
        var offset = (target - current + 7) % 7
        if offset == 0 { offset = 7 }
        guard var date = calendar.date(byAdding: .day, value: offset, to: day) else { return nil }
        let modifier = groups[0].trimmingCharacters(in: .whitespaces)
        if ["next", "sledeci", "sledeći"].contains(modifier),
           calendar.isDate(date, equalTo: day, toGranularity: .weekOfYear) {
            // "Next Friday" said on a Tuesday means Friday of the following week.
            date = calendar.date(byAdding: .day, value: 7, to: date) ?? date
        }
        return date
    }

    private static func relativeOffset(_ text: String, from day: Date, calendar: Calendar) -> Date? {
        let words = numberWords.keys.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let pattern = #"^(?:(?:in|within|over) (?:the next )?)(\d{1,3}|"# + words
            + #") (business day|working day|day|week|month)s?(?: from now)?$"#
        guard let groups = captures(text, pattern), groups.count == 2 else { return nil }
        guard let amount = Int(groups[0]) ?? numberWords[groups[0]], amount > 0 else { return nil }
        switch groups[1] {
        case "day":
            return calendar.date(byAdding: .day, value: amount, to: day)
        case "business day", "working day":
            var date = day
            var remaining = amount
            while remaining > 0 {
                guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
                date = next
                if !calendar.isDateInWeekend(date) { remaining -= 1 }
            }
            return date
        case "week":
            return calendar.date(byAdding: .day, value: amount * 7, to: day)
        case "month":
            return calendar.date(byAdding: .month, value: amount, to: day)
        default:
            return nil
        }
    }

    private static func quarter(_ text: String, from day: Date, calendar: Calendar) -> Date? {
        let pattern = leading + #"(?:end of )?(?:q([1-4])|(first|second|third|fourth) quarter)(?: (\d{4}))?$"#
        guard let groups = captures(text, pattern), groups.count == 3 else { return nil }
        let ordinal = ["first": 1, "second": 2, "third": 3, "fourth": 4]
        guard let number = Int(groups[0]) ?? ordinal[groups[1]] else { return nil }
        var year = Int(groups[2]) ?? calendar.component(.year, from: day)
        func end(_ year: Int) -> Date? {
            guard let firstOfLastMonth = calendar.date(from: DateComponents(
                year: year, month: number * 3, day: 1)) else { return nil }
            return lastDayOfMonth(containing: firstOfLastMonth, calendar: calendar)
        }
        guard var date = end(year) else { return nil }
        if groups[2].isEmpty, date < day {
            year += 1
            date = end(year) ?? date
        }
        return date
    }

    private static func monthDay(_ text: String, from day: Date, calendar: Calendar) -> Date? {
        let months = monthNames.flatMap(\.1).joined(separator: "|")
        let dayPart = #"(\d{1,2})(?:st|nd|rd|th|\.)?"#
        let monthFirst = leading + "(" + months + #")\.? "# + dayPart + #"(?:,? (\d{4}))?$"#
        let dayFirst = leading + dayPart + #" (?:of )?("# + months + #")\.?(?:,? (\d{4}))?$"#
        var month: Int?
        var dayOfMonth: Int?
        var explicitYear: Int?
        if let groups = captures(text, monthFirst), groups.count == 3 {
            month = monthNames.first { $0.1.contains(groups[0]) }?.0
            dayOfMonth = Int(groups[1])
            explicitYear = Int(groups[2])
        } else if let groups = captures(text, dayFirst), groups.count == 3 {
            dayOfMonth = Int(groups[0])
            month = monthNames.first { $0.1.contains(groups[1]) }?.0
            explicitYear = Int(groups[2])
        }
        guard let month, let dayOfMonth, (1...31).contains(dayOfMonth) else { return nil }
        var year = explicitYear ?? calendar.component(.year, from: day)
        func make(_ year: Int) -> Date? {
            let components = DateComponents(year: year, month: month, day: dayOfMonth)
            guard let date = calendar.date(from: components),
                  calendar.component(.day, from: date) == dayOfMonth else { return nil }
            return date
        }
        guard var date = make(year) else { return nil }
        // Without a year, a date well before the meeting refers to next year.
        if explicitYear == nil,
           let cutoff = calendar.date(byAdding: .day, value: -31, to: day), date < cutoff {
            year += 1
            date = make(year) ?? date
        }
        return date
    }

    private static func isoDate(_ text: String, calendar: Calendar) -> Date? {
        guard let groups = captures(text, #"^(?:(?:by|before|until|on|due) )?(\d{4})-(\d{2})-(\d{2})$"#),
              groups.count == 3,
              let year = Int(groups[0]), let month = Int(groups[1]), let day = Int(groups[2]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.day, from: date) == day,
              calendar.component(.month, from: date) == month else { return nil }
        return date
    }

    // MARK: - Calendar helpers

    private static func endOfWorkWeek(containing day: Date, calendar: Calendar) -> Date? {
        let weekday = calendar.component(.weekday, from: day)
        // Friday is weekday 6 in the Gregorian numbering used by Foundation.
        let offset = 6 - weekday
        if offset >= 0 { return calendar.date(byAdding: .day, value: offset, to: day) }
        // Saturday: the working week already ended; keep the stated day.
        return day
    }

    private static func lastDayOfMonth(containing day: Date, calendar: Calendar) -> Date? {
        guard let interval = calendar.dateInterval(of: .month, for: day) else { return nil }
        return calendar.date(byAdding: .day, value: -1, to: interval.end)
            .map { calendar.startOfDay(for: $0) }
    }

    // MARK: - Text helpers

    private static func normalized(_ phrase: String) -> String {
        phrase.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[!?;]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,")))
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// Returns every capture group, with unmatched optional groups as "".
    private static func captures(_ text: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        return (1..<max(1, match.numberOfRanges)).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
