import Foundation

struct CotypingLiveMeasure: Codable, Equatable, Sendable {
    var shown = 0
    var visibleLatenciesMs: [Int] = []
    var accepts = 0
    var insertionsConfirmed = 0
    var insertionsMismatched = 0
    var insertionsUnconfirmed = 0
    var acceptsCorrected = 0

    static let maxLatencies = 50

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func count(_ key: CodingKeys) throws -> Int {
            try container.decodeIfPresent(Int.self, forKey: key) ?? 0
        }
        shown = try count(.shown)
        visibleLatenciesMs = try container.decodeIfPresent([Int].self, forKey: .visibleLatenciesMs) ?? []
        accepts = try count(.accepts)
        insertionsConfirmed = try count(.insertionsConfirmed)
        insertionsMismatched = try count(.insertionsMismatched)
        insertionsUnconfirmed = try count(.insertionsUnconfirmed)
        acceptsCorrected = try count(.acceptsCorrected)
    }

    var isEmpty: Bool { self == CotypingLiveMeasure() }
    var medianVisibleMs: Int? { Self.percentile(visibleLatenciesMs, 0.5) }
    var p95VisibleMs: Int? { Self.percentile(visibleLatenciesMs, 0.95) }
    var insertionsChecked: Int { insertionsConfirmed + insertionsMismatched }

    mutating func recordShown(latencyMs: Int) {
        shown += 1
        visibleLatenciesMs.append(max(0, latencyMs))
        if visibleLatenciesMs.count > Self.maxLatencies {
            visibleLatenciesMs.removeFirst(visibleLatenciesMs.count - Self.maxLatencies)
        }
    }

    mutating func record(_ outcome: CotypingInsertionCheck.Outcome) {
        switch outcome {
        case .confirmed: insertionsConfirmed += 1
        case .mismatched: insertionsMismatched += 1
        case .unconfirmed: insertionsUnconfirmed += 1
        case .pending: break
        }
    }

    mutating func merge(_ other: CotypingLiveMeasure) {
        shown += other.shown
        visibleLatenciesMs += other.visibleLatenciesMs
        accepts += other.accepts
        insertionsConfirmed += other.insertionsConfirmed
        insertionsMismatched += other.insertionsMismatched
        insertionsUnconfirmed += other.insertionsUnconfirmed
        acceptsCorrected += other.acceptsCorrected
    }

    static func percentile(_ samples: [Int], _ p: Double) -> Int? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let index = max(0, min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[index]
    }
}

struct CotypingInsertionCheck: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case pending
        case confirmed
        case mismatched
        case unconfirmed
    }

    static let timeoutMilliseconds = 1_500
    private static let tailLength = 48

    let tail: String
    private(set) var inserted: String
    private(set) var count = 1
    let surface: String
    let processID: pid_t
    let role: String
    private(set) var startedUptimeNanoseconds: UInt64

    init(field: CotypingField, inserted: String, surface: String, startedUptimeNanoseconds: UInt64) {
        tail = Self.normalized(String(field.precedingText.suffix(Self.tailLength)))
        self.inserted = Self.normalized(inserted)
        self.surface = surface
        processID = field.processID
        role = field.role
        self.startedUptimeNanoseconds = startedUptimeNanoseconds
    }

    mutating func extend(byInserting text: String, at uptimeNanoseconds: UInt64) {
        inserted += Self.normalized(text)
        count += 1
        startedUptimeNanoseconds = uptimeNanoseconds
    }

    func outcome(live: CotypingField?, elapsedMilliseconds: Int) -> Outcome {
        let timedOut = elapsedMilliseconds >= Self.timeoutMilliseconds
        guard let live, live.processID == processID, live.role == role else {
            return timedOut ? .unconfirmed : .pending
        }
        let text = Self.normalized(live.precedingText)
        let window = String(text.suffix(tail.count + inserted.count + 64))
        if window.contains(tail + inserted) { return .confirmed }
        guard timedOut else { return .pending }
        let after: Substring
        if tail.isEmpty {
            after = Substring(window)
        } else if let before = window.range(of: tail, options: .backwards) {
            after = window[before.upperBound...]
        } else {
            return .unconfirmed
        }
        return after.isEmpty ? .unconfirmed : .mismatched
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}

extension CotypingSurfaceClass {
    var measureTitle: String {
        switch self {
        case .other: "Native apps"
        case .browser: "Browsers"
        case .chat: "Chat"
        case .email: "Email"
        case .codeEditor: "Code editors"
        case .terminal: "Terminals"
        }
    }

    static let measured: [CotypingSurfaceClass] = [.other, .browser, .chat, .email, .codeEditor, .terminal]
}

extension CotypingStats {
    var liveTotal: CotypingLiveMeasure {
        var total = CotypingLiveMeasure()
        for measure in live.values { total.merge(measure) }
        return total
    }

    var liveRows: [(title: String, measure: CotypingLiveMeasure)] {
        var rows: [(title: String, measure: CotypingLiveMeasure)] = []
        for surface in CotypingSurfaceClass.measured {
            if let measure = live[surface.rawValue], !measure.isEmpty {
                rows.append((surface.measureTitle, measure))
            }
        }
        return rows
    }

    func report(model: String) -> String {
        var lines = ["Autocomplete typing measurements (\(model))"]
        let generation = medianLatencyMs.map { " · generation median \($0) ms, p95 \(p95LatencyMs ?? $0) ms" } ?? ""
        lines.append("Suggested \(generations) · accepted \(accepts)\(generation)")
        lines.append("")
        lines.append("| Surface | Shown | Keystroke to visible (median / p95) | Accepted | Insertions confirmed / wrong / unconfirmed | Corrected right after |")
        lines.append("| --- | ---: | ---: | ---: | ---: | ---: |")
        var rows = liveRows
        if rows.count > 1 { rows.append(("All", liveTotal)) }
        for row in rows {
            let measure = row.measure
            let timing = measure.medianVisibleMs.map { "\($0) / \(measure.p95VisibleMs ?? $0) ms" } ?? "n/a"
            let insertions = "\(measure.insertionsConfirmed) / \(measure.insertionsMismatched) / \(measure.insertionsUnconfirmed)"
            lines.append("| \(row.title) | \(measure.shown) | \(timing) | \(measure.accepts) | \(insertions) | \(measure.acceptsCorrected) |")
        }
        if rows.isEmpty { lines.append("| No typing measured yet | 0 | n/a | 0 | 0 / 0 / 0 | 0 |") }
        return lines.joined(separator: "\n")
    }
}
