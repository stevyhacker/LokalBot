import AppKit
import SwiftUI
import XCTest
@testable import LokalBot

/// What assistive tools and clicks meet on the meeting page's menus and
/// speaker names. Each view is hosted in a window that stays off screen.
@MainActor
final class MeetingMenuAccessibilityTests: XCTestCase {
    private func host<Content: View>(_ content: Content, size: CGSize = CGSize(width: 600, height: 300)) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content.environment(\.locale, Locale(identifier: "en")))
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func descendants<View: NSView>(of type: View.Type, in view: NSView?) -> [View] {
        guard let view else { return [] }
        var found = (view as? View).map { [$0] } ?? []
        for subview in view.subviews { found += descendants(of: type, in: subview) }
        return found
    }

    /// The accessibility audit flagged the owner chip as having no press
    /// action while it was a SwiftUI `Menu`.
    func testOwnerChipIsTheNativePullDownLaidUndrawnOverItsLabel() throws {
        var chosen: [String] = []
        let options: [MeetingDetailPresentation.OwnerOption] = [
            .init(id: "you", title: "You", value: "Me", kind: .you, isSelected: false),
            .init(id: "speaker:them 2", title: "Speaker 2", value: "Them 2", kind: .speaker, isSelected: true),
            .init(id: "invited:daniel", title: "Daniel Ortiz", value: "Daniel Ortiz", kind: .invited, isSelected: false),
            .init(id: "none", title: "No owner", value: "", kind: .none, isSelected: false),
        ]
        let window = host(MeetingActionOwnerMenu(
            owner: "Speaker 2", needsAttention: true, options: options,
            identifier: "meeting.action.owner.a", language: .english, offersNaming: true,
            onChoose: { chosen.append($0.value) }, onNameSpeakers: { chosen.append("name") })
            .padding(40))
        defer { window.close() }
        let button = try XCTUnwrap(descendants(of: WorkspaceMenu.PopUpButton.self, in: window.contentView).first,
                                   "the chip must be the menu type that has Press and Show Menu")
        XCTAssertTrue(button.drawsNothing, "the chip's own label is the only thing drawn")
        // In every other respect it is the menu the "…" buttons use, which
        // assistive tools can already open.
        XCTAssertFalse(button.isTransparent)
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(button.alphaValue, 1)
        XCTAssertTrue(button.pullsDown)
        XCTAssertEqual(button.accessibilityLabel(), "Owner: Speaker 2")
        XCTAssertEqual(button.accessibilityIdentifier(), "meeting.action.owner.a")
        XCTAssertGreaterThan(button.frame.width, 50, "the menu covers the whole chip")
        XCTAssertLessThan(button.frame.width, 140)
        let items = try XCTUnwrap(button.menu).items.dropFirst()
        XCTAssertEqual(items.map { $0.isSeparatorItem ? "-" : $0.title },
                       ["You", "Speaker 2", "-", "Invited", "Daniel Ortiz", "-", "Name this speaker…", "No owner"])
        XCTAssertEqual(items.first { $0.title == "Speaker 2" }?.state, .on)
        XCTAssertEqual(items.first { $0.title == "Invited" }?.isEnabled, false, "a heading, not a choice")
        for title in ["Daniel Ortiz", "Name this speaker…", "No owner"] {
            let item = try XCTUnwrap(items.first { $0.title == title })
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        }
        XCTAssertEqual(chosen, ["Daniel Ortiz", "name", ""])
    }

    /// Measured by CI: a turn's speaker button ran 61 pt past the text below
    /// it, because it took the whole line and not just its name.
    func testTranscriptSpeakerButtonIsNoWiderThanItsName() throws {
        let window = host(VStack(alignment: .leading) {
            HStack(spacing: 6) {
                TranscriptSpeakerButton(title: "Ana", query: "", activeMatchIndex: nil,
                                        identifier: "transcript.segment.0.speaker") {}
            }
            .frame(height: 20, alignment: .leading)
            HStack(spacing: 6) {
                TranscriptSpeakerButton(title: String(repeating: "Alexandria Montgomery-Wellington ", count: 6),
                                        query: "", activeMatchIndex: nil,
                                        identifier: "transcript.segment.1.speaker") {}
            }
            .frame(height: 20, alignment: .leading)
        }
        .frame(width: 600, alignment: .leading))
        defer { window.close() }
        let buttons = descendants(of: NSButton.self, in: window.contentView)
        let short = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier() == "transcript.segment.0.speaker" })
        let long = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier() == "transcript.segment.1.speaker" })
        XCTAssertGreaterThan(short.frame.width, 10)
        XCTAssertLessThan(short.frame.width, 80, "a short name leaves the rest of the line alone")
        XCTAssertLessThanOrEqual(long.frame.width, 600, "a long name truncates inside the line")
    }

    /// The audit flagged the sheet's hosting view as a group with no name.
    func testNamingSheetNamesTheViewThatHostsIt() throws {
        let window = host(MeetingSpeakerNamingSheet(
            voices: [.init(id: "them", label: "Other speaker", colorIndex: 1, sample: nil, speechSeconds: 30,
                           actionCount: 1)],
            known: [], suggestions: [], assignedCalendarIdentityIDs: [], canPlay: false, busy: false, notice: nil,
            onPlay: { _ in }, onChange: { _ in }, onSave: { _ in }, onCancel: {}),
                          size: CGSize(width: 600, height: 300))
        defer { window.close() }
        XCTAssertEqual(window.contentView?.accessibilityLabel(), "Name speakers")
    }
}
