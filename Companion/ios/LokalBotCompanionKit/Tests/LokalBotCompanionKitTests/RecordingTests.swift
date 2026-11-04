import Foundation
import Testing
@testable import LokalBotCompanionKit

@MainActor
private final class FakeCapture: AudioCapture {
    var onEvent: ((AudioCaptureEvent) -> Void)?
    var currentTime: TimeInterval = 0
    var level: Float = 0
    var permission = true
    var startError: Error?
    var writes = true
    private(set) var url: URL?
    private(set) var stopped = 0
    private(set) var resumed = 0

    func requestPermission() async -> Bool { permission }

    func start(url: URL) throws {
        if let startError { throw startError }
        self.url = url
        if writes { try Data([0xFF, 0xF1, 0x50]).write(to: url) }
        currentTime = 12.5
    }

    func resume() throws { resumed += 1 }

    func stop() -> TimeInterval {
        stopped += 1
        return currentTime
    }
}

private struct Boom: LocalizedError {
    var errorDescription: String? { "The microphone is busy." }
}

@MainActor
private func pairedSession(reachable: Bool = true) async throws -> CompanionSession {
    let status = SyncStatus(paired: true, lastSyncAt: Date(), lastAddress: "192.168.1.20:17890", macName: "Dev Mac")
    let store = try FixtureStore.sampleLibrary(configuration: .init(pairedStatus: status, macReachable: reachable))
    let session = CompanionSession(store: store)
    await session.start()
    return session
}

@Suite("Recording")
@MainActor
struct RecordingModelTests {
    @Test func recordingGoesToTheMacWhenStopped() async throws {
        let session = try await pairedSession()
        let capture = FakeCapture()
        let model = RecordingModel(session: session, capture: capture)

        await model.begin()
        #expect(model.isPresented)
        #expect(model.phase == .recording)
        #expect(session.recordings.first?.state == .recording)
        model.title = "  Site visit "

        await model.stop()
        #expect(model.phase == .idle)
        #expect(!model.isPresented)
        #expect(capture.stopped == 1)
        let row = try #require(session.recordings.first)
        #expect(row.state == .uploaded)
        #expect(row.title == "Site visit")
        #expect(row.durationSeconds == 12.5)
        #expect(!FileManager.default.fileExists(atPath: try #require(capture.url).path), "the audio left the device")
    }

    @Test func aRecordingWaitsWhileTheMacIsAway() async throws {
        let session = try await pairedSession(reachable: false)
        let capture = FakeCapture()
        let model = RecordingModel(session: session, capture: capture)
        await model.begin()
        await model.stop()
        #expect(session.recordings.first?.state == .waiting)
        #expect(FileManager.default.fileExists(atPath: try #require(capture.url).path))
        try? FileManager.default.removeItem(at: try #require(capture.url))
    }

    @Test func aRefusedMicrophoneRecordsNothing() async throws {
        let session = try await pairedSession()
        let capture = FakeCapture()
        capture.permission = false
        let model = RecordingModel(session: session, capture: capture)
        await model.begin()
        #expect(model.isPresented)
        #expect(model.microphoneDenied)
        #expect(model.phase == .idle)
        #expect(session.recordings.isEmpty)
    }

    @Test func aRecorderThatWontStartLeavesNoRow() async throws {
        let session = try await pairedSession()
        let capture = FakeCapture()
        capture.startError = Boom()
        let model = RecordingModel(session: session, capture: capture)
        await model.begin()
        #expect(model.phase == .idle)
        #expect(model.errorMessage == "The microphone is busy.")
        #expect(session.recordings.isEmpty)
    }

    @Test func stoppingWithNothingWrittenSaysSo() async throws {
        let session = try await pairedSession()
        let capture = FakeCapture()
        capture.writes = false
        let model = RecordingModel(session: session, capture: capture)
        await model.begin()
        await model.stop()
        #expect(model.errorMessage == "Nothing was recorded.")
        #expect(session.recordings.isEmpty)
    }

    @Test func discardLeavesNothing() async throws {
        let session = try await pairedSession()
        let capture = FakeCapture()
        let model = RecordingModel(session: session, capture: capture)
        await model.begin()
        await model.discard()
        #expect(capture.stopped == 1)
        #expect(!model.isPresented)
        #expect(session.recordings.isEmpty)
    }

    @Test func aCallPausesAndResumeCarriesOn() async throws {
        let session = try await pairedSession()
        let capture = FakeCapture()
        let model = RecordingModel(session: session, capture: capture)
        await model.begin()
        capture.onEvent?(.interrupted)
        #expect(model.phase == .interrupted)
        model.resume()
        #expect(capture.resumed == 1)
        #expect(model.phase == .recording)
        capture.onEvent?(.interrupted)
        capture.onEvent?(.resumed)
        #expect(model.phase == .recording)
        await model.stop()
    }

    @Test func aRecorderFailureKeepsTheRecordingAndSaysSo() async throws {
        let session = try await pairedSession()
        let capture = FakeCapture()
        let model = RecordingModel(session: session, capture: capture)
        await model.begin()
        capture.onEvent?(.failed)
        for _ in 0..<500 where session.recordings.first?.state != .uploaded {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.phase == .idle)
        #expect(model.errorMessage?.contains("saved") == true)
        #expect(session.recordings.first?.state == .uploaded)
    }

    @Test func beingRemovedStopsTheRecorder() async throws {
        let session = try await pairedSession()
        let capture = FakeCapture()
        let model = RecordingModel(session: session, capture: capture)
        await model.begin()
        await session.removeThisDevice()
        model.sessionModeChanged()
        #expect(capture.stopped == 1)
        #expect(model.phase == .idle)
        #expect(!model.isPresented)
        #expect(session.recordings.isEmpty)
    }

    @Test func aSecondTapOnRecordStartsNothingMore() async throws {
        let session = try await pairedSession()
        let capture = FakeCapture()
        let model = RecordingModel(session: session, capture: capture)
        async let first: Void = model.begin()
        async let second: Void = model.begin()
        _ = await (first, second)
        #expect(session.recordings.count == 1)
        await model.stop()
    }

    @Test func beingRemovedByTheMacKeepsWhatWasRecorded() async throws {
        let session = try await pairedSession()
        let capture = FakeCapture()
        let model = RecordingModel(session: session, capture: capture)
        await model.begin()
        // As if a sync heard `revoked`: the pairing goes, the recording stays.
        let store = try #require(session.store as? FixtureStore)
        await store.forgetPairingKeepingRecordings()
        await session.refresh()
        model.sessionModeChanged()
        for _ in 0..<500 where session.recordings.first?.state != .waiting {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(capture.stopped == 1)
        #expect(session.recordings.first?.state == .waiting)
        try? FileManager.default.removeItem(at: try #require(capture.url))
    }

    @Test func aCallAsksForAttentionAndComingBackClearsIt() async throws {
        let session = try await pairedSession()
        let capture = FakeCapture()
        let model = RecordingModel(session: session, capture: capture)
        var interruptions = 0
        var resumes = 0
        model.onInterrupted = { interruptions += 1 }
        model.onResumed = { resumes += 1 }
        await model.begin()
        capture.onEvent?(.interrupted)
        #expect(interruptions == 1)
        model.resume()
        #expect(resumes == 1)
        await model.stop()
    }

    @Test func aRecordingCutShortIsKeptAtLaunch() async throws {
        let status = SyncStatus(paired: true, macName: "Dev Mac")
        let store = try FixtureStore.sampleLibrary(configuration: .init(pairedStatus: status, macReachable: false))
        await store.setRecordings([RecordingItem(id: "a", state: .recording, startedAt: Date())])
        let session = CompanionSession(store: store)
        await session.start()
        #expect(session.recordings.first?.state == .waiting)
    }
}

@Suite("Recording rows")
struct RecordingRowTests {
    @Test func theManifestFieldIsOptionalForOlderMacs() throws {
        let json = """
        {"schemaVersion":1,"libraryName":"L","macName":"M","historyDays":0,"askEnabled":true,\
        "dataClasses":{"meetings":true,"transcripts":true,"digests":true,"timeline":true,\
        "windowTitles":true,"people":true,"projects":true},"generatedAt":"2026-10-31T10:12:00.000Z"}
        """
        #expect(try CompanionJSON.decode(Manifest.self, from: json).recordingsEnabled == nil)
    }

    @Test func onlyWhatHasNotReachedTheMacIsTheOnlyCopy() {
        let row = RecordingItem(id: "a", state: .waiting, startedAt: Date())
        #expect(row.isOnlyCopy)
        var sent = row
        sent.state = .uploaded
        #expect(!sent.isOnlyCopy)
    }
}
