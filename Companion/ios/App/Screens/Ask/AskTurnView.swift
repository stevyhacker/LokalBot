import LokalBotCompanionKit
import SwiftUI

/// One question and its answer, or what to do when the Mac can't answer.
struct AskTurnView: View {
    @Environment(CompanionSession.self) private var session
    let turn: AskModel.Turn
    let isFirst: Bool
    let model: AskModel
    @Binding var citationTarget: MeetingRoute?
    @State private var copied = false

    private let format = LBFormat.current

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !isFirst { Divider() }
            question
            answer
            if let results = turn.localResults {
                LocalResults(hits: results)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var question: some View {
        VStack(alignment: .leading, spacing: 7) {
            metadata("You", systemImage: "person.crop.circle", time: turn.askedAt)
            Text(turn.request.question)
                .font(LBTokens.Typography.question)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder private var answer: some View {
        switch turn.state {
        case .answering where turn.answer.isEmpty:
            LoadingStateLabel("Asking \(session.macName)…")
        case .answering, .answered:
            VStack(alignment: .leading, spacing: 10) {
                metadata(turn.state == .answering ? "LokalBot is answering" : "LokalBot",
                         systemImage: "sparkles", time: turn.result?.answeredAt)
                answerText
                if let result = turn.result {
                    answerActions(result)
                    if !result.citations.isEmpty { sources(result.citations) }
                    origin(result)
                }
            }
        case .macUnreachable:
            unreachable
        case .queued:
            Label {
                Text("Waiting for your Mac. It's sent the next time your Mac is reachable, and you'll get a notification with the answer.")
            } icon: {
                Image(systemName: "clock.arrow.2.circlepath")
            }
            .font(LBTokens.Typography.secondary)
            .foregroundStyle(LBTokens.Palette.attentionText)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lbStatusSurface(LBTokens.Palette.attention)
        case .failed(let message):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Brand.error)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Answer unavailable").font(LBTokens.Typography.body.weight(.semibold))
                    Text(message).font(LBTokens.Typography.secondary).workspaceSupportingForeground()
                }
                Spacer(minLength: 8)
                Button("Retry") { Task { await model.retry(turn.id, session: session) } }
                    .buttonStyle(.bordered)
            }
            .padding(12)
            .lbGroupedSurface()
        }
    }

    private var answerText: some View {
        let valid = Set(turn.result?.citations.map(\.index) ?? [])
        let markdown = AskCitationParser.linkedMarkdown(turn.answer, valid: valid, streaming: turn.state == .answering)
        return MarkdownText(markdown, inline: Self.styledCitations)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                guard let number = AskCitationParser.citationNumber(from: url) else { return .systemAction }
                if let citation = turn.result?.citations.first(where: { $0.index == number }), let meetingID = citation.meetingId {
                    citationTarget = MeetingRoute(id: meetingID, offset: citation.at)
                }
                return .handled
            })
    }

    /// `[n]` source badges inside the answer: teal on a teal wash.
    static func styledCitations(_ text: String) -> AttributedString {
        var attributed = MarkdownInline.attributed(text)
        for run in attributed.runs where run.link?.scheme == AskCitationParser.scheme {
            attributed[run.range].font = LBTokens.Typography.secondary.weight(.semibold).monospacedDigit()
            attributed[run.range].foregroundColor = Brand.teal
            attributed[run.range].backgroundColor = Brand.teal.opacity(0.12)
        }
        return attributed
    }

    private func answerActions(_ result: AskResult) -> some View {
        HStack(spacing: 16) {
            Button {
                UIPasteboard.general.string = AskCitationParser.plainText(result.answer)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
            ShareLink(item: AskCitationParser.plainText(result.answer)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        .font(LBTokens.Typography.secondary)
        .buttonStyle(.plain)
        .foregroundStyle(LBTokens.Palette.supporting)
    }

    /// Numbered sources, as the Mac lists them under an answer.
    private func sources(_ citations: [AskCitation]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Sources", systemImage: "checkmark.shield")
                .font(LBTokens.Typography.secondary.weight(.semibold))
            ForEach(citations) { citation in
                if let meetingID = citation.meetingId {
                    NavigationLink(value: MeetingRoute(id: meetingID, offset: citation.at)) {
                        sourceRow(citation, available: true)
                    }
                    .buttonStyle(.plain)
                    .lbHoverEffect()
                } else {
                    sourceRow(citation, available: false)
                }
            }
        }
    }

    private func sourceRow(_ citation: AskCitation, available: Bool) -> some View {
        HStack(spacing: 10) {
            Text("\(citation.index)")
                .font(LBTokens.Typography.secondary.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: 22, minHeight: 22)
                .background(Brand.tealFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Image(systemName: available ? "person.2" : "display")
                .foregroundStyle(LBTokens.Palette.supporting)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(citation.label)
                .font(LBTokens.Typography.body.weight(available ? .semibold : .regular))
                .foregroundStyle(available ? Color.primary : LBTokens.Palette.supporting)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 4)
            if available {
                Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .lbGroupedSurface()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(available ? "Opens the meeting at this moment" : "A screen moment, shown as text only")
    }

    /// Where the answer was produced: teal for the Mac's own engine, amber
    /// for an approved remote engine.
    private func origin(_ result: AskResult) -> some View {
        let remote = result.location == .remote
        return HStack(spacing: 6) {
            StatusDot(color: remote ? Brand.amber : LBTokens.Palette.accentFill, size: 7)
            Text(remote ? "Answered with an approved remote engine · \(result.engineLabel)"
                        : "Answered on your Mac · \(result.engineLabel)")
        }
        .font(LBTokens.Typography.caption.weight(.medium))
        .foregroundStyle(remote ? LBTokens.Palette.attentionText : Brand.teal)
        .accessibilityElement(children: .combine)
    }

    private var unreachable: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Your Mac isn't reachable", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                .font(LBTokens.Typography.body.weight(.semibold))
                .foregroundStyle(LBTokens.Palette.attentionText)
            Text("It needs to be awake with sharing on, on the same Wi-Fi or on Tailscale. Until then you can search what's on this device, or let the question wait.")
                .font(LBTokens.Typography.secondary)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: 8, lineSpacing: 8) {
                Button {
                    Task { await model.searchDevice(turn.id, session: session) }
                } label: {
                    Label("Search This Device", systemImage: "magnifyingglass")
                }
                .buttonStyle(.bordered)
                Button {
                    Task {
                        await QueuedAnswerNotification.requestPermission()
                        await model.queue(turn.id, session: session)
                    }
                } label: {
                    Label("Ask When My Mac Is Back", systemImage: "clock.arrow.2.circlepath")
                }
                .primaryActionButton()
                Button("Try Again") { Task { await model.retry(turn.id, session: session) } }
                    .buttonStyle(.workspaceLink)
                    .padding(.vertical, 7)
            }
            .font(LBTokens.Typography.secondary.weight(.medium))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lbStatusSurface(LBTokens.Palette.attention)
    }

    private func metadata(_ title: String, systemImage: String, time: Date?) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage).frame(width: 14)
            Text(title).fontWeight(.semibold)
            if let time {
                Text("·").foregroundStyle(.tertiary)
                Text(format.time(time)).monospacedDigit()
            }
            if turn.request.scope != nil, title == "You" {
                Text("·").foregroundStyle(.tertiary)
                Image(systemName: "scope")
                Text(turn.request.scope?.day != nil ? "One day" : "One meeting").lineLimit(1)
            }
        }
        .font(LBTokens.Typography.secondary)
        .foregroundStyle(Color.primary.opacity(0.68))
        .accessibilityElement(children: .combine)
    }
}

/// "Search this device" results, each opening its meeting or day.
struct LocalResults: View {
    let hits: [SearchHit]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("On this device", systemImage: "iphone")
                .font(LBTokens.Typography.secondary.weight(.semibold))
            if hits.isEmpty {
                Text("Nothing on this device matches. Try fewer words, or let the question wait for your Mac.")
                    .workspaceTextRole(.supporting)
            } else {
                VStack(spacing: 0) {
                    ForEach(hits) { hit in
                        Group {
                            if let meetingID = hit.meetingId {
                                NavigationLink(value: MeetingRoute(id: meetingID, offset: hit.at)) {
                                    row(hit)
                                }
                            } else if let day = hit.date.flatMap(DayKey.init) {
                                NavigationLink(value: DayRoute(day: day)) { row(hit) }
                            } else {
                                row(hit)
                            }
                        }
                        .buttonStyle(.plain)
                        if hit.id != hits.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 12)
                .lbGroupedSurface()
            }
        }
    }

    private func row(_ hit: SearchHit) -> some View {
        HStack {
            SearchHitRow(hit: hit, query: "")
            Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
