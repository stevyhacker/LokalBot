import AppKit
import SwiftUI

struct HeldPaneWidth {
    private(set) var width: CGFloat?
    private var unreachableWidth: CGFloat?
    private static let tolerance: CGFloat = 1

    mutating func settle(at width: CGFloat) {
        self.width = width
        unreachableWidth = nil
    }

    mutating func resized(to paneWidth: CGFloat, byUser: Bool) -> CGFloat? {
        if byUser {
            settle(at: paneWidth)
            return nil
        }
        guard let width else { return nil }
        guard abs(paneWidth - width) > Self.tolerance else {
            unreachableWidth = nil
            return nil
        }
        if let unreachableWidth, abs(paneWidth - unreachableWidth) <= Self.tolerance { return nil }
        return width
    }

    mutating func restoreFailed(at paneWidth: CGFloat) {
        unreachableWidth = paneWidth
    }
}

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
        private var initialWidthPending = true
        private var initialWidthAttempts = 0
        private static let maximumInitialWidthAttempts = 12
        private static let maximumRestoreRetries = 2
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

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            if initialWidth != nil, initialWidthPending { updatePaneLabel() }
        }

        func updatePaneLabel() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                var child: NSView = self
                while let parent = child.superview {
                    if let split = parent as? NSSplitView {
                        if let name = self.autosaveName,
                           split.autosaveName != name {
                            if Self.hasSavedFrames(name) { self.initialWidthPending = false }
                            split.autosaveName = name
                        }
                        self.applyInitialWidth(of: child, in: split)
                        child.setAccessibilityLabel(self.label)
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

        private func applyInitialWidth(of pane: NSView, in split: NSSplitView) {
            guard let width = initialWidth, split.isVertical, split.arrangedSubviews.count == 2,
                  let index = split.arrangedSubviews.firstIndex(where: { $0 === pane }) else { return }
            observeResizes(of: split, pane: pane)
            let holding = NSLayoutConstraint.Priority.defaultLow + 10
            if let controller = split.delegate as? NSSplitViewController {
                if controller.splitViewItems.indices.contains(index),
                   controller.splitViewItems[index].holdingPriority != holding {
                    controller.splitViewItems[index].holdingPriority = holding
                }
            } else if split.holdingPriorityForSubview(at: index) != holding {
                split.setHoldingPriority(holding, forSubviewAt: index)
            }
            let shown = Self.shownWidth(of: pane)
            guard initialWidthPending else {
                if held.width == nil { held.settle(at: shown) }
                return
            }
            guard split.bounds.width > width + Self.coveredWidth(of: pane) + split.dividerThickness else { return }
            if abs(shown - width) <= 1 {
                initialWidthPending = false
                held.settle(at: shown)
                return
            }
            initialWidthAttempts += 1
            split.setPosition(Self.dividerPosition(showing: width, of: pane, at: index, in: split), ofDividerAt: 0)
            if initialWidthAttempts >= Self.maximumInitialWidthAttempts {
                initialWidthPending = false
                held.settle(at: Self.shownWidth(of: pane))
            }
        }

        private static func coveredWidth(of pane: NSView) -> CGFloat {
            pane.safeAreaInsets.left + pane.safeAreaInsets.right
        }

        private static func shownWidth(of pane: NSView) -> CGFloat {
            pane.frame.width - coveredWidth(of: pane)
        }

        private static func dividerPosition(showing width: CGFloat, of pane: NSView, at index: Int,
                                            in split: NSSplitView) -> CGFloat {
            let paneWidth = width + coveredWidth(of: pane)
            return index == 0 ? paneWidth : split.bounds.width - paneWidth - split.dividerThickness
        }

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
                  split.arrangedSubviews.contains(where: { $0 === pane }),
                  let target = held.resized(to: Self.shownWidth(of: pane), byUser: byUser) else { return }
            restore(pane, to: target, in: split, retries: Self.maximumRestoreRetries)
        }

        private func restore(_ pane: NSView, to target: CGFloat, in split: NSSplitView, retries: Int) {
            guard let index = split.arrangedSubviews.firstIndex(where: { $0 === pane }) else { return }
            restoringHeldWidth = true
            split.setPosition(Self.dividerPosition(showing: target, of: pane, at: index, in: split), ofDividerAt: 0)
            restoringHeldWidth = false
            let restored = Self.shownWidth(of: pane)
            guard abs(restored - target) > 1 else { return }
            guard retries > 0 else {
                held.restoreFailed(at: restored)
                return
            }
            DispatchQueue.main.async { [weak self, weak pane, weak split] in
                guard let self, let pane, let split, self.observedSplit === split,
                      self.held.width == target,
                      abs(Self.shownWidth(of: pane) - target) > 1 else { return }
                self.restore(pane, to: target, in: split, retries: retries - 1)
            }
        }

        private static func hasSavedFrames(_ autosaveName: String) -> Bool {
            UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(autosaveName)") != nil
        }
    }
}

enum SplitStructureDirection {
    static func isHeldLeftToRight(
        onMacOS majorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) -> Bool {
        majorVersion == 26
    }
}

private struct HoldsSplitStructureLeftToRightKey: EnvironmentKey {
    static let defaultValue = SplitStructureDirection.isHeldLeftToRight()
}

private struct SplitPaneContentDirectionKey: EnvironmentKey {
    static let defaultValue: LayoutDirection? = nil
}

extension EnvironmentValues {
    var holdsSplitStructureLeftToRight: Bool {
        get { self[HoldsSplitStructureLeftToRightKey.self] }
        set { self[HoldsSplitStructureLeftToRightKey.self] = newValue }
    }

    var splitPaneContentDirection: LayoutDirection? {
        get { self[SplitPaneContentDirectionKey.self] }
        set { self[SplitPaneContentDirectionKey.self] = newValue }
    }
}

private struct HeldSplitStructure: ViewModifier {
    @Environment(\.layoutDirection) private var direction
    @Environment(\.holdsSplitStructureLeftToRight) private var held

    func body(content: Content) -> some View {
        content
            .environment(\.splitPaneContentDirection, held ? direction : nil)
            .environment(\.layoutDirection, held ? .leftToRight : direction)
    }
}

private struct SplitPaneContentDirection: ViewModifier {
    @Environment(\.layoutDirection) private var direction
    @Environment(\.splitPaneContentDirection) private var contentDirection

    func body(content: Content) -> some View {
        content.environment(\.layoutDirection, contentDirection ?? direction)
    }
}

extension View {
    func splitPaneAccessibilityLabel(
        _ label: String,
        autosaveName: String? = nil,
        initialWidth: CGFloat? = nil
    ) -> some View {
        modifier(SplitPaneContentDirection()).background {
            SplitPaneAccessibility(label: label, autosaveName: autosaveName, initialWidth: initialWidth)
        }
    }

    func splitStructureDirection() -> some View {
        modifier(HeldSplitStructure())
    }

    func detailSplitMinimumWidth(_ paneMinimums: [CGFloat]) -> some View {
        splitStructureDirection()
            .frame(minWidth: paneMinimums.reduce(0, +) + CGFloat(max(paneMinimums.count - 1, 0)))
    }
}
