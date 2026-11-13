import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct MainWindowView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Native sidebar toggle and restored visibility share the same binding.
    @SceneStorage("workspace.sidebar.visible") private var sidebarVisible = true
    @State private var pendingDelete: Set<Meeting.ID>?
    /// Timeline's day, kept across visits to other pages.
    @StateObject private var capture = CaptureModel()

    var body: some View {
        navigation
        .confirmationDialog(
            "Delete \(pendingDelete?.count ?? 0) meeting\((pendingDelete?.count ?? 0) == 1 ? "" : "s")?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete (removes recordings & transcripts)", role: .destructive) {
                if let ids = pendingDelete { app.deleteMeetings(ids) }
                pendingDelete = nil
            }
        } message: {
            Text("This permanently deletes the audio, transcript and summary files.")
        }
        .sheet(item: $app.followUpDraftMeeting) { meeting in
            FollowUpDraftSheet(meeting: meeting)
                .environmentObject(app)
        }
        .sheet(item: $app.followThroughSession) { session in
            FollowThroughSheet(session: session)
                .environmentObject(app)
        }
        .sheet(isPresented: $app.showsSampleSetup) {
            SampleMeetingSetupSheet(modelRoles: app.modelRoles)
                .environmentObject(app)
        }
        .task {
            // Let non-View code (menu bar, AppDelegate reopen) open windows.
            // First-run permission onboarding is now triggered from AppState.
            WindowAccess.shared.register { openWindow(id: $0) }
        }

    }

    /// Every workspace keeps its own list-and-page split inside the detail
    /// column, rather than adding global navigation columns.
    private var navigation: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { sidebarVisible ? .all : .detailOnly },
            set: { sidebarVisible = $0 != .detailOnly })) {
            sidebar
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Workspace navigation")
                .splitPaneAccessibilityLabel("Workspace navigation")
        } detail: {
            workspace
                .safeAreaInset(edge: .bottom, spacing: 0) { errorFeedback }
                // Model code sets this feedback, so animate on its values: the
                // bar enters from the bottom edge while the workspace above
                // yields its space in the same motion.
                .animation(bottomFeedbackAnimation, value: app.lastError)
                .animation(bottomFeedbackAnimation, value: app.micRecoveryNeeded)
                .animation(bottomFeedbackAnimation, value: app.textRecognitionStalled)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Workspace content")
                .splitPaneAccessibilityLabel("Workspace content")
        }
        .splitStructureDirection()
    }

    /// Reserve space for recovery feedback so it cannot cover a workspace's
    /// composer, transport, or other bottom controls.
    @ViewBuilder private var errorFeedback: some View {
        if app.micRecoveryNeeded {
            ErrorToast(
                message: "Microphone access is off for LokalBot. Turn it on in System Settings to record.",
                actionTitle: "Open System Settings",
                action: {
                    PermissionManager.shared.openSettings(for: .microphone)
                    app.micRecoveryNeeded = false
                }) { app.micRecoveryNeeded = false }
                .transition(WorkspaceMotion.bottomEdgeTransition(reduceMotion: reduceMotion))
        } else if let error = app.lastError {
            ErrorToast(message: error) { app.lastError = nil }
                .transition(WorkspaceMotion.bottomEdgeTransition(reduceMotion: reduceMotion))
        } else if app.textRecognitionStalled {
            ErrorToast(
                message: "Text recognition stopped answering. Screen memory is incomplete until LokalBot restarts.",
                actionTitle: "Relaunch",
                action: { PermissionManager.relaunch() }) { app.textRecognitionStalled = false }
                .transition(WorkspaceMotion.bottomEdgeTransition(reduceMotion: reduceMotion))
        }
    }

    private var bottomFeedbackAnimation: Animation? {
        WorkspaceMotion.animation(.drawer, reduceMotion: reduceMotion)
    }

    @ViewBuilder private var workspace: some View {
        switch app.navSection {
        case .today:
            TodayView()
        case .actions:
            ActionsWorkspaceView()
        case .timeline:
            TimelineContentView(model: capture)
        case .meetings:
            HSplitView {
                MeetingListView(pendingDelete: $pendingDelete)
                    .frame(minWidth: LBTokens.Metric.contentColumnMinWidth,
                           idealWidth: LBTokens.Metric.contentColumnWidth, maxWidth: 340)
                    .splitPaneAccessibilityLabel("Meeting library", autosaveName: "LokalBot.meetings", initialWidth: LBTokens.Metric.contentColumnWidth)
                MeetingLibraryDetailView(pendingDelete: $pendingDelete)
                    .frame(minWidth: LBTokens.Metric.contentDetailMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                    .splitPaneAccessibilityLabel("Meeting details")
            }
            .detailSplitMinimumWidth([LBTokens.Metric.contentColumnMinWidth, LBTokens.Metric.contentDetailMinWidth])
            .id("workspace.meetings")
        case .people:
            PeopleWorkspaceView(connections: app.connections, store: app.peopleStore)
                .id("workspace.people")
        case .projects:
            ProjectsWorkspaceView(connections: app.connections, store: app.projectStore)
                .id("workspace.projects")
        case .ask:
            HSplitView {
                ChatConversationList()
                        .frame(minWidth: LBTokens.Metric.contentColumnMinWidth,
                               idealWidth: LBTokens.Metric.contentColumnWidth, maxWidth: 340)
                        .splitPaneAccessibilityLabel("Conversations", autosaveName: "LokalBot.recall", initialWidth: LBTokens.Metric.contentColumnWidth)
                AskView().frame(minWidth: LBTokens.Metric.contentDetailMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                    .splitPaneAccessibilityLabel("Search and conversation")
            }
            .detailSplitMinimumWidth([LBTokens.Metric.contentColumnMinWidth, LBTokens.Metric.contentDetailMinWidth])
            .id("workspace.recall")
        case .agent:
            AgentView(sessions: app.agentSessions, installer: app.agentInstaller)
        }
    }

    /// Today and Actions lead; Remember holds what was captured; Assistant
    /// holds the two places you ask for work. Settings and the storage line
    /// sit in the footer, outside the destinations list.
    private var sidebar: some View {
        List(selection: sidebarSelection) {
            sidebarDestination(
                "Today", section: .today,
                identifier: "sidebar.today")
            sidebarDestination(
                "Actions", section: .actions,
                identifier: "sidebar.actions", showsOpenActionCount: true)
            sidebarSectionHeader("Remember")
            sidebarDestination(
                "Meetings", section: .meetings,
                identifier: "sidebar.meetings")
            sidebarDestination(
                "Timeline", section: .timeline,
                identifier: "sidebar.timeline")
            sidebarDestination(
                "People", section: .people,
                identifier: "sidebar.people")
            sidebarDestination(
                "Projects", section: .projects,
                identifier: "sidebar.projects")
            sidebarSectionHeader("Assistant")
            sidebarDestination(
                "Ask", section: .ask,
                identifier: "sidebar.ask")
            sidebarDestination(
                "Agent", section: .agent,
                identifier: "sidebar.agent")
        }
        .listStyle(.sidebar)
        .tint(Brand.tealFill)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFooter(scriptedLabelColor: isScriptedCapture ? scriptedSidebarLabelColor : nil)
        }
        .frame(minWidth: LBTokens.Metric.sidebarMinWidth, maxWidth: .infinity, alignment: .leading)
        .navigationSplitViewColumnWidth(min: LBTokens.Metric.sidebarMinWidth,
                                        ideal: LBTokens.Metric.sidebarWidth, max: 260)

    }

    /// Native source-list selection gives VoiceOver and keyboard navigation
    /// one semantic destination per row. Section headings remain static text.
    /// Scripted exports leave it empty; `sidebarRowBackground` marks the row.
    private var sidebarSelection: Binding<AppState.NavSection?> {
        Binding(
            get: { isScriptedCapture ? nil : app.navSection },
            set: { selection in
                if let selection {
                    app.evidenceReturnSection = nil
                    app.navSection = selection
                }
            })
    }

    /// `cacheDisplay` does not flatten the sidebar's vibrancy text correctly:
    /// AppKit gives the offscreen bitmap the mask color (black) instead of the
    /// composited label color. The selection highlight gets the same mask, a
    /// solid black bar. Use resolved colors only for scripted exports;
    /// normal app and UI-test windows keep the native sidebar rendering.
    @ViewBuilder
    private func sidebarDestination(
        _ title: String,
        section: AppState.NavSection,
        identifier: String,
        showsOpenActionCount: Bool = false
    ) -> some View {
        SidebarDestinationLabel(title: title, systemImage: section.symbol,
                                scriptedLabelColor: isScriptedCapture ? scriptedSidebarLabelColor : nil,
                                openActions: showsOpenActionCount ? app.outcomeIndex : nil)
        .tag(section)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowBackground(sidebarRowBackground(section))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(LocalizedStringKey(title)))
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(app.navSection == section ? .isSelected : [])
    }

    /// Scripted exports draw AppKit's unemphasized selection color in place of
    /// the masked native highlight.
    @ViewBuilder
    private func sidebarRowBackground(_ section: AppState.NavSection) -> some View {
        if isScriptedCapture && app.navSection == section {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                .padding(.horizontal, 10)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func sidebarSectionHeader(_ title: String) -> some View {
        Text(LocalizedStringKey(title))
            .font(.scaled(.subheadline).bold())
            .foregroundStyle(isScriptedCapture ? scriptedSidebarHeaderColor : Color.secondary)
            .padding(.leading, 11)
            .padding(.top, title == "Remember" ? 3 : 8)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
            .selectionDisabled(true)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .accessibilityIdentifier(
                title == "Remember" ? "sidebar.section.remember" : "sidebar.section.assistant")
    }

    private var scriptedSidebarLabelColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.90) : Color.black.opacity(0.84)
    }

    private var scriptedSidebarHeaderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.56) : Color.black.opacity(0.50)
    }

    private var isScriptedCapture: Bool {
#if LOKALBOT_UI_TEST_HOST
        ProcessInfo.processInfo.environment["LOKALBOT_CAPTURE_FILE"] != nil
#else
        false
#endif
    }

}

/// Read prominence inside the row so native selection supplies its foreground.
private struct SidebarDestinationLabel: View {
    @Environment(\.backgroundProminence) private var prominence
    let title: String
    let systemImage: String
    let scriptedLabelColor: Color?
    var openActions: OutcomeIndex?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(Brand.teal))
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(title))
                .font(.scaled(.body))
                .foregroundStyle(scriptedLabelColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
            Spacer(minLength: 0)
            if let openActions {
                SidebarOpenActionCount(index: openActions, scriptedLabelColor: scriptedLabelColor)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: LBTokens.Metric.sidebarRowHeight)
        .contentShape(Rectangle())
    }
}

/// The number of open actions that are yours. It observes the outcome index
/// itself, so a status change redraws this number and not the whole sidebar.
private struct SidebarOpenActionCount: View {
    @ObservedObject var index: OutcomeIndex
    let scriptedLabelColor: Color?

    var body: some View {
        let count = index.openUserActionThreads.count
        if count > 0 {
            Text(count, format: .number)
                .font(.scaled(.subheadline).monospacedDigit())
                .foregroundStyle(scriptedLabelColor.map { AnyShapeStyle($0.opacity(0.6)) } ?? AnyShapeStyle(.secondary))
                .accessibilityIdentifier("sidebar.actions.count")
        }
    }
}

/// The sidebar's foot: what is running now, then Settings, then where the
/// library and the AI are.
private struct SidebarFooter: View {
    @EnvironmentObject private var app: AppState
    let scriptedLabelColor: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if app.currentMeeting != nil {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        StatusDot(color: Brand.recording)
                        Text("Recording").font(.scaled(.callout).weight(.semibold))
                        Spacer(minLength: 0)
                        MeetingRecordingTimerText(recording: app.recording)
                            .font(.scaled(.callout).monospacedDigit())
                    }
                    Button("Live Transcript & Notes", action: app.showLiveMeeting)
                        .buttonStyle(.plain)
                        .font(.scaled(.callout))
                        .help("Open the current recording")
                        .accessibilityIdentifier("sidebar.recording")
                }
                .foregroundStyle(LBTokens.Palette.recordingText)
                .padding(10)
                .lbStatusSurface(.red)
            }
            BackgroundActivityCard(monitor: app.backgroundActivity)
            VStack(alignment: .leading, spacing: 2) {
                SidebarSettingsRow(scriptedLabelColor: scriptedLabelColor)
                SidebarPrivacyLine()
            }
        }
        .padding(10)
    }
}

/// Settings is a place you visit rarely, so it sits at the foot and not among
/// the destinations. It looks like a sidebar row and opens the Settings
/// window, so it never shows as selected: the main window stays where it was.
private struct SidebarSettingsRow: View {
    @EnvironmentObject private var app: AppState
    let scriptedLabelColor: Color?

    var body: some View {
        Button { app.openSettings() } label: {
            HStack(spacing: 10) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Brand.teal)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text("Settings")
                    .font(.scaled(.body))
                    .foregroundStyle(scriptedLabelColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: LBTokens.Metric.sidebarRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.settings")
    }
}

/// Reflects the *actual* privacy posture instead of a hardcoded claim. With
/// everything local it is one line. With a remote Think, transcription or
/// autocomplete server it names storage and AI separately and lists each
/// host once, because meeting and workday text goes to those origins.
private struct SidebarPrivacyLine: View {
    @EnvironmentObject private var app: AppState

    private var destination: InferencePresentation { InferencePresentation(settings: app.settings) }

    /// Think's server, the transcription server and autocomplete's server,
    /// each named once.
    private var remoteHosts: [String] { app.settings.remoteAIHosts }

    private var blocked: Bool {
        if case .blocked = destination { return true }
        return false
    }

    private var everythingLocal: Bool { remoteHosts.isEmpty && !blocked }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Brand.teal)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                if everythingLocal {
                    Text("On this Mac")
                } else {
                    Text("Storage: this Mac")
                    HStack(spacing: 4) {
                        Text(processingLabel)
                        StatusDot(color: .orange, size: 5)
                    }
                    ForEach(remoteHosts, id: \.self) { host in
                        Text(host)
                    }
                }
                if app.settings.companionSharingEnabled {
                    SidebarCompanionLine(host: app.companion)
                }
            }
            .font(.scaled(.subheadline))
            .workspaceSupportingForeground()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.localPrivacy")
    }

    private var processingLabel: String {
        blocked ? "AI: connection blocked" : "AI: local + remote"
    }
}

/// While sharing is on, the storage line says the library also has copies
/// on the person's paired phones and tablets.
private struct SidebarCompanionLine: View {
    @ObservedObject var host: CompanionHost

    var body: some View {
        Group {
            switch host.devices.count {
            case 0: Text("Phones & tablets: none paired")
            case 1: Text("Copy on 1 paired device")
            default: Text("Copies on \(host.devices.count) paired devices")
            }
        }
        .font(.scaled(.subheadline))
        .workspaceSupportingForeground()
        .accessibilityIdentifier("sidebar.companionDevices")
    }
}
