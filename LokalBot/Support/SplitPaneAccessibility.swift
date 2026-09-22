import AppKit
import SwiftUI

/// SwiftUI labels a column's content, but macOS also exposes the native split
/// item's hosting view as a separate group. Name that boundary without
/// replacing the native split view, its children, or its keyboard behavior.
private struct SplitPaneAccessibility: NSViewRepresentable {
    let label: String
    var autosaveName: String?

    func makeNSView(context: Context) -> PaneAnchor {
        let anchor = PaneAnchor()
        anchor.setAccessibilityElement(false)
        anchor.label = label
        anchor.autosaveName = autosaveName
        return anchor
    }

    func updateNSView(_ anchor: PaneAnchor, context: Context) {
        anchor.label = label
        anchor.autosaveName = autosaveName
        anchor.updatePaneLabel()
    }

    final class PaneAnchor: NSView {
        var label = ""
        var autosaveName: String?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updatePaneLabel()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            updatePaneLabel()
        }

        func updatePaneLabel() {
            // Defer until SwiftUI has attached the hosting view to its split
            // item. Only this anchor's nearest pane is ever modified.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                var child: NSView = self
                while let parent = child.superview {
                    if let split = parent as? NSSplitView {
                        // HSplitView's idealWidth is only a layout proposal.
                        // Give each workspace its own native divider storage;
                        // never borrow a sibling workspace's split position.
                        if let name = self.autosaveName,
                           split.autosaveName != name {
                            split.autosaveName = name
                        }
                        child.setAccessibilityLabel(self.label)
                        // NSSplitView exposes pane proxies separately from
                        // its arranged NSViews. The proxy, rather than the
                        // child hosting view, is the group VoiceOver enters.
                        let panes: [any NSAccessibilityProtocol] = (split.accessibilityChildren() ?? [])
                            .compactMap { $0 as? any NSAccessibilityProtocol }
                            .filter { $0.accessibilityRole() == .group }
                        if panes.count == split.arrangedSubviews.count,
                           let index = split.arrangedSubviews.firstIndex(where: { $0 === child }) {
                            panes[index].setAccessibilityLabel(self.label)
                            panes[index].setAccessibilityTitle(self.label)
                        }
                        return
                    }
                    child = parent
                }
            }
        }
    }
}

extension View {
    func splitPaneAccessibilityLabel(_ label: String, autosaveName: String? = nil) -> some View {
        background { SplitPaneAccessibility(label: label, autosaveName: autosaveName) }
    }
}
