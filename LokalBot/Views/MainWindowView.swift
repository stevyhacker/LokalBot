import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct MainWindowView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    /// Native sidebar toggle and restored visibility share the same binding.
    @SceneStorage("workspace.sidebar.visible") private var sidebarVisible = true
    @State private var pendingDelete: Set<Meeting.ID>?
    /// Shared by Timeline's chronology and bounded context panel.
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
        .toolbar {
            if app.navSection == .timeline, app.evidenceReturnSection != nil {
                ToolbarItem(placement: .navigation) {
                    Button(action: app.returnFromEvidence) {
                        Label("Back", systemImage: "chevron.left")
                    }.help("Return to the source search or conversation")
                }
            }
        }
        .task {
            // Let non-View code (menu bar, AppDelegate reopen) open windows.
            // First-run permission onboarding is now triggered from AppState.
            WindowAccess.shared.register { openWindow(id: $0) }
        }

    }

    /// Timeline is one day-explorer workspace inside the global shell. Its
    /// chronology/context split belongs to that workspace, rather than
    /// becoming two more global navigation columns. Meetings and Ask retain
    /// their native three-column information architecture.
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
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        errorFeedback
                        if !app.outcomeIndex.statusUndo.isEmpty {
                            HStack {
                                Text("Updated \(app.outcomeIndex.statusUndo.count) action(s)")
                                Button("Undo") {
                                    app.outcomeIndex.undoStatusChange()
                                    app.lastError = app.outcomeIndex.lastError
                                }
                                    .accessibilityIdentifier("outcomes.undo")
                                Spacer()
                                Button("Dismiss") { app.outcomeIndex.dismissUndo() }
                            }
                            .font(Font.body)
                            .padding(12).background(.bar)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Workspace content")
                .splitPaneAccessibilityLabel("Workspace content")
        }
    }

    /// Reserve space for recovery feedback so it cannot cover Undo or a
    /// workspace's composer, transport, or other bottom controls.
    @ViewBuilder private var errorFeedback: some View {
        if app.micRecoveryNeeded {
            ErrorToast(
                message: "Microphone access is off for LokalBot. Turn it on in System Settings to record.",
                actionTitle: "Open System Settings",
                action: {
                    PermissionManager.shared.openSettings(for: .microphone)
                    app.micRecoveryNeeded = false
                }) { app.micRecoveryNeeded = false }
        } else if let error = app.lastError {
            ErrorToast(message: error) { app.lastError = nil }
        }
    }

    @ViewBuilder private var workspace: some View {
        switch app.navSection {
        case .today:
            if app.showingActions { ActionsWorkspaceView() } else { TodayView() }
        case .timeline:
            TimelineContentView(model: capture)
        case .meetings:
            HSplitView {
                MeetingListView(pendingDelete: $pendingDelete)
                    .frame(minWidth: 240, idealWidth: LBTokens.Metric.contentColumnWidth, maxWidth: 340)
                    .splitPaneAccessibilityLabel("Meeting library", autosaveName: "LokalBot.meetings", initialWidth: LBTokens.Metric.contentColumnWidth)
                MeetingLibraryDetailView(pendingDelete: $pendingDelete)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                    .splitPaneAccessibilityLabel("Meeting details")
            }
            .id("workspace.meetings")
        case .ask:
            HSplitView {
                ChatConversationList()
                        .frame(minWidth: 240, idealWidth: LBTokens.Metric.contentColumnWidth, maxWidth: 340)
                        .splitPaneAccessibilityLabel("Conversations", autosaveName: "LokalBot.recall", initialWidth: LBTokens.Metric.contentColumnWidth)
                AskView().frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                    .splitPaneAccessibilityLabel("Search and conversation")
            }
            .id("workspace.recall")
        case .agent:
            AgentView(sessions: app.agentSessions, installer: app.agentInstaller)
        case .settings:
            SettingsView()
                .id("workspace.settings")
        }
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            sidebarDestination(
                "Today", systemImage: "sun.max", section: .today,
                identifier: "sidebar.today")
            sidebarSectionHeader("Remember")
            sidebarDestination(
                "Meetings", systemImage: "waveform.circle", section: .meetings,
                identifier: "sidebar.meetings")
            sidebarDestination(
                "Timeline",
                systemImage: "calendar.day.timeline.left",
                section: .timeline,
                identifier: "sidebar.timeline")
            sidebarDestination(
                "Ask", systemImage: "sparkle.magnifyingglass", section: .ask,
                identifier: "sidebar.ask")
            sidebarSectionHeader("Tools")
            sidebarDestination(
                "Agent", systemImage: "wand.and.sparkles", section: .agent,
                identifier: "sidebar.agent")
            sidebarDestination(
                "Settings", systemImage: "gearshape", section: .settings,
                identifier: "sidebar.settings")
        }
        .listStyle(.sidebar)
        .tint(Brand.tealFill)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarPrivacyFooter()
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
                    if selection == .today { app.showingActions = false }
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
        systemImage: String,
        section: AppState.NavSection,
        identifier: String
    ) -> some View {
        SidebarDestinationLabel(title: title, systemImage: systemImage,
                                scriptedLabelColor: isScriptedCapture ? scriptedSidebarLabelColor : nil)
        .tag(section)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowBackground(sidebarRowBackground(section))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
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
        Text(title)
            .font(.subheadline.bold())
            .foregroundStyle(isScriptedCapture ? scriptedSidebarHeaderColor : Color.secondary)
            .padding(.leading, 11)
            .padding(.top, title == "Remember" ? 3 : 8)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
            .selectionDisabled(true)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .accessibilityIdentifier(
                title == "Remember" ? "sidebar.section.remember" : "sidebar.section.writeAct")
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

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(Brand.teal))
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(title)
                .font(.body)
                .foregroundStyle(scriptedLabelColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: LBTokens.Metric.sidebarRowHeight)
        .contentShape(Rectangle())
    }
}

/// Reflects the *actual* privacy posture instead of a hardcoded claim: with a
/// remote Think backend configured, "No data leaves your Mac" would be false —
/// meeting and workday text goes to the approved origin.
private struct SidebarPrivacyFooter: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.colorScheme) private var colorScheme

    private var destination: InferencePresentation { InferencePresentation(settings: app.settings) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if app.currentMeeting != nil {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        StatusDot(color: Brand.recording)
                        Text("Recording").font(.callout.weight(.semibold))
                        Spacer(minLength: 0)
                        MeetingRecordingTimerText(recording: app.recording)
                            .font(.callout.monospacedDigit())
                    }
                    Button("Live Transcript & Notes", action: app.showLiveMeeting)
                        .buttonStyle(.plain)
                        .font(.callout)
                        .help("Open the current recording")
                }
                .foregroundStyle(LBTokens.Palette.recordingText)
                .padding(10)
                .lbStatusSurface(.red)
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield").foregroundStyle(Brand.teal)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Storage: this Mac").font(.callout.weight(.semibold))
                    HStack(spacing: 4) {
                        Text(processingLabel)
                        if case .remote = destination { StatusDot(color: .orange, size: 5) }
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                    if case .remote(let host) = destination {
                        Text(host).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .lbGroupedSurface()
        }
        .padding(10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.localPrivacy")
    }

    private var processingLabel: String {
        switch destination {
        case .onDevice: "AI: on this Mac"
        case .remote: "AI: local + remote"
        case .blocked: "AI: connection blocked"
        }
    }
}
