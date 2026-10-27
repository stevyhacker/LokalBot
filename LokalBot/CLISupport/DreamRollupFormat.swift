import CryptoKit
import Foundation

/// One line per past week and month, condensed from the overnight reviews.
/// The app writes them (`DreamRollupService`); the CLI reads them for the
/// agent briefing. A rollup is a cache over the daily reviews: it records a
/// stamp of the reviews it was made from, and anyone reading it recomputes
/// that stamp, so a deleted, retracted, or regenerated review makes it stale
/// at once. Stale rollups are never shown and are rebuilt the next night.
/// Clear work memory removes them with the reviews (they live in `dreams/`).
enum DreamRollupFormat {
    enum Kind: String, Codable, Sendable {
        case week
        case month
    }

    struct Rollup: Codable, Equatable, Sendable {
        var kind: Kind
        /// "2026-W41" or "2026-09".
        var key: String
        var firstDay: String
        var lastDay: String
        var line: String
        var stamp: String
        var generatedAt: Date
    }

    /// The fields of a stored overnight review the briefing and rollups use.
    struct DayReview: Decodable, Equatable, Sendable {
        var day: String
        var generatedAt: Date
        var narrative: String
    }

    struct Period: Equatable, Sendable {
        var kind: Kind
        var key: String
        var firstDay: String
        var lastDay: String
        var label: String
    }

    static func dreamsDirectory(root: URL) -> URL {
        root.appendingPathComponent("dreams", isDirectory: true)
    }

    static func rollupsDirectory(root: URL) -> URL {
        dreamsDirectory(root: root).appendingPathComponent("rollups", isDirectory: true)
    }

    static func rollupURL(root: URL, key: String) -> URL {
        rollupsDirectory(root: root).appendingPathComponent("\(key).json")
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Every readable review, keyed by day. A file whose embedded day does
    /// not match its name is ignored, as the app's store does.
    static func reviews(root: URL) -> [String: DayReview] {
        let folder = dreamsDirectory(root: root)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil) else { return [:] }
        var result: [String: DayReview] = [:]
        for file in files where file.pathExtension == "json" {
            let name = file.deletingPathExtension().lastPathComponent
            guard isDayKey(name),
                  let data = try? Data(contentsOf: file),
                  let review = try? decoder.decode(DayReview.self, from: data),
                  review.day == name else { continue }
            result[name] = review
        }
        return result
    }

    static func rollups(root: URL) -> [Rollup] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: rollupsDirectory(root: root), includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? decoder.decode(Rollup.self, from: data)
        }
    }

    /// Reviews whose day falls inside the period, oldest first.
    static func reviews(in period: Period, from reviews: [String: DayReview]) -> [DayReview] {
        reviews.values
            .filter { $0.day >= period.firstDay && $0.day <= period.lastDay }
            .sorted { $0.day < $1.day }
    }

    /// Changes whenever a review in the period appears, disappears, or is
    /// regenerated.
    static func stamp(of reviews: [DayReview]) -> String {
        let formatter = ISO8601DateFormatter()
        let material = reviews.sorted { $0.day < $1.day }
            .map { "\($0.day)|\(formatter.string(from: $0.generatedAt))" }
            .joined(separator: "\n")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func isValid(_ rollup: Rollup, reviews: [String: DayReview]) -> Bool {
        let period = Period(kind: rollup.kind, key: rollup.key, firstDay: rollup.firstDay,
                            lastDay: rollup.lastDay, label: "")
        let inside = self.reviews(in: period, from: reviews)
        return !inside.isEmpty && stamp(of: inside) == rollup.stamp
    }

    // MARK: - Calendar

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(fromDayKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func isDayKey(_ text: String) -> Bool {
        text.count == 10 && text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    /// The Monday-to-Sunday week containing `date`.
    static func week(containing date: Date, calendar: Calendar) -> Period {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        let start = iso.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        let end = iso.date(byAdding: .day, value: 6, to: start) ?? start
        let parts = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: start)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM d"
        return Period(kind: .week,
                      key: String(format: "%04d-W%02d", parts.yearForWeekOfYear ?? 0, parts.weekOfYear ?? 0),
                      firstDay: dayKey(start, calendar: calendar), lastDay: dayKey(end, calendar: calendar),
                      label: "Week of \(formatter.string(from: start))")
    }

    /// The calendar month containing `date`.
    static func month(containing date: Date, calendar: Calendar) -> Period {
        let start = calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        let next = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        let end = calendar.date(byAdding: .day, value: -1, to: next) ?? start
        let parts = calendar.dateComponents([.year, .month], from: start)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMMM yyyy"
        return Period(kind: .month, key: String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0),
                      firstDay: dayKey(start, calendar: calendar), lastDay: dayKey(end, calendar: calendar),
                      label: formatter.string(from: start))
    }

    // MARK: - Text

    /// The first `count` sentences of a review's narrative, on one line.
    static func sentences(_ text: String, count: Int, maxCharacters: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var result = ""
        var taken = 0
        flat.enumerateSubstrings(in: flat.startIndex..., options: .bySentences) { sentence, _, _, stop in
            guard let sentence = sentence?.trimmingCharacters(in: .whitespaces), !sentence.isEmpty else { return }
            result += (result.isEmpty ? "" : " ") + sentence
            taken += 1
            if taken >= count { stop = true }
        }
        if result.isEmpty { result = flat }
        guard result.count > maxCharacters else { return result }
        return String(result.prefix(maxCharacters - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
