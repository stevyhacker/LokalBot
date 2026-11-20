import AppKit
import CoreGraphics

struct SelectionSource: Equatable, Sendable {
    let processID: pid_t
    let bundleID: String?
    let appName: String
}

struct SelectionCaptureResult: Equatable, Sendable {
    enum Issue: Equatable, Sendable {
        case accessibilityNeeded
        case excludedApp
        case secureField
        case focusChanged
    }

    var source: SelectionSource?
    var text = ""
    var target: DictationDeliveryTarget?
    var issue: Issue?
    var readThroughClipboard = false

    var hasSelection: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canInsert: Bool { target != nil && issue == nil }
    var isClipped: Bool { text.count > SelectionActionPrompt.selectionCharacterLimit }
}

@MainActor
enum SelectionCapture {
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
        guard dependencies.changeCount() != before else { return nil }
        let copiedGeneration = dependencies.changeCount()
        defer { if dependencies.changeCount() == copiedGeneration { restore() } }
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
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        CotypingSyntheticMarker.mark(down)
        CotypingSyntheticMarker.mark(up)
        down.postToPid(processID)
        up.postToPid(processID)
        return true
    }
}
