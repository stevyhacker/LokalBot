import Combine
import Foundation

struct GenerationMetric: Identifiable, Equatable {
    let id: UUID
    let label: String
    let date: Date
    let durationSec: Double
    let approxTokens: Int

    var tokensPerSec: Double {
        durationSec > 0 ? Double(approxTokens) / durationSec : 0
    }

    init(
        id: UUID = UUID(),
        label: String,
        date: Date = Date(),
        durationSec: Double,
        approxTokens: Int
    ) {
        self.id = id
        self.label = label
        self.date = date
        self.durationSec = durationSec
        self.approxTokens = approxTokens
    }
}

@MainActor
final class GenerationMetricsStore: ObservableObject {
    static let shared = GenerationMetricsStore()

    static let maximumMetrics = 20

    @Published private(set) var recent: [GenerationMetric] = []

    init() {}

    func record(label: String, durationSec: Double, approxTokens: Int) {
        let metric = GenerationMetric(label: label, durationSec: durationSec, approxTokens: approxTokens)
        var updated = recent
        updated.append(metric)
        if updated.count > Self.maximumMetrics {
            updated.removeFirst(updated.count - Self.maximumMetrics)
        }
        recent = updated
    }
}
