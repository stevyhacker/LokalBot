import Foundation

enum InferencePriority: Int, Comparable, CaseIterable, Sendable {
    case interactive = 0
    case agent = 1
    case pipeline = 2
    case background = 3

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .interactive: "interactive"
        case .agent: "agent"
        case .pipeline: "pipeline"
        case .background: "background"
        }
    }
}

enum InferenceRole: String, CaseIterable, Sendable {
    case mainLLM
    case embedder
    case cotypingServer

    var serverRole: LlamaServerRole {
        switch self {
        case .mainLLM: .main
        case .embedder: .embedder
        case .cotypingServer: .cotyping
        }
    }

    init?(serverRole: LlamaServerRole) {
        guard let role = Self.allCases.first(where: { $0.serverRole == serverRole }) else {
            return nil
        }
        self = role
    }

    var residencyID: String { serverRole.residencyID }

    var defaultLingerSeconds: TimeInterval {
        switch self {
        case .mainLLM: 600
        case .embedder: 600
        case .cotypingServer: 900
        }
    }
}

struct InferenceLease: Identifiable, Equatable, Sendable {
    let id: UUID
    let role: InferenceRole
    let modelPath: String
    let priority: InferencePriority
    let purpose: String
}

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

    var pinnedResidencyIDs: Set<String> {
        Set(records.map { $0.lease.role.residencyID })
    }

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
