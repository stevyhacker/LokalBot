// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

import CoreGraphics
import Foundation

/// How an observed keystroke relates to cotyping.
enum CotypingKeyKind: Equatable, Sendable {
    case acceptance    // plain Tab — consumed by the accept tap, reported for awareness
    case fullAcceptance // the full-accept key — consumed by the accept tap
    case dismissal     // Esc / Return / Enter
    case navigation    // arrow keys
    case shortcut      // any Command/Control-modified key
    case textMutation  // printable character, Backspace, or Forward Delete
    case other
}

struct CotypingInputEvent: Equatable, Sendable {
    var kind: CotypingKeyKind
    var characters: String
    /// Command-Z. Reported so an accept that is undone at once can be counted.
    var isUndo = false
    /// Plain Escape, which the accept tap may take while a suggestion shows.
    var isEscape = false

    /// A key that takes text back: Backspace, Forward Delete, or undo.
    var isCorrection: Bool {
        isUndo || (kind == .textMutation && characters.isEmpty)
    }
}

/// Global keyboard watcher for cotyping. Ported from Cotabby's `InputMonitor`:
///
///  • an always-on **observer** tap (`.listenOnly`, head-insert) that classifies
///    keystrokes so the coordinator can schedule/dismiss — it can never drop
///    events, so it cannot stall other apps; and
///  • an **accept** tap (`.defaultTap`, tail-append) installed only while a
///    suggestion is visible, which returns `nil` to swallow the accept key (Tab)
///    so it lands in the suggestion instead of moving focus.
///
/// Requires the Input Monitoring grant. Cotyping's own synthetic inserts are
/// tagged (`CotypingSyntheticMarker`) and skipped.
@MainActor
final class CotypingInputMonitor {
    /// Fired for every observed keyDown (not the accept key consumption itself).
    var onKey: ((CotypingInputEvent) -> Void)?
    /// Fired on every left mouse button press: a click may move focus or the
    /// caret. The event itself is not read.
    var onPointerDown: (() -> Void)?
    /// Invoked by the accept tap with the scope of the key that fired (next
    /// chunk vs whole). Returns `true` if it acted (key swallowed); else passthrough.
    var onAcceptKey: ((CotypingAcceptScope) -> Bool)?
    /// Invoked by the accept tap for plain Escape while a suggestion is
    /// visible. Returns `true` when the key was taken (swallowed).
    var onDismissKey: (() -> Bool)?
    /// Consulted at event time: should the accept tap even consider this key?
    var acceptGate: () -> Bool = { false }
    /// The configured accept keys, read live at event time.
    var acceptKeyCodeProvider: () -> CGKeyCode = { 48 }
    var fullAcceptKeyCodeProvider: () -> CGKeyCode? = { 50 }

    private var observerTap: CFMachPort?
    private var observerSource: CFRunLoopSource?
    private var acceptTap: CFMachPort?
    private var acceptSource: CFRunLoopSource?
    private var acceptTeardownWorkItem: DispatchWorkItem?
    private let suppressionController: CotypingInputSuppressionController

    private(set) var isRunning = false
    private(set) var isAcceptActive = false

    /// Keep the accepting tap alive briefly after a final accept. The inserter
    /// posts synthetic key events from inside the accept tap callback; invalidating
    /// the tap immediately can pull it from the event chain before those events
    /// drain into the host app.
    nonisolated static let acceptTapTeardownDelaySeconds: TimeInterval = 0.05

    init(suppressionController: CotypingInputSuppressionController = CotypingInputSuppressionController()) {
        self.suppressionController = suppressionController
    }

    /// Installs the listen-only observer tap. Returns false if the OS refuses
    /// (Input Monitoring not granted).
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: cotypingObserverCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        observerTap = tap
        observerSource = source
        isRunning = true
        return true
    }

    func stop() {
        acceptTeardownWorkItem?.cancel()
        acceptTeardownWorkItem = nil
        isAcceptActive = false
        teardown(tap: &acceptTap, source: &acceptSource)
        teardown(tap: &observerTap, source: &observerSource)
        isRunning = false
    }

    /// Installs/removes the consuming accept tap. The coordinator turns it on
    /// only while a suggestion is visible, so cotyping sits in the synchronous
    /// keystroke path for the briefest possible window.
    func setAcceptActive(_ active: Bool) {
        guard active != isAcceptActive else { return }
        if active {
            acceptTeardownWorkItem?.cancel()
            acceptTeardownWorkItem = nil
            if acceptTap != nil {
                isAcceptActive = true
                return
            }
            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: cotypingAcceptCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            acceptTap = tap
            acceptSource = source
            isAcceptActive = true
        } else {
            isAcceptActive = false
            acceptTeardownWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.isAcceptActive else { return }
                self.teardown(tap: &self.acceptTap, source: &self.acceptSource)
                self.acceptTeardownWorkItem = nil
            }
            acceptTeardownWorkItem = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.acceptTapTeardownDelaySeconds,
                execute: work)
        }
    }

    private func teardown(tap: inout CFMachPort?, source: inout CFRunLoopSource?) {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        source = nil
    }

    // MARK: - Callback bodies (always on the main run loop)

    fileprivate func handleObserver(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let observerTap { CGEvent.tapEnable(tap: observerTap, enable: true) }
            return
        }
        if type == .leftMouseDown {
            onPointerDown?()
            return
        }
        guard type == .keyDown else { return }
        if suppressionController.isSynthetic(event) {
            _ = suppressionController.consumeIfNeeded()
            return
        }
        if suppressionController.consumeIfNeeded() {
            return
        }
        onKey?(classify(event))
    }

    /// Returns `true` to swallow the key.
    fileprivate func handleAccept(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let acceptTap { CGEvent.tapEnable(tap: acceptTap, enable: true) }
            return false
        }
        guard type == .keyDown, !suppressionController.isSynthetic(event) else { return false }
        guard acceptGate() else { return false }
        if Self.isPlainEscape(event) { return onDismissKey?() ?? false }
        guard let scope = acceptScope(for: event) else { return false }
        return onAcceptKey?(scope) ?? false
    }

    // MARK: - Classification

    private func classify(_ event: CGEvent) -> CotypingInputEvent {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let plain = !flags.contains(.maskCommand) && !flags.contains(.maskControl)
            && !flags.contains(.maskAlternate) && !flags.contains(.maskShift)
        if plain {
            if keyCode == acceptKeyCodeProvider() {
                return CotypingInputEvent(kind: .acceptance, characters: "")
            }
            if let full = fullAcceptKeyCodeProvider(), keyCode == full {
                return CotypingInputEvent(kind: .fullAcceptance, characters: "")
            }
        }
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            // Matched by the character it produces, so it holds on any layout.
            let isUndo = flags.contains(.maskCommand) && !flags.contains(.maskControl)
                && !flags.contains(.maskAlternate) && !flags.contains(.maskShift)
                && Self.characters(from: event).lowercased() == "z"
            return CotypingInputEvent(kind: .shortcut, characters: "", isUndo: isUndo)
        }
        switch Int(keyCode) {
        case 53: return CotypingInputEvent(kind: .dismissal, characters: "", isEscape: plain)
        case 36, 76: return CotypingInputEvent(kind: .dismissal, characters: "")  // Return, Keypad Enter
        case 123, 124, 125, 126: return CotypingInputEvent(kind: .navigation, characters: "") // arrows
        case 51, 117: return CotypingInputEvent(kind: .textMutation, characters: "") // Backspace, Forward Delete
        default:
            let chars = Self.characters(from: event)
            if !chars.isEmpty, chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) {
                return CotypingInputEvent(kind: .textMutation, characters: chars)
            }
            return CotypingInputEvent(kind: .other, characters: chars)
        }
    }

    /// The accept scope for a plain (unmodified) keypress, or nil if it isn't an
    /// accept key. The primary key wins if both map to the same code.
    private func acceptScope(for event: CGEvent) -> CotypingAcceptScope? {
        let flags = event.flags
        guard !flags.contains(.maskCommand), !flags.contains(.maskControl),
              !flags.contains(.maskAlternate), !flags.contains(.maskShift) else { return nil }
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if keyCode == acceptKeyCodeProvider() { return .chunk }
        if let full = fullAcceptKeyCodeProvider(), keyCode == full { return .whole }
        return nil
    }

    private static func isPlainEscape(_ event: CGEvent) -> Bool {
        let flags = event.flags
        return event.getIntegerValueField(.keyboardEventKeycode) == 53
            && !flags.contains(.maskCommand) && !flags.contains(.maskControl)
            && !flags.contains(.maskAlternate) && !flags.contains(.maskShift)
    }

    static func characters(from event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(
            maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0 else { return "" }
        return String(utf16CodeUnits: buffer, count: min(length, buffer.count))
    }
}

// MARK: - C event-tap callbacks

private func cotypingObserverCallback(
    _ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let monitor = Unmanaged<CotypingInputMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        MainActor.assumeIsolated { monitor.handleObserver(type: type, event: event) }
    }
    return Unmanaged.passUnretained(event)
}

private func cotypingAcceptCallback(
    _ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<CotypingInputMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    let swallow = MainActor.assumeIsolated { monitor.handleAccept(type: type, event: event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
