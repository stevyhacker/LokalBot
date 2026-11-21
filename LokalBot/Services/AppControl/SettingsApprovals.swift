import Foundation

@MainActor
final class SettingsApprovals: ObservableObject {
    enum Subject: Equatable {
        case settings(SettingsChangeRequest)
        case secret(AppSecret, value: String)
        case meetingImport(MeetingImportRequest)
    }

    struct MeetingImportRequest: Equatable {
        var source: ExternalMeetingSource
        var paths: [String]
    }

    struct Request: Identifiable {
        let id: UUID
        let caller: String
        let createdAt: Date
        let expiresAt: Date
        var subject: Subject
        var changes: [JSONValue]
        var items: [SettingsChangePlan.Item]
        var retention: RetentionReview?
        var state: SettingsRequestState = .pending
        var answeredAt: Date?
        var result: JSONValue?
        var problem: String?

        var json: JSONValue {
            var object: [String: JSONValue] = [
                "id": .string(id.uuidString),
                "state": .string(state.rawValue),
                "caller": .string(caller),
                "createdAt": .string(Self.timestamp(createdAt)),
                "expiresAt": .string(Self.timestamp(expiresAt)),
                "changes": .array(changes),
            ]
            if let answeredAt { object["answeredAt"] = .string(Self.timestamp(answeredAt)) }
            if let result { object["result"] = result }
            if let retention {
                object["retentionReview"] = [
                    "days": .number(Double(retention.days)),
                    "keepTextForever": .bool(retention.keepTextForever),
                    "imagesRemoved": .number(Double(retention.pixelCount)),
                    "textRecordsRemoved": .number(Double(retention.textCount)),
                    "activityTitlesCleared": .number(Double(retention.activityTitles.count)),
                ]
            }
            return .object(object)
        }

        var headline: String {
            switch subject {
            case .secret(let secret, _):
                return "Setting the \(secret.title)"
            case .meetingImport(let request):
                return "Importing meetings from \(request.source.title)"
            case .settings:
                let titles = items.filter { $0.change == .widening }.map(\.spec.title)
                return titles.isEmpty ? "This change" : titles.joined(separator: ", ")
            }
        }

        private static func timestamp(_ date: Date) -> String {
            ISO8601DateFormatter().string(from: date)
        }
    }

    static let lifetime: TimeInterval = 5 * 60
    static let maximumPending = 5
    static let answeredLifetime: TimeInterval = 30 * 60

    @Published private(set) var pending: [Request] = []
    private var answered: [Request] = []
    private let now: () -> Date

    var announce: (Request) -> Void = { _ in }
    var withdraw: (Request) -> Void = { _ in }

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func submit(_ subject: Subject, caller: String, items: [SettingsChangePlan.Item],
                changes: [JSONValue], retention: RetentionReview? = nil) throws -> Request {
        expireStale()
        if !subject.holdsSecret,
           let existing = pending.first(where: { $0.subject == subject && $0.caller == caller }) {
            return existing
        }
        guard pending.count < Self.maximumPending else { throw AppControlError.tooManyRequests }
        let created = now()
        let request = Request(
            id: UUID(), caller: caller, createdAt: created,
            expiresAt: created.addingTimeInterval(Self.lifetime),
            subject: subject, changes: changes, items: items, retention: retention)
        pending.append(request)
        scheduleExpiry(of: request.id)
        announce(request)
        return request
    }

    func request(_ id: UUID) -> Request? {
        expireStale()
        return pending.first { $0.id == id } ?? answered.first { $0.id == id }
    }

    func approve(_ id: UUID, apply: (Request) throws -> JSONValue) throws {
        expireStale()
        guard let index = pending.firstIndex(where: { $0.id == id }) else {
            switch request(id)?.state {
            case .approved?: return
            case .denied?: throw AppControlError.denied
            case .expired?: throw AppControlError.expired
            case .pending?, nil: throw AppControlError.unknownRequest(id.uuidString)
            }
        }
        do {
            let result = try apply(pending[index])
            if let index = pending.firstIndex(where: { $0.id == id }) {
                finish(at: index, as: .approved, result: result)
            }
        } catch {
            if let index = pending.firstIndex(where: { $0.id == id }) {
                pending[index].problem = error.localizedDescription
            }
            throw error
        }
    }

    func deny(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        finish(at: index, as: .denied, result: nil)
    }

    func denyAll() {
        while !pending.isEmpty { finish(at: 0, as: .denied, result: nil) }
    }

    func update(_ id: UUID, _ change: (inout Request) -> Void) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        change(&pending[index])
    }

    func expireStale() {
        let current = now()
        while let index = pending.firstIndex(where: { $0.expiresAt <= current }) {
            finish(at: index, as: .expired, result: nil)
        }
        answered.removeAll { ($0.answeredAt ?? current).addingTimeInterval(Self.answeredLifetime) <= current }
    }

    private func finish(at index: Int, as state: SettingsRequestState, result: JSONValue?) {
        var request = pending.remove(at: index)
        request.state = state
        request.answeredAt = now()
        request.result = result
        request.problem = nil
        if case .secret(let secret, _) = request.subject { request.subject = .secret(secret, value: "") }
        answered.append(request)
        answered = Array(answered.suffix(50))
        withdraw(request)
    }

    private func scheduleExpiry(of id: UUID) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((Self.lifetime + 1) * 1_000_000_000))
            self?.expireStale()
        }
    }
}

extension SettingsApprovals.Subject {
    var holdsSecret: Bool {
        if case .secret = self { return true }
        return false
    }
}

enum SettingsApprovalError: LocalizedError {
    case changedWhileWaiting

    var errorDescription: String? {
        "Your settings changed while this request was waiting. Review the updated changes before approving."
    }
}
