import XCTest
import Combine
@testable import LokalBot

/// Every AppState change re-renders every view observing AppState, so
/// high-frequency state must reach only the views that draw it.
@MainActor
final class AppStateFanOutTests: XCTestCase {
    func testTypingMeetingNotesDoesNotRepublishAppState() {
        let app = AppState()
        var updates = 0
        let observer = app.objectWillChange.sink { updates += 1 }
        let meetingID = UUID()
        var text = ""
        for character in "Send the revised launch plan to Ana" {
            text.append(character)
            app.meetingNoteDrafts[meetingID] = text
        }
        XCTAssertEqual(updates, 0, "A keystroke in meeting notes must not re-render the whole app")
        XCTAssertEqual(app.meetingNoteDrafts[meetingID], text, "A remounted editor must resume the draft")
        withExtendedLifetime(observer) {}
    }

    func testTypingAnAskQueryRepublishesOnlyTheRecallWorkspace() {
        let app = AppState()
        var appUpdates = 0
        var recallUpdates = 0
        let appObserver = app.objectWillChange.sink { appUpdates += 1 }
        let recallObserver = app.recall.objectWillChange.sink { recallUpdates += 1 }
        var query = ""
        for character in "budget review" {
            query.append(character)
            app.recall.query = query
        }
        app.recallState.facet = .screen
        XCTAssertEqual(appUpdates, 0, "A keystroke in Ask must not re-render the whole app")
        XCTAssertEqual(recallUpdates, 14)
        XCTAssertEqual(app.recallQuery, "budget review")
        XCTAssertEqual(app.recall.state.facet, .screen)
        withExtendedLifetime((appObserver, recallObserver)) {}
    }

    func testSwitchingSettingsCategoryRepublishesAppStateOnce() {
        let app = AppState()
        let original = app.settingsTab
        defer { app.settingsTab = original }
        let target: AppState.SettingsTab = original == .privacy ? .general : .privacy
        var updates = 0
        let observer = app.objectWillChange.sink { updates += 1 }
        app.selectSettingsTab(target)
        XCTAssertEqual(updates, 1, "Clearing an already-empty focus must not add a second change")
        app.selectSettingsTab(target)
        XCTAssertEqual(updates, 1, "Choosing the shown category changes nothing")
        XCTAssertEqual(app.settingsTab, target)
        withExtendedLifetime(observer) {}
    }

    func testReloadingUnchangedDreamMemoryDoesNotRepublishAppState() {
        let app = AppState()
        app.refreshDreamMemory()
        var updates = 0
        let observer = app.objectWillChange.sink { updates += 1 }
        app.refreshDreamMemory()
        app.refreshDreamMemory()
        XCTAssertEqual(updates, 0, "Settings visits and evidence changes reload an unchanged memory")
        withExtendedLifetime(observer) {}
    }

    func testAppScenesRefreshOnlyWhenTheirValuesChange() async {
        let app = AppState()
        let scene = AppSceneState(app: app)
        var updates = 0
        let observer = scene.objectWillChange.sink { updates += 1 }
        // AppState changes no menu, window title or status glyph reads.
        app.lastError = "Could not reach the model server."
        app.showingActions = true
        app.selectedPersonID = "person"
        app.evidenceMeetingID = UUID()
        await drainMainQueue()
        XCTAssertEqual(updates, 0, "The App body, menus and scenes must not rebuild for unrelated changes")

        app.navSection = .agent
        await drainMainQueue()
        XCTAssertEqual(updates, 1)
        XCTAssertTrue(scene.values.agentActive)
        XCTAssertFalse(scene.values.canSearchSelectedMeeting)
        withExtendedLifetime(observer) {}
    }

    func testDownloadProgressReachesModelViewsButNotAppState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fan-out-download-\(UUID().uuidString)", isDirectory: true)
        let storage = StorageManager(rootURL: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let ticks = 40
        let downloads = ModelDownloadManager(
            stagedDownloader: { _, _, _, _, progress in
                for written in 1...ticks {
                    progress.publish(.init(bytesWritten: Int64(written), totalBytes: 100))
                }
                try await Task.sleep(for: .seconds(60))
                throw CancellationError()
            },
            sha256Digest: { _ in "" })
        let roles = ModelRoles(
            settings: { AppSettings() }, storage: storage, downloads: downloads,
            downloadedTranscriptionModels: { _ in [] }, onReadinessChanged: {})
        var modelViewUpdates = 0
        var relayed = 0
        let viewObserver = roles.objectWillChange.sink { modelViewUpdates += 1 }
        // AppState forwards exactly this publisher.
        let relayObserver = roles.readinessChanges.sink { relayed += 1 }

        downloads.download(url: "https://models.example.test/think.gguf", fileName: "think.gguf",
                           id: "think", storage: storage)
        let deadline = Date().addingTimeInterval(5)
        while roles.downloadProgress["think"] != Double(ticks) / 100, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(roles.downloadProgress["think"], Double(ticks) / 100)
        XCTAssertGreaterThanOrEqual(modelViewUpdates, ticks, "Progress views observe ModelRoles directly")
        XCTAssertEqual(relayed, 1, "Only the start of the download is a readiness change")

        downloads.cancel(id: "think")
        XCTAssertNil(roles.downloadProgress["think"])
        XCTAssertEqual(relayed, 2, "The end of the download is a readiness change")
        withExtendedLifetime((viewObserver, relayObserver)) {}
    }

    /// Runs after every block already queued on the main queue.
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
