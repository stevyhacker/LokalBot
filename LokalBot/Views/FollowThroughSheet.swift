import SwiftUI

/// Follow-through for one action: Muse's reads, then each proposed step as an
/// editable card. Approving opens the step as a draft in the person's own app.
struct FollowThroughSheet: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var session: FollowThroughSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(session.steps) { step in
                            stepView(step).id(step.id)
                        }
                        progress.id("progress")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .onChange(of: session.steps.count) { proxy.scrollTo("progress", anchor: .bottom) }
            }
            Divider()
            footer
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 700, minHeight: 600, idealHeight: 720)
        .onAppear { session.start() }
        .onDisappear { if session.state != .finished { session.cancel() } }
        .accessibilityIdentifier("followThrough.sheet")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Follow Through").font(.scaled(.title2).bold())
                BrandChip(icon: "sparkles", text: MetaModelAPI.displayName(for: session.model), size: .compact)
            }
            Text(session.target.text).font(.scaled(.headline)).textSelection(.enabled)
            Text("From \(session.target.meetingTitle) · \(session.target.meetingDate.formatted(date: .abbreviated, time: .shortened))"
                 + (session.target.due.map { " · due \($0)" } ?? ""))
                .workspaceTextRole(.supporting)
        }
    }

    @ViewBuilder private func stepView(_ step: FollowThroughSession.Step) -> some View {
        switch step {
        case .read(_, let tool, let summary):
            Label("\(Self.readLabel(tool)): \(summary)", systemImage: "magnifyingglass")
                .font(.scaled(.callout)).foregroundStyle(.secondary)
        case .note(_, let text):
            Text(text).font(.scaled(.callout))
        case .proposal(let proposal):
            ProposalCard(proposal: proposal,
                         codingAgents: ActionAgentAvailability.installed,
                         approve: { session.approve($0) },
                         decline: { session.decline(proposal.id) })
                .id("\(proposal.id)-\(String(describing: proposal.status))")
        }
    }

    @ViewBuilder private var progress: some View {
        switch session.state {
        case .idle, .working:
            LoadingStateLabel("Muse is planning the next step…")
        case .waitingForApproval:
            Text("Waiting for you to approve or decline the step above.").workspaceTextRole(.supporting)
        case .finished:
            VStack(alignment: .leading, spacing: 6) {
                Label("Done", systemImage: "checkmark.seal").font(.scaled(.headline))
                Text(session.summary ?? "Follow-through finished.")
                    .font(LBTokens.Typography.reading).textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lbStatusSurface(LBTokens.Palette.success)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.scaled(.callout)).foregroundStyle(Brand.error)
                .accessibilityIdentifier("followThrough.error")
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Sends the action, its source passages, the meeting notes, and what Muse reads from your meetings to api.meta.ai. "
                 + "Nothing is sent to anyone until you approve a step, and approved steps open as drafts. "
                 + RadarItemList.costLabel(session.cost) + " so far.")
                .font(.scaled(.caption)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 16)
            if session.state == .working || session.state == .waitingForApproval {
                Button("Stop") { session.cancel() }
            }
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private static func readLabel(_ tool: String) -> String {
        switch tool {
        case "search_meetings": "Searched meetings"
        case "get_meeting": "Read meeting"
        case "get_action_items": "Read actions"
        default: tool
        }
    }
}

/// One proposed step. Pending steps are editable; the person's version is
/// what runs.
private struct ProposalCard: View {
    let proposal: FollowThroughProposal
    let codingAgents: [ActionAgentHandoff]
    let approve: (FollowThroughProposal) -> Void
    let decline: () -> Void

    @State private var to = ""
    @State private var cc = ""
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var title = ""
    @State private var start = Date()
    @State private var minutes = 30
    @State private var agent: ActionAgentHandoff = .claudeCode
    @State private var loaded = false

    private var isPending: Bool { proposal.status == .pending }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: proposal.systemImage).foregroundStyle(LBTokens.Palette.accentText)
                Text(proposal.title).font(.scaled(.headline))
                Spacer()
                statusLabel
            }
            if !proposal.rationale.isEmpty {
                Text(proposal.rationale).workspaceTextRole(.supporting)
            }
            fields.disabled(!isPending)
            if isPending {
                HStack {
                    Button(approveTitle) { approve(edited()) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("followThrough.approve")
                    Button("Decline") { decline() }
                        .accessibilityIdentifier("followThrough.decline")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lbGroupedSurface()
        .onAppear(perform: load)
    }

    @ViewBuilder private var statusLabel: some View {
        switch proposal.status {
        case .pending:
            EmptyView()
        case .approved(let result):
            Label(result.isEmpty ? "Approved" : result, systemImage: "checkmark.circle.fill")
                .font(.scaled(.caption)).foregroundStyle(LBTokens.Palette.successText)
                .lineLimit(2)
        case .declined:
            Label("Declined", systemImage: "xmark.circle").font(.scaled(.caption)).foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.scaled(.caption)).foregroundStyle(Brand.error).lineLimit(2)
        }
    }

    @ViewBuilder private var fields: some View {
        switch proposal.kind {
        case .email:
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow { Text("To").foregroundStyle(.secondary); TextField("Names or addresses", text: $to) }
                GridRow { Text("Cc").foregroundStyle(.secondary); TextField("", text: $cc) }
                GridRow { Text("Subject").foregroundStyle(.secondary); TextField("", text: $subject) }
            }
            .font(.scaled(.callout))
            editor($bodyText, minHeight: 160)
            Text("LokalBot fills in addresses from the meeting's calendar invitation on this Mac.")
                .font(.scaled(.caption)).foregroundStyle(.secondary)
        case .event:
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow { Text("Title").foregroundStyle(.secondary); TextField("", text: $title) }
                GridRow {
                    Text("Starts").foregroundStyle(.secondary)
                    DatePicker("", selection: $start).labelsHidden()
                }
                GridRow {
                    Text("Length").foregroundStyle(.secondary)
                    Stepper("\(minutes) minutes", value: $minutes, in: 5...480, step: 5)
                }
                GridRow { Text("Invite").foregroundStyle(.secondary); TextField("Names or addresses", text: $to) }
            }
            .font(.scaled(.callout))
            editor($bodyText, minHeight: 80)
        case .codingTask:
            if codingAgents.count > 1 {
                Picker("Agent", selection: $agent) {
                    ForEach(codingAgents) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            editor($bodyText, minHeight: 140)
        case .markDone(let note):
            if !note.isEmpty { Text(note).font(.scaled(.callout)) }
        }
    }

    private func editor(_ text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.scaled(.callout))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 6))
    }

    private var approveTitle: String {
        switch proposal.kind {
        case .email: "Open in Mail"
        case .event: "Open in Calendar"
        case .codingTask: "Open in \(agent.rawValue)"
        case .markDone: "Mark Done"
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch proposal.kind {
        case .email(let recipients, let copies, let subjectLine, let body):
            to = recipients.joined(separator: ", ")
            cc = copies.joined(separator: ", ")
            subject = subjectLine
            bodyText = body
        case .event(let eventTitle, let eventStart, let eventMinutes, let attendees, let notes):
            title = eventTitle
            start = eventStart
            minutes = eventMinutes
            to = attendees.joined(separator: ", ")
            bodyText = notes
        case .codingTask(let chosen, let prompt):
            agent = chosen
            bodyText = prompt
        case .markDone:
            break
        }
    }

    private func edited() -> FollowThroughProposal {
        func list(_ text: String) -> [String] {
            text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        var result = proposal
        switch proposal.kind {
        case .email:
            result.kind = .email(to: list(to), cc: list(cc), subject: subject, body: bodyText)
        case .event:
            result.kind = .event(title: title, start: start, minutes: minutes, attendees: list(to), notes: bodyText)
        case .codingTask:
            result.kind = .codingTask(agent: agent, prompt: bodyText)
        case .markDone:
            break
        }
        return result
    }
}
