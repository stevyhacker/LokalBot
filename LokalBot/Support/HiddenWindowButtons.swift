import AppKit
import SwiftUI

/// Hides the traffic-light buttons of the hosting window. Quick Recall is a
/// transient search panel dismissed with Escape, so window controls read as
/// clutter there.
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
