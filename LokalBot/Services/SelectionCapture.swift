import AppKit
import CoreGraphics

/// The app a selection action was invoked from.
struct SelectionSource: Equatable, Sendable {
    let processID: pid_t
    let bundleID: String?
    let appName: String
}

/// What the selection actions shortcut found in the frontmost app. The text
/// lives only in memory for the panel's lifetime and is never stored.
struct SelectionCaptureResult: Equatable, Sendable {
    enum Issue: Equatable, Sendable {
        /// LokalBot lacks Accessibility access, so it cannot read or paste.
        case accessibilityNeeded
        /// The app is on the user's exclusion list; nothing was read.
        case excludedApp
        /// A password or other secure field has focus; nothing was read.
        case secureField
    }

    var source: SelectionSource?
    var text = ""
    /// The editable field the selection sits in (with its selection range),
    /// where a result can replace the selection or be inserted at the caret.
    /// Nil for read-only text such as a web page or a PDF.
    var target: DictationDeliveryTarget?
    var issue: Issue?
    /// The app did not share its selection through Accessibility, so LokalBot
    /// copied it and restored the clipboard.
    var readThroughClipboard = false

    var hasSelection: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// A result can go back into the source app's field.
    var canInsert: Bool { target != nil && issue == nil }
    var isClipped: Bool { text.count > SelectionActionPrompt.selectionCharacterLimit }
}

/// Reads the selected text in the frontmost app once, on an explicit
/// shortcut press. Accessibility comes first; apps that do not expose their
/// selection that way (many Electron and web views) get a synthetic ⌘C whose
/// result is read and the previous clipboard put back.
@MainActor
enum SelectionCapture {
    /// Longest selection kept in memory; the prompt uses less.
    nonisolated static let maximumCharacters = 50_000

    static func capture(excludedApps: [String]) async -> SelectionCaptureResult {
        guard let frontmost = FocusReturn.frontmostOtherApplication() else {
            return SelectionCaptureResult()
        }
        let source = SelectionSource(
            processID: frontmost.processIdentifier,
            bundleID: frontmost.bundleIdentifier,
            appName: frontmost.localizedName ?? "")
        var result = SelectionCaptureResult(source: source)
        guard !CotypingAvailability.isExcluded(
            appName: source.appName, bundleID: source.bundleID, excluded: excludedApps) else {
            result.issue = .excludedApp
            return result
        }
        guard CotypingAXHelper.isTrusted else {
            result.issue = .accessibilityNeeded
            return result
        }

        let focus = await DictationFocusSnapshotExecutor.shared.capture(deadlineMilliseconds: 300)
        if let snapshot = focus.snapshot, !focus.timedOut, snapshot.processID == source.processID {
            guard !snapshot.isSecureOrBlocked else {
                result.issue = .secureField
                return result
            }
            // Only an editable field has an identity; read-only text cannot
            // take a replacement.
            if snapshot.focusIdentityKey?.isEmpty == false {
                result.target = DictationDeliveryTarget.captured(from: snapshot)
            }
        }

        if let text = await readThroughAccessibility() {
            result.text = text
            return result
        }
        if let text = await SelectionClipboardCopy.copySelection(),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.text = text.count > maximumCharacters ? String(text.prefix(maximumCharacters)) : text
            result.readThroughClipboard = true
        }
        return result
    }

    /// Off the main thread with a wall-clock deadline, so a wedged app costs
    /// a short wait instead of a beachball.
    private static func readThroughAccessibility() async -> String? {
        let limit = maximumCharacters
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                once.resume(CotypingAXHelper.selectedTextForSelectionAction(maxCharacters: limit))
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(400)) {
                once.resume(nil)
            }
        }
    }
}

/// Resumes a continuation with the first value only.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: String?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// The ⌘C fallback. The copy comes from the source app, so clipboard managers
/// may record it like any copy the person makes; the previous clipboard is
/// restored right after, marked as generated.
@MainActor
enum SelectionClipboardCopy {
    static func copySelection(timeout: Duration = .milliseconds(450)) async -> String? {
        // The shortcut's own modifiers may still be held; ⌃⇧⌘C is not Copy.
        await waitForModifierRelease(timeout: .milliseconds(400))
        let pasteboard = NSPasteboard.general
        let saved = CotypingInserter.snapshotPasteboard(pasteboard)
        let before = pasteboard.changeCount
        guard postCommandC() else { return nil }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while pasteboard.changeCount == before, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(15))
        }
        // Nothing selected: the app copied nothing and the clipboard is untouched.
        guard pasteboard.changeCount != before else { return nil }
        // A password manager's concealed copy is never read.
        let concealed = pasteboard.types?.contains(DictationPasteboardHandoff.concealedType) ?? false
        let text = concealed ? nil : pasteboard.string(forType: .string)
        CotypingInserter.restorePasteboard(saved, to: pasteboard)
        return text
    }

    private static func waitForModifierRelease(timeout: Duration) async {
        let held: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !CGEventSource.flagsState(.combinedSessionState).isDisjoint(with: held),
              clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    private static func postCommandC() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)
        // Virtual key 0x08 is C.
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // Marked so Autocomplete's and Dictation's input taps ignore it.
        CotypingSyntheticMarker.mark(down)
        CotypingSyntheticMarker.mark(up)
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }
}
