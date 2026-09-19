import SwiftUI
import Combine
import AVFoundation
import CoreGraphics

/// Process entry point. Parses any headless subcommand before SwiftUI exists,
/// and disables AppKit window restoration *before* SwiftUI launches when
/// starting menu-bar-only — `applicationWillFinishLaunching` runs after AppKit
/// has already read the flag, so a previously-open window would be restored
/// and force the Dock icon back on. Setting it pre-launch is the only
/// reliable point.
@main
enum LokalBotMain {
    @MainActor
    static func main() {
        // Carry a prior LokalBotV2 install's data forward before anything reads
        // a store: settings are loaded below (via lokalbotLaunchesMenuBarOnly),
        // and AppState builds StorageManager/SearchIndex right after.
        DataMigration.runIfNeeded()
        HeadlessCommand.requested = HeadlessCommand.parse(CommandLine.arguments)
        UserDefaults.standard.set(lokalbotLaunchesMenuBarOnly(),
                                  forKey: "ApplePersistenceIgnoreState")
        LokalBotApp.main()
    }
}

struct LokalBotApp: App {
    @StateObject private var app: AppState
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let appState = AppState()
        _app = StateObject(wrappedValue: appState)
        AppDelegate.appState = appState
    }

    var body: some Scene {
        Window("LokalBot", id: "main") {
            mainWindow
        }
        .defaultSize(width: 1180, height: 740)
        .commands {
            CommandMenu("Recording") {
                Button(app.isRecording ? "Stop Recording" : "Start Recording") {
                    app.isRecording
                        ? app.stopRecording()
                        : app.startRecording(context: app.recordingContext(for: app.detector.activeApp), source: "command")
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button(
                    app.dictation.state.isRecording
                        ? "Stop & Compose Dictation"
                        : app.dictation.isStarting || app.dictation.state.isWorking
                            ? "Cancel Dictation" : "Start Dictation"
                ) {
                    app.dictation.toggle(source: "command")
                }
            }
            // ⌘K opens the command palette. Registered at the app level so it
            // works from anywhere; the palette window is opened via openWindow.
            CommandGroup(after: .toolbar) {
                Button("Command Palette…") {
                    WindowAccess.shared.open("palette")
                }
                .keyboardShortcut("k", modifiers: [.command])

                Button("Ask…") {
                    WindowAccess.shared.open("quick-recall")
                }
            }
            CommandGroup(before: .textEditing) {
                Button("Find in Meeting…") {
                    app.requestSelectedMeetingSearch()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!app.canSearchSelectedMeeting)
            }
            // Keep the standard Settings shortcut inside the main workspace.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    app.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        Window("Welcome to LokalBot", id: "onboarding") {
            OnboardingView()
                .environmentObject(app)
        }
        .windowResizability(.contentSize)

        // The ⌘K command palette. A lightweight, keyboard-first launcher that
        // records, navigates, and opens recent meetings without the sidebar.
        Window("Command Palette", id: "palette") {
            CommandPaletteView()
                .environmentObject(app)
                .brandTinted()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)

        Window("Ask", id: "quick-recall") {
            QuickRecallView()
                .environmentObject(app)
                .brandTinted()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)

#if !LOKALBOT_UI_TEST_HOST
        MenuBarExtra {
            MenuBarView(dictation: app.dictation)
                .environmentObject(app)
                .brandTinted()
        } label: {
            MenuBarLabel(app: app, dictation: app.dictation)
        }
        .menuBarExtraStyle(.window)
#endif
    }

    private var mainWindow: some View {
        MainWindowView()
            .environmentObject(app)
            .brandTinted()
    }
}

/// One long-lived utility worker owns the background FTS connection. A
/// dictionary keeps only the latest pending snapshot for each meeting, while
/// the actor serializes SQLite writes across the entire queue.
actor SearchIndexWorkQueue {
    private let databaseURL: URL
    private let rootURL: URL
    private var index: SearchIndex?
    private var storage: StorageManager?
    private var pending: [Meeting.ID: Meeting] = [:]
    private var deleted: Set<Meeting.ID> = []
    private var drainTask: Task<Void, Never>?
    private var stopped = false

    init(databaseURL: URL, rootURL: URL) {
        self.databaseURL = databaseURL
        self.rootURL = rootURL
    }

    func enqueue(_ meeting: Meeting) {
        enqueue([meeting])
    }

    func enqueue(_ meetings: [Meeting]) {
        guard !stopped else { return }
        for meeting in meetings where !deleted.contains(meeting.id) {
            pending[meeting.id] = meeting
        }
        startDrainIfNeeded()
    }

    @discardableResult
    func remove(_ meetingID: Meeting.ID) -> (search: Bool, embedding: Bool) {
        deleted.insert(meetingID)
        pending.removeValue(forKey: meetingID)
        let searchClean = searchIndex.remove(meetingID)
        let embeddingClean = EmbeddingIndex.remove(
            meetingID, databaseURL: databaseURL)
        return (searchClean, embeddingClean)
    }

    /// Reopens a source folded into a merged meeting and queues its existing
    /// evidence for indexing again. The actor serializes this with any late
    /// cleanup request from the original merge.
    func restore(_ meeting: Meeting) throws -> Meeting {
        guard !stopped else { throw CancellationError() }
        let restored = try workerStorage.restoreMergedSource(meeting)
        deleted.remove(meeting.id)
        searchIndex.noteRestoration(meeting.id)
        pending[meeting.id] = restored
        startDrainIfNeeded()
        return restored
    }

    @discardableResult
    func reconcileDeletedMeetings() -> (search: Bool, embedding: Bool) {
        let searchClean = searchIndex.reconcileDeletedMeetings()
        let embeddingClean = EmbeddingIndex.reconcileDeletedMeetings(
            databaseURL: databaseURL)
        return (searchClean, embeddingClean)
    }

    func stop() {
        stopped = true
        pending.removeAll()
        drainTask?.cancel()
        drainTask = nil
    }

    /// Test/diagnostic seam: wait for the currently scheduled drain and any
    /// follow-up work that arrived while it yielded between meetings.
    func waitUntilIdle() async {
        while let drainTask {
            await drainTask.value
        }
    }

    private var searchIndex: SearchIndex {
        if let index { return index }
        let created = SearchIndex(databaseURL: databaseURL)
        index = created
        return created
    }

    private var workerStorage: StorageManager {
        if let storage { return storage }
        let created = StorageManager(rootURL: rootURL)
        storage = created
        return created
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil, !pending.isEmpty, !stopped else { return }
        drainTask = Task(priority: .utility) { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !Task.isCancelled, !stopped, let (meetingID, meeting) = pending.first {
            pending.removeValue(forKey: meetingID)
            searchIndex.reindex(meeting, storage: workerStorage)
            // Let enqueues, deletions, and shutdown coalesce or cancel work
            // between meetings without allowing concurrent SQLite writers.
            await Task.yield()
        }
        drainTask = nil
        startDrainIfNeeded()
    }
}
