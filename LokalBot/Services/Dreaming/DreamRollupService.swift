import Foundation

/// After the overnight review: one line for each recent finished week and
/// month, condensed from that period's daily reviews, so the agent briefing
/// can show older time at lower detail (recent days in full, then weeks, then
/// months). Each line records a stamp of the reviews it came from; a deleted
/// or regenerated review makes it stale, and stale lines are removed here and
/// never shown. At most a few model calls a night, newest periods first.
enum DreamRollupService {
    typealias Period = DreamRollupFormat.Period
    typealias Rollup = DreamRollupFormat.Rollup
    typealias DayReview = DreamRollupFormat.DayReview

    static let weeksKept = 8
    static let monthsKept = 6
    static let maximumPerNight = 3
    static let maximumInputCharacters = 12_000
    static let maximumLineCharacters = 280

    struct Outcome: Equatable {
        var written: [Rollup] = []
        var removed: [String] = []
    }

    /// The finished weeks and months the briefing can show, newest first.
    static func periods(now: Date, calendar: Calendar) -> [Period] {
        let today = DreamRollupFormat.dayKey(now, calendar: calendar)
        var periods: [Period] = []
        for offset in 1...weeksKept {
            guard let date = calendar.date(byAdding: .day, value: -7 * offset, to: now) else { continue }
            periods.append(DreamRollupFormat.week(containing: date, calendar: calendar))
        }
        let thisMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        for offset in 1...monthsKept {
            guard let date = calendar.date(byAdding: .month, value: -offset, to: thisMonth) else { continue }
            periods.append(DreamRollupFormat.month(containing: date, calendar: calendar))
        }
        let finished = periods.filter { $0.lastDay < today }
        return finished.sorted { (lhs: Period, rhs: Period) -> Bool in
            if lhs.lastDay != rhs.lastDay { return lhs.lastDay > rhs.lastDay }
            return lhs.kind == .week && rhs.kind == .month
        }
    }

    /// Periods with reviews but no current line, newest first.
    static func due(reviews: [String: DayReview], rollups: [Rollup], now: Date, calendar: Calendar) -> [Period] {
        let valid = rollups.filter { DreamRollupFormat.isValid($0, reviews: reviews) }
        let current = Set(valid.map { $0.key })
        return periods(now: now, calendar: calendar).filter { period in
            !current.contains(period.key) && !DreamRollupFormat.reviews(in: period, from: reviews).isEmpty
        }
    }

    /// New lines are written at most this often. A night that rebuilds
    /// several reviews runs this after each one; without the gap it rewrote
    /// the same week after every rebuilt day.
    static let minimumGenerationInterval: TimeInterval = 20 * 60 * 60

    /// Removes stale lines and lines for periods the briefing no longer
    /// shows, then writes up to `limit` due lines, unless lines were written
    /// within `minimumInterval`. The engine is made only when something is due.
    static func run(root: URL, now: Date, calendar: Calendar = .current, limit: Int = maximumPerNight,
                    minimumInterval: TimeInterval = minimumGenerationInterval,
                    makeEngine: () async throws -> TextEngine) async throws -> Outcome {
        var outcome = Outcome()
        let reviews = DreamRollupFormat.reviews(root: root)
        let kept = Set(periods(now: now, calendar: calendar).map(\.key))
        var rollups: [Rollup] = []
        for rollup in DreamRollupFormat.rollups(root: root) {
            if kept.contains(rollup.key) && DreamRollupFormat.isValid(rollup, reviews: reviews) {
                rollups.append(rollup)
            } else {
                try? FileManager.default.removeItem(at: DreamRollupFormat.rollupURL(root: root, key: rollup.key))
                outcome.removed.append(rollup.key)
            }
        }
        let due = due(reviews: reviews, rollups: rollups, now: now, calendar: calendar).prefix(limit)
        guard !due.isEmpty else { return outcome }
        if let last = lastGeneration(root: root), now.timeIntervalSince(last) < minimumInterval { return outcome }
        let engine = try await makeEngine()
        recordGeneration(root: root, at: now)
        for period in due {
            try Task.checkCancellation()
            let inside = DreamRollupFormat.reviews(in: period, from: reviews)
            let output = try await engine.generate(
                system: system, prompt: prompt(period: period, reviews: inside, calendar: calendar), context: [],
                options: TextGenerationOptions(maxTokens: 200, reasoningBudgetTokens: 0, temperature: 0.2))
            guard let line = line(from: output) else { continue }
            let rollup = Rollup(kind: period.kind, key: period.key, firstDay: period.firstDay,
                                lastDay: period.lastDay, line: line,
                                stamp: DreamRollupFormat.stamp(of: inside), generatedAt: now)
            try write(rollup, root: root)
            outcome.written.append(rollup)
        }
        return outcome
    }

    private static func generationMarker(root: URL) -> URL {
        DreamRollupFormat.rollupsDirectory(root: root).appendingPathComponent(".last-generation")
    }

    static func lastGeneration(root: URL) -> Date? {
        guard let text = try? String(contentsOf: generationMarker(root: root), encoding: .utf8) else { return nil }
        return ISO8601DateFormatter().date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func recordGeneration(root: URL, at date: Date) {
        let url = generationMarker(root: root)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? Data(ISO8601DateFormatter().string(from: date).utf8).write(to: url, options: .atomic)
    }

    /// Removes every line covering `dayKey`, for when that day's review is
    /// deleted or rebuilt.
    static func removeRollups(covering dayKey: String, root: URL) {
        for rollup in DreamRollupFormat.rollups(root: root)
        where rollup.firstDay <= dayKey && dayKey <= rollup.lastDay {
            try? FileManager.default.removeItem(at: DreamRollupFormat.rollupURL(root: root, key: rollup.key))
        }
    }

    // MARK: - Prompt

    static let system = """
        You condense a person's daily work reviews into a single line that sums up a past week or month. \
        Use only the reviews given. Name the main projects, decisions, and outcomes; leave out routine \
        activity, dates, and feelings. Write one plain sentence of at most 35 words, in the language the \
        reviews are written in, with no heading, label, list, or quotation marks.
        """

    static func prompt(period: Period, reviews: [DayReview], calendar: Calendar) -> String {
        let perReview = max(200, maximumInputCharacters / max(1, reviews.count))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE MMM d"
        let days = reviews.map { review -> String in
            let label = DreamRollupFormat.date(fromDayKey: review.day, calendar: calendar)
                .map(formatter.string(from:)) ?? review.day
            let sentences = period.kind == .week ? 6 : 3
            return "\(label): "
                + PromptContextSanitizer.sanitize(
                    DreamRollupFormat.sentences(review.narrative, count: sentences, maxCharacters: perReview),
                    maxCharacters: perReview)
        }
        let span = period.kind == .week ? "week (\(period.label))" : "month (\(period.label))"
        return "Daily reviews for the \(span):\n\n" + days.joined(separator: "\n\n")
            + "\n\nWrite the one-line summary of this \(period.kind == .week ? "week" : "month")."
    }

    static func line(from output: String) -> String? {
        let text = strippingReasoning(output)
        guard let first = text.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        var line = first
        for prefix in ["Summary:", "Week:", "Month:"] where line.hasPrefix(prefix) {
            line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”*- "))
        let clean = PromptContextSanitizer.sanitize(line, maxCharacters: maximumLineCharacters)
        return clean.isEmpty ? nil : clean
    }

    // MARK: - Storage

    static func write(_ rollup: Rollup, root: URL) throws {
        let url = DreamRollupFormat.rollupURL(root: root, key: rollup.key)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rollup).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
