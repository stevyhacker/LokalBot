import AppKit
import SwiftUI

/// Native editable field for page-level meeting find. AppKit owns the
/// accessibility role and first-responder transition so a bar inserted by a
/// Command-F request is immediately exposed to VoiceOver and XCUITest.
struct MeetingSearchTextField: NSViewRepresentable {
    @Environment(\.locale) private var locale
    @Binding var text: String
    let focusRequest: Int
    let onSubmit: () -> Void
    let onCancel: () -> Void
    var placeholder = "Search this meeting"
    var focusesOnAppear = true

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> FocusOwningTextField {
        let field = FocusOwningTextField()
        field.delegate = context.coordinator
        field.stringValue = text
        field.placeholderString = AppLanguage.matching(locale).localized(placeholder)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.identifier = NSUserInterfaceItemIdentifier("meeting.search.field")
        field.setAccessibilityIdentifier("meeting.search.field")
        field.setAccessibilityLabel(AppLanguage.matching(locale).localized(placeholder))
        field.apply(layoutDirection: context.environment.layoutDirection)
        if focusesOnAppear { field.requestFocus() }
        return field
    }

    func updateNSView(_ field: FocusOwningTextField, context: Context) {
        context.coordinator.update(parent: self)
        field.placeholderString = AppLanguage.matching(locale).localized(placeholder)
        field.setAccessibilityLabel(AppLanguage.matching(locale).localized(placeholder))
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
        private var onCancel: () -> Void
        private var lastFocusRequest: Int

        init(parent: MeetingSearchTextField) {
            text = parent.$text
            onSubmit = parent.onSubmit
            onCancel = parent.onCancel
            lastFocusRequest = parent.focusRequest
        }

        func update(parent: MeetingSearchTextField) {
            text = parent.$text
            onSubmit = parent.onSubmit
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
            case #selector(NSResponder.cancelOperation(_:)):
                onCancel()
            default:
                return false
            }
            return true
        }
    }
}
