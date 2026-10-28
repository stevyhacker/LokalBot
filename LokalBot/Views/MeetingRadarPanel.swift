import SwiftUI

/// The Live Radar pane beside the live transcript. Nothing is sent until the
/// person presses Start Radar for this meeting.
struct MeetingRadarPanel: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var radar: MeetingRadar
    let meeting: Meeting

    private var isThisMeeting: Bool { radar.meetingID == meeting.id }
    private var items: [RadarItem] { isThisMeeting ? radar.items : [] }
    private var unavailableReason: String? { MeetingRadar.unavailableReason(app.settings) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Live Radar").font(.scaled(.headline)).lineLimit(1)
                Spacer(minLength: 4)
                controls.fixedSize()
            }
            status
            RadarItemList(items: items, emptyMessage: emptyMessage, folder: meeting.folderURL(in: app.storage))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .lbGroupedSurface()
            Text(footnote)
                .font(.scaled(.caption2))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder private var controls: some View {
        Group {
            if isThisMeeting, radar.state == .running {
                Button("Stop Radar") { radar.stop() }
                    .accessibilityIdentifier("live.radar.stop")
            } else if isThisMeeting, case .failed = radar.state {
                Button("Retry Radar") { start() }
                    .accessibilityIdentifier("live.radar.retry")
            } else if unavailableReason != nil {
                Button("Set Up…") { app.openSettings(tab: .recording) }
                    .accessibilityIdentifier("live.radar.setup")
            } else {
                Button("Start Radar") { start() }
                    .disabled(radar.state == .finishing)
                    .accessibilityIdentifier("live.radar.start")
            }
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder private var status: some View {
        if isThisMeeting, let message = radar.statusMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.scaled(.callout)).foregroundStyle(Brand.error)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("live.radar.error")
        } else if isThisMeeting, radar.state == .running || radar.state == .finishing {
            HStack(spacing: 6) {
                if radar.isAnalyzing {
                    LoadingStateLabel("Reading the newest lines…", font: .scaled(.callout))
                } else {
                    Text("Listening with \(modelName).")
                        .workspaceTextRole(.supporting)
                }
            }
            if radar.totals.passes > 0 {
                Text(passSummary).font(.scaled(.caption).monospacedDigit()).foregroundStyle(.secondary)
            }
        } else if let reason = unavailableReason {
            Text(reason).workspaceTextRole(.supporting)
        } else {
            Text("Catches commitments, decisions, open questions, and conflicts with earlier meetings as they are said. Sends \(modelName) new live transcript lines, the meeting title, invited names, and related passages from your earlier meetings at api.meta.ai. Starts the live preview if it is off.")
                .workspaceTextRole(.supporting)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footnote: String {
        var sent = ["new transcript lines as text"]
        if app.settings.museScreenAnswersEnabled { sent.append("crops of screen captures that answer a question") }
        let audio = app.settings.museLiveTextEnabled ? "Speakers stay on this Mac; fast live text streams audio."
            : "Audio and speakers stay on this Mac."
        return "Muse reads " + sent.joined(separator: " and ") + ". " + audio
    }

    private var modelName: String {
        MetaModelAPI.displayName(for: isThisMeeting ? radar.model : app.settings.museRadarModel)
    }

    private var passSummary: String {
        let passes = "\(radar.totals.passes) pass\(radar.totals.passes == 1 ? "" : "es")"
        let last = radar.totals.lastPassSeconds.map { String(format: " · last %.1f s", $0) } ?? ""
        return passes + last + " · " + RadarItemList.costLabel(radar.totals.cost)
    }

    private var emptyMessage: String {
        guard isThisMeeting, radar.isActive else { return "Start Radar to catch commitments and conflicts as they are said." }
        return radar.totals.passes == 0 ? "Waiting for the first transcript lines…" : "Nothing caught yet."
    }

    private func start() {
        radar.start(meeting: meeting, folder: meeting.folderURL(in: app.storage))
    }
}

/// Radar items grouped by kind, contradictions first. Used live and on the
/// finished meeting.
struct RadarItemList: View {
    @EnvironmentObject var app: AppState
    let items: [RadarItem]
    var emptyMessage = "Nothing caught."
    /// Offered on the person's own commitments once the meeting has ended.
    var followThrough: ((RadarItem) -> Void)?
    var openSource: ((RadarItem) -> Void)?
    /// The meeting folder, where screen-answer crops are saved.
    var folder: URL?
    /// False inside a page that already scrolls.
    var scrolls = true

    static let order: [RadarItem.Kind] = [.contradiction, .commitment, .decision, .question]

    static func costLabel(_ cost: Double) -> String {
        cost < 0.01 ? "under $0.01" : String(format: "$%.2f", cost)
    }

    var body: some View {
        if items.isEmpty {
            Text(emptyMessage)
                .workspaceTextRole(.supporting)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if scrolls {
            ScrollView {
                groups.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("radar.items")
        } else {
            groups.accessibilityIdentifier("radar.items")
        }
    }

    private var groups: some View {
        VStack(alignment: .leading, spacing: 12) {
            let fromScreen = items.filter { $0.screenAnswer != nil }
            if !fromScreen.isEmpty {
                Text("Answered from your screen")
                    .font(.scaled(.caption).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                ForEach(fromScreen) { item in row(item) }
            }
            ForEach(Self.order, id: \.self) { kind in
                let group = items.filter { $0.kind == kind && $0.screenAnswer == nil }
                if !group.isEmpty {
                    Text(kind.pluralLabel)
                        .font(.scaled(.caption).weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    ForEach(group) { item in row(item) }
                }
            }
        }
    }

    private func row(_ item: RadarItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: item.kind.systemImage)
                    .foregroundStyle(item.kind == .contradiction ? LBTokens.Palette.attentionText : LBTokens.Palette.accentText)
                    .accessibilityLabel(item.kind.label)
                Text(item.text)
                    .font(LBTokens.Typography.reading)
                    .strikethrough(item.answered)
                    .foregroundStyle(item.answered ? .secondary : .primary)
                    .textSelection(.enabled)
            }
            let details = [item.owner.map { $0 == "Me" ? "You" : $0 }, item.due, item.answered ? "answered" : nil]
                .compactMap { $0 }
            if !details.isEmpty {
                Text(details.joined(separator: " · ")).font(.scaled(.caption)).foregroundStyle(.secondary)
            }
            Button { openSource?(item) } label: {
                Text("\(MeetingRadarAnalyzer.timestamp(item.time))  “\(item.quote)”")
                    .font(.scaled(.callout))
                    .italic()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .disabled(openSource == nil)
            if let earlier = item.earlier {
                Button {
                    if !earlier.isCurrentMeeting { app.openMeeting(earlier.meetingID, seek: earlier.time) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(earlier.isCurrentMeeting ? "Earlier in this meeting"
                             : "Earlier: \(earlier.meetingTitle) · \(earlier.meetingDate.formatted(date: .abbreviated, time: .omitted))"
                                + (earlier.time.map { " · \(MeetingRadarAnalyzer.timestamp($0))" } ?? ""))
                            .font(.scaled(.caption).weight(.semibold))
                        Text("“\(earlier.text)”").font(.scaled(.callout)).multilineTextAlignment(.leading)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lbStatusSurface(LBTokens.Palette.attention)
                }
                .buttonStyle(.plain)
                .help(earlier.isCurrentMeeting ? "" : "Open the earlier meeting at this passage")
            }
            if let answer = item.screenAnswer {
                RadarScreenAnswerView(answer: answer, folder: folder)
            }
            if let followThrough, item.isUserCommitment {
                Button("Follow Through…") { followThrough(item) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("radar.followThrough.\(item.id)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("radar.item.\(item.kind.rawValue).\(item.id)")
    }
}

/// The answer to a meeting question, with the crop of the earlier screen
/// capture it came from. Clicking opens the capture in screen memory.
private struct RadarScreenAnswerView: View {
    @EnvironmentObject var app: AppState
    let answer: RadarScreenAnswer
    let folder: URL?
    @State private var image: NSImage?

    var body: some View {
        Button { app.openScreenSnapshot(answer.snapshotID) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Label("On your screen", systemImage: "rectangle.on.rectangle")
                    .font(.scaled(.caption).weight(.semibold))
                Text(answer.text)
                    .font(.scaled(.title3).weight(.semibold))
                    .textSelection(.enabled)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 150, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                        .accessibilityLabel("Screen capture: \(answer.quote)")
                }
                Text(source)
                    .font(.scaled(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lbStatusSurface(LBTokens.Palette.success)
        }
        .buttonStyle(.plain)
        .help("Open this capture in screen memory")
        .accessibilityIdentifier("radar.screenAnswer")
        .task(id: answer.image) {
            guard let folder else { return }
            let url = folder.appendingPathComponent(answer.image)
            let data = await Task.detached { try? Data(contentsOf: url) }.value
            image = data.flatMap(NSImage.init(data:))
        }
    }

    private var source: String {
        let title = answer.windowTitle.isEmpty ? "" : " · \(answer.windowTitle)"
        return "\(answer.app)\(title) · \(answer.capturedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}
