import AppKit
import SwiftUI

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
    var font: NSFont = .systemFont(ofSize: NSFont.smallSystemFontSize)
    var drawsButton = true
    @Environment(\.isEnabled) private var isEnabled

    private var buttonFont: NSFont { symbol == nil ? font : .menuFont(ofSize: 0) }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PopUpButton {
        let button = PopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        button.controlSize = .small
        button.font = buttonFont
        button.drawsNothing = !drawsButton
        return button
    }

    func updateNSView(_ button: PopUpButton, context: Context) {
        let coordinator = context.coordinator
        let flattened = items.flatMap(\.flattened)
        coordinator.actions = flattened.map(\.action)
        let fingerprint = [title, symbol ?? ""] + flattened.map {
            "\($0.identifier)|\($0.title)|\($0.enabled)|\($0.selected)|\($0.children.count)"
        }
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
        if button.drawsNothing == drawsButton {
            button.drawsNothing = !drawsButton
            button.needsDisplay = true
        }
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(label ?? title)
        button.setAccessibilityTitle(label ?? title)
        button.setAccessibilityValue(title)
        button.setAccessibilityIdentifier(identifier)
        button.toolTip = label ?? title
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PopUpButton, context: Context) -> CGSize? {
        if !drawsButton { return CGSize(width: proposal.width ?? 32, height: proposal.height ?? 24) }
        let width = symbol == nil
            ? (title as NSString).size(withAttributes: [.font: nsView.font ?? NSFont.systemFont(ofSize: 13)]).width
            : 18
        return CGSize(width: max(32, ceil(width) + 22), height: 24)
    }

    final class PopUpButton: NSPopUpButton {
        var drawsNothing = false

        override func draw(_ dirtyRect: NSRect) {
            if !drawsNothing { super.draw(dirtyRect) }
        }

        override func accessibilityPerformPress() -> Bool {
            guard isEnabled else { return false }
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
