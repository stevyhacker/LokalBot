import AppKit
import XCTest
@testable import LokalBot

@MainActor
final class MeetingFindWindowTests: XCTestCase {
    func testPlainCommandFInvokesMeetingFindActionThroughWindowEventDispatch() throws {
        let window = MeetingFindWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        var invocationCount = 0
        window.meetingFindAction = {
            invocationCount += 1
            return true
        }

        let event = try XCTUnwrap(keyEvent(characters: "f", modifiers: .command))

        window.sendEvent(event)
        XCTAssertEqual(invocationCount, 1)
    }

    func testPlainCommandFInvokesMeetingFindActionThroughKeyEquivalent() throws {
        let window = MeetingFindWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        var invocationCount = 0
        window.meetingFindAction = {
            invocationCount += 1
            return true
        }

        let event = try XCTUnwrap(keyEvent(characters: "f", modifiers: .command))

        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertEqual(invocationCount, 1)
    }

    func testModifiedOrRepeatedCommandFDoesNotInvokeMeetingFindAction() throws {
        let window = MeetingFindWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        var invocationCount = 0
        window.meetingFindAction = {
            invocationCount += 1
            return true
        }

        let modified = try XCTUnwrap(
            keyEvent(characters: "f", modifiers: [.command, .shift]))
        let repeated = try XCTUnwrap(
            keyEvent(characters: "f", modifiers: .command, isARepeat: true))

        XCTAssertFalse(MeetingFindWindow.isMeetingFindKeyEquivalent(modified))
        XCTAssertFalse(MeetingFindWindow.isMeetingFindKeyEquivalent(repeated))
        XCTAssertEqual(invocationCount, 0)
    }

    private func keyEvent(
        characters: String,
        modifiers: NSEvent.ModifierFlags,
        isARepeat: Bool = false
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: isARepeat,
            keyCode: 3)
    }
}
