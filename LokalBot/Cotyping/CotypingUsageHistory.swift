import Foundation

struct CotypingUsageCounts: Codable, Equatable, Sendable {
    var shown = 0
    var used = 0
    var accepts = 0
    var words = 0
    var characters = 0
    var takenBack = 0

    private enum CodingKeys: String, CodingKey {
        case shown, used, accepts, words, characters, takenBack
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func count(_ key: CodingKeys) throws -> Int {
            try container.decodeIfPresent(Int.self, forKey: key) ?? 0
        }
        shown = try count(.shown)
        used = try count(.used)
        accepts = try count(.accepts)
        words = try count(.words)
        characters = try count(.characters)
        takenBack = try count(.takenBack)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        func count(_ value: Int, _ key: CodingKeys) throws {
            if value != 0 { try container.encode(value, forKey: key) }
        }
        try count(shown, .shown)
        try count(used, .used)
        try count(accepts, .accepts)
        try count(words, .words)
        try count(characters, .characters)
        try count(takenBack, .takenBack)
    }

    var isEmpty: Bool { self == CotypingUsageCounts() }

    var acceptanceRate: Double? {
        shown > 0 ? Double(min(used, shown)) / Double(shown) : nil
    }

    var wordsPerUsedSuggestion: Double? {
        used > 0 ? Double(words) / Double(used) : nil
    }

    var keystrokesSaved: Int { max(0, characters - accepts) }

    mutating func merge(_ other: CotypingUsageCounts) {
        shown += other.shown
        used += other.used
        accepts += other.accepts
        words += other.words
        characters += other.characters
        takenBack += other.takenBack
    }
}

struct CotypingUsageBucket: Codable, Equatable, Sendable {
    var suggestions = CotypingUsageCounts()
    var surfaces: [String: CotypingUsageCounts] = [:]
    var models: [String: CotypingUsageCounts] = [:]
    var typedCharacters = 0
    var typingMilliseconds = 0
    var typingGaps = 0
    var typosFixed = 0

    private enum CodingKeys: String, CodingKey {
        case suggestions, surfaces, models, typedCharacters, typingMilliseconds, typingGaps, typosFixed
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func count(_ key: CodingKeys) throws -> Int {
            try container.decodeIfPresent(Int.self, forKey: key) ?? 0
        }
        suggestions = try container.decodeIfPresent(CotypingUsageCounts.self, forKey: .suggestions) ?? .init()
        surfaces = try container.decodeIfPresent([String: CotypingUsageCounts].self, forKey: .surfaces) ?? [:]
        models = try container.decodeIfPresent([String: CotypingUsageCounts].self, forKey: .models) ?? [:]
        typedCharacters = try count(.typedCharacters)
        typingMilliseconds = try count(.typingMilliseconds)
        typingGaps = try count(.typingGaps)
        typosFixed = try count(.typosFixed)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        func count(_ value: Int, _ key: CodingKeys) throws {
            if value != 0 { try container.encode(value, forKey: key) }
        }
        if !suggestions.isEmpty { try container.encode(suggestions, forKey: .suggestions) }
        if !surfaces.isEmpty { try container.encode(surfaces, forKey: .surfaces) }
        if !models.isEmpty { try container.encode(models, forKey: .models) }
        try count(typedCharacters, .typedCharacters)
        try count(typingMilliseconds, .typingMilliseconds)
        try count(typingGaps, .typingGaps)
        try count(typosFixed, .typosFixed)
    }

    var isEmpty: Bool { self == CotypingUsageBucket() }

    var shareOfText: Double? {
        let total = suggestions.characters + typedCharacters
        return total > 0 ? Double(suggestions.characters) / Double(total) : nil
    }

    var millisecondsPerKeystroke: Double? {
        typingGaps >= CotypingUsageHistory.minimumTypingGaps
            ? Double(typingMilliseconds) / Double(typingGaps) : nil
    }

    mutating func merge(_ other: CotypingUsageBucket) {
        suggestions.merge(other.suggestions)
        for (key, counts) in other.surfaces { surfaces[key, default: .init()].merge(counts) }
        for (key, counts) in other.models { models[key, default: .init()].merge(counts) }
        typedCharacters += other.typedCharacters
        typingMilliseconds += other.typingMilliseconds
        typingGaps += other.typingGaps
        typosFixed += other.typosFixed
    }

    mutating func update(surface: String, model: String, _ change: (inout CotypingUsageCounts) -> Void) {
        change(&suggestions)
        change(&surfaces[surface, default: .init()])
        change(&models[model, default: .init()])
    }
}

struct CotypingUsageHistory: Codable, Equatable, Sendable {
    var days: [String: CotypingUsageBucket] = [:]
    var months: [String: CotypingUsageBucket] = [:]

    static let retainedDays = 92
    static let maxTypingGapMilliseconds = 1_000
    static let minimumTypingGaps = 200
    static let fallbackMillisecondsPerKeystroke = 300.0

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        days = try container.decodeIfPresent([String: CotypingUsageBucket].self, forKey: .days) ?? [:]
        months = try container.decodeIfPresent([String: CotypingUsageBucket].self, forKey: .months) ?? [:]
    }

    var isEmpty: Bool { months.values.allSatisfy(\.isEmpty) }

    mutating func recordShown(surface: String, model: String, at date: Date, calendar: Calendar = .current) {
        record(at: date, calendar: calendar) { bucket in
            bucket.update(surface: surface, model: model) { $0.shown += 1 }
        }
    }

    mutating func recordAccept(
        words: Int, characters: Int, firstOfSuggestion: Bool,
        surface: String, model: String, at date: Date, calendar: Calendar = .current
    ) {
        record(at: date, calendar: calendar) { bucket in
            bucket.update(surface: surface, model: model) { counts in
                counts.accepts += 1
                counts.words += max(0, words)
                counts.characters += max(0, characters)
                if firstOfSuggestion { counts.used += 1 }
            }
        }
    }

    mutating func recordTakenBack(surface: String, model: String, at date: Date, calendar: Calendar = .current) {
        record(at: date, calendar: calendar) { bucket in
            bucket.update(surface: surface, model: model) { $0.takenBack += 1 }
        }
    }

    mutating func recordTyped(characters: Int, gapMilliseconds: Int?, at date: Date, calendar: Calendar = .current) {
        record(at: date, calendar: calendar) { bucket in
            bucket.typedCharacters += max(0, characters)
            if let gap = gapMilliseconds, gap >= 0, gap <= Self.maxTypingGapMilliseconds {
                bucket.typingMilliseconds += gap
                bucket.typingGaps += 1
            }
        }
    }

    mutating func recordTypoFixed(at date: Date, calendar: Calendar = .current) {
        record(at: date, calendar: calendar) { $0.typosFixed += 1 }
    }

    private mutating func record(at date: Date, calendar: Calendar, _ change: (inout CotypingUsageBucket) -> Void) {
        let day = Self.dayKey(date, calendar: calendar)
        if days[day] == nil { prune(before: date, calendar: calendar) }
        change(&days[day, default: .init()])
        change(&months[Self.monthKey(date, calendar: calendar), default: .init()])
    }

    private mutating func prune(before date: Date, calendar: Calendar) {
        guard let cutoff = calendar.date(byAdding: .day, value: -(Self.retainedDays - 1),
                                         to: calendar.startOfDay(for: date)) else { return }
        let oldest = Self.dayKey(cutoff, calendar: calendar)
        days = days.filter { $0.key >= oldest }
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func monthKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }
}

enum CotypingUsageRange: String, CaseIterable, Identifiable, Sendable {
    case week, month, year, allTime

    var id: String { rawValue }

    var label: String {
        switch self {
        case .week: "7 days"
        case .month: "30 days"
        case .year: "12 months"
        case .allTime: "All time"
        }
    }
}

struct CotypingUsageSummary: Equatable, Sendable {
    struct Bar: Identifiable, Equatable, Sendable {
        var start: Date
        var bucket: CotypingUsageBucket
        var id: Date { start }
    }

    var range: CotypingUsageRange
    var total: CotypingUsageBucket
    var bars: [Bar]
    var barUnit: Calendar.Component
    var millisecondsPerKeystroke: Double?

    var wordsPerMinute: Int? {
        millisecondsPerKeystroke.map { Int((60_000 / ($0 * 5)).rounded()) }
    }

    var timeSavedSeconds: Double {
        Double(total.suggestions.keystrokesSaved)
            * (millisecondsPerKeystroke ?? CotypingUsageHistory.fallbackMillisecondsPerKeystroke) / 1_000
    }

    var activeBars: Int { bars.filter { $0.bucket.suggestions.accepts > 0 }.count }
}

extension CotypingUsageHistory {
    func summary(_ range: CotypingUsageRange, now: Date = Date(), calendar: Calendar = .current) -> CotypingUsageSummary {
        let today = calendar.startOfDay(for: now)
        var bars: [CotypingUsageSummary.Bar] = []
        let unit: Calendar.Component
        switch range {
        case .week, .month:
            unit = .day
            let count = range == .week ? 7 : 30
            for offset in stride(from: count - 1, through: 0, by: -1) {
                guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
                bars.append(.init(start: day, bucket: days[Self.dayKey(day, calendar: calendar)] ?? .init()))
            }
        case .year, .allTime:
            unit = .month
            guard let thisMonth = calendar.dateInterval(of: .month, for: now)?.start else { break }
            var count = 12
            if range == .allTime {
                let first = months.filter { !$0.value.isEmpty }.keys.min()
                    .flatMap { Self.monthStart($0, calendar: calendar) } ?? thisMonth
                count = max(1, (calendar.dateComponents([.month], from: first, to: thisMonth).month ?? 0) + 1)
            }
            for offset in stride(from: count - 1, through: 0, by: -1) {
                guard let month = calendar.date(byAdding: .month, value: -offset, to: thisMonth) else { continue }
                bars.append(.init(start: month, bucket: months[Self.monthKey(month, calendar: calendar)] ?? .init()))
            }
        }
        var total = CotypingUsageBucket()
        for bar in bars { total.merge(bar.bucket) }
        var everything = CotypingUsageBucket()
        for month in months.values {
            everything.typingMilliseconds += month.typingMilliseconds
            everything.typingGaps += month.typingGaps
        }
        return CotypingUsageSummary(
            range: range, total: total, bars: bars, barUnit: unit,
            millisecondsPerKeystroke: everything.millisecondsPerKeystroke)
    }

    private static func monthStart(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1))
    }
}
