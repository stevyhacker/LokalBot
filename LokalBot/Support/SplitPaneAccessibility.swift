import AppKit
import SwiftUI

/// SwiftUI labels a column's content, but macOS also exposes the native split
/// item's hosting view as a separate group. Name that boundary without
/// replacing the native split view, its children, or its keyboard behavior.
private struct SplitPaneAccessibility: NSViewRepresentable {
    let label: String
    var autosaveName: String?
    var initialWidth: CGFloat?

    func makeNSView(context: Context) -> PaneAnchor {
        let anchor = PaneAnchor()
        anchor.setAccessibilityElement(false)
        anchor.label = label
        anchor.autosaveName = autosaveName
        anchor.initialWidth = initialWidth
        return anchor
    }

    func updateNSView(_ anchor: PaneAnchor, context: Context) {
        anchor.label = label
        anchor.autosaveName = autosaveName
        anchor.initialWidth = initialWidth
        anchor.updatePaneLabel()
    }

    final class PaneAnchor: NSView {
        var label = ""
        var autosaveName: String?
        var initialWidth: CGFloat?
        /// Cleared once the pane has its opening width, or once a divider
        /// position the user saved earlier has been restored instead.
        private var initialWidthPending = true

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updatePaneLabel()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            updatePaneLabel()
        }

        /// The split can attach before it has its final width. Keep retrying
        /// as the pane lays out until the opening width lands, instead of
        /// leaving (and saving) HSplitView's even split.
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            if initialWidth != nil, initialWidthPending { updatePaneLabel() }
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
                            // Check before naming: assigning the name restores
                            // a saved position, which must win over the default.
                            if Self.hasSavedFrames(name) { self.initialWidthPending = false }
                            split.autosaveName = name
                        }
                        self.applyInitialWidth(of: child, in: split)
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

        /// HSplitView splits two flexible panes evenly. A pane with an opening
        /// width gets it once, and then holds its width while the window
        /// resizes so the sibling pane absorbs the change instead.
        private func applyInitialWidth(of pane: NSView, in split: NSSplitView) {
            guard let width = initialWidth, split.isVertical, split.arrangedSubviews.count == 2,
                  let index = split.arrangedSubviews.firstIndex(where: { $0 === pane }) else { return }
            // HSplitView's split view belongs to a split view controller, which
            // owns holding priorities through its items.
            let holding = NSLayoutConstraint.Priority.defaultLow + 10
            if let controller = split.delegate as? NSSplitViewController {
                if controller.splitViewItems.indices.contains(index),
                   controller.splitViewItems[index].holdingPriority != holding {
                    controller.splitViewItems[index].holdingPriority = holding
                }
            } else if split.holdingPriorityForSubview(at: index) != holding {
                split.setHoldingPriority(holding, forSubviewAt: index)
            }
            guard initialWidthPending, split.bounds.width > width + split.dividerThickness else { return }
            initialWidthPending = false
            let position = index == 0 ? width : split.bounds.width - width - split.dividerThickness
            split.setPosition(position, ofDividerAt: 0)
        }

        private static func hasSavedFrames(_ autosaveName: String) -> Bool {
            UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(autosaveName)") != nil
        }
    }
}

extension View {
    /// Names a split pane for VoiceOver. `autosaveName` gives the split its own
    /// saved divider position; `initialWidth` sets this pane's width the first
    /// time the split appears without one.
    func splitPaneAccessibilityLabel(
        _ label: String,
        autosaveName: String? = nil,
        initialWidth: CGFloat? = nil
    ) -> some View {
        background {
            SplitPaneAccessibility(label: label, autosaveName: autosaveName, initialWidth: initialWidth)
        }
    }
}
