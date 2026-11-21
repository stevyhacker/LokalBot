import AppKit
import SwiftUI

struct RehearsalTextEditor: NSViewRepresentable {
    @Binding var text: String
    let suggestion: String
    let acceptKey: CotypingAcceptKey
    let fullAcceptKey: CotypingFullAcceptKey
    let focusRevision: Int
    let onAccept: (CotypingAcceptScope) -> Void
    let onReject: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let editor = RehearsalNativeTextView()
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 8, height: 10)
        editor.font = .systemFont(ofSize: 14)
        editor.drawsBackground = false
        editor.delegate = context.coordinator
        editor.setAccessibilityIdentifier("autocomplete.rehearsal.editor")
        editor.setAccessibilityLabel("Autocomplete rehearsal text")
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? RehearsalNativeTextView else { return }
        context.coordinator.parent = self
        if editor.string != text, !editor.hasMarkedText() {
            context.coordinator.isApplyingText = true
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            context.coordinator.isApplyingText = false
        }
        editor.suggestion = suggestion
        editor.setAccessibilityPlaceholderValue(suggestion.isEmpty ? nil : suggestion)
        editor.acceptKey = acceptKey
        editor.fullAcceptKey = fullAcceptKey
        editor.onAccept = onAccept
        editor.onReject = onReject
        editor.needsDisplay = true
        if focusRevision > context.coordinator.focusRevision {
            context.coordinator.focusRevision = focusRevision
            DispatchQueue.main.async { [weak editor] in
                guard let editor else { return }
                editor.window?.makeFirstResponder(editor)
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RehearsalTextEditor
        var focusRevision = 0
        var isApplyingText = false
        init(_ parent: RehearsalTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            if editor.hasMarkedText() { parent.onReject(); return }
            parent.text = editor.string
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            editor.needsDisplay = true
            guard !isApplyingText, !parent.suggestion.isEmpty, !editor.hasMarkedText() else { return }
            let selection = editor.selectedRange()
            if selection.length > 0 || selection.location != (editor.string as NSString).length {
                parent.onReject()
            }
        }
    }
}

private final class RehearsalNativeTextView: NSTextView {
    private let inputSource = CotypingKeyboardInputSourceMonitor()
    var suggestion = ""
    var acceptKey: CotypingAcceptKey = .tab
    var fullAcceptKey: CotypingFullAcceptKey = .backtick
    var onAccept: ((CotypingAcceptScope) -> Void)?
    var onReject: (() -> Void)?

    private var canAccept: Bool {
        !suggestion.isEmpty && selectedRange().location == (string as NSString).length
            && CotypingAcceptanceSnapshotPolicy.canAccept(
                markedTextState: hasMarkedText() ? .active : .inactive,
                composingInputModeActive: inputSource.isComposingIMEActive,
                hasLiveContent: true, selectionLength: selectedRange().length)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if canAccept, modifiers.isEmpty {
            if event.keyCode == UInt16(acceptKey.rawValue) {
                onAccept?(.chunk)
                return
            }
            if let full = fullAcceptKey.keyCode, event.keyCode == UInt16(full) {
                onAccept?(.whole)
                return
            }
        }
        if event.keyCode == 48, !hasMarkedText(), !inputSource.isComposingIMEActive,
           modifiers.isEmpty || modifiers == .shift {
            if modifiers == .shift { window?.selectPreviousKeyView(self) } else { window?.selectNextKeyView(self) }
            return
        }
        if !hasMarkedText(), event.keyCode == 53, !suggestion.isEmpty {
            onReject?()
            return
        }
        if (123...126).contains(Int(event.keyCode)), !suggestion.isEmpty {
            onReject?()
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard canAccept, let currentContainer = textContainer else { return }
        let preview = NSTextStorage(attributedString: attributedString())
        let range = NSRange(location: preview.length, length: (suggestion as NSString).length)
        var attributes = typingAttributes
        attributes[.font] = font ?? NSFont.systemFont(ofSize: 14)
        attributes[.foregroundColor] = NSColor.secondaryLabelColor
        preview.append(NSAttributedString(string: suggestion, attributes: attributes))
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: currentContainer.size.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = currentContainer.lineFragmentPadding
        preview.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        layout.drawGlyphs(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), at: textContainerOrigin)
    }
}
