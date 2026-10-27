import AppKit
import SwiftUI

/// A narrow AppKit bridge for the command palette's editor. The palette needs
/// one responder to own both text insertion and navigation commands; combining
/// SwiftUI's text-field bridge with ancestor `onKeyPress` handlers can deliver
/// the same printable key through two input paths on macOS.
struct CommandPaletteTextField: NSViewRepresentable {
    @Environment(\.locale) private var locale
    @Binding var text: String
    let focusRequest: Int
    let onSubmit: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> FocusOwningTextField {
        let field = FocusOwningTextField()
        field.delegate = context.coordinator
        field.stringValue = text
        field.placeholderString = AppLanguage.matching(locale).localized("Type a command or search meetings…")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.identifier = NSUserInterfaceItemIdentifier("palette.input")
        field.setAccessibilityIdentifier("palette.input")
        field.setAccessibilityLabel(AppLanguage.matching(locale).localized("Command palette input"))
        field.apply(layoutDirection: context.environment.layoutDirection)
        field.requestFocus()
        return field
    }

    func updateNSView(_ field: FocusOwningTextField, context: Context) {
        context.coordinator.update(parent: self)
        field.placeholderString = AppLanguage.matching(locale).localized("Type a command or search meetings…")
        field.setAccessibilityLabel(AppLanguage.matching(locale).localized("Command palette input"))
        field.apply(layoutDirection: context.environment.layoutDirection)
        if field.stringValue != text {
            field.stringValue = text
        }
        if context.coordinator.consumeFocusRequest(focusRequest) {
            field.requestFocus()
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var text: Binding<String>
        private var onSubmit: () -> Void
        private var onPrevious: () -> Void
        private var onNext: () -> Void
        private var onCancel: () -> Void
        private var lastFocusRequest: Int

        init(parent: CommandPaletteTextField) {
            text = parent.$text
            onSubmit = parent.onSubmit
            onPrevious = parent.onPrevious
            onNext = parent.onNext
            onCancel = parent.onCancel
            lastFocusRequest = parent.focusRequest
        }

        func update(parent: CommandPaletteTextField) {
            text = parent.$text
            onSubmit = parent.onSubmit
            onPrevious = parent.onPrevious
            onNext = parent.onNext
            onCancel = parent.onCancel
        }

        func consumeFocusRequest(_ request: Int) -> Bool {
            guard request != lastFocusRequest else { return false }
            lastFocusRequest = request
            return true
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  text.wrappedValue != field.stringValue else { return }
            text.wrappedValue = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                onSubmit()
            case #selector(NSResponder.moveUp(_:)):
                onPrevious()
            case #selector(NSResponder.moveDown(_:)):
                onNext()
            case #selector(NSResponder.cancelOperation(_:)):
                onCancel()
            default:
                return false
            }
            return true
        }
    }
}

/// An AppKit editor can enter the view tree before a newly opened SwiftUI
/// window becomes active or key. Keep focus acquisition with the native
/// control and retry across that short scene transition instead of relying on
/// a single next-run-loop `makeFirstResponder` call.
final class FocusOwningTextField: NSTextField {
    private var focusRequestToken = 0

    /// AppKit controls don't read SwiftUI's layout direction. Mirror it so the
    /// field and its placeholder start at the leading edge of a right-to-left
    /// window; the text's own bidi order is unaffected.
    func apply(layoutDirection: LayoutDirection) {
        let rightToLeft = layoutDirection == .rightToLeft
        userInterfaceLayoutDirection = rightToLeft ? .rightToLeft : .leftToRight
        alignment = rightToLeft ? .right : .left
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestFocus()
    }

    func requestFocus() {
        focusRequestToken &+= 1
        attemptFocus(token: focusRequestToken, attempt: 0)
    }

    private func attemptFocus(token: Int, attempt: Int) {
        let delay = attempt == 0 ? 0 : min(0.05 * Double(attempt), 0.2)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard token == focusRequestToken else { return }
            guard let window else {
                retryFocus(token: token, after: attempt)
                return
            }
            if let editor = currentEditor(),
               window.firstResponder === editor,
               NSApp.isActive,
               window.isKeyWindow {
                return
            }

            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            if window.canBecomeMain {
                window.makeMain()
            }

            guard NSApp.isActive, window.isKeyWindow else {
                retryFocus(token: token, after: attempt)
                return
            }
            guard window.makeFirstResponder(self) else {
                retryFocus(token: token, after: attempt)
                return
            }
            // NSTextField delegates editing to the window's field editor.
            // Starting that editing session makes the AX text field report
            // keyboard focus as soon as its containing window becomes key.
            selectText(nil)
            uiTestDiagnosticLog(
                "text field focus acquired id=\(identifier?.rawValue ?? "unknown")")
        }
    }

    private func retryFocus(token: Int, after attempt: Int) {
        guard attempt < 6 else {
            uiTestDiagnosticLog(
                "text field focus failed id=\(identifier?.rawValue ?? "unknown")")
            return
        }
        attemptFocus(token: token, attempt: attempt + 1)
    }
}
