import AppKit
import Carbon.HIToolbox
import XCTest
@testable import LokalBot

/// The dictation shortcut can be changed in Settings.
final class DictationShortcutTests: XCTestCase {
    private let controlShiftD = DictationShortcut(
        keyCode: CGKeyCode(kVK_ANSI_D), modifiers: [.maskControl, .maskShift])

    func testDefaultStaysOptionSpace() {
        XCTAssertEqual(AppSettings().dictationShortcut, .handyDefault)
        XCTAssertEqual(DictationShortcut.handyDefault.displayLabel, "⌥ Space")
    }

    func testLabelsUseMacModifierOrder() {
        XCTAssertEqual(DictationShortcut(
            keyCode: CGKeyCode(kVK_Return), modifiers: [.maskCommand, .maskShift, .maskControl]).displayLabel,
                       "⌃⇧⌘ Return")
        XCTAssertEqual(DictationShortcut(keyCode: CGKeyCode(kVK_F5), modifiers: []).displayLabel, "F5")
        let letter = controlShiftD.displayLabel
        XCTAssertTrue(letter.hasPrefix("⌃⇧ "))
        XCTAssertFalse(letter.contains("Key "), "character keys are named from the keyboard layout")
    }

    func testShortcutsThatWouldBlockTypingAreRejected() {
        let d = CGKeyCode(kVK_ANSI_D)
        XCTAssertEqual(DictationShortcut(keyCode: d, modifiers: []).problem, .needsModifier)
        XCTAssertEqual(DictationShortcut(keyCode: d, modifiers: .maskShift).problem, .needsModifier,
                       "⇧D types a capital D")
        XCTAssertEqual(DictationShortcut(keyCode: CGKeyCode(kVK_Space), modifiers: []).problem, .needsModifier)
        XCTAssertEqual(DictationShortcut(keyCode: d, modifiers: .maskCommand).problem, .commandOnly)
        XCTAssertEqual(DictationShortcut(keyCode: CGKeyCode(kVK_Escape), modifiers: .maskAlternate).problem,
                       .reservedForCancel)

        XCTAssertNil(controlShiftD.problem)
        XCTAssertNil(DictationShortcut(keyCode: CGKeyCode(kVK_F5), modifiers: []).problem)
        XCTAssertNil(DictationShortcut(keyCode: CGKeyCode(kVK_Space), modifiers: .maskCommand).problem)
        XCTAssertNil(DictationShortcut.handyDefault.problem)
    }

    func testModifiersOutsideTheShortcutAreIgnored() {
        let withCapsLock = DictationShortcut(
            keyCode: CGKeyCode(kVK_Space), modifiers: [.maskAlternate, .maskAlphaShift])
        XCTAssertEqual(withCapsLock, .handyDefault)
    }

    func testShortcutPersistsWithSettings() throws {
        var settings = AppSettings()
        settings.dictationShortcut = controlShiftD
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.dictationShortcut, controlShiftD)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stored = try XCTUnwrap(json["dictationShortcut"] as? [String: Any])
        XCTAssertEqual(stored["keyCode"] as? Int, kVK_ANSI_D)
        XCTAssertEqual(stored["modifiers"] as? [String], ["control", "shift"])
    }

    func testSettingsWithoutAShortcutOrWithAnUnsafeOneUseTheDefault() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(AppSettings())) as? [String: Any])
        json.removeValue(forKey: "dictationShortcut")
        XCTAssertEqual(try decode(json).dictationShortcut, .handyDefault)

        json["dictationShortcut"] = ["keyCode": kVK_ANSI_D, "modifiers": [String]()]
        XCTAssertEqual(try decode(json).dictationShortcut, .handyDefault,
                       "a bare letter would swallow typing system-wide")
    }

    @MainActor
    func testMonitorFollowsTheConfiguredShortcut() throws {
        let monitor = DictationInputMonitor()
        var shortcut = controlShiftD
        var toggles = 0
        monitor.triggerModeProvider = { .toggle }
        monitor.shortcutProvider = { shortcut }
        monitor.onToggle = { toggles += 1 }

        XCTAssertFalse(monitor.handle(type: .keyDown, event: try keyEvent(
            .handyDefault, down: true)), "⌥ Space passes through once it is not the shortcut")
        XCTAssertTrue(monitor.handle(type: .keyDown, event: try keyEvent(controlShiftD, down: true)))
        XCTAssertTrue(monitor.handle(type: .keyUp, event: try keyEvent(controlShiftD, down: false)))
        XCTAssertEqual(toggles, 1)

        shortcut = .handyDefault
        XCTAssertTrue(monitor.handle(type: .keyDown, event: try keyEvent(.handyDefault, down: true)))
        XCTAssertEqual(toggles, 2)
    }

    @MainActor
    func testRecordingANewShortcutSuspendsTheGlobalOne() throws {
        let monitor = DictationInputMonitor()
        var toggles = 0
        monitor.triggerModeProvider = { .toggle }
        monitor.shortcutProvider = { .handyDefault }
        monitor.onToggle = { toggles += 1 }

        monitor.isSuspended = true
        XCTAssertFalse(monitor.handle(type: .keyDown, event: try keyEvent(.handyDefault, down: true)),
                       "the recorder must receive the key")
        XCTAssertEqual(toggles, 0)
        monitor.isSuspended = false
        _ = monitor.handle(type: .keyUp, event: try keyEvent(.handyDefault, down: false))
        XCTAssertTrue(monitor.handle(type: .keyDown, event: try keyEvent(.handyDefault, down: true)))
        XCTAssertEqual(toggles, 1)
    }

    // MARK: - Modifier-only shortcuts (⌃⌥, as in Wispr Flow)

    private let controlOption = DictationShortcut(keyCode: nil, modifiers: [.maskControl, .maskAlternate])

    func testModifierOnlyShortcutNeedsTwoModifiers() throws {
        XCTAssertEqual(controlOption.displayLabel, "⌃⌥")
        XCTAssertNil(controlOption.problem)
        XCTAssertNil(DictationShortcut(keyCode: nil, modifiers: [.maskShift, .maskCommand]).problem)
        XCTAssertEqual(DictationShortcut(keyCode: nil, modifiers: .maskAlternate).problem, .needsTwoModifiers,
                       "⌥ alone would fire whenever ⌥ is used for anything else")
        XCTAssertEqual(DictationShortcut(keyCode: nil, modifiers: []).problem, .needsTwoModifiers)

        var settings = AppSettings()
        settings.dictationShortcut = controlOption
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data).dictationShortcut, controlOption)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stored = try XCTUnwrap(json["dictationShortcut"] as? [String: Any])
        XCTAssertNil(stored["keyCode"])
        XCTAssertEqual(stored["modifiers"] as? [String], ["control", "option"])
    }

    @MainActor
    func testHoldingAModifierChordStartsAndReleasingItStops() async throws {
        let (monitor, calls) = chordMonitor(mode: .pushToTalk)
        XCTAssertFalse(monitor.handle(type: .flagsChanged, event: try flags(.maskControl)))
        XCTAssertFalse(monitor.handle(type: .flagsChanged, event: try flags([.maskControl, .maskAlternate])),
                       "modifiers are never swallowed")
        XCTAssertEqual(calls.starts, 0, "the microphone waits for the hold delay")
        try await waitForStart(calls)
        XCTAssertEqual(calls.starts, 1)

        XCTAssertFalse(monitor.handle(type: .flagsChanged, event: try flags(.maskControl)))
        XCTAssertEqual(calls.stops, 1)
        XCTAssertEqual(calls.cancels, 0)
    }

    @MainActor
    func testAnotherShortcutStartingWithTheChordNeverStartsDictation() async throws {
        let (monitor, calls) = chordMonitor(mode: .pushToTalk)
        _ = monitor.handle(type: .flagsChanged, event: try flags([.maskControl, .maskAlternate]))
        XCTAssertFalse(monitor.handle(type: .keyDown, event: try key(17, [.maskControl, .maskAlternate])),
                       "⌃⌥T reaches the app that owns it")
        try await Task.sleep(for: .milliseconds(120))
        _ = monitor.handle(type: .flagsChanged, event: try flags([]))
        XCTAssertEqual(calls.starts, 0)
        XCTAssertEqual(calls.stops, 0)

        _ = monitor.handle(type: .flagsChanged, event: try flags([.maskControl, .maskAlternate]))
        _ = monitor.handle(type: .flagsChanged, event: try flags([.maskControl, .maskAlternate, .maskCommand]))
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(calls.starts, 0, "⌃⌥⌘ is a different chord")
    }

    @MainActor
    func testKeyPressedDuringAStartedChordCancelsTheDictation() async throws {
        let (monitor, calls) = chordMonitor(mode: .pushToTalk)
        _ = monitor.handle(type: .flagsChanged, event: try flags([.maskControl, .maskAlternate]))
        try await waitForStart(calls)
        XCTAssertEqual(calls.starts, 1)
        _ = monitor.handle(type: .keyDown, event: try key(17, [.maskControl, .maskAlternate]))
        _ = monitor.handle(type: .flagsChanged, event: try flags([]))
        XCTAssertEqual(calls.cancels, 1)
        XCTAssertEqual(calls.stops, 0, "a cancelled chord is not also finished")
    }

    @MainActor
    func testToggleChordFiresOnACleanTapOnly() throws {
        let (monitor, calls) = chordMonitor(mode: .toggle)
        _ = monitor.handle(type: .flagsChanged, event: try flags([.maskControl, .maskAlternate]))
        XCTAssertEqual(calls.toggles, 0)
        _ = monitor.handle(type: .flagsChanged, event: try flags(.maskAlternate))
        XCTAssertEqual(calls.toggles, 1)
        _ = monitor.handle(type: .flagsChanged, event: try flags([]))

        _ = monitor.handle(type: .flagsChanged, event: try flags([.maskControl, .maskAlternate]))
        _ = monitor.handle(type: .keyDown, event: try key(17, [.maskControl, .maskAlternate]))
        _ = monitor.handle(type: .flagsChanged, event: try flags([]))
        XCTAssertEqual(calls.toggles, 1, "⌃⌥T does not toggle dictation")
    }

    func testRecorderReadsAppKitModifiers() {
        XCTAssertEqual(ShortcutRecorder.eventFlags(from: [.control, .shift, .capsLock]),
                       [.maskControl, .maskShift])
        XCTAssertEqual(ShortcutRecorder.eventFlags(from: [.option, .command]),
                       [.maskAlternate, .maskCommand])
    }

    /// The start fires on the main queue after the hold delay; a fixed sleep
    /// only just longer than the delay loses to a busy runner.
    @MainActor
    private func waitForStart(_ calls: ChordCalls) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while calls.starts == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private func chordMonitor(mode: DictationTriggerMode) -> (DictationInputMonitor, ChordCalls) {
        let monitor = DictationInputMonitor()
        let calls = ChordCalls()
        monitor.chordHoldDelay = 0.05
        monitor.triggerModeProvider = { mode }
        monitor.shortcutProvider = { [controlOption] in controlOption }
        monitor.onStart = { calls.starts += 1 }
        monitor.onStop = { calls.stops += 1 }
        monitor.onToggle = { calls.toggles += 1 }
        monitor.onCancel = { calls.cancels += 1 }
        return (monitor, calls)
    }

    private func flags(_ modifiers: CGEventFlags) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Option), keyDown: true))
        event.flags = modifiers
        return event
    }

    private func key(_ keyCode: CGKeyCode, _ modifiers: CGEventFlags) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true))
        event.flags = modifiers
        return event
    }

    private func decode(_ json: [String: Any]) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func keyEvent(_ shortcut: DictationShortcut, down: Bool) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(
            keyboardEventSource: nil, virtualKey: try XCTUnwrap(shortcut.keyCode), keyDown: down))
        event.flags = shortcut.modifiers
        return event
    }
}

private final class ChordCalls {
    var starts = 0
    var stops = 0
    var toggles = 0
    var cancels = 0
}
