import AVFoundation
import Carbon.HIToolbox
import XCTest
@testable import LokalBot

/// Recording feedback (real levels, first-audio cue), paste read-back, Esc,
/// Tap or hold, microphone choice and the Secure Input warning.
@MainActor
final class DictationFeedbackTests: XCTestCase {

    // MARK: - Levels and first audio

    func testLevelMeterMapsLoudnessAndKeepsRecentHistory() throws {
        XCTAssertEqual(AudioLevelMeter.normalized(rms: 0), 0)
        XCTAssertEqual(AudioLevelMeter.normalized(rms: 0.0005), 0, "room noise stays flat")
        XCTAssertEqual(AudioLevelMeter.normalized(rms: 0.5), 1, "loud speech fills the bar")
        let meter = AudioLevelMeter()
        XCTAssertEqual(meter.recent(3), [0, 0, 0])
        for level in 1...40 { meter.record(Float(level) / 40) }
        XCTAssertEqual(meter.recent(2), [39 / 40, 1])
        meter.reset()
        XCTAssertEqual(meter.recent(1), [0])

        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = 1_600
        for index in 0..<1_600 { buffer.floatChannelData![0][index] = 0.5 * sinf(Float(index) * 0.2) }
        XCTAssertEqual(AudioLevelMeter.rms(of: buffer), 0.3536, accuracy: 0.01)
        XCTAssertEqual(AudioLevelBars.height(for: 0, maxHeight: 18), 3)
        XCTAssertEqual(AudioLevelBars.height(for: 1, maxHeight: 18), 18)
    }

    func testRecorderReportsFirstAudioAndLevels() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-levels-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("tone.wav")
        try MicRecorderFileInputTests.writeTone(to: source, seconds: 2)
        let recorder = MicRecorder(makeInput: { try FileMicrophoneInput(url: source, speed: 4) })
        let firstAudio = expectation(description: "first audio")
        recorder.onFirstAudio = { firstAudio.fulfill() }
        try recorder.start(writingTo: folder.appendingPathComponent("dictation.caf"))
        defer { recorder.stop() }
        wait(for: [firstAudio], timeout: 3)
        XCTAssertGreaterThan(recorder.levelMeter.recent(1)[0], 0.3, "the 0.2-amplitude tone registers")
    }

    // MARK: - Paste read-back

    func testInsertionCheckToleratesReformattingButNotAbsence() {
        let sent = "Thanks, I'll bring the 4 copies tomorrow :)"
        XCTAssertEqual(DictationInsertionCheck.verdict(
            textBeforeCaret: "Earlier text. " + sent, inserted: sent), .landed)
        XCTAssertEqual(DictationInsertionCheck.verdict(
            textBeforeCaret: "Earlier text. Thanks, I’ll bring the 4 copies tomorrow 🙂", inserted: sent), .landed,
            "smart quotes and emoji conversion still count")
        XCTAssertEqual(DictationInsertionCheck.verdict(textBeforeCaret: "Earlier text.", inserted: sent), .missing)
        XCTAssertEqual(DictationInsertionCheck.verdict(textBeforeCaret: "", inserted: sent), .missing)
        XCTAssertEqual(DictationInsertionCheck.verdict(textBeforeCaret: nil, inserted: sent), .unknown,
                       "an unreadable field is not reported as a failure")
        XCTAssertEqual(DictationInsertionCheck.verdict(textBeforeCaret: "x", inserted: "  …  "), .unknown)
    }

    /// Review finding on 719b3dc: Chinese has no spaces between words, so a
    /// correct continuation looked like a failed paste.
    func testInsertionCheckMatchesScriptsWithoutWordSpaces() {
        XCTAssertEqual(DictationInsertionCheck.verdict(textBeforeCaret: "我们明天开会。", inserted: "开会。"), .landed)
        XCTAssertEqual(DictationInsertionCheck.verdict(
            textBeforeCaret: "明日は会議です。資料を送ります", inserted: "資料を送ります"), .landed)
        XCTAssertEqual(DictationInsertionCheck.verdict(textBeforeCaret: "我们明天", inserted: "开会。"), .missing)
    }

    /// Review finding on 719b3dc: an app-only target (no field identity) let
    /// the read-back inspect whatever field had focus, including a secure one.
    func testReadBackRequiresTheBoundFieldAndNeverASecureOne() {
        XCTAssertFalse(DictationInsertionCheck.allowsReadBack(boundIdentity: nil, liveIdentity: "field", isSecure: false))
        XCTAssertFalse(DictationInsertionCheck.allowsReadBack(boundIdentity: "", liveIdentity: "", isSecure: false))
        XCTAssertFalse(DictationInsertionCheck.allowsReadBack(boundIdentity: "field", liveIdentity: "other", isSecure: false))
        XCTAssertFalse(DictationInsertionCheck.allowsReadBack(boundIdentity: "field", liveIdentity: "field", isSecure: true))
        XCTAssertTrue(DictationInsertionCheck.allowsReadBack(boundIdentity: "field", liveIdentity: "field", isSecure: false))
    }

    /// Review finding on 719b3dc: levels never expired, so a stalled
    /// microphone froze the bars at its last loudness.
    func testStaleLevelsReadAsSilence() {
        let meter = AudioLevelMeter()
        meter.record(0.8, at: 1_000_000_000)
        XCTAssertEqual(meter.recent(1, now: 1_100_000_000), [0.8])
        XCTAssertEqual(meter.recent(1, now: 1_700_000_000), [0], "older than half a second")
    }

    // MARK: - Esc

    /// Review finding on 719b3dc: Esc pressed while holding ⌥ Space carries
    /// ⌥, was not recognized, and releasing the shortcut then transcribed.
    func testEscWhileHoldingThePushToTalkShortcutCancelsWithoutFinishing() throws {
        let monitor = DictationInputMonitor()
        var active = false
        var starts = 0, stops = 0, escapes = 0
        monitor.triggerModeProvider = { .pushToTalk }
        monitor.shortcutProvider = { .handyDefault }
        monitor.isDictationActive = { active }
        monitor.onStart = { starts += 1; active = true }
        monitor.onStop = { stops += 1 }
        monitor.onEscape = { escapes += 1; active = false }
        let space = CGKeyCode(kVK_Space)
        XCTAssertTrue(monitor.handle(type: .keyDown, event: try key(space, .maskAlternate)))
        XCTAssertFalse(monitor.handle(type: .keyDown, event: try key(CGKeyCode(kVK_Escape), [.maskAlternate, .maskCommand])),
                       "⌥⌘Esc adds a modifier the shortcut does not hold")
        XCTAssertTrue(monitor.handle(type: .keyDown, event: try key(CGKeyCode(kVK_Escape), .maskAlternate)))
        XCTAssertTrue(monitor.handle(type: .keyUp, event: try key(space, .maskAlternate, down: false)))
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(escapes, 1)
        XCTAssertEqual(stops, 0, "the release after Esc must not transcribe")

        XCTAssertTrue(monitor.handle(type: .keyDown, event: try key(space, .maskAlternate)))
        XCTAssertTrue(monitor.handle(type: .keyUp, event: try key(space, .maskAlternate, down: false)))
        XCTAssertEqual(stops, 1, "the next hold works normally")
    }

    func testEscWhileHoldingAChordCancelsWithoutFinishing() async throws {
        let monitor = DictationInputMonitor()
        var active = false
        var stops = 0, escapes = 0, cancels = 0
        monitor.triggerModeProvider = { .pushToTalk }
        monitor.shortcutProvider = { DictationShortcut(keyCode: nil, modifiers: [.maskControl, .maskAlternate]) }
        monitor.chordHoldDelay = 0.02
        monitor.isDictationActive = { active }
        monitor.onStart = { active = true }
        monitor.onStop = { stops += 1 }
        monitor.onCancel = { cancels += 1 }
        monitor.onEscape = { escapes += 1; active = false }
        _ = monitor.handle(type: .flagsChanged, event: try flags([.maskControl, .maskAlternate]))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(monitor.handle(type: .keyDown, event: try key(CGKeyCode(kVK_Escape), [.maskControl, .maskAlternate])))
        _ = monitor.handle(type: .flagsChanged, event: try flags([]))
        XCTAssertEqual(escapes, 1)
        XCTAssertEqual(stops, 0)
        XCTAssertEqual(cancels, 0, "Esc already cancelled; the chord does not cancel again")
    }

    func testEscCancelsOnlyWhileDictating() throws {
        let monitor = DictationInputMonitor()
        var active = false
        var escapes = 0
        monitor.isDictationActive = { active }
        monitor.onEscape = { escapes += 1 }
        XCTAssertFalse(monitor.handle(type: .keyDown, event: try key(CGKeyCode(kVK_Escape))),
                       "Esc belongs to the app when no dictation runs")
        active = true
        XCTAssertTrue(monitor.handle(type: .keyDown, event: try key(CGKeyCode(kVK_Escape))))
        XCTAssertFalse(monitor.handle(type: .keyDown, event: try key(CGKeyCode(kVK_Escape), [.maskCommand])),
                       "⌘Esc is another shortcut")
        XCTAssertEqual(escapes, 1)
    }

    // MARK: - Tap or hold

    func testTapOrHoldKeyTapKeepsRecordingAndHoldFinishesOnRelease() async throws {
        let (monitor, calls) = tapHoldMonitor(shortcut: .handyDefault)
        let space = CGKeyCode(kVK_Space)
        XCTAssertTrue(monitor.handle(type: .keyDown, event: try key(space, .maskAlternate)))
        XCTAssertTrue(monitor.handle(type: .keyUp, event: try key(space, .maskAlternate, down: false)))
        XCTAssertEqual(calls.starts, 1)
        XCTAssertEqual(calls.stops, 0, "a tap keeps recording")

        calls.active = true
        _ = monitor.handle(type: .keyDown, event: try key(space, .maskAlternate))
        _ = monitor.handle(type: .keyUp, event: try key(space, .maskAlternate, down: false))
        XCTAssertEqual(calls.stops, 1, "the next tap finishes, and its release does nothing more")

        calls.active = false
        _ = monitor.handle(type: .keyDown, event: try key(space, .maskAlternate))
        try await Task.sleep(for: .milliseconds(120))
        _ = monitor.handle(type: .keyUp, event: try key(space, .maskAlternate, down: false))
        XCTAssertEqual(calls.starts, 2)
        XCTAssertEqual(calls.stops, 2, "a hold finishes on release")
    }

    func testTapOrHoldChordTapStartsAndHoldFinishes() async throws {
        let chord = DictationShortcut(keyCode: nil, modifiers: [.maskControl, .maskAlternate])
        let (monitor, calls) = tapHoldMonitor(shortcut: chord)
        _ = monitor.handle(type: .flagsChanged, event: try flags([.maskControl, .maskAlternate]))
        _ = monitor.handle(type: .flagsChanged, event: try flags([]))
        XCTAssertEqual(calls.starts, 1, "a quick clean tap starts")
        XCTAssertEqual(calls.stops, 0)

        calls.active = true
        _ = monitor.handle(type: .flagsChanged, event: try flags([.maskControl, .maskAlternate]))
        _ = monitor.handle(type: .flagsChanged, event: try flags([]))
        XCTAssertEqual(calls.stops, 1, "tapping again finishes")

        calls.active = false
        _ = monitor.handle(type: .flagsChanged, event: try flags([.maskControl, .maskAlternate]))
        try await Task.sleep(for: .milliseconds(150))
        _ = monitor.handle(type: .flagsChanged, event: try flags([]))
        XCTAssertEqual(calls.starts, 2)
        XCTAssertEqual(calls.stops, 2, "holding past the threshold finishes on release")
    }

    // MARK: - Microphone and Secure Input

    func testMicrophoneChoiceKeepsADisconnectedPreferenceVisible() {
        let connected = [DictationMicrophone.Option(id: "built-in", name: "MacBook Pro Microphone")]
        let rows = DictationMicrophone.options(preferredID: "airpods", available: connected, defaultName: "System default")
        XCTAssertEqual(rows.map(\.id), ["", "built-in", "airpods"])
        XCTAssertEqual(rows.last?.name, "Not connected")
        XCTAssertEqual(DictationMicrophone.options(preferredID: "", available: connected, defaultName: "Default").count, 2)
    }

    func testSecureInputMessageNamesTheAppWhenKnown() {
        XCTAssertTrue(DictationSecureInput.message(appName: "Terminal").contains("Terminal"))
        XCTAssertTrue(DictationSecureInput.message(appName: nil).contains("another app"))
        let chinese = DictationSecureInput.message(appName: "Terminal") { AppLanguage.simplifiedChinese.localized($0) }
        XCTAssertTrue(chinese.contains("Terminal"))
        XCTAssertNotEqual(chinese, DictationSecureInput.message(appName: "Terminal"))
    }

    func testNewDictationSettingsPersist() throws {
        var settings = AppSettings()
        XCTAssertTrue(settings.dictationPlaysStartSound)
        XCTAssertEqual(settings.dictationMicrophoneID, "")
        settings.dictationPlaysStartSound = false
        settings.dictationMicrophoneID = "BuiltInMicrophoneDevice"
        settings.dictationTriggerMode = .tapOrHold
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(decoded.dictationPlaysStartSound)
        XCTAssertEqual(decoded.dictationMicrophoneID, "BuiltInMicrophoneDevice")
        XCTAssertEqual(decoded.dictationTriggerMode, .tapOrHold)
        XCTAssertTrue(DictationView.readyText(triggerMode: .tapOrHold, shortcut: .handyDefault).contains("hold"))
    }

    // MARK: - Helpers

    private final class Calls {
        var starts = 0
        var stops = 0
        var active = false
    }

    private func tapHoldMonitor(shortcut: DictationShortcut) -> (DictationInputMonitor, Calls) {
        let monitor = DictationInputMonitor()
        let calls = Calls()
        monitor.triggerModeProvider = { .tapOrHold }
        monitor.shortcutProvider = { shortcut }
        monitor.tapHoldThreshold = 0.08
        monitor.chordHoldDelay = 0.03
        monitor.isDictationActive = { calls.active }
        monitor.onStart = { calls.starts += 1 }
        monitor.onStop = { calls.stops += 1 }
        return (monitor, calls)
    }

    private func key(_ keyCode: CGKeyCode, _ modifiers: CGEventFlags = [], down: Bool = true) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down))
        event.flags = modifiers
        return event
    }

    private func flags(_ modifiers: CGEventFlags) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Option), keyDown: true))
        event.flags = modifiers
        return event
    }
}
