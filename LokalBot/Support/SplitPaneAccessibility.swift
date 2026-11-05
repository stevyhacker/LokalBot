import AppKit
import SwiftUI

/// The width a split pane keeps once it has settled. SwiftUI can re-divide an
/// HSplitView when the sibling pane's content changes — the Timeline swapping
/// its day column for a selection's details did, widening the sessions rail to
/// its maximum. Only a divider drag chooses a new width; any other resize is
/// put back.
struct HeldPaneWidth {
    private(set) var width: CGFloat?
    /// A width the split clamped a restore to (the window is too narrow).
    /// Retrying at that same width would loop.
    private var unreachableWidth: CGFloat?
    private static let tolerance: CGFloat = 1

    mutating func settle(at width: CGFloat) {
        self.width = width
        unreachableWidth = nil
    }

    /// The width to restore after the pane was resized, or nil to leave it.
    mutating func resized(to paneWidth: CGFloat, byUser: Bool) -> CGFloat? {
        if byUser {
            settle(at: paneWidth)
            return nil
        }
        guard let width, abs(paneWidth - width) > Self.tolerance else { return nil }
        if let unreachableWidth, abs(paneWidth - unreachableWidth) <= Self.tolerance { return nil }
        return width
    }

    mutating func restoreFailed(at paneWidth: CGFloat) {
        unreachableWidth = paneWidth
    }
}

/// Tells a divider drag from every other resize by the mouse event being
/// handled. The resize notification can't: from macOS 26 at least, plain layout
/// passes name a divider too, so a re-division looked like a drag and the pane
/// kept the width SwiftUI gave it. A click is not a drag, so selecting a row
/// never counts, and the drag's own last step can land on its mouse-up.
struct DividerDragDetector {
    private var dragging = false

    mutating func isDrag(currentEvent: NSEvent.EventType?) -> Bool {
        switch currentEvent {
        case .leftMouseDragged:
            dragging = true
            return true
        case .leftMouseUp where dragging:
            dragging = false
            return true
        default:
            dragging = false
            return false
        }
    }
}

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
        /// SwiftUI can even out the split after the first placement, for
        /// example when a window is resized right after opening. Placement is
        /// retried until the pane measures its opening width, a bounded number
        /// of times so it never fights a divider the user is dragging.
        private var initialWidthAttempts = 0
        private static let maximumInitialWidthAttempts = 12
        private var held = HeldPaneWidth()
        private var dividerDrag = DividerDragDetector()
        private weak var observedSplit: NSSplitView?
        private var resizeObserver: NSObjectProtocol?
        private var restoringHeldWidth = false

        deinit {
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        }

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
            observeResizes(of: split, pane: pane)
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
            guard initialWidthPending else {
                // A restored divider position counts as settled too.
                if held.width == nil { held.settle(at: pane.frame.width) }
                return
            }
            guard split.bounds.width > width + split.dividerThickness else { return }
            if abs(pane.frame.width - width) <= 1 || initialWidthAttempts >= Self.maximumInitialWidthAttempts {
                initialWidthPending = false
                held.settle(at: pane.frame.width)
                return
            }
            initialWidthAttempts += 1
            let position = index == 0 ? width : split.bounds.width - width - split.dividerThickness
            split.setPosition(position, ofDividerAt: 0)
        }

        /// Only a divider drag chooses a width; every other resize is a
        /// re-division to undo.
        private func observeResizes(of split: NSSplitView, pane: NSView) {
            guard observedSplit !== split else { return }
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            observedSplit = split
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification, object: split, queue: .main
            ) { [weak self, weak pane] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let byUser = self.dividerDrag.isDrag(currentEvent: NSApp.currentEvent?.type)
                    self.splitDidResize(pane: pane, byUser: byUser)
                }
            }
        }

        private func splitDidResize(pane: NSView?, byUser: Bool) {
            guard let pane, let split = observedSplit, !initialWidthPending, !restoringHeldWidth,
                  let index = split.arrangedSubviews.firstIndex(where: { $0 === pane }),
                  let target = held.resized(to: pane.frame.width, byUser: byUser) else { return }
            restoringHeldWidth = true
            defer { restoringHeldWidth = false }
            let position = index == 0 ? target : split.bounds.width - target - split.dividerThickness
            split.setPosition(position, ofDividerAt: 0)
            if abs(pane.frame.width - target) > 1 { held.restoreFailed(at: pane.frame.width) }
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

    /// The minimum width of an `HSplitView` in the main window's detail column:
    /// its visible panes' minimums plus their 1 pt dividers. From macOS 26 the
    /// detail column runs under the sidebar, an AppKit split adds the sidebar's
    /// width to its own minimum, and NavigationSplitView then adds the sidebar
    /// again, so Meetings could not shrink below about 1,100 pt. Stating the
    /// panes' real minimum keeps the window resizable down to sidebar + panes.
    func detailSplitMinimumWidth(_ paneMinimums: [CGFloat]) -> some View {
        frame(minWidth: paneMinimums.reduce(0, +) + CGFloat(max(paneMinimums.count - 1, 0)))
    }
}
