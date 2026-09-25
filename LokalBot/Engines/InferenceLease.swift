import Foundation

/// Who is waiting on an inference request, in increasing order of
/// deferability. Step 1 records priorities for the dashboard and the broker
/// API; eviction stays LRU+pins — priority-ordered eviction is a step-2
/// concern once pressure-derived budgets exist.
enum InferencePriority: Int, Comparable, CaseIterable, Sendable {
    /// The user is watching this happen (chat, cotyping, model test).
    case interactive = 0
    /// An agent is waiting (Agent Mode session, external ask_library).
    case agent = 1
    /// Pipeline work nobody is watching (summaries, digests, embeddings).
    case background = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .interactive: "interactive"
        case .agent: "agent"
        case .background: "background"
        }
    }
}

/// The three shared llama-server runtimes the broker owns in step 1.
/// Granite's private ASR server (17875) holds direct ModelResidency pins during
/// preparation/transcription; it does not need a broker role.
enum InferenceRole: String, CaseIterable, Sendable {
    case mainLLM
    case embedder
    case cotypingServer

    var serverPort: Int {
        switch self {
        case .mainLLM: 17872
        case .embedder: 17873
        case .cotypingServer: 17874
        }
    }

    init?(serverPort: Int) {
        guard let role = Self.allCases.first(where: { $0.serverPort == serverPort }) else {
            return nil
        }
        self = role
    }

    /// Matches the ledger id `LlamaServer` registers under ("llama-server:<port>").
    var residencyID: String { "llama-server:\(serverPort)" }

    /// How long the server stays resident after its last lease releases —
    /// long enough that bursty consumers (chat follow-ups, typing) don't pay
    /// a model reload, short enough that the RAM comes back within minutes.
    var defaultLingerSeconds: TimeInterval {
        switch self {
        case .mainLLM: 600
        case .embedder: 600
        case .cotypingServer: 900
        }
    }
}

/// A claim on a running model: held for one request (or one Agent Mode
/// session). While any lease on a role is open, that model cannot be evicted
/// by the residency budget.
struct InferenceLease: Identifiable, Equatable, Sendable {
    let id: UUID
    let role: InferenceRole
    /// Canonical weights path served for the entire lifetime of this lease.
    /// Leases on the same role but a different model are queued by the broker.
    let modelPath: String
    let priority: InferencePriority
    let purpose: String
}

/// Pure lease bookkeeping. The broker actor owns one; keeping the arithmetic
/// here (no clocks, no tasks, no I/O) makes it unit-testable the same way
/// `ModelResidencyPolicy` is.
struct LeaseBook {
    struct Record: Equatable {
        let lease: InferenceLease
        let expiresAt: Date?
    }

    private(set) var records: [Record] = []

    mutating func acquire(role: InferenceRole, modelPath: String = "",
                          priority: InferencePriority, purpose: String,
                          expiresAt: Date? = nil) -> InferenceLease {
        let lease = InferenceLease(
            id: UUID(), role: role, modelPath: modelPath,
            priority: priority, purpose: purpose)
        records.append(Record(lease: lease, expiresAt: expiresAt))
        return lease
    }

    @discardableResult
    mutating func release(id: UUID) -> Bool {
        guard let index = records.firstIndex(where: { $0.lease.id == id }) else { return false }
        records.remove(at: index)
        return true
    }

    func record(id: UUID) -> Record? {
        records.first { $0.lease.id == id }
    }

    func activeCount(for role: InferenceRole) -> Int {
        records.filter { $0.lease.role == role }.count
    }

    /// Residency ids that must never be eviction victims right now.
    var pinnedResidencyIDs: Set<String> {
        Set(records.map { $0.lease.role.residencyID })
    }

    /// Dashboard strings per residency id, e.g. "chat (interactive)",
    /// ordered by priority then purpose so the display is stable.
    var descriptionsByResidencyID: [String: [String]] {
        var out: [String: [String]] = [:]
        let ordered = records.sorted {
            ($0.lease.priority.rawValue, $0.lease.purpose)
                < ($1.lease.priority.rawValue, $1.lease.purpose)
        }
        for record in ordered {
            out[record.lease.role.residencyID, default: []]
                .append("\(record.lease.purpose) (\(record.lease.priority.label))")
        }
        return out
    }
}
