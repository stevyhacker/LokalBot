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
        var children: [Item] = []
        var flattened: [Item] { [self] + children.flatMap(\.flattened) }
        static var separator: Self { Self(title: "") }
    }

    let title: String
    var symbol: String?
    var label: String?
    var identifier = ""
    let items: [Item]
    /// Composer rows match their neighboring SwiftUI controls' type.
    var font: NSFont = .systemFont(ofSize: NSFont.smallSystemFontSize)
    @Environment(\.isEnabled) private var isEnabled

    /// AppKit gives the menu its button's font. A symbol button shows no
    /// text, so its menu keeps the standard menu size.
    private var buttonFont: NSFont { symbol == nil ? font : .menuFont(ofSize: 0) }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PopUpButton {
        let button = PopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        button.controlSize = .small
        button.font = buttonFont
        return button
    }

    func updateNSView(_ button: PopUpButton, context: Context) {
        let coordinator = context.coordinator
        let flattened = items.flatMap(\.flattened)
        coordinator.actions = flattened.map(\.action)
        let fingerprint = [title, symbol ?? ""] + flattened.map {
            "\($0.identifier)|\($0.title)|\($0.enabled)|\($0.selected)|\($0.children.count)"
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
            var actionIndex = 0
            func append(_ items: [Item], to menu: NSMenu) {
                for item in items {
                    let index = actionIndex
                    actionIndex += 1
                    if item.title.isEmpty { menu.addItem(.separator()); continue }
                    let entry = NSMenuItem(title: item.title, action: #selector(Coordinator.select(_:)), keyEquivalent: "")
                    entry.target = coordinator
                    entry.tag = index
                    entry.isEnabled = item.enabled
                    entry.state = item.selected ? .on : .off
                    if !item.identifier.isEmpty { entry.identifier = NSUserInterfaceItemIdentifier(item.identifier) }
                    if !item.children.isEmpty {
                        let submenu = NSMenu(title: item.title)
                        submenu.autoenablesItems = false
                        append(item.children, to: submenu)
                        entry.submenu = submenu
                    }
                    menu.addItem(entry)
                }
            }
            append(items, to: menu)
            button.menu = menu
        }
        if button.font != buttonFont { button.font = buttonFont }
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(label ?? title)
        button.setAccessibilityTitle(label ?? title)
        button.setAccessibilityValue(title)
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
