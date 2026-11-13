import AppKit
import XCTest
@testable import LokalBot

/// Open and save dialogs stay quiet: a file name is not prose.
final class CotypingFileDialogDetectorTests: XCTestCase {
    func testOpenAndSavePanelsAreRecognizedByTheirWindow() {
        XCTAssertTrue(CotypingFileDialogDetector.isFileDialog(windowIdentifiers: ["save-panel"]))
        XCTAssertTrue(CotypingFileDialogDetector.isFileDialog(windowIdentifiers: ["open-panel"]))
        // Go to Folder: a sheet whose own window has no name, on the panel.
        XCTAssertTrue(CotypingFileDialogDetector.isFileDialog(windowIdentifiers: [nil, "save-panel"]))
    }

    func testOrdinaryWindowsAreNotDialogs() {
        XCTAssertFalse(CotypingFileDialogDetector.isFileDialog(windowIdentifiers: []))
        XCTAssertFalse(CotypingFileDialogDetector.isFileDialog(windowIdentifiers: [nil]))
        XCTAssertFalse(CotypingFileDialogDetector.isFileDialog(windowIdentifiers: ["Untitled", "main"]))
        XCTAssertFalse(CotypingFileDialogDetector.isFileDialog(windowIdentifiers: ["Save-Panel"]),
                       "AppKit's name is lowercase; a look-alike app label is not the panel")
    }

    /// AppKit's own name for the panels, read in-process with no window shown.
    @MainActor
    func testAppKitStillNamesItsPanelsThisWay() {
        XCTAssertEqual(NSSavePanel().accessibilityIdentifier(), "save-panel")
        XCTAssertEqual(NSOpenPanel().accessibilityIdentifier(), "open-panel")
    }
}

/// macOS's own inline predictions compete with autocomplete at the caret.
final class CotypingSystemInlinePredictionsTests: XCTestCase {
    private let key = CotypingSystemInlinePredictions.defaultsKey

    func testUnsetMeansOn() {
        XCTAssertTrue(CotypingSystemInlinePredictions.isOn(globalDomain: nil))
        XCTAssertTrue(CotypingSystemInlinePredictions.isOn(globalDomain: [:]))
    }

    func testTheUsersChoiceIsRead() {
        XCTAssertFalse(CotypingSystemInlinePredictions.isOn(globalDomain: [key: false]))
        XCTAssertFalse(CotypingSystemInlinePredictions.isOn(globalDomain: [key: NSNumber(value: 0)]))
        XCTAssertFalse(CotypingSystemInlinePredictions.isOn(globalDomain: [key: "0"]))
        XCTAssertTrue(CotypingSystemInlinePredictions.isOn(globalDomain: [key: true]))
    }
}

/// Keyboard hooks left behind by an app slow every keystroke on the Mac.
final class EventTapAuditTests: XCTestCase {
    private let names: [pid_t: (String, String?)] = [
        10: ("Mouse Utility", "com.example.mouse"),
        20: ("LokalBot", "me.dotenv.LokalBot"),
        30: ("Launcher", "com.example.launcher"),
    ]

    private func audit(_ taps: [EventTapAudit.Tap]) -> EventTapAudit {
        EventTapAudit(taps: taps, lokalBotBundleID: "me.dotenv.LokalBot") { processID in
            let described = self.names[processID] ?? ("pid \(processID)", nil)
            return (name: described.0, bundleID: described.1)
        }
    }

    func testAnAppHoldingManyTapsIsFlaggedAndLokalBotIsCounted() {
        var taps = [EventTapAudit.Tap(processID: 10, enabled: true)]
        for _ in 0..<10 { taps.append(EventTapAudit.Tap(processID: 10, enabled: false)) }
        taps.append(EventTapAudit.Tap(processID: 20, enabled: true))
        taps.append(EventTapAudit.Tap(processID: 30, enabled: true))
        taps.append(EventTapAudit.Tap(processID: 30, enabled: true))
        let result = audit(taps)
        XCTAssertEqual(result.holders.map(\.name), ["Mouse Utility", "Launcher", "LokalBot"])
        XCTAssertEqual(result.holders.first?.taps, 11)
        XCTAssertEqual(result.holders.first?.enabled, 1)
        XCTAssertEqual(result.holders.filter(\.likelyLeaking).map(\.name), ["Mouse Utility"])
        XCTAssertEqual(result.lokalBotTaps, 1)
        XCTAssertTrue(result.lokalBotWithinMaximum)
    }

    func testLokalBotHoldingMoreThanItNeedsIsReported() {
        var taps: [EventTapAudit.Tap] = []
        for _ in 0..<4 { taps.append(EventTapAudit.Tap(processID: 20, enabled: true)) }
        let result = audit(taps)
        XCTAssertEqual(result.lokalBotTaps, 4)
        XCTAssertFalse(result.lokalBotWithinMaximum)
        XCTAssertEqual(result.holders.first?.isLokalBot, true)
    }

    func testTheFlagIsRecognizedBeforeLaunch() {
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--event-taps"]), .eventTaps)
    }
}
