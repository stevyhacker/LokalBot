import Combine
import Foundation

/// One recorded local-generation pass — narrow on purpose: just what a Settings →
/// Performance row shows. `tokensPerSec` is derived so the throughput figure can't
/// drift out of sync with the duration/token inputs it's computed from.
struct GenerationMetric: Identifiable, Equatable {
    let id: UUID
    let label: String
    let date: Date
    let durationSec: Double
    let approxTokens: Int

    /// Throughput, guarding the divide so a zero/negative duration reads as 0
    /// rather than infinity or NaN poisoning a displayed average.
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

/// In-memory ring of the most recent local-generation timings, published for a
/// live Settings → Performance readout. Deliberately not persisted: these numbers
/// matter only while you're watching them, and a bounded window keeps the array
/// renderable without virtualization. Merges Cotabby's two metrics stores into the
/// single shape LokalBot needs (rolling window + per-pass throughput).
@MainActor
final class GenerationMetricsStore: ObservableObject {
    /// Shared sink the generation paths record into.
    static let shared = GenerationMetricsStore()

    /// Retained window size. Old entries fall off the front, so `recent.last` is
    /// always the newest pass and the array stays in chronological order.
    static let maximumMetrics = 20

    @Published private(set) var recent: [GenerationMetric] = []

    /// Not private despite the singleton: tests construct isolated instances to
    /// exercise the ring without mutating `shared`.
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
