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
        /// Focus changed or could not be verified; no selection is accepted.
        case focusChanged
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

    struct Dependencies {
        var source: @MainActor () -> SelectionSource?
        var isTrusted: @MainActor () -> Bool
        var focus: @MainActor () async -> DictationFocusCaptureResult
        var read: @MainActor (SelectionSource, [String]) async -> String?
        var copy: @MainActor (SelectionSource, [String]) async -> String?

        static var live: Self {
            Self(source: SelectionCapture.currentSource, isTrusted: { CotypingAXHelper.isTrusted },
                 focus: { await DictationFocusSnapshotExecutor.shared.capture(deadlineMilliseconds: 300) },
                 read: SelectionCapture.readThroughAccessibility,
                 copy: { await SelectionClipboardCopy.copySelection(from: $0, excludedApps: $1) })
        }
    }

    static func currentSource() -> SelectionSource? {
        FocusReturn.frontmostOtherApplication().map {
            SelectionSource(processID: $0.processIdentifier, bundleID: $0.bundleIdentifier,
                            appName: $0.localizedName ?? "")
        }
    }

    static func capture(excludedApps: [String], dependencies: Dependencies = .live) async -> SelectionCaptureResult {
        guard let source = dependencies.source() else { return SelectionCaptureResult() }
        var result = SelectionCaptureResult(source: source)
        guard !CotypingAvailability.isExcluded(
            appName: source.appName, bundleID: source.bundleID, excluded: excludedApps) else {
            result.issue = .excludedApp
            return result
        }
        guard dependencies.isTrusted() else {
            result.issue = .accessibilityNeeded
            return result
        }

        let focus = await dependencies.focus()
        guard !Task.isCancelled, dependencies.source() == source,
              !focus.timedOut, let snapshot = focus.snapshot,
              snapshot.processID == source.processID, snapshot.bundleID == source.bundleID else {
            result.issue = .focusChanged
            return result
        }
        guard !snapshot.isSecureOrBlocked else {
            result.issue = .secureField
            return result
        }
        // Only an editable field has an identity; read-only text cannot take a replacement.
        if snapshot.focusIdentityKey?.isEmpty == false {
            result.target = DictationDeliveryTarget.captured(from: snapshot)
        }

        let accessibleText = await dependencies.read(source, excludedApps)
        guard !Task.isCancelled, dependencies.source() == source else {
            return SelectionCaptureResult(source: source, issue: .focusChanged)
        }
        if let text = accessibleText {
            result.text = text
            return result
        }
        let copiedText = await dependencies.copy(source, excludedApps)
        guard !Task.isCancelled, dependencies.source() == source else {
            return SelectionCaptureResult(source: source, issue: .focusChanged)
        }
        if let text = copiedText,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.text = text.count > maximumCharacters ? String(text.prefix(maximumCharacters)) : text
            result.readThroughClipboard = true
        }
        return result
    }

    /// Off the main thread with a wall-clock deadline, so a wedged app costs
    /// a short wait instead of a beachball.
    private static func readThroughAccessibility(source: SelectionSource, excludedApps: [String]) async -> String? {
        let limit = maximumCharacters
        return await boundedRead {
            CotypingAXHelper.selectedTextForSelectionAction(
                source: source, excludedApps: excludedApps, maxCharacters: limit)
        }
    }

    static func boundedRead<Value: Sendable>(_ read: @escaping @Sendable () -> Value?) async -> Value? {
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                once.resume(read())
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(400)) {
                once.resume(nil)
            }
        }
    }
}

/// Resumes a continuation with the first value only.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?

    init(_ continuation: CheckedContinuation<Value?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value?) {
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
    struct Dependencies {
        var waitForModifiers: @MainActor () async -> Void
        var isAllowed: @MainActor (SelectionSource, [String]) async -> Bool
        var isFrontmost: @MainActor (SelectionSource) -> Bool
        var changeCount: @MainActor () -> Int
        var saveClipboard: @MainActor () -> @MainActor () -> Void
        var postCopy: @MainActor (pid_t) -> Bool
        var readText: @MainActor () -> String?

        static var live: Self {
            Self(waitForModifiers: { await waitForModifierRelease(timeout: .milliseconds(400)) },
                 isAllowed: { source, excluded in
                     await SelectionCapture.boundedRead {
                         CotypingAXHelper.selectionActionFocusIsAllowed(source: source, excludedApps: excluded)
                     } == true
                 },
                 isFrontmost: { SelectionCapture.currentSource() == $0 },
                 changeCount: { NSPasteboard.general.changeCount },
                 saveClipboard: {
                     let saved = CotypingInserter.snapshotPasteboard(NSPasteboard.general)
                     return { CotypingInserter.restorePasteboard(saved, to: NSPasteboard.general) }
                 },
                 postCopy: postCommandC,
                 readText: {
                     let pasteboard = NSPasteboard.general
                     let concealed = pasteboard.types?.contains(DictationPasteboardHandoff.concealedType) ?? false
                     return concealed ? nil : pasteboard.string(forType: .string)
                 })
        }
    }

    static func copySelection(from source: SelectionSource, excludedApps: [String],
                              timeout: Duration = .milliseconds(450),
                              dependencies: Dependencies = .live) async -> String? {
        // The shortcut's own modifiers may still be held; ⌃⇧⌘C is not Copy.
        await dependencies.waitForModifiers()
        guard !Task.isCancelled, await dependencies.isAllowed(source, excludedApps),
              !Task.isCancelled, dependencies.isFrontmost(source) else { return nil }
        let restore = dependencies.saveClipboard()
        let before = dependencies.changeCount()
        guard dependencies.isFrontmost(source), dependencies.postCopy(source.processID) else { return nil }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while dependencies.changeCount() == before, clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(15))
        }
        // Nothing selected: the app copied nothing and the clipboard is untouched.
        guard dependencies.changeCount() != before else { return nil }
        let copiedGeneration = dependencies.changeCount()
        defer { if dependencies.changeCount() == copiedGeneration { restore() } }
        // Re-check after the app handles Copy. A changed app/secure field is
        // never read, and a newer clipboard generation is not ours to restore.
        guard !Task.isCancelled, await dependencies.isAllowed(source, excludedApps),
              !Task.isCancelled, dependencies.isFrontmost(source),
              dependencies.changeCount() == copiedGeneration else { return nil }
        return dependencies.readText()
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

    private static func postCommandC(processID: pid_t) -> Bool {
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
        // Bind the event destination even if focus moves between validation and posting.
        down.postToPid(processID)
        up.postToPid(processID)
        return true
    }
}
