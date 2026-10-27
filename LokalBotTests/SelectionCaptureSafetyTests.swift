import XCTest
@testable import LokalBot

@MainActor
final class SelectionCaptureSafetyTests: XCTestCase {
    private let source = SelectionSource(processID: 42, bundleID: "com.example.editor", appName: "Editor")
    private let other = SelectionSource(processID: 99, bundleID: "com.example.private", appName: "Private")
    private var current: SelectionSource?
    private var reads = 0
    private var copies = 0
    private var secure = false
    private var timedOut = false
    private var snapshotProcess: pid_t = 42
    private var afterSnapshot: (() -> Void)?
    private var duringRead: (() -> Void)?
    private var duringCopy: (() -> Void)?
    private var accessibleText: String? = "Selected text"

    private func capture(excluded: [String] = []) async -> SelectionCaptureResult {
        current = source
        return await SelectionCapture.capture(excludedApps: excluded, dependencies: .init(
            source: { self.current }, isTrusted: { true },
            focus: {
                self.afterSnapshot?()
                return .init(snapshot: .init(
                    processID: self.snapshotProcess, bundleID: self.source.bundleID,
                    focusIdentityKey: "field", isSecureOrBlocked: self.secure), timedOut: self.timedOut)
            },
            read: { bound, exclusions in
                XCTAssertEqual(bound, self.source)
                XCTAssertEqual(exclusions, excluded)
                self.reads += 1
                self.duringRead?()
                return self.accessibleText
            },
            copy: { bound, exclusions in
                XCTAssertEqual(bound, self.source)
                XCTAssertEqual(exclusions, excluded)
                self.copies += 1
                self.duringCopy?()
                return "Copied selection"
            }))
    }

    private func assertBlocked(_ result: SelectionCaptureResult,
                               issue: SelectionCaptureResult.Issue = .focusChanged,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.issue, issue, file: file, line: line)
        XCTAssertEqual(result.text, "", file: file, line: line)
        XCTAssertNil(result.target, file: file, line: line)
        XCTAssertEqual(reads, 0, file: file, line: line)
        XCTAssertEqual(copies, 0, file: file, line: line)
    }

    func testFocusSwitchDuringSnapshotDoesNotReadEitherSource() async {
        afterSnapshot = { self.current = self.other }
        assertBlocked(await capture(excluded: ["Private"]))
    }

    func testAXSnapshotFromAnotherProcessDoesNotReadOrCopy() async {
        snapshotProcess = other.processID
        assertBlocked(await capture())
    }

    func testTimedOutSnapshotFailsClosed() async {
        timedOut = true
        assertBlocked(await capture())
    }

    func testSecureFieldNeverReadsOrCopies() async {
        secure = true
        assertBlocked(await capture(), issue: .secureField)
    }

    func testExcludedSourceNeverReadsOrCopies() async {
        assertBlocked(await capture(excluded: ["com.example.editor"]), issue: .excludedApp)
    }

    func testAXReadStaysBoundToTheAuthorizedSource() async {
        let result = await capture(excluded: ["Private"])
        XCTAssertEqual(result.text, "Selected text")
        XCTAssertEqual(result.target?.processID, source.processID)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(copies, 0)
    }

    func testFocusSwitchDuringAXReadDiscardsTextWithoutCopying() async {
        duringRead = { self.current = self.other }
        let result = await capture()
        XCTAssertEqual(result.issue, .focusChanged)
        XCTAssertEqual(result.text, "")
        XCTAssertNil(result.target)
        XCTAssertEqual(copies, 0)
    }

    func testClipboardFallbackStaysBoundToTheAuthorizedSource() async {
        accessibleText = nil
        let result = await capture(excluded: ["Private"])
        XCTAssertEqual(result.text, "Copied selection")
        XCTAssertTrue(result.readThroughClipboard)
        XCTAssertEqual(copies, 1)
    }

    func testFocusSwitchDuringClipboardCopyDiscardsText() async {
        accessibleText = nil
        duringCopy = { self.current = self.other }
        let result = await capture()
        XCTAssertEqual(result.issue, .focusChanged)
        XCTAssertEqual(result.text, "")
        XCTAssertNil(result.target)
    }
}

@MainActor
final class SelectionClipboardSafetyTests: XCTestCase {
    private let source = SelectionSource(processID: 42, bundleID: "com.example.editor", appName: "Editor")
    private var allowed = true
    private var frontmost = true
    private var generation = 0
    private var validations = 0
    private var reads = 0
    private var saves = 0
    private var restores = 0
    private var posted: [pid_t] = []
    private var releaseModifiers: (() -> Void)?
    private var afterPost: (() -> Void)?
    private var duringValidation: (() -> Void)?

    private func copy() async -> String? {
        await SelectionClipboardCopy.copySelection(from: source, excludedApps: ["Private"], dependencies: .init(
            waitForModifiers: { self.releaseModifiers?() },
            isAllowed: { bound, excluded in
                XCTAssertEqual(bound, self.source)
                XCTAssertEqual(excluded, ["Private"])
                self.validations += 1
                self.duringValidation?()
                return self.allowed
            },
            isFrontmost: { $0 == self.source && self.frontmost },
            changeCount: { self.generation },
            saveClipboard: {
                self.saves += 1
                return { self.restores += 1 }
            },
            postCopy: {
                self.posted.append($0)
                self.generation += 1
                self.afterPost?()
                return true
            },
            readText: { self.reads += 1; return "Copied selection" }))
    }

    func testFocusChangeWhileModifiersAreHeldDoesNotCopy() async {
        releaseModifiers = { self.frontmost = false }
        let result = await copy()
        XCTAssertNil(result)
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(posted, [])
        XCTAssertEqual(reads, 0)
    }

    func testExcludedOrSecureFieldDoesNotCopy() async {
        allowed = false
        let result = await copy()
        XCTAssertNil(result)
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(posted, [])
        XCTAssertEqual(reads, 0)
    }

    func testFocusChangeDuringValidationDoesNotCopy() async {
        duringValidation = { self.frontmost = false }
        let result = await copy()
        XCTAssertNil(result)
        XCTAssertEqual(posted, [])
    }

    func testCopyTargetsTheOriginalProcessAndRestoresClipboard() async {
        let result = await copy()
        XCTAssertEqual(result, "Copied selection")
        XCTAssertEqual(posted, [source.processID])
        XCTAssertEqual(validations, 2)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(restores, 1)
    }

    func testFocusChangeAfterCopyDoesNotReadClipboard() async {
        afterPost = { self.frontmost = false }
        let result = await copy()
        XCTAssertNil(result)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(restores, 1)
    }

    func testSecureFieldAfterCopyDoesNotReadClipboard() async {
        afterPost = { self.allowed = false }
        let result = await copy()
        XCTAssertNil(result)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(restores, 1)
    }

    func testNewerClipboardDuringValidationIsNeitherReadNorOverwritten() async {
        duringValidation = { if self.validations == 2 { self.generation += 1 } }
        let result = await copy()
        XCTAssertNil(result)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(restores, 0)
    }
}

@MainActor
final class SelectionDeliverySafetyTests: XCTestCase {
    private let selected = DictationTextSelection(location: 10, length: 5)

    private func check(original: DictationTextSelection?, current: DictationTextSelection?,
                       process: pid_t = 42, secure: Bool = false) -> DictationDeliveryCheck {
        SelectionDelivery.check(
            target: .init(processID: 42, bundleID: "com.example.editor", focusIdentityKey: "field", selection: original),
            snapshot: .init(processID: process, bundleID: "com.example.editor", focusIdentityKey: "field",
                            isSecureOrBlocked: secure, selection: current))
    }

    func testClearingCapturedSelectionCopiesInsteadOfPastingAtNewCaret() {
        XCTAssertEqual(check(original: selected, current: nil), .selectionChanged)
        XCTAssertTrue(SelectionDelivery.message(for: .selectionChanged).contains("copied to the clipboard"))
    }

    func testMovingSelectionCopiesInsteadOfReplacingOtherText() {
        XCTAssertEqual(check(original: selected, current: .init(location: 30, length: 5)), .selectionChanged)
    }

    func testNewSelectionCannotBeOverwrittenByAnInsertion() {
        XCTAssertEqual(check(original: nil, current: selected), .selectionChanged)
    }

    func testUnchangedSelectionCanBeReplaced() {
        XCTAssertEqual(check(original: selected, current: selected), .deliverable)
    }

    func testInsertionWithNoSelectionRemainsAllowed() {
        XCTAssertEqual(check(original: nil, current: nil), .deliverable)
    }

    func testSecureFieldAndDifferentAppRemainBlocked() {
        XCTAssertEqual(check(original: selected, current: selected, secure: true), .secureField)
        XCTAssertEqual(check(original: selected, current: selected, process: 99), .focusMoved)
    }
}
