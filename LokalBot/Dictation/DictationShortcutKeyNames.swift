import Carbon.HIToolbox
import CoreGraphics
import Foundation

enum DictationShortcutKeyNames {
    static let escape = CGKeyCode(kVK_Escape)

    private static let named: [CGKeyCode: String] = [
        CGKeyCode(kVK_Space): "Space",
        CGKeyCode(kVK_Return): "Return",
        CGKeyCode(kVK_ANSI_KeypadEnter): "Enter",
        CGKeyCode(kVK_Tab): "Tab",
        CGKeyCode(kVK_Delete): "Delete",
        CGKeyCode(kVK_ForwardDelete): "Forward Delete",
        CGKeyCode(kVK_Escape): "Esc",
        CGKeyCode(kVK_LeftArrow): "←",
        CGKeyCode(kVK_RightArrow): "→",
        CGKeyCode(kVK_DownArrow): "↓",
        CGKeyCode(kVK_UpArrow): "↑",
        CGKeyCode(kVK_Home): "Home",
        CGKeyCode(kVK_End): "End",
        CGKeyCode(kVK_PageUp): "Page Up",
        CGKeyCode(kVK_PageDown): "Page Down",
        CGKeyCode(kVK_Help): "Help",
    ]

    private static let functionKeys: [CGKeyCode: String] = [
        CGKeyCode(kVK_F1): "F1", CGKeyCode(kVK_F2): "F2", CGKeyCode(kVK_F3): "F3",
        CGKeyCode(kVK_F4): "F4", CGKeyCode(kVK_F5): "F5", CGKeyCode(kVK_F6): "F6",
        CGKeyCode(kVK_F7): "F7", CGKeyCode(kVK_F8): "F8", CGKeyCode(kVK_F9): "F9",
        CGKeyCode(kVK_F10): "F10", CGKeyCode(kVK_F11): "F11", CGKeyCode(kVK_F12): "F12",
        CGKeyCode(kVK_F13): "F13", CGKeyCode(kVK_F14): "F14", CGKeyCode(kVK_F15): "F15",
        CGKeyCode(kVK_F16): "F16", CGKeyCode(kVK_F17): "F17", CGKeyCode(kVK_F18): "F18",
        CGKeyCode(kVK_F19): "F19", CGKeyCode(kVK_F20): "F20",
    ]

    static func isFunctionKey(_ keyCode: CGKeyCode) -> Bool {
        functionKeys[keyCode] != nil
    }

    static func isNamedKey(_ keyCode: CGKeyCode) -> Bool {
        named[keyCode] != nil || functionKeys[keyCode] != nil
    }

    static func name(for keyCode: CGKeyCode) -> String {
        if let name = named[keyCode] ?? functionKeys[keyCode] { return name }
        if let character = layoutCharacter(for: keyCode) { return character }
        return "Key \(keyCode)"
    }

    private static func layoutCharacter(for keyCode: CGKeyCode) -> String? {
        let sources = [
            TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
        ].compactMap { $0 }
        guard let property = sources.lazy.compactMap({
            TISGetInputSourceProperty($0, kTISPropertyUnicodeKeyLayoutData)
        }).first else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState,
                characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return text.isEmpty ? nil : text.uppercased()
    }
}
