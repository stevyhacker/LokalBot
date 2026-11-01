import LokalBotCompanionKit
import SwiftUI

struct RootView: View {
    @Environment(CompanionSession.self) private var session
    @Environment(AppLock.self) private var appLock

    var body: some View {
        Group {
            switch session.mode {
            case .loading:
                ProgressView().controlSize(.large)
            case .unpaired:
                WelcomeScreen()
            case .sample, .paired:
                MainTabs()
            }
        }
        .brandTinted()
        .overlay {
            if appLock.isLocked || appLock.isObscured {
                LockCover()
            }
        }
        .alert("LokalBot", isPresented: Binding(get: { session.notice != nil }, set: { if !$0 { session.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.notice ?? "")
        }
    }
}

/// The tab bar on iPhone and in compact width; a sidebar like the Mac's on a
/// full-width iPad. Which one follows the size class, so Split View, Slide
/// Over, Stage Manager and rotation all work.
struct MainTabs: View {
    @Environment(AppNavigator.self) private var navigator
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        GeometryReader { proxy in
            tabs(wide: proxy.size.width >= 1100)
        }
    }

    private func tabs(wide: Bool) -> some View {
        @Bindable var navigator = navigator
        return TabView(selection: $navigator.tab) {
            if sizeClass == .compact {
                tab(.today)
                tab(.meetings)
                tab(.actions)
                tab(.ask)
                Tab(AppSection.more.title, systemImage: AppSection.more.systemImage, value: AppSection.more) {
                    MoreScreen().brandTinted()
                }
            } else {
                tab(.today)
                tab(.actions)
                TabSection("Remember") {
                    tab(.meetings)
                    tab(.timeline)
                    tab(.people)
                    tab(.projects)
                    tab(.ask)
                }
                tab(.settings)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // Beside the content like the Mac's when there is room; a tab bar
        // in portrait, where an open sidebar would cover the page.
        .defaultAdaptableTabBarPlacement(wide ? .sidebar : .automatic)
        .tabViewSidebarBottomBar { SidebarSyncCard() }
        // The sidebar's selection is white on the deep teal, as on the Mac;
        // pages keep the text teal (see tab(_:)).
        .tint(sizeClass == .regular ? Brand.tealFill : Brand.teal)
        .focusedSceneValue(\.navigator, navigator)
        .onAppear { navigator.adapt(compact: sizeClass == .compact) }
        .onChange(of: sizeClass) { _, new in navigator.adapt(compact: new == .compact) }
    }

    private func tab(_ section: AppSection) -> some TabContent<AppSection> {
        Tab(section.title, systemImage: section.systemImage, value: section) {
            SectionHost(section: section).brandTinted()
        }
    }
}

/// A top-level section in its container: a split view where a list leads to
/// details, a stack elsewhere.
struct SectionHost: View {
    let section: AppSection

    var body: some View {
        switch section {
        case .today:
            NavigationStack { TodayScreen().companionDestinations() }
        case .actions:
            ActionsSplit()
        case .meetings:
            MeetingsSplit()
        case .timeline:
            NavigationStack { TimelineScreen().companionDestinations() }
        case .people:
            PeopleSplit()
        case .projects:
            ProjectsSplit()
        case .ask:
            AskSplit()
        case .settings:
            NavigationStack { SettingsScreen() }
        case .more:
            MoreScreen()
        }
    }
}

/// Timeline, People, Projects and Settings in compact width.
struct MoreScreen: View {
    @Environment(AppNavigator.self) private var navigator

    var body: some View {
        @Bindable var navigator = navigator
        NavigationStack(path: $navigator.morePath) {
            List {
                Section {
                    ForEach([AppSection.timeline, .people, .projects], id: \.self) { row($0) }
                }
                Section {
                    row(.settings)
                }
                Section {
                    SidebarSyncCard()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("More")
            .companionDestinations()
            .navigationDestination(for: AppSection.self) { section in
                Group {
                    switch section {
                    case .timeline: TimelineScreen()
                    case .people: PeopleList(selection: nil)
                    case .projects: ProjectsList(selection: nil)
                    default: SettingsScreen()
                    }
                }
                .onAppear { navigator.showing(section) }
            }
        }
    }

    private func row(_ section: AppSection) -> some View {
        NavigationLink(value: section) {
            Label {
                Text(section.title)
            } icon: {
                Image(systemName: section.systemImage).foregroundStyle(Brand.teal)
            }
        }
    }
}

/// "Synced with your Mac" at the foot of the sidebar, where the Mac shows
/// "Storage: this Mac".
struct SidebarSyncCard: View {
    @Environment(CompanionSession.self) private var session

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: session.mode == .sample ? "shippingbox" : "lock.shield")
                .foregroundStyle(Brand.teal)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.mode == .sample ? "Sample library" : session.macName)
                    .font(LBTokens.Typography.secondary.weight(.semibold))
                    .lineLimit(1)
                SyncStatusLine()
                Text("End-to-end encrypted")
                    .font(LBTokens.Typography.caption)
                    .workspaceSupportingForeground()
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .lbGroupedSurface()
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}

/// The sync state as one quiet line, refreshed every half minute.
struct SyncStatusLine: View {
    @Environment(CompanionSession.self) private var session

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(SyncStatusPill(state: session.presentation).text(now: session.referenceDateOverride ?? context.date))
                .font(LBTokens.Typography.caption)
                .foregroundStyle(session.presentation.isAttention ? LBTokens.Palette.attentionText : LBTokens.Palette.supporting)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct LockCover: View {
    @Environment(AppLock.self) private var appLock

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            VStack(spacing: 16) {
                IconTile(systemImage: "lock.fill", size: 56)
                Text("LokalBot is locked").font(LBTokens.Typography.columnTitle)
                if appLock.isLocked && !appLock.isObscured {
                    Button("Unlock with \(appLock.biometryName)") { Task { await appLock.unlock() } }
                        .primaryActionButton()
                        .controlSize(.large)
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// A meeting in its own window, from the iPad's "Open in New Window".
struct MeetingWindow: View {
    static let id = "meeting"
    let meetingID: String?
    @Environment(CompanionSession.self) private var session

    var body: some View {
        NavigationStack {
            if let meetingID, session.mode != .loading {
                MeetingDetailScreen(meetingID: meetingID, focus: nil)
                    .companionDestinations()
            } else {
                ContentUnavailableView("No meeting", systemImage: "waveform.circle")
            }
        }
        .brandTinted()
        .task { if session.mode == .loading { await session.start() } }
    }
}
