import AppKit
import SwiftUI

/// The Quick Recall field. One AppKit responder owns both text insertion and
/// the keys that move through the list, as the ⌘K palette's field did:
/// combining SwiftUI's text-field bridge with ancestor `onKeyPress` handlers
/// can deliver the same printable key through two input paths on macOS, so a
/// typed character arrived twice.
struct QuickRecallTextField: NSViewRepresentable {
    @Environment(\.locale) private var locale
    @Binding var text: String
    /// A catalog key.
    let placeholder: String
    /// What the keys do, for VoiceOver. A catalog key. It is set on the
    /// AppKit field itself: a SwiftUI accessibility modifier here would wrap
    /// the field and hide its identifier and value.
    var hint: String?
    let fontSize: CGFloat
    /// Each new value moves keyboard focus to the field.
    let focusRequest: Int
    /// Return.
    let onSubmit: () -> Void
    /// ⌘Return, when it reaches the field instead of the Ask row's shortcut.
    let onCommandSubmit: () -> Void
    /// Up (-1) or Down (1). False leaves the key to the field.
    let onMove: (Int) -> Bool
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> QuickRecallField {
        let field = QuickRecallField()
        field.delegate = context.coordinator
        field.stringValue = text
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.identifier = NSUserInterfaceItemIdentifier("quickRecall.input")
        field.setAccessibilityIdentifier("quickRecall.input")
        apply(to: field, context: context)
        field.requestFocus()
        return field
    }

    func updateNSView(_ field: QuickRecallField, context: Context) {
        context.coordinator.update(parent: self)
        apply(to: field, context: context)
        if field.stringValue != text {
            field.stringValue = text
        }
        if context.coordinator.consumeFocusRequest(focusRequest) {
            field.requestFocus()
        }
    }

    private func apply(to field: QuickRecallField, context: Context) {
        let language = AppLanguage.matching(locale)
        let title = language.localized(placeholder)
        if field.placeholderString != title {
            field.placeholderString = title
            field.setAccessibilityLabel(title)
        }
        let help = hint.map { language.localized($0) }
        if field.accessibilityHelp() != help {
            field.setAccessibilityHelp(help)
        }
        if field.font?.pointSize != fontSize {
            field.font = .systemFont(ofSize: fontSize)
        }
        let rightToLeft = context.environment.layoutDirection == .rightToLeft
        field.userInterfaceLayoutDirection = rightToLeft ? .rightToLeft : .leftToRight
        field.alignment = rightToLeft ? .right : .left
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var parent: QuickRecallTextField
        private var lastFocusRequest: Int

        init(parent: QuickRecallTextField) {
            self.parent = parent
            lastFocusRequest = parent.focusRequest
        }

        func update(parent: QuickRecallTextField) {
            self.parent = parent
        }

        func consumeFocusRequest(_ request: Int) -> Bool {
            guard request != lastFocusRequest else { return false }
            lastFocusRequest = request
            return true
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  parent.text != field.stringValue else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                    parent.onCommandSubmit()
                } else {
                    parent.onSubmit()
                }
            case #selector(NSResponder.moveUp(_:)):
                return parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onMove(1)
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
            default:
                return false
            }
            return true
        }
    }
}

/// Takes keyboard focus as soon as it is in a window, whether or not that
/// window is key yet: Quick Recall opens while LokalBot is still coming
/// forward from another app, and must be ready for typing when it arrives.
/// The field never activates the app or orders a window itself.
final class QuickRecallField: NSTextField {
    private var focusToken = 0
    private var keyObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        guard let window else { return }
        // A window shown again after Escape can come back with nothing focused.
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.focusIfNothingIsFocused() }
        }
        requestFocus()
    }

    func requestFocus() {
        focusToken &+= 1
        attemptFocus(token: focusToken, attempt: 0)
    }

    private func focusIfNothingIsFocused() {
        guard let window, window.firstResponder === window || window.firstResponder == nil else { return }
        requestFocus()
    }

    private func attemptFocus(token: Int, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.05)) { [weak self] in
            guard let self, token == focusToken else { return }
            guard let window else {
                retryFocus(token: token, after: attempt)
                return
            }
            // A text field edits through the window's field editor.
            if let editor = currentEditor(), window.firstResponder === editor { return }
            guard window.makeFirstResponder(self) else {
                retryFocus(token: token, after: attempt)
                return
            }
            uiTestDiagnosticLog("text field focus acquired id=quickRecall.input")
        }
    }

    private func retryFocus(token: Int, after attempt: Int) {
        guard attempt < 20 else {
            uiTestDiagnosticLog("text field focus failed id=quickRecall.input")
            return
        }
        attemptFocus(token: token, attempt: attempt + 1)
    }
}
