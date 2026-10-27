import SwiftUI

/// The approval window: one card for each terminal request waiting for the
/// person, listing every change it makes in full. Approve applies exactly
/// those changes through the same paths as Settings; Deny changes nothing.
struct SettingsApprovalView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        SettingsApprovalList(approvals: app.settingsApprovals)
    }
}

private struct SettingsApprovalList: View {
    @ObservedObject var approvals: SettingsApprovals
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if approvals.pending.isEmpty {
                VStack(spacing: 16) {
                    Text("Nothing is waiting for your approval.")
                    Button("Close") { dismissWindow(id: "settings-approval") }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(32)
                .frame(width: 560)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(approvals.pending) { request in
                            SettingsApprovalCard(request: request)
                            if request.id != approvals.pending.last?.id { Divider() }
                        }
                    }
                    .padding(24)
                }
                .frame(width: 560)
                .frame(minHeight: 260, idealHeight: 420, maxHeight: 680)
            }
        }
        .onAppear { approvals.expireStale() }
        // The window goes away with the last request it was showing.
        .onChange(of: approvals.pending.isEmpty) { _, empty in
            if empty { dismissWindow(id: "settings-approval") }
        }
    }
}

private struct SettingsApprovalCard: View {
    @EnvironmentObject private var app: AppState
    let request: SettingsApprovals.Request

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(verbatim: request.caller).font(.scaled(.headline))
                } icon: {
                    Image(systemName: "terminal")
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(remaining(at: context.date))
                        .monospacedDigit()
                        .settingsSecondary()
                }
            }
            Text(isSecret ? secretLine : settingsLine)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: row.widens ? "exclamationmark.shield" : "slider.horizontal.3")
                            .foregroundStyle(row.widens ? Brand.error : .secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LocalizedStringKey(row.title))
                            if let detail = row.detail {
                                Text(verbatim: detail).settingsSecondary()
                            }
                            // Every value in full: this is what the person approves.
                            ForEach(row.change, id: \.self) { line in
                                Text(verbatim: line)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            if let review = request.retention {
                SettingsApprovalRetention(review: review)
            }
            if let problem = request.problem {
                Text(verbatim: problem).workspaceTextRole(.warning)
            }
            Text("Approve only what you asked your agent to do. Approving can show macOS permission prompts for what it turns on.")
                .workspaceTextRole(.trust)
            HStack {
                Spacer()
                Button("Deny") { app.settingsApprovals.deny(request.id) }
                    .accessibilityIdentifier("settingsApproval.deny")
                Button(request.retention == nil ? approveTitle : cleanupTitle,
                       role: request.retention == nil ? nil : .destructive) {
                    // A failure stays on the card as its problem.
                    try? app.approveSettingsRequest(request.id)
                }
                .primaryActionButton()
                .accessibilityIdentifier("settingsApproval.approve")
            }
        }
    }

    private let secretLine: LocalizedStringKey = "wants to save an API key in LokalBot."
    private let settingsLine: LocalizedStringKey = "wants to change LokalBot settings."
    private let approveTitle: LocalizedStringKey = "Approve"
    private let cleanupTitle: LocalizedStringKey = "Approve and clean up"

    private var isSecret: Bool {
        if case .secret = request.subject { return true }
        return false
    }

    private struct Row: Identifiable {
        let id: String
        let title: String
        let detail: String?
        let change: [String]
        let widens: Bool
    }

    private var rows: [Row] {
        if case .secret(let secret, _) = request.subject {
            let change = request.changes.first
            return [Row(
                id: secret.rawValue, title: secret.title, detail: secret.summary,
                change: ["\(change?["previous"]?.stringValue ?? "") → \(change?["value"]?.stringValue ?? "")"],
                widens: true)]
        }
        let language = app.settings.appLanguage
        return request.items.map { item in
            Row(id: item.spec.key,
                title: item.spec.title,
                detail: item.change == .widening ? item.spec.summary : nil,
                change: item.spec.changeLines(from: item.previous, to: item.stored, language: language),
                widens: item.change == .widening)
        }
    }

    private func remaining(at date: Date) -> String {
        let seconds = max(0, Int(request.expiresAt.timeIntervalSince(date)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// The same counts the retention review in Settings shows. Approving deletes
/// exactly this.
private struct SettingsApprovalRetention: View {
    let review: RetentionReview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keep images and activity titles for \(review.days) days. "
                 + (review.keepTextForever
                    ? "Keep unsaved screen text and metadata indefinitely."
                    : "Delete unsaved screen text, metadata, and search vectors on the same schedule."))
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 6) {
                GridRow { Text("Images to remove"); Text(verbatim: "\(review.pixelCount)") }
                GridRow { Text("Text records to remove"); Text(verbatim: "\(review.textCount)") }
                GridRow { Text("Search vectors to remove"); Text(verbatim: "\(review.vectorCount)") }
                GridRow { Text("Activity titles to clear"); Text(verbatim: "\(review.activityTitles.count)") }
                GridRow { Text("Saved moments preserved"); Text(verbatim: "\(review.savedCount)") }
            }
            Text("Cleanup cannot be undone. The policy stays unchanged until you apply this review. Failed deletions remain visible and can be retried.")
                .workspaceTextRole(.trust)
        }
    }
}

/// The menu bar row for requests waiting for the person.
struct SettingsApprovalMenuRow: View {
    @ObservedObject var approvals: SettingsApprovals

    var body: some View {
        if !approvals.pending.isEmpty {
            Button { WindowAccess.shared.open("settings-approval") } label: {
                Label(title, systemImage: "exclamationmark.shield.fill")
                    .font(.scaled(.caption))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Brand.error)
            .accessibilityIdentifier("menuBar.settingsApproval")
        }
    }

    private var title: LocalizedStringKey {
        approvals.pending.count == 1
            ? "A settings change is waiting for your approval"
            : "\(approvals.pending.count) settings changes are waiting for your approval"
    }
}

extension SettingSpec {
    /// What the approval card says a change does, in full. Lists name every
    /// entry added and removed; other values show before and after.
    func changeLines(from old: JSONValue?, to new: JSONValue?, language: AppLanguage = .english) -> [String] {
        if let before = listEntries(old), let after = listEntries(new) {
            let beforeKeys = Set(before.map { $0.lowercased() })
            let afterKeys = Set(after.map { $0.lowercased() })
            let added = after.filter { !beforeKeys.contains($0.lowercased()) }
            let removed = before.filter { !afterKeys.contains($0.lowercased()) }
            var lines: [String] = []
            if !added.isEmpty {
                lines.append(String(format: language.localized("Adds: %@"), added.joined(separator: ", ")))
            }
            if !removed.isEmpty {
                lines.append(String(format: language.localized("Removes: %@"), removed.joined(separator: ", ")))
            }
            if !lines.isEmpty { return lines }
        }
        let before = displayText(old, language: language)
        let after = displayText(new, language: language)
        guard before == after, old != new else { return ["\(before) → \(after)"] }
        // A URL's user info or query, or a structured value, changed.
        return ["\(before) → \(after)",
                language.localized("Changes details that are hidden here, such as a URL's password or query.")]
    }

    /// A setting's whole value as the person reads it. URLs leave out user
    /// info and query.
    func displayText(_ value: JSONValue?, language: AppLanguage = .english) -> String {
        guard let value else { return language.localized("Default") }
        switch value {
        case .bool(let flag):
            return language.localized(flag ? "On" : "Off")
        case .number(let number):
            return presented(value).stringValue
                ?? (number == number.rounded() ? String(Int(number)) : String(number))
        case .string(let string):
            if case .text(.url) = kind { return DiagnosticsSettingsSanitizer.redactURL(string) }
            if string.isEmpty { return language.localized("Not set") }
            // Choices stored as display names read better than tokens.
            if case .choice = kind { return language.localized(string) }
            return string
        case .array(let items):
            let names = items.map { presented($0).stringValue ?? "?" }
            return names.isEmpty ? language.localized("None") : names.joined(separator: ", ")
        case .null, .object:
            return language.localized("Configured")
        }
    }

    /// The entries of a list setting, or nil for other settings.
    private func listEntries(_ value: JSONValue?) -> [String]? {
        switch kind {
        case .textList, .choiceList:
            guard case .array(let items)? = value else { return value == nil ? [] : nil }
            return items.map { presented($0).stringValue ?? "?" }
        case .text(.commaSeparated):
            return (value?.stringValue ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        default:
            return nil
        }
    }
}
