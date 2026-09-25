import Darwin
import Foundation

/// Admission and residency ledger for runtimes that do not belong to the GGUF
/// eviction ledger. It covers retained in-process CoreML/MLX models and
/// short-lived ONNX helpers, without changing their established lifetimes.
@MainActor
final class ModelRuntimeRegistry: ObservableObject {
    static let shared = ModelRuntimeRegistry()
    private let residency: ModelResidency

    init(residency: ModelResidency? = nil) {
        self.residency = residency ?? .shared
    }

    struct Resident: Identifiable, Equatable, Sendable {
        let id: String
        var role: String
        var label: String
        var estimatedBytes: UInt64?
        var processIdentifier: pid_t?
        var processStartTime: UInt64?
    }

    @Published private(set) var residents: [Resident] = []

    var totalEstimatedBytes: UInt64 {
        residents.reduce(0) { partial, resident in
            let result = partial.addingReportingOverflow(resident.estimatedBytes ?? 0)
            return result.overflow ? UInt64.max : result.partialValue
        }
    }

    /// Account for a retained in-process model before its download/load
    /// suspends. The placeholder makes concurrent preparations and the next
    /// GGUF admission see it. Retained runtimes remain non-evictable until
    /// their established idle-unload path, so admission cannot interrupt
    /// active inference.
    func reserve(id: String, role: String, label: String,
                 estimatedBytes: UInt64?) async {
        register(id: id, role: role, label: label, estimatedBytes: estimatedBytes)
        let admission = await residency.willLoad(
            id: id, bytes: 0,
            currentReservedBytes: { Int64(clamping: self.totalEstimatedBytes) })
        // This ledger already owns the reservation; do not count it twice.
        residency.cancelLoad(admission)
    }

    func register(id: String, role: String, label: String,
                  estimatedBytes: UInt64?,
                  processIdentifier: pid_t? = nil,
                  processStartTime: UInt64? = nil) {
        let resident = Resident(
            id: id,
            role: role,
            label: label,
            estimatedBytes: estimatedBytes,
            processIdentifier: processIdentifier,
            processStartTime: processStartTime
        )
        if let index = residents.firstIndex(where: { $0.id == id }) {
            residents[index] = resident
        } else {
            residents.append(resident)
        }
    }

    func unregister(id: String) {
        residents.removeAll { $0.id == id }
    }

    nonisolated static func gibibytes(_ value: Double) -> UInt64 {
        UInt64(value * 1_073_741_824)
    }

    nonisolated static func fileBytes(at url: URL) -> UInt64? {
        guard let number = try? FileManager.default.attributesOfItem(
            atPath: url.path
        )[.size] as? NSNumber else { return nil }
        return number.uint64Value
    }
}
