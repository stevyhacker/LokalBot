import Carbon.HIToolbox
import XCTest
@testable import LokalBot

/// The system-wide Ask shortcut can be changed in Settings.
final class QuickRecallShortcutTests: XCTestCase {
    private let controlOptionK = DictationShortcut(
        keyCode: CGKeyCode(kVK_ANSI_K), modifiers: [.maskControl, .maskAlternate])
    // Combinations nobody presses, so the brief registrations below cannot
    // fire while the tests run.
    private let hyperF18 = DictationShortcut(
        keyCode: CGKeyCode(kVK_F18), modifiers: [.maskControl, .maskAlternate, .maskShift, .maskCommand])
    private let hyperF19 = DictationShortcut(
        keyCode: CGKeyCode(kVK_F19), modifiers: [.maskControl, .maskAlternate, .maskShift, .maskCommand])

    func testDefaultStaysControlShiftSpace() {
        XCTAssertEqual(AppSettings().quickRecallShortcut, .quickRecallDefault)
        XCTAssertEqual(DictationShortcut.quickRecallDefault.displayLabel, "⌃⇧ Space")
        XCTAssertEqual(DictationShortcut.quickRecallDefault.keyCode, CGKeyCode(kVK_Space))
        XCTAssertEqual(
            QuickRecallHotKeyController.carbonModifiers(DictationShortcut.quickRecallDefault.modifiers),
            UInt32(controlKey | shiftKey), "the default registers the same hot key as before")
        XCTAssertNil(DictationShortcut.quickRecallDefault.quickRecallProblem)
    }

    func testCarbonModifiersCoverEveryModifier() {
        XCTAssertEqual(QuickRecallHotKeyController.carbonModifiers(hyperF18.modifiers),
                       UInt32(controlKey | optionKey | shiftKey | cmdKey))
        XCTAssertEqual(QuickRecallHotKeyController.carbonModifiers([]), 0)
    }

    func testAskNeedsAKeyAndTheTypingSafeRules() {
        XCTAssertEqual(DictationShortcut(keyCode: nil, modifiers: [.maskControl, .maskAlternate]).quickRecallProblem,
                       .needsKey, "a hot key cannot be modifiers alone")
        XCTAssertEqual(DictationShortcut(keyCode: CGKeyCode(kVK_ANSI_K), modifiers: .maskShift).quickRecallProblem,
                       .needsModifier, "⇧K types a capital K")
        XCTAssertEqual(DictationShortcut(keyCode: CGKeyCode(kVK_ANSI_K), modifiers: .maskCommand).quickRecallProblem,
                       .commandOnly)
        XCTAssertEqual(DictationShortcut(keyCode: CGKeyCode(kVK_Escape), modifiers: .maskControl).quickRecallProblem,
                       .reservedForCancel)

        XCTAssertNil(controlOptionK.quickRecallProblem)
        XCTAssertNil(DictationShortcut(keyCode: CGKeyCode(kVK_F5), modifiers: []).quickRecallProblem)
    }

    @MainActor
    func testAskAndDictationCannotShareAShortcut() {
        XCTAssertEqual(QuickRecallHotKeyController.problem(
            for: .handyDefault, dictationShortcut: .handyDefault), .usedByDictation)
        XCTAssertEqual(QuickRecallHotKeyController.problem(
            for: hyperF19, dictationShortcut: hyperF19), .usedByDictation)
        XCTAssertNil(QuickRecallHotKeyController.problem(
            for: hyperF19, dictationShortcut: .handyDefault))
        XCTAssertEqual(QuickRecallHotKeyController.problem(
            for: DictationShortcut(keyCode: nil, modifiers: [.maskControl, .maskShift]),
            dictationShortcut: .handyDefault), .needsKey)
    }

    @MainActor
    func testGlobalShortcutsCannotShareACombination() {
        XCTAssertEqual(QuickRecallHotKeyController.problem(
            for: hyperF19, dictationShortcut: .handyDefault, askShortcut: hyperF19), .usedByAsk)
        XCTAssertEqual(QuickRecallHotKeyController.problem(
            for: hyperF19, dictationShortcut: .handyDefault, selectionActionsShortcut: hyperF19),
                       .usedBySelectionActions)
        XCTAssertNil(QuickRecallHotKeyController.problem(
            for: hyperF19, dictationShortcut: .handyDefault, askShortcut: hyperF18,
            selectionActionsShortcut: hyperF18))
        XCTAssertNotEqual(DictationShortcut.selectionActionsDefault, .quickRecallDefault)
        XCTAssertNotEqual(DictationShortcut.selectionActionsDefault, .handyDefault)
        XCTAssertNil(DictationShortcut.selectionActionsDefault.quickRecallProblem)
        XCTAssertEqual(DictationShortcut.selectionActionsDefault.keyCode, CGKeyCode(kVK_ANSI_W))
    }

    func testSelectionActionsAreOffByDefaultAndPersist() throws {
        XCTAssertFalse(AppSettings().selectionActionsEnabled, "reading another app's selection is opt-in")
        var settings = AppSettings()
        settings.selectionActionsEnabled = true
        settings.selectionActionsShortcut = controlOptionK
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(decoded.selectionActionsEnabled)
        XCTAssertEqual(decoded.selectionActionsShortcut, controlOptionK)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(AppSettings())) as? [String: Any])
        json["selectionActionsShortcut"] = ["modifiers": ["control", "shift"]]
        XCTAssertEqual(try decode(json).selectionActionsShortcut, .selectionActionsDefault,
                       "a hot key cannot be modifiers alone")
    }

    @MainActor
    func testAskAndSelectionActionsRegisterSideBySide() {
        let ask = QuickRecallHotKeyController()
        let selection = QuickRecallHotKeyController(identifier: QuickRecallHotKeyController.selectionActionsIdentifier)
        defer {
            ask.stop()
            selection.stop()
        }
        XCTAssertTrue(ask.setShortcut(hyperF18))
        XCTAssertTrue(selection.setShortcut(hyperF19))
        XCTAssertEqual(ask.registeredShortcut, hyperF18)
        XCTAssertEqual(selection.registeredShortcut, hyperF19)

        selection.isSuspended = true
        XCTAssertNil(selection.registeredShortcut)
        XCTAssertEqual(ask.registeredShortcut, hyperF18, "suspending one leaves the other registered")
    }

    func testShortcutPersistsWithSettings() throws {
        var settings = AppSettings()
        settings.quickRecallShortcut = controlOptionK
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data).quickRecallShortcut, controlOptionK)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stored = try XCTUnwrap(json["quickRecallShortcut"] as? [String: Any])
        XCTAssertEqual(stored["keyCode"] as? Int, kVK_ANSI_K)
        XCTAssertEqual(stored["modifiers"] as? [String], ["control", "option"])
    }

    func testSettingsWithoutAShortcutOrWithAnUnusableOneUseTheDefault() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(AppSettings())) as? [String: Any])
        json.removeValue(forKey: "quickRecallShortcut")
        XCTAssertEqual(try decode(json).quickRecallShortcut, .quickRecallDefault)

        json["quickRecallShortcut"] = ["modifiers": ["control", "option"]]
        XCTAssertEqual(try decode(json).quickRecallShortcut, .quickRecallDefault,
                       "a hot key cannot be modifiers alone")
        json["quickRecallShortcut"] = ["keyCode": kVK_ANSI_K, "modifiers": [String]()]
        XCTAssertEqual(try decode(json).quickRecallShortcut, .quickRecallDefault,
                       "a bare letter would swallow typing system-wide")
    }

    @MainActor
    func testChangingTheShortcutReplacesTheRegisteredHotKey() {
        let controller = QuickRecallHotKeyController()
        defer { controller.stop() }

        XCTAssertTrue(controller.setShortcut(hyperF18))
        XCTAssertEqual(controller.registeredShortcut, hyperF18)
        XCTAssertTrue(controller.setShortcut(hyperF19))
        XCTAssertEqual(controller.registeredShortcut, hyperF19, "the new shortcut replaces the old one")

        XCTAssertTrue(controller.setShortcut(nil))
        XCTAssertNil(controller.registeredShortcut)
    }

    @MainActor
    func testRecordingANewShortcutSuspendsTheHotKey() {
        let controller = QuickRecallHotKeyController()
        defer { controller.stop() }
        XCTAssertTrue(controller.setShortcut(hyperF18))

        controller.isSuspended = true
        XCTAssertNil(controller.registeredShortcut, "the recorder must receive the keys")
        XCTAssertTrue(controller.setShortcut(hyperF19))
        XCTAssertNil(controller.registeredShortcut, "nothing registers until recording ends")

        controller.isSuspended = false
        XCTAssertEqual(controller.registeredShortcut, hyperF19)
    }

    @MainActor
    func testRefusedShortcutLeavesNoHotKey() {
        let owner = QuickRecallHotKeyController()
        let controller = QuickRecallHotKeyController()
        defer {
            controller.stop()
            owner.stop()
        }
        XCTAssertTrue(owner.setShortcut(hyperF18))

        XCTAssertFalse(controller.setShortcut(hyperF18), "a combination that is already taken is refused")
        XCTAssertNil(controller.registeredShortcut)
        XCTAssertFalse(controller.setShortcut(
            DictationShortcut(keyCode: nil, modifiers: [.maskControl, .maskShift])))
        XCTAssertTrue(controller.setShortcut(hyperF19))
        XCTAssertEqual(controller.registeredShortcut, hyperF19)
    }

    private func decode(_ json: [String: Any]) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
