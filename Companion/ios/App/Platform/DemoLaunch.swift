import Foundation
import LokalBotCompanionKit
import SwiftUI

/// Debug-only launch arguments that open the app on a given screen with the
/// sample library presented as a paired Mac, for screenshots without UI
/// automation. For example:
///
///     -demoPaired YES -demoSection meetings -demoMeeting <id> -demoTab transcript
enum DemoLaunch {
    private static var defaults: UserDefaults { .standard }

    @MainActor
    static func store() -> (any CompanionStore)? {
        #if DEBUG
        if defaults.bool(forKey: "demoHeldRecordings") {
            let store = FixtureStore(envelopes: [])
            let held = RecordingItem(id: "demo-held", title: "Site visit", state: .waiting, startedAt: Date(), durationSeconds: 1_834)
            Task { await store.setRecordings([held]) }
            return store
        }
        guard defaults.bool(forKey: "demoPaired") else { return nil }
        let now = SampleLibrary.referenceDate
        let status = SyncStatus(paired: true, lastSyncAt: now.addingTimeInterval(-120),
                                lastAddress: defaults.bool(forKey: "demoTailscale") ? "100.101.102.103:17890" : "192.168.1.20:17890",
                                cursor: 19, macName: "Stevan's MacBook Pro")
        let store = try? FixtureStore.sampleLibrary(configuration: .init(
            now: { now }, keepsChangesPending: true, pairedStatus: status,
            macReachable: !defaults.bool(forKey: "demoUnreachable")))
        if defaults.bool(forKey: "demoRecordings"), let store {
            // With -demoUnreachable the waiting ones stay as they are.
            let waiting = RecordingItem(id: "demo-waiting", title: "Site visit", state: .waiting,
                                        startedAt: now.addingTimeInterval(-3_000), durationSeconds: 1_834)
            let held = RecordingItem(id: "demo-held", state: .waiting, startedAt: now.addingTimeInterval(-9_000),
                                     durationSeconds: 612,
                                     message: "This computer isn't accepting recordings. Turn on \"Accept recordings from my devices\" in its settings.")
            let refused = RecordingItem(id: "demo-failed", title: "Hallway chat", state: .failed,
                                        startedAt: now.addingTimeInterval(-20_000), durationSeconds: 4,
                                        message: "This recording has no audio your Mac can transcribe.")
            let sent = RecordingItem(id: "demo-sent", title: "Budget review", state: .uploaded,
                                     startedAt: now.addingTimeInterval(-1_200), durationSeconds: 2_410)
            Task { await store.setRecordings([sent, waiting, held, refused]) }
        }
        return store
        #else
        return nil
        #endif
    }

    /// The microphone, or with `-demoPaired` a stand-in that writes a few bytes
    /// and shows a moving level, so screenshots never record anyone.
    @MainActor
    static func capture() -> AudioCapture {
        #if DEBUG
        if defaults.bool(forKey: "demoPaired") { return DemoCapture() }
        #endif
        return AudioRecorderCapture()
    }

    #if DEBUG
    @MainActor
    private final class DemoCapture: AudioCapture {
        var onEvent: ((AudioCaptureEvent) -> Void)?
        private var started: Date?
        var currentTime: TimeInterval { (started.map { Date().timeIntervalSince($0) } ?? 0) + 754 }
        var level: Float { 0.55 + 0.25 * Float(sin(currentTime * 4)) }

        func requestPermission() async -> Bool { true }

        func start(url: URL) throws {
            try Data([0xFF, 0xF1, 0x50, 0x80]).write(to: url)
            started = Date()
        }

        func resume() throws {}

        func stop() -> TimeInterval { currentTime }
    }
    #endif

    /// Exercises the real store end to end against a test host:
    /// `-demoPairLink <lokalbot://pair?d=…>` pairs at launch,
    /// `-demoToggleAction <meetingID>/<actionID>` marks an action done, and
    /// `-demoQueueRecording <path>` queues a file as if it had just been
    /// recorded, which sends it without touching the microphone.
    @MainActor
    static func exercise(_ environment: AppEnvironment) async {
        #if DEBUG
        let session = environment.session
        if defaults.bool(forKey: "demoSample") {
            do {
                try await session.showSampleLibrary()
            } catch {
                session.notice = "The sample library didn't load: \(error.localizedDescription)"
            }
        }
        if let link = defaults.string(forKey: "demoPairLink") {
            do {
                if let name = defaults.string(forKey: "demoDeviceName") {
                    try await StoreFactory.useDeviceName(name, in: session)
                }
                _ = try await session.pair(payload: link)
            } catch {
                session.notice = "Pairing failed: \(error.localizedDescription)"
            }
        }
        if let toggle = defaults.string(forKey: "demoToggleAction") {
            let parts = toggle.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                try? await session.setActionStatus(.done, meetingID: parts[0], actionID: parts[1])
            }
        }
        if let path = defaults.string(forKey: "demoQueueRecording") {
            do {
                let item = try await session.store.beginRecording(title: defaults.string(forKey: "demoRecordingTitle"))
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: item.filePath).deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(atPath: path, toPath: item.filePath)
                _ = try await session.store.finishRecording(id: item.id, durationSeconds: 20)
                await session.recordingsDidChange()
                await session.uploadRecordings()
            } catch {
                session.notice = "Queueing the recording failed: \(error.localizedDescription)"
            }
        }
        if defaults.bool(forKey: "demoRecordingScreen") { await environment.recording.begin() }
        #endif
    }

    @MainActor
    static func apply(to environment: AppEnvironment) {
        #if DEBUG
        if defaults.bool(forKey: "demoPaired") {
            environment.session.referenceDateOverride = SampleLibrary.referenceDate.addingTimeInterval(120)
        }
        let navigator = environment.navigator
        if let action = defaults.string(forKey: "demoAction") { navigator.actionSelection = action }
        if let person = defaults.string(forKey: "demoPerson") { navigator.personSelection = person }
        if let project = defaults.string(forKey: "demoProject") { navigator.projectSelection = project }
        if let day = defaults.string(forKey: "demoDay").flatMap(DayKey.init) { navigator.timelineDay = day }
        if let question = defaults.string(forKey: "demoAsk") { navigator.demoQuestion = question }
        if let link = defaults.string(forKey: "demoPairingLink") { navigator.demoPairingLink = link }
        if let meeting = defaults.string(forKey: "demoMeeting") {
            navigator.meetingSelection = meeting
            let offset = defaults.string(forKey: "demoAt").flatMap(Double.init)
            navigator.meetingFocus = .init(meetingID: meeting, offset: offset)
            navigator.demoMeetingTab = defaults.string(forKey: "demoTab")
        }
        if let section = defaults.string(forKey: "demoSection").flatMap(AppSection.init(rawValue:)) {
            navigator.open(section)
        }
        #endif
    }

    /// `-demoWidth 375` narrows the window's content and makes it compact,
    /// approximating Split View and Slide Over widths in screenshots.
    struct Frame<Content: View>: View {
        @ViewBuilder let content: Content

        /// `-demoSizeClass regular` keeps a narrow window regular, like an
        /// unfolded foldable that reports regular width.
        private var sizeClass: UserInterfaceSizeClass? {
            switch UserDefaults.standard.string(forKey: "demoSizeClass") {
            case "regular": .regular
            case "compact": .compact
            default: nil
            }
        }

        var body: some View {
            #if DEBUG
            if let width = UserDefaults.standard.string(forKey: "demoWidth").flatMap(Double.init) {
                content
                    .frame(width: width)
                    .environment(\.horizontalSizeClass, sizeClass ?? (width < 700 ? .compact : .regular))
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Color.black).frame(width: 1).offset(x: 1).ignoresSafeArea()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                content
            }
            #else
            content
            #endif
        }
    }
}
