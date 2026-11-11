import AppKit
import SwiftUI
import XCTest
@testable import LokalBot

/// The Quick Recall window opens ready for typing. On hosted macOS 26 it
/// opened with no field focused, so Return did nothing until the field was
/// clicked. The window here is off-screen and never key, as a window is while
/// the app is still coming forward.
@MainActor
final class FocusOnAppearTests: XCTestCase {
    private struct SearchWindow: View {
        @State private var query = "failover"
        @FocusState private var inputFocused: Bool

        var body: some View {
            VStack {
                TextField("Search memory or run a command…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($inputFocused)
                    .focusOnAppear($inputFocused)
                Button("Clear") { query = "" }
            }
            .frame(width: 660, height: 480)
        }
    }

    func testFieldIsFirstResponderOnceTheWindowHasOpened() async throws {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 660, height: 480),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SearchWindow())
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .seconds(1))
        // An editing text field's first responder is its field editor.
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView,
                                   "first responder: \(String(describing: window.firstResponder.map { type(of: $0) }))")
        XCTAssertTrue(editor.isFieldEditor)
    }

    /// Quick Recall's own field: one AppKit responder for typing and for the
    /// keys that move through the list.
    private struct QuickRecallWindow: View {
        @ObservedObject var probe: Probe

        var body: some View {
            VStack {
                QuickRecallTextField(
                    text: $probe.query, placeholder: "Search, ask, or run a command",
                    hint: "Return opens the selected result. Command-Return asks.", fontSize: 22,
                    focusRequest: probe.focusRequest,
                    onSubmit: { probe.events.append("return") },
                    onCommandSubmit: { probe.events.append("command-return") },
                    onMove: { offset in
                        probe.events.append(offset < 0 ? "up" : "down")
                        return probe.handlesArrows
                    },
                    onCancel: { probe.events.append("escape") })
                    .frame(height: 30)
                Button("Clear") { probe.query = "" }
            }
            .frame(width: 660, height: 480)
            .environment(\.locale, Locale(identifier: "en"))
        }
    }

    private final class Probe: ObservableObject {
        @Published var query = ""
        @Published var focusRequest = 0
        var events: [String] = []
        var handlesArrows = true
    }

    private func quickRecallWindow(_ probe: Probe) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 660, height: 480),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: QuickRecallWindow(probe: probe))
        window.orderBack(nil)
        return window
    }

    func testQuickRecallFieldTakesTheKeyboardBeforeItsWindowIsKey() async throws {
        let probe = Probe()
        let window = quickRecallWindow(probe)
        defer { window.close() }
        try await Task.sleep(for: .seconds(1))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView,
                                   "first responder: \(String(describing: window.firstResponder.map { type(of: $0) }))")
        XCTAssertTrue(editor.isFieldEditor)
        let field = try XCTUnwrap(editor.delegate as? NSTextField)
        XCTAssertEqual(field.identifier?.rawValue, "quickRecall.input")
        XCTAssertEqual(field.accessibilityIdentifier(), "quickRecall.input")
        XCTAssertEqual(field.placeholderString, "Search, ask, or run a command")
        XCTAssertEqual(field.accessibilityHelp(), "Return opens the selected result. Command-Return asks.")

        // Losing the keyboard and asking for it again (the back arrow, Clear).
        XCTAssertTrue(window.makeFirstResponder(nil))
        probe.focusRequest += 1
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue((window.firstResponder as? NSTextView)?.isFieldEditor == true)
    }

    /// The ⌘K palette's guarantee, kept for this field: a typed character
    /// reaches the text once, and the list's keys reach the list, not the text.
    func testQuickRecallFieldTypesOnceAndSendsListKeysToTheList() async throws {
        let probe = Probe()
        let window = quickRecallWindow(probe)
        defer { window.close() }
        try await Task.sleep(for: .seconds(1))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)

        editor.insertText("AI tooling", replacementRange: editor.selectedRange())
        XCTAssertEqual(probe.query, "AI tooling")
        XCTAssertEqual(editor.string, "AI tooling")

        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(probe.events, ["down", "up", "return", "escape"])
        XCTAssertEqual(probe.query, "AI tooling", "none of those keys edits the text")

        // Inside an answer the list is gone, so the field keeps its arrows.
        probe.handlesArrows = false
        probe.query = "AI"
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(editor.string, "AI", "text set from outside (Clear, the back arrow) reaches the field")
    }
}
