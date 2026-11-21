import AppKit
import SwiftUI

struct SearchableNotesEditor: NSViewRepresentable {
    @Binding var text: String
    let query: String
    let occurrence: Int?

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let editor = scroll.documentView as? NSTextView else { return scroll }
        editor.isRichText = false
        editor.font = .systemFont(ofSize: 14)
        editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.backgroundColor = .textBackgroundColor
        editor.delegate = context.coordinator
        editor.setAccessibilityIdentifier("meeting.notes.editor")
        editor.setAccessibilityLabel("Meeting notes")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if editor.string != text, !editor.hasMarkedText() { editor.string = text }
        let target = "\(query)|\(occurrence ?? -1)"
        guard context.coordinator.lastTarget != target else { return }
        context.coordinator.lastTarget = target
        guard !query.isEmpty, let occurrence else { return }
        let value = editor.string as NSString
        var range = NSRange(location: 0, length: value.length)
        for index in 0...max(0, occurrence) {
            let match = value.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: range)
            guard match.location != NSNotFound else { return }
            if index == occurrence {
                editor.setSelectedRange(match)
                editor.scrollRangeToVisible(match)
            }
            range = NSRange(location: NSMaxRange(match), length: value.length - NSMaxRange(match))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SearchableNotesEditor
        var lastTarget = ""
        init(_ parent: SearchableNotesEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}
