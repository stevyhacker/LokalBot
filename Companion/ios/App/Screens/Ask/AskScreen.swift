import LokalBotCompanionKit
import SwiftUI

/// Conversations beside the open one where there is room; on iPhone the
/// conversation opens directly and Back lists the others.
struct AskSplit: View {
    @Environment(CompanionSession.self) private var session
    @Environment(AppNavigator.self) private var navigator
    @State private var model = AskModel()
    @State private var compactColumn = NavigationSplitViewColumn.detail
    @State private var handledRequest = 0
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            ConversationList(model: model) { compactColumn = .detail }
        } detail: {
            NavigationStack {
                AskConversationView(model: model, composerFocused: $composerFocused)
                    .companionDestinations()
            }
        }
        .task(id: session.revision) { await model.load(session) }
        .onAppear(perform: consumeRequests)
        .onChange(of: navigator.newQuestionRequest) { consumeRequests() }
    }

    /// "Ask About…" buttons and ⌘N start a new question, scoped and drafted.
    private func consumeRequests() {
        if navigator.newQuestionRequest != handledRequest {
            handledRequest = navigator.newQuestionRequest
            model.newConversation(scope: navigator.askScope)
            model.draft = navigator.askDraft ?? ""
            navigator.askScope = nil
            navigator.askDraft = nil
            compactColumn = .detail
            composerFocused = true
        }
        if let question = navigator.demoQuestion {
            navigator.demoQuestion = nil
            model.newConversation()
            model.draft = question
            Task { await model.submit(session) }
        }
    }
}

struct ConversationList: View {
    @Environment(CompanionSession.self) private var session
    let model: AskModel
    let onOpen: () -> Void

    var body: some View {
        @Bindable var model = model
        List(selection: $model.currentID) {
            ForEach(model.conversations.filter { !$0.turns.isEmpty }) { conversation in
                VStack(alignment: .leading, spacing: 3) {
                    Text(conversation.title)
                        .font(LBTokens.Typography.body.weight(.medium))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(LBFormat.current.ago(conversation.updatedAt, now: Date()))
                        if conversation.turns.count > 1 {
                            Text("· \(conversation.turns.count) questions")
                        }
                        if conversation.turns.contains(where: { $0.state == .queued }) {
                            Label("Waiting for your Mac", systemImage: "clock")
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(LBTokens.Palette.attentionText)
                        }
                    }
                    .font(LBTokens.Typography.caption)
                    .foregroundStyle(LBTokens.Palette.supporting)
                    .lineLimit(1)
                }
                .padding(.vertical, 3)
                .tag(conversation.id)
            }
        }
        .listStyle(.plain)
        .tint(Brand.tealFill)
        .overlay {
            if model.loaded && !model.conversations.contains(where: { !$0.turns.isEmpty }) {
                ContentUnavailableView("No questions yet", systemImage: "sparkle.magnifyingglass",
                                       description: Text("Questions you ask and their answers stay on this device."))
            }
        }
        .navigationTitle("Conversations")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.newConversation()
                    onOpen()
                } label: {
                    Label("New Question", systemImage: "square.and.pencil")
                }
            }
        }
        .onChange(of: model.currentID) { _, id in if id != nil { onOpen() } }
    }
}

/// The Mac's editorial reading layout: no bubbles, the question in semibold,
/// the answer with numbered teal sources, and the composer docked below.
struct AskConversationView: View {
    @Environment(CompanionSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: AskModel
    var composerFocused: FocusState<Bool>.Binding
    @State private var citationTarget: MeetingRoute?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if let turns = model.current?.turns, !turns.isEmpty {
                        ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                            AskTurnView(turn: turn, isFirst: index == 0, model: model, citationTarget: $citationTarget)
                                .id(turn.id)
                        }
                    } else {
                        AskEmptyState(model: model, composerFocused: composerFocused)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: LBTokens.Spacing.readingMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.current?.turns.last?.answer) {
                withAnimation(WorkspaceMotion.animation(.autoScroll, reduceMotion: reduceMotion)) {
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }
            .onChange(of: model.current?.turns.count) {
                proxy.scrollTo("end", anchor: .bottom)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AskComposer(model: model, focused: composerFocused)
        }
        .navigationTitle("Ask")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $citationTarget) { route in
            MeetingDetailScreen(meetingID: route.id, focus: route.offset)
        }
    }
}

struct AskEmptyState: View {
    @Environment(CompanionSession.self) private var session
    let model: AskModel
    var composerFocused: FocusState<Bool>.Binding

    private let suggestions = ["What's overdue?", "Summarize yesterday", "What did Maya ask me for?"]

    var body: some View {
        VStack(spacing: 14) {
            IconTile(systemImage: "sparkle.magnifyingglass", size: 52)
            Text("Ask your work memory")
                .font(LBTokens.Typography.pageTitle)
                .multilineTextAlignment(.center)
            Text(session.mode == .sample
                 ? "In the sample library, answers come from its sample meetings."
                 : "\(session.macName.prefix(1).uppercased() + session.macName.dropFirst()) answers from your meetings, digests and Timeline, and sends the answer here with its sources.")
                .font(LBTokens.Typography.body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if session.manifest?.askEnabled == false {
                Text("Your Mac isn't answering questions from devices. Turn it on in LokalBot Settings → Phones & tablets on your Mac.")
                    .workspaceTextRole(.warning)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        model.draft = suggestion
                        Task { await model.submit(session) }
                    } label: {
                        HStack {
                            Text(suggestion).foregroundStyle(Color.primary)
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.circle.fill").foregroundStyle(Brand.teal)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .frame(maxWidth: 420)
                        .background(LBTokens.Palette.chipFill, in: RoundedRectangle(cornerRadius: LBTokens.Radius.control, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .lbHoverEffect()
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

/// The composer, docked: Liquid Glass on iOS 26, a material before it.
struct AskComposer: View {
    @Environment(CompanionSession.self) private var session
    let model: AskModel
    var focused: FocusState<Bool>.Binding

    private let format = LBFormat.current

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            if let scope = model.scope {
                HStack(spacing: 6) {
                    Image(systemName: "scope")
                    Text(scopeLabel(scope)).lineLimit(1)
                    Button {
                        model.scope = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Ask about everything")
                }
                .font(LBTokens.Typography.caption.weight(.medium))
                .foregroundStyle(Brand.teal)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(LBTokens.Palette.accentWash, in: Capsule())
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask your work memory", text: $model.draft, axis: .vertical)
                    .font(LBTokens.Typography.body)
                    .lineLimit(1...5)
                    .focused(focused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .accessibilityLabel("Question")
                Button(action: send) {
                    Image(systemName: model.isAnswering ? "ellipsis.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(model.canSubmit ? Brand.tealFill : LBTokens.Palette.supporting.opacity(0.4))
                        .symbolEffect(.pulse, isActive: model.isAnswering)
                }
                .buttonStyle(.plain)
                .disabled(!model.canSubmit)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("Ask")
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .composerChrome(focused: focused.wrappedValue)
            statusLine
                .padding(.horizontal, 6)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: LBTokens.Spacing.readingMaxWidth)
        .frame(maxWidth: .infinity)
        // Answers fade out under the dock, so the status line stays readable.
        .background {
            LinearGradient(stops: [.init(color: Color(uiColor: .systemBackground).opacity(0), location: 0),
                                   .init(color: Color(uiColor: .systemBackground).opacity(0.92), location: 0.45)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var statusLine: some View {
        let unreachable = session.presentation.isAttention
        return HStack(spacing: 5) {
            Image(systemName: session.mode == .sample ? "shippingbox" : "desktopcomputer")
                .foregroundStyle(unreachable ? LBTokens.Palette.attentionText : Brand.teal)
            Text(statusText)
                .foregroundStyle(unreachable ? LBTokens.Palette.attentionText : LBTokens.Palette.supporting)
                .lineLimit(1)
        }
        .font(LBTokens.Typography.caption)
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        switch session.presentation {
        case .sample: return "Answers come from the sample library"
        case .unreachable: return "Mac not reachable · questions can wait for it"
        case .synced(_, let route): return ["Your Mac answers", route?.label].compactMap { $0 }.joined(separator: " · ")
        default: return "Your Mac answers"
        }
    }

    private func scopeLabel(_ scope: AskRequest.Scope) -> String {
        if let day = scope.day.flatMap(DayKey.init) { return "About \(format.dayTitle(day, today: session.today).lowercasedFirstWordIfRelative)" }
        if scope.meetingId != nil { return "About this meeting" }
        return "About everything"
    }

    private func send() {
        guard model.canSubmit else { return }
        Task { await model.submit(session) }
    }
}
