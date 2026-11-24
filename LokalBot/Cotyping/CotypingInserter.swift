// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum CotypingSyntheticMarker {
    private static let legacyStaticMarker: Int64 = 0x4C6F_6B61_6C

    static let userData: Int64 = generateMarker()

    private static func generateMarker() -> Int64 {
        while true {
            let candidate = Int64.random(in: 1...Int64.max)
            if candidate != legacyStaticMarker { return candidate }
        }
    }

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

@MainActor
final class CotypingInserter {
    typealias PasteboardItemSnapshot = [(type: NSPasteboard.PasteboardType, data: Data)]

    private var pendingPasteboardRestore: DispatchWorkItem?
    private var savedClipboardForRestore: [PasteboardItemSnapshot]?
    private var activeHandoff: DictationPasteboardHandoff?
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
        case pasted
        case unconfirmed
        case failed
        case skipped
    }

    nonisolated static let pasteReadTimeout: Duration = .milliseconds(1_500)

    func insertViaPaste(
        _ text: String,
        fitToField: (@MainActor (String) async -> String)? = nil,
        revalidateAfterWaiting: @escaping @MainActor () async -> Bool = { true }
    ) async -> PasteOutcome {
        await pasteQueue.run(stillWanted: revalidateAfterWaiting) { [weak self] in
            guard let self else { return .failed }
            let fitted = await fitToField?(text) ?? text
            guard !Task.isCancelled else { return .skipped }
            return await self.pasteAndConfirm(fitted, clipboardText: text)
        } ?? .skipped
    }

    private func pasteAndConfirm(_ text: String, clipboardText: String? = nil) async -> PasteOutcome {
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
                pasteboard.setString((clipboardText ?? text).replacingOccurrences(of: "\r", with: ""), forType: .string)
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
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        suppressionController.registerSyntheticInsertion(expectedKeyDownCount: 1)
        suppressionController.markSynthetic(vDown)
        suppressionController.markSynthetic(vUp)
        vDown.post(tap: .cgAnnotatedSessionEventTap)
        vUp.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

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
        saved: [PasteboardItemSnapshot],
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

    private static let pasteboardRestoreDelay: TimeInterval = 0.3

    private func clearPendingPasteboardRestore() {
        pendingPasteboardRestore = nil
        savedClipboardForRestore = nil
        activeHandoff = nil
    }

    static func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [PasteboardItemSnapshot] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var reps: PasteboardItemSnapshot = []
            for type in item.types {
                if let data = item.data(forType: type) { reps.append((type: type, data: data)) }
            }
            return reps
        }
    }

    static func restorePasteboard(_ saved: [PasteboardItemSnapshot], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard let items = restoredItems(saved) else { return }
        pasteboard.writeObjects(items)
    }

    static func restoredItems(_ saved: [PasteboardItemSnapshot]) -> [NSPasteboardItem]? {
        guard !saved.isEmpty,
              !saved.contains(where: { snapshot in
                  snapshot.contains { $0.type == DictationPasteboardHandoff.concealedType }
              }) else { return nil }
        return saved.map { snapshot -> NSPasteboardItem in
            let item = NSPasteboardItem()
            var hasAutoGenerated = false
            for entry in snapshot {
                item.setData(entry.data, forType: entry.type)
                if entry.type == DictationPasteboardHandoff.autoGeneratedType {
                    hasAutoGenerated = true
                }
            }
            if !hasAutoGenerated {
                item.setData(Data(), forType: DictationPasteboardHandoff.autoGeneratedType)
            }
            return item
        }
    }
}

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

@MainActor
final class SerialTaskQueue {
    private var tail: Task<Void, Never>?

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
