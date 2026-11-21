import AppKit
import SwiftUI

struct HiddenWindowButtons: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowButtonHidingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowButtonHidingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window?.standardWindowButton(kind)?.isHidden = true
            }
        }
    }
}
