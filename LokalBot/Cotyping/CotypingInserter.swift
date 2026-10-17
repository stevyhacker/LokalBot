// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Tags Cotyping's own synthetic keystrokes so the input taps ignore them and
/// never re-observe an insert as user typing. Ported from Cotabby's
/// `InputSuppressionController` (identity field only).
enum CotypingSyntheticMarker {
    /// "Lokal" in ASCII — an arbitrary sentinel on the event's source user data.
    static let userData: Int64 = 0x4C6F_6B61_6C

    static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: userData)
    }

    static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == userData
    }
}

final class CotypingInputSuppressionController {
    private var remainingKeyDownSuppressions = 0
    private var suppressionExpiry = Date.distantPast

    nonisolated static let syntheticSuppressionWindowSeconds: TimeInterval = 1.0

    func registerSyntheticInsertion(expectedKeyDownCount: Int, now: Date = Date()) {
        if now > suppressionExpiry {
            remainingKeyDownSuppressions = 0
        }
        remainingKeyDownSuppressions += max(expectedKeyDownCount, 0)
        suppressionExpiry = now.addingTimeInterval(Self.syntheticSuppressionWindowSeconds)
    }

    func consumeIfNeeded(now: Date = Date()) -> Bool {
        guard remainingKeyDownSuppressions > 0 else {
            return false
        }
        guard now <= suppressionExpiry else {
            remainingKeyDownSuppressions = 0
            return false
        }
        remainingKeyDownSuppressions -= 1
        return true
    }

    func markSynthetic(_ event: CGEvent) {
        CotypingSyntheticMarker.mark(event)
    }

    func isSynthetic(_ event: CGEvent) -> Bool {
        CotypingSyntheticMarker.isSynthetic(event)
    }
}

/// Inserts accepted ghost text into the focused host app by synthesizing Unicode
/// keystrokes (Cotabby's approach — AX value-set is silently dropped by Chromium
/// and others). Each event is marked synthetic so the input monitor skips it.
@MainActor
final class CotypingInserter {
    /// Pending restore of the user's clipboard after a paste insert, so overlapping
    /// pastes coalesce onto the single saved clipboard rather than re-snapshotting
    /// our own completion back into it.
    private var pendingPasteboardRestore: DispatchWorkItem?
    private var savedClipboardForRestore: [[NSPasteboard.PasteboardType: Data]]?
    /// Kept alive while its promised text may still be read.
    private var activeHandoff: DictationPasteboardHandoff?
    /// Pastes run one at a time. A second paste waits for the first; otherwise
    /// it would snapshot the first one's dictated text as the user's clipboard.
    private let pasteQueue = SerialTaskQueue()
    private var cachedPasteMenuItems: [pid_t: AXUIElement] = [:]
    private let suppressionController: CotypingInputSuppressionController

    init(suppressionController: CotypingInputSuppressionController = CotypingInputSuppressionController()) {
        self.suppressionController = suppressionController
    }

    @discardableResult
    func insert(_ text: String) -> Bool {
        let scrubbed = text.replacingOccurrences(of: "\r", with: "")
        guard !scrubbed.isEmpty else { return false }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            return false
        }
        let utf16 = Array(scrubbed.utf16)
        utf16.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
        }
        suppressionController.registerSyntheticInsertion(expectedKeyDownCount: 1)
        suppressionController.markSynthetic(down)
        suppressionController.markSynthetic(up)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Deletes `deletingCharacters` graphemes (one Backspace each) then types
    /// `text`, in one suppressed synthetic burst. Used to swap a typo for its
    /// correction. Backspace is virtual key 51.
    @discardableResult
    func replace(deletingCharacters count: Int, with text: String) -> Bool {
        let scrubbed = text.replacingOccurrences(of: "\r", with: "")
        guard CotypingSyntheticEditPolicy.allowsBackwardDeletion(count),
              count > 0 || !scrubbed.isEmpty else {
            return false
        }
        var events: [CGEvent] = []
        for _ in 0..<max(0, count) {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: false) else { return false }
            events.append(down)
            events.append(up)
        }
        if !scrubbed.isEmpty {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return false }
            let utf16 = Array(scrubbed.utf16)
            utf16.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            }
            events.append(down)
            events.append(up)
        }
        suppressionController.registerSyntheticInsertion(
            expectedKeyDownCount: max(0, count) + (scrubbed.isEmpty ? 0 : 1))
        for event in events { suppressionController.markSynthetic(event) }
        for event in events { event.post(tap: .cghidEventTap) }
        return true
    }

    /// Deletes `deletingCharacters` graphemes to the right of the caret (Forward
    /// Delete, virtual key 117) and then types `text`. Used for mid-word accepts
    /// where the model's first characters are already present after the caret.
    @discardableResult
    func replaceForward(deletingCharacters count: Int, with text: String) -> Bool {
        let scrubbed = text.replacingOccurrences(of: "\r", with: "")
        guard CotypingSyntheticEditPolicy.allowsForwardDeletion(count),
              count > 0 || !scrubbed.isEmpty else {
            return false
        }
        var events: [CGEvent] = []
        for _ in 0..<max(0, count) {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 117, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 117, keyDown: false) else { return false }
            events.append(down)
            events.append(up)
        }
        if !scrubbed.isEmpty {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return false }
            let utf16 = Array(scrubbed.utf16)
            utf16.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            }
            events.append(down)
            events.append(up)
        }
        suppressionController.registerSyntheticInsertion(
            expectedKeyDownCount: max(0, count) + (scrubbed.isEmpty ? 0 : 1))
        for event in events { suppressionController.markSynthetic(event) }
        for event in events { event.post(tap: .cghidEventTap) }
        return true
    }

    /// Types `text` in short Unicode keystrokes. Many apps take only the first
    /// 20 UTF-16 units of a single synthetic key event, so the whole string in
    /// one event could silently lose the rest. Dictation's fallback when paste
    /// cannot be set up.
    @discardableResult
    func typeInChunks(_ text: String) -> Bool {
        let chunks = Self.typingChunks(text.replacingOccurrences(of: "\r", with: ""))
        guard !chunks.isEmpty else { return false }
        var events: [CGEvent] = []
        for chunk in chunks {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return false }
            let utf16 = Array(chunk.utf16)
            utf16.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            }
            events.append(down)
            events.append(up)
        }
        suppressionController.registerSyntheticInsertion(expectedKeyDownCount: chunks.count)
        for event in events { suppressionController.markSynthetic(event) }
        for event in events { event.post(tap: .cghidEventTap) }
        return true
    }

    /// Splits `text` at character boundaries into runs of at most
    /// `maximumUTF16` code units. A single longer character (a long emoji
    /// sequence) stays whole in its own run.
    nonisolated static func typingChunks(_ text: String, maximumUTF16: Int = 20) -> [String] {
        var chunks: [String] = []
        var current = ""
        var currentLength = 0
        for character in text {
            let length = character.utf16.count
            if currentLength > 0, currentLength + length > maximumUTF16 {
                chunks.append(current)
                current = ""
                currentLength = 0
            }
            current.append(character)
            currentLength += length
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    enum PasteOutcome: Equatable {
        /// An app read the text after the paste command.
        case pasted
        /// The paste command was sent but no app read the text in time. The
        /// text is left on the clipboard so it is not lost.
        case unconfirmed
        /// The pasteboard or paste command could not be set up; the clipboard
        /// has been restored.
        case failed
        /// Nothing was pasted: the caller was cancelled, or after waiting for
        /// an earlier paste its destination was no longer valid.
        case skipped
    }

    /// How long an app has to read the pasted text before LokalBot stops
    /// waiting and leaves the text on the clipboard.
    nonisolated static let pasteReadTimeout: Duration = .milliseconds(1_500)

    /// Inserts `text` by placing it on the pasteboard and sending Paste, then
    /// restoring the user's clipboard once the focused app has read it. The
    /// text is provided lazily so LokalBot learns when the read happens; a
    /// fixed delay used to restore the old clipboard before a busy app read it,
    /// and that app pasted the previous clipboard instead. A trimmed port of
    /// Cotabby's `insertViaPaste`, used by dictation commits.
    ///
    /// `revalidateAfterWaiting` runs only when this paste had to wait for an
    /// earlier one; focus may have moved meanwhile, so the caller re-checks
    /// its destination. Cancelling the caller cancels a paste that has not
    /// started.
    func insertViaPaste(
        _ text: String,
        revalidateAfterWaiting: @escaping @MainActor () async -> Bool = { true }
    ) async -> PasteOutcome {
        await pasteQueue.run(stillWanted: revalidateAfterWaiting) { [weak self] in
            guard let self else { return .failed }
            return await self.pasteAndConfirm(text)
        } ?? .skipped
    }

    private func pasteAndConfirm(_ text: String) async -> PasteOutcome {
        let scrubbed = text.replacingOccurrences(of: "\r", with: "")
        guard !scrubbed.isEmpty else { return .failed }
        let pasteboard = NSPasteboard.general
        if pendingPasteboardRestore == nil {
            savedClipboardForRestore = Self.snapshotPasteboard(pasteboard)
        }
        pendingPasteboardRestore?.cancel()
        pendingPasteboardRestore = nil
        let saved = savedClipboardForRestore ?? []

        let handoff = DictationPasteboardHandoff(text: scrubbed)
        activeHandoff = handoff
        guard handoff.place(on: pasteboard) else {
            Self.restorePasteboard(saved, to: pasteboard)
            clearPendingPasteboardRestore()
            return .failed
        }
        let expectedChangeCount = pasteboard.changeCount
        // Reads before the paste command (clipboard managers that ignore the
        // transient marker) do not confirm anything.
        handoff.armConfirmation()

        var sent = await pressPasteMenuItem()
        if !sent { sent = postCommandV() }
        guard sent else {
            if pasteboard.changeCount == expectedChangeCount {
                Self.restorePasteboard(saved, to: pasteboard)
            }
            clearPendingPasteboardRestore()
            return .failed
        }

        guard await handoff.waitForRead(timeout: Self.pasteReadTimeout) else {
            if pasteboard.changeCount == expectedChangeCount {
                pasteboard.clearContents()
                pasteboard.setString(scrubbed, forType: .string)
            }
            clearPendingPasteboardRestore()
            return .unconfirmed
        }
        schedulePasteboardRestore(saved: saved, expectedChangeCount: expectedChangeCount)
        return .pasted
    }

    private func postCommandV() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)
        guard let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            return false
        }
        // Cmd via flags (no separate modifier key event). Marked synthetic so the
        // consuming input tap ignores it.
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        suppressionController.registerSyntheticInsertion(expectedKeyDownCount: 1)
        suppressionController.markSynthetic(vDown)
        suppressionController.markSynthetic(vUp)
        vDown.post(tap: .cgAnnotatedSessionEventTap)
        vUp.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

    /// Finds the menu item on the main actor but presses it on a background
    /// queue: the app answers the press by reading the pasteboard, and that
    /// read is served from LokalBot's main thread.
    private func pressPasteMenuItem() async -> Bool {
        guard let focusedElement = CotypingAXHelper.focusedElement(),
              let application = CotypingAXHelper.owningApplication(of: focusedElement) else {
            return false
        }
        let pid = application.processIdentifier
        if let cached = cachedPasteMenuItems[pid] {
            if await Self.press(cached) {
                return true
            }
            cachedPasteMenuItems[pid] = nil
        }
        guard let item = CotypingAXHelper.pasteMenuItem(forApplicationPID: pid),
              await Self.press(item) else {
            return false
        }
        cachedPasteMenuItems[pid] = item
        return true
    }

    nonisolated private static func press(_ item: AXUIElement) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: AXUIElementPerformAction(item, kAXPressAction as CFString) == .success)
            }
        }
    }

    private func schedulePasteboardRestore(
        saved: [[NSPasteboard.PasteboardType: Data]],
        expectedChangeCount: Int
    ) {
        let restore = DispatchWorkItem { [weak self] in
            if NSPasteboard.general.changeCount == expectedChangeCount {
                Self.restorePasteboard(saved, to: NSPasteboard.general)
            }
            self?.clearPendingPasteboardRestore()
        }
        pendingPasteboardRestore?.cancel()
        pendingPasteboardRestore = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pasteboardRestoreDelay, execute: restore)
    }

    /// How long the completion stays on the pasteboard before the user's clipboard
    /// is restored — long enough for the host to service Cmd-V, short enough that
    /// the user's clipboard is theirs again almost immediately.
    private static let pasteboardRestoreDelay: TimeInterval = 0.3

    private func clearPendingPasteboardRestore() {
        pendingPasteboardRestore = nil
        savedClipboardForRestore = nil
        activeHandoff = nil
    }

    /// Captures every representation of every pasteboard item so the user's
    /// clipboard can be restored exactly, not just its plain-text form.
    static func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var reps: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { reps[type] = data }
            }
            return reps
        }
    }

    /// Puts the user's clipboard back, marked as generated so clipboard
    /// managers do not record it as a second copy. A concealed item (a password
    /// manager's copy) is not put back: its owner clears it on a timer only
    /// while the pasteboard is unchanged, so a restored copy would linger.
    static func restorePasteboard(_ saved: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard let items = restoredItems(saved) else { return }
        pasteboard.writeObjects(items)
    }

    /// Nil when nothing should be restored.
    static func restoredItems(_ saved: [[NSPasteboard.PasteboardType: Data]]) -> [NSPasteboardItem]? {
        guard !saved.isEmpty,
              !saved.contains(where: { $0[DictationPasteboardHandoff.concealedType] != nil }) else { return nil }
        return saved.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            if dict[DictationPasteboardHandoff.autoGeneratedType] == nil {
                item.setData(Data(), forType: DictationPasteboardHandoff.autoGeneratedType)
            }
            return item
        }
    }
}

/// Dictated text on its way to the focused app. The string is promised rather
/// than written, so the first read after the paste command tells LokalBot the
/// paste happened. Marked with the nspasteboard.org conventions so clipboard
/// managers skip it.
final class DictationPasteboardHandoff: NSObject, NSPasteboardItemDataProvider {
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")

    private let text: String
    private var isArmed = false
    private(set) var confirmedRead = false
    private var waiter: CheckedContinuation<Bool, Never>?

    init(text: String) {
        self.text = text
    }

    @MainActor
    func place(on pasteboard: NSPasteboard) -> Bool {
        let item = NSPasteboardItem()
        guard item.setDataProvider(self, forTypes: [.string]) else { return false }
        item.setData(Data(), forType: Self.transientType)
        item.setData(Data(), forType: Self.autoGeneratedType)
        if let bundleID = Bundle.main.bundleIdentifier {
            item.setString(bundleID, forType: Self.sourceType)
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    /// Reads from now on count as the paste.
    @MainActor
    func armConfirmation() {
        isArmed = true
    }

    @MainActor
    func waitForRead(timeout: Duration) async -> Bool {
        if confirmedRead { return true }
        return await withCheckedContinuation { continuation in
            waiter = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finishWaiting(false)
            }
        }
    }

    /// AppKit calls providers on the main thread.
    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        item.setString(text, forType: type)
        MainActor.assumeIsolated {
            guard isArmed else { return }
            confirmedRead = true
            finishWaiting(true)
        }
    }

    @MainActor
    private func finishWaiting(_ read: Bool) {
        guard let waiter else { return }
        self.waiter = nil
        waiter.resume(returning: read)
    }
}

/// Runs main-actor operations one after another. An operation that had to
/// wait is dropped when its caller was cancelled meanwhile or `stillWanted`
/// says no, so queued work never acts on a decision that went stale.
@MainActor
final class SerialTaskQueue {
    private var tail: Task<Void, Never>?

    /// The operation's result, or nil when it did not run.
    func run<T: Sendable>(
        stillWanted: @escaping @MainActor () async -> Bool = { true },
        operation: @escaping @MainActor () async -> T
    ) async -> T? {
        let previous = tail
        let work = Task { @MainActor () -> T? in
            if let previous {
                await previous.value
                guard !Task.isCancelled, await stillWanted() else { return nil }
            }
            guard !Task.isCancelled else { return nil }
            return await operation()
        }
        tail = Task { @MainActor in _ = await work.value }
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }
}
