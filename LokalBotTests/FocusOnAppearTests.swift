import AppKit
import SwiftUI
import XCTest
@testable import LokalBot

/// The system-wide Ask window opens ready for typing. On hosted macOS 26 it
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
}
