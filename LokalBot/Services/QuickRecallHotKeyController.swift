import Carbon.HIToolbox
import Foundation

/// Registers one of LokalBot's opt-in, system-wide shortcuts (Ask, selection
/// actions) without an event tap. Carbon hot keys work while another app is
/// focused and do not read or retain any other keyboard input.
@MainActor
final class QuickRecallHotKeyController {
    /// Each controller registers under its own identifier, so several can be
    /// active at once and each handler ignores the others' presses.
    nonisolated static let askIdentifier: UInt32 = 1
    nonisolated static let selectionActionsIdentifier: UInt32 = 2

    var onInvoke: (() -> Void)?

    /// True while Settings records a new shortcut, so the current one reaches
    /// the recorder instead of opening Ask.
    var isSuspended = false {
        didSet { if isSuspended != oldValue { sync() } }
    }

    private static let signature: OSType = 0x4C425152 // "LBQR"
    private let identifier: UInt32

    /// The shortcut Ask should answer to, or nil when it is off.
    private var shortcut: DictationShortcut?
    /// The shortcut `hotKey` was registered with.
    private(set) var registeredShortcut: DictationShortcut?
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    init(identifier: UInt32 = QuickRecallHotKeyController.askIdentifier) {
        self.identifier = identifier
    }

    /// Registers `shortcut`, replacing the previous one, or unregisters for
    /// nil. Returns false when the system refuses the combination; Ask then
    /// has no shortcut until a later call succeeds.
    @discardableResult
    func setShortcut(_ shortcut: DictationShortcut?) -> Bool {
        self.shortcut = shortcut
        return sync()
    }

    @discardableResult
    private func sync() -> Bool {
        let wanted = isSuspended ? nil : shortcut
        guard wanted != registeredShortcut else { return true }
        unregister()
        guard let wanted else { return true }
        guard let keyCode = wanted.keyCode, installHandlerIfNeeded() else { return false }

        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(
            signature: Self.signature,
            id: identifier)
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            Self.carbonModifiers(wanted.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference)
        guard status == noErr else { return false }
        hotKey = reference
        registeredShortcut = wanted
        return true
    }

    /// Why `candidate` cannot be a system-wide shortcut, or nil. Pass the
    /// other global shortcuts that are not being edited.
    static func problem(
        for candidate: DictationShortcut,
        dictationShortcut: DictationShortcut,
        askShortcut: DictationShortcut? = nil,
        selectionActionsShortcut: DictationShortcut? = nil
    ) -> DictationShortcut.Problem? {
        if let problem = candidate.quickRecallProblem { return problem }
        if candidate == dictationShortcut { return .usedByDictation }
        if candidate == askShortcut { return .usedByAsk }
        if candidate == selectionActionsShortcut { return .usedBySelectionActions }
        if isSystemShortcut(candidate) { return .usedBySystem }
        return nil
    }

    /// Enabled macOS keyboard shortcuts, such as ⌘ Space for Spotlight, take
    /// the keys before a hot key registered here would see them.
    static func isSystemShortcut(_ shortcut: DictationShortcut) -> Bool {
        guard let keyCode = shortcut.keyCode else { return false }
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let hotKeys = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return false }
        let relevantModifiers = controlKey | optionKey | shiftKey | cmdKey
        let modifiers = Int(carbonModifiers(shortcut.modifiers))
        return hotKeys.contains { hotKey in
            guard (hotKey[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = hotKey[kHISymbolicHotKeyCode as String] as? Int,
                  let systemModifiers = hotKey[kHISymbolicHotKeyModifiers as String] as? Int else {
                return false
            }
            return code == Int(keyCode) && systemModifiers & relevantModifiers == modifiers
        }
    }

    nonisolated static func carbonModifiers(_ modifiers: CGEventFlags) -> UInt32 {
        var result = 0
        if modifiers.contains(.maskControl) { result |= controlKey }
        if modifiers.contains(.maskAlternate) { result |= optionKey }
        if modifiers.contains(.maskShift) { result |= shiftKey }
        if modifiers.contains(.maskCommand) { result |= cmdKey }
        return UInt32(result)
    }

    func stop() {
        shortcut = nil
        unregister()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    fileprivate func invokeIfMatching(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        var actualSize = 0
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            &actualSize,
            &hotKeyID)
        guard status == noErr,
              hotKeyID.signature == Self.signature,
              hotKeyID.id == identifier else {
            return OSStatus(eventNotHandledErr)
        }
        onInvoke?()
        return noErr
    }

    private func installHandlerIfNeeded() -> Bool {
        guard eventHandler == nil else { return true }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            quickRecallHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler)
        guard status == noErr else { return false }
        eventHandler = handler
        return true
    }

    private func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        registeredShortcut = nil
    }
}

private func quickRecallHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    let controller = Unmanaged<QuickRecallHotKeyController>
        .fromOpaque(userData)
        .takeUnretainedValue()
    return MainActor.assumeIsolated {
        controller.invokeIfMatching(event)
    }
}
