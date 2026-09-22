import AppKit
import SwiftUI

/// A native pull-down menu with explicit accessibility actions. SwiftUI's
/// macOS 15 Menu proxy omits Press/Show Menu on these workspace controls.
struct WorkspaceMenu: NSViewRepresentable {
    struct Item {
        var title: String
        var identifier = ""
        var enabled = true
        var selected = false
        var action: () -> Void = {}
        static var separator: Self { Self(title: "") }
    }

    let title: String
    var symbol: String?
    var label: String?
    var identifier = ""
    let items: [Item]
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PopUpButton {
        let button = PopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return button
    }

    func updateNSView(_ button: PopUpButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.actions = items.map(\.action)
        let fingerprint = [title, symbol ?? ""] + items.map {
            "\($0.identifier)|\($0.title)|\($0.enabled)|\($0.selected)"
        }
        // Playback updates frequently. Keep an open menu intact when only
        // closure captures changed, while always using the latest callbacks.
        if coordinator.fingerprint != fingerprint {
            coordinator.fingerprint = fingerprint
            let menu = NSMenu()
            menu.autoenablesItems = false
            let heading = NSMenuItem(title: symbol == nil ? title : "", action: nil, keyEquivalent: "")
            if let symbol { heading.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(heading)
            for (index, item) in items.enumerated() {
                if item.title.isEmpty { menu.addItem(.separator()); continue }
                let entry = NSMenuItem(title: item.title, action: #selector(Coordinator.select(_:)), keyEquivalent: "")
                entry.target = coordinator
                entry.tag = index
                entry.isEnabled = item.enabled
                entry.state = item.selected ? .on : .off
                if !item.identifier.isEmpty { entry.identifier = NSUserInterfaceItemIdentifier(item.identifier) }
                menu.addItem(entry)
            }
            button.menu = menu
        }
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(label ?? title)
        button.setAccessibilityTitle(label ?? title)
        button.setAccessibilityIdentifier(identifier)
        button.toolTip = label ?? title
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PopUpButton, context: Context) -> CGSize? {
        let width = symbol == nil
            ? (title as NSString).size(withAttributes: [.font: nsView.font ?? NSFont.systemFont(ofSize: 13)]).width
            : 18
        return CGSize(width: max(32, ceil(width) + 22), height: 24)
    }

    final class PopUpButton: NSPopUpButton {
        override func accessibilityPerformPress() -> Bool {
            guard isEnabled else { return false }
            // Menu tracking is synchronous. Return to the accessibility
            // client before starting it so that client can choose an item.
            DispatchQueue.main.async { [weak self] in self?.performClick(nil) }
            return true
        }
        override func accessibilityPerformShowMenu() -> Bool { accessibilityPerformPress() }
    }

    final class Coordinator: NSObject {
        var fingerprint: [String] = []
        var actions: [() -> Void] = []
        @objc func select(_ sender: NSMenuItem) {
            guard actions.indices.contains(sender.tag) else { return }
            actions[sender.tag]()
        }
    }
}

/// Name the native popover boundary as well as its SwiftUI content group.
struct PopoverAccessibilityLabel: NSViewRepresentable {
    let label: String
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        view.label = label
        view.labelWindow()
    }
    final class Anchor: NSView {
        var label = ""
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); labelWindow() }
        func labelWindow() {
            window?.setAccessibilityLabel(label)
            window?.title = label
        }
    }
}
