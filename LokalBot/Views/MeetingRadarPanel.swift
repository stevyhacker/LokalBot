import SwiftUI

/// Live Radar in the live meeting view: the main area, beside the transcript
/// and notes. Nothing is sent until the person presses Start Radar for this
/// meeting; once it runs, the floating panel shows the same items over the
/// meeting app.
struct MeetingRadarPanel: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var radar: MeetingRadar
    let meeting: Meeting

    private var isThisMeeting: Bool { radar.meetingID == meeting.id }
    private var items: [RadarItem] { isThisMeeting ? radar.items : [] }
    private var unavailableReason: String? { MeetingRadar.unavailableReason(app.settings) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Label("Live Radar", systemImage: "dot.radiowaves.left.and.right")
                    .font(.scaled(.title3).weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                RadarCounts(items: items)
                Spacer(minLength: 8)
                if isThisMeeting, radar.isActive {
                    Button {
                        app.liveRadarPanel.toggle()
                    } label: {
                        Label("Floating Panel", systemImage: "rectangle.inset.topright.filled")
                    }
                    .accessibilityIdentifier("live.radar.panel")
                }
                controls
            }
            .buttonStyle(.bordered)
            .fixedSize(horizontal: false, vertical: true)
            status
            if items.isEmpty {
                emptyState
            } else {
                RadarItemList(items: items, folder: meeting.folderURL(in: app.storage),
                              steps: isThisMeeting ? radar.answerSteps : [:])
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footnote
                .font(.scaled(.caption2))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder private var controls: some View {
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
                .buttonStyle(.borderedProminent)
                .disabled(radar.state == .finishing)
                .accessibilityIdentifier("live.radar.start")
        }
    }

    @ViewBuilder private var status: some View {
        if isThisMeeting, let message = radar.statusMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.scaled(.callout)).foregroundStyle(Brand.error)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("live.radar.error")
        } else if isThisMeeting, radar.state == .running || radar.state == .finishing {
            HStack(spacing: 10) {
                if radar.isAnalyzing {
                    LoadingStateLabel("Reading the newest lines…", font: .scaled(.callout))
                } else {
                    Text("Listening with \(modelName).")
                        .workspaceTextRole(.supporting)
                }
                if radar.totals.passes > 0 {
                    passSummary.font(.scaled(.caption).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Before the radar starts, or while it waits for its first item.
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(LBTokens.Palette.accentText)
            if isThisMeeting, radar.isActive {
                Text(radar.totals.passes == 0 ? "Waiting for the first transcript lines…" : "Nothing caught yet.")
                    .font(.scaled(.title3))
                    .foregroundStyle(.secondary)
            } else if let reason = unavailableReason {
                Text(verbatim: reason).workspaceTextRole(.supporting)
            } else {
                Text("Catches commitments, decisions, open questions, and conflicts with earlier meetings as they are said. Sends \(modelName) new live transcript lines, the meeting title, invited names, and related passages from your earlier meetings at api.meta.ai. Starts the live preview if it is off.")
                    .font(.scaled(.callout))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    option("Fast live text with Muse Voice Transcribe", on: app.settings.museLiveTextEnabled)
                    option("Answer meeting questions from your screen", on: app.settings.museScreenAnswersEnabled)
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .lbGroupedSurface()
    }

    private func option(_ title: LocalizedStringKey, on: Bool) -> some View {
        Label(title, systemImage: on ? "checkmark.circle.fill" : "circle")
            .font(.scaled(.callout))
            .foregroundStyle(on ? LBTokens.Palette.successText : .secondary)
    }

    private var footnote: Text {
        let sent: Text = app.settings.museScreenAnswersEnabled
            ? Text("Muse reads new transcript lines as text and crops of screen captures that answer a question.")
            : Text("Muse reads new transcript lines as text.")
        let audio: Text = app.settings.museLiveTextEnabled
            ? Text("Speakers stay on this Mac; fast live text streams audio.")
            : Text("Audio and speakers stay on this Mac.")
        return sent + Text(verbatim: " ") + audio
    }

    private var modelName: String {
        MetaModelAPI.displayName(for: isThisMeeting ? radar.model : app.settings.museRadarModel)
    }

    private var passSummary: Text {
        let cost = RadarItemList.costLabel(radar.totals.cost)
        guard let last = radar.totals.lastPassSeconds else { return Text("Passes: \(radar.totals.passes) · \(cost)") }
        return Text("Passes: \(radar.totals.passes) · last \(String(format: "%.1f", last)) s · \(cost)")
    }

    private func start() {
        app.startLiveRadar(for: meeting)
    }
}

extension RadarItem.Kind {
    /// One color per kind across the board, the floating panel, and the
    /// meeting page.
    var tint: Color {
        switch self {
        case .contradiction: LBTokens.Palette.attention
        case .commitment: LBTokens.Palette.accentFill
        case .decision: .purple
        case .question: .blue
        }
    }

    var tintText: Color {
        switch self {
        case .contradiction: LBTokens.Palette.attentionText
        case .commitment: LBTokens.Palette.accentText
        case .decision: .purple
        case .question: .blue
        }
    }
}

/// How many of each kind the radar holds, as icons with numbers.
struct RadarCounts: View {
    let items: [RadarItem]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(RadarItemList.order, id: \.self) { kind in
                let count = items.filter { $0.kind == kind }.count
                if count > 0 {
                    Label("\(count)", systemImage: kind.systemImage)
                        .labelStyle(.titleAndIcon)
                        .font(.scaled(.caption).weight(.semibold).monospacedDigit())
                        .foregroundStyle(kind.tintText)
                        .help(LocalizedStringKey(kind.pluralLabel))
                }
            }
        }
    }
}

/// Radar items as cards: contradictions and questions answered from the
/// screen first and full width, then commitments, decisions, and questions
/// in a grid, newest first. Used live and on the finished meeting.
struct RadarItemList: View {
    @EnvironmentObject var app: AppState
    let items: [RadarItem]
    var emptyMessage: LocalizedStringKey = "Nothing caught."
    /// Offered on the person's own commitments once the meeting has ended.
    var followThrough: ((RadarItem) -> Void)?
    var openSource: ((RadarItem) -> Void)?
    /// The meeting folder, where screen-answer crops are saved.
    var folder: URL?
    /// Live answers' current step per question, while it looks.
    var steps: [String: String] = [:]
    /// False inside a page that already scrolls.
    var scrolls = true

    static let order: [RadarItem.Kind] = [.contradiction, .commitment, .decision, .question]

    static func costLabel(_ cost: Double) -> String {
        cost < 0.01 ? String(localized: "under $0.01") : String(format: "$%.2f", cost)
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
                groups.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("radar.items")
        } else {
            groups.accessibilityIdentifier("radar.items")
        }
    }

    private static let columns = [GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)]

    private var groups: some View {
        let newest = items.sorted { $0.time > $1.time }
        let attention = newest.filter { $0.kind == .contradiction || $0.screenAnswer != nil || $0.answer != nil }
        return VStack(alignment: .leading, spacing: 16) {
            if !attention.isEmpty {
                section(Text("Needs Attention")) {
                    VStack(spacing: 12) {
                        ForEach(attention) { card($0, prominent: true) }
                    }
                }
            }
            ForEach([RadarItem.Kind.commitment, .decision, .question], id: \.self) { kind in
                let group = newest.filter { $0.kind == kind && $0.screenAnswer == nil && $0.answer == nil }
                if !group.isEmpty {
                    section(Text(LocalizedStringKey(kind.pluralLabel))) {
                        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 12) {
                            ForEach(group) { card($0, prominent: false) }
                        }
                    }
                }
            }
        }
    }

    private func section(_ title: Text, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            title
                .font(.scaled(.caption).weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    private func card(_ item: RadarItem, prominent: Bool) -> some View {
        RadarCard(item: item, folder: folder, prominent: prominent, step: steps[item.id],
                  openSource: openSource, followThrough: followThrough)
    }
}

/// One radar item: its kind and time, the text, owner and deadline, the
/// line it quotes, and what it conflicts with or how the screen answered it.
struct RadarCard: View {
    @EnvironmentObject var app: AppState
    let item: RadarItem
    var folder: URL?
    /// Larger text, for what needs attention and the panel's spotlight.
    var prominent = false
    /// Prefix of the accessibility identifiers, so the floating panel's
    /// copies don't collide with the main window's.
    var idPrefix = "radar"
    /// False where a popover can't open, as in the floating panel.
    var allowsEnlarge = true
    /// What live answers is doing for this question right now.
    var step: String?
    var openSource: ((RadarItem) -> Void)?
    var followThrough: ((RadarItem) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: item.kind.systemImage)
                Text(LocalizedStringKey(item.kind.label)).textCase(.uppercase)
                Spacer(minLength: 4)
                Text(verbatim: MeetingRadarAnalyzer.timestamp(item.time)).monospacedDigit()
            }
            .font(.scaled(.caption).weight(.semibold))
            .foregroundStyle(item.kind.tintText)
            Text(item.text)
                .font(prominent ? .scaled(.title3).weight(.semibold) : .scaled(.body).weight(.medium))
                .strikethrough(item.answered)
                .foregroundStyle(item.answered ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            let details = [item.owner.map { $0 == "Me" ? String(localized: "You") : $0 }, item.due,
                           item.answered ? String(localized: "answered") : nil].compactMap { $0 }
            if !details.isEmpty {
                Text(verbatim: details.joined(separator: " · ")).font(.scaled(.caption)).foregroundStyle(.secondary)
            }
            Button { openSource?(item) } label: {
                Text(verbatim: "“\(item.quote)”")
                    .font(.scaled(.callout))
                    .italic()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .disabled(openSource == nil)
            if let earlier = item.earlier {
                earlierPassage(earlier)
            }
            if let answer = item.answer {
                RadarLiveAnswerView(answer: answer)
            } else if let step {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: step)
                        .font(.scaled(.callout))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .accessibilityIdentifier("radar.answerStep")
            }
            if let answer = item.screenAnswer {
                // The panel is narrow; the board has room for a readable crop.
                RadarScreenAnswerView(answer: answer, folder: folder, allowsEnlarge: allowsEnlarge,
                                      imageHeight: prominent && allowsEnlarge ? 220 : 120)
            }
            if let followThrough, item.isUserCommitment {
                Button("Follow Through…") { followThrough(item) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("radar.followThrough.\(item.id)")
            }
        }
        .padding(.vertical, 10)
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(item.kind.tint.opacity(prominent ? 0.10 : 0.06))
        .overlay(alignment: .leading) {
            Rectangle().fill(item.kind.tint).frame(width: 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(item.kind.tint.opacity(0.25))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(idPrefix).item.\(item.kind.rawValue).\(item.id)")
    }

    private func earlierPassage(_ earlier: RadarEvidence) -> some View {
        Button {
            if !earlier.isCurrentMeeting { app.openMeeting(earlier.meetingID, seek: earlier.time) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    let date = earlier.meetingDate.formatted(date: .abbreviated, time: .omitted)
                    if earlier.isCurrentMeeting {
                        Text("Earlier in this meeting")
                    } else if let time = earlier.time {
                        Text("Earlier: \(earlier.meetingTitle) · \(date) · \(MeetingRadarAnalyzer.timestamp(time))")
                    } else {
                        Text("Earlier: \(earlier.meetingTitle) · \(date)")
                    }
                }
                .font(.scaled(.caption).weight(.semibold))
                Text(verbatim: "“\(earlier.text)”")
                    .font(.scaled(.callout))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lbStatusSurface(LBTokens.Palette.attention)
        }
        .buttonStyle(.plain)
        .help(earlier.isCurrentMeeting ? "" : "Open the earlier meeting at this passage")
    }
}

/// The answer to a meeting question, with the line it quotes and the crop
/// of the earlier screen capture it came from. Clicking the crop shows it
/// full size, with a way into screen memory.
struct RadarScreenAnswerView: View {
    @EnvironmentObject var app: AppState
    let answer: RadarScreenAnswer
    let folder: URL?
    var allowsEnlarge = true
    var imageHeight: CGFloat = 160
    @State private var image: NSImage?
    @State private var enlarged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("On your screen", systemImage: "rectangle.on.rectangle")
                .font(.scaled(.caption).weight(.semibold))
            Text(verbatim: answer.text)
                .font(.scaled(.title2).weight(.bold))
                .textSelection(.enabled)
            Text(verbatim: "“\(answer.quote)”")
                .font(.scaled(.callout))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let image {
                Button { if allowsEnlarge { enlarged = true } else { app.openScreenSnapshot(answer.snapshotID) } } label: {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: imageHeight, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Screen capture: \(answer.quote)"))
                .accessibilityIdentifier("radar.screenAnswer.image")
                .popover(isPresented: $enlarged) {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 760, maxHeight: 520)
                        HStack {
                            Text(verbatim: source).font(.scaled(.caption)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Open Capture") {
                                enlarged = false
                                app.openScreenSnapshot(answer.snapshotID)
                            }
                            .help("Open this capture in screen memory")
                        }
                    }
                    .padding(12)
                }
            }
            Text(verbatim: source)
                .font(.scaled(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lbStatusSurface(LBTokens.Palette.success)
        .accessibilityElement(children: .contain)
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

/// A live answer: the answer to say, the sources it rests on with the words
/// that support it, and where it looked. Clicking a source opens it: the
/// meeting at that moment, or the file, commit, or pull request.
struct RadarLiveAnswerView: View {
    @EnvironmentObject var app: AppState
    let answer: RadarAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Answer from your work", systemImage: "sparkle.magnifyingglass")
                .font(.scaled(.caption).weight(.semibold))
            Text(verbatim: answer.text)
                .font(.scaled(.title3).weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            ForEach(answer.sources) { source in
                Button { open(source) } label: { row(source) }
                    .buttonStyle(.plain)
                    .disabled(source.meetingID == nil && source.link == nil)
            }
            if !answer.steps.isEmpty {
                Text(verbatim: answer.steps.joined(separator: " → ") + String(format: " · %.0f s", answer.seconds))
                    .font(.scaled(.caption2))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lbStatusSurface(LBTokens.Palette.success)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("radar.answer")
    }

    private func row(_ source: RadarAnswer.Source) -> some View {
        let isCode = [.code, .commit].contains(source.kind)
        return VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(verbatim: source.title)
                    .font(isCode ? .scaled(.caption).monospaced() : .scaled(.caption).weight(.semibold))
            } icon: {
                Image(systemName: Self.icon(source.kind))
            }
            .foregroundStyle(LBTokens.Palette.successText)
            Text(verbatim: "“\(source.quote)”")
                .font(isCode ? .scaled(.caption).monospaced() : .scaled(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .contentShape(Rectangle())
    }

    private func open(_ source: RadarAnswer.Source) {
        if let meetingID = source.meetingID {
            app.openMeeting(meetingID, seek: source.time)
        } else if let link = source.link, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }

    static func icon(_ kind: RadarAnswer.Source.Kind) -> String {
        switch kind {
        case .memory: "brain"
        case .project: "folder.badge.person.crop"
        case .action: "checklist"
        case .meeting: "person.2"
        case .screen: "rectangle.on.rectangle"
        case .document: "doc.text"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .commit: "point.topleft.down.to.point.bottomright.curvepath"
        case .pullRequest: "arrow.triangle.pull"
        case .issue: "exclamationmark.circle"
        }
    }
}
