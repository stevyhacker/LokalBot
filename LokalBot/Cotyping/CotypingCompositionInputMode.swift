import Carbon.HIToolbox
import Foundation

enum CotypingCompositionInputModeClassifier {
    static let nonComposingInputModeIDs: Set<String> = [
        "com.apple.inputmethod.Roman"
    ]

    static func isComposingInputMode(isKeyboardLayout: Bool?, inputModeID: String?) -> Bool {
        if isKeyboardLayout == true {
            return false
        }
        if let inputModeID, nonComposingInputModeIDs.contains(inputModeID) {
            return false
        }
        return true
    }
}

@MainActor
final class CotypingKeyboardInputSourceMonitor {
    private(set) var isComposingIMEActive = false

    private var observer: NSObjectProtocol?

    init() {
        refresh()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.selectedInputSourceChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    private static let selectedInputSourceChangedNotification = Notification.Name(
        kTISNotifySelectedKeyboardInputSourceChanged as String
    )

    func refresh() {
        guard let unmanagedSource = TISCopyCurrentKeyboardInputSource() else {
            isComposingIMEActive = true
            return
        }
        let source = unmanagedSource.takeRetainedValue()
        let inputSourceType = Self.stringProperty(source, kTISPropertyInputSourceType)
        let isKeyboardLayout = inputSourceType.map { $0 == (kTISTypeKeyboardLayout as String) }
        let inputModeID = Self.stringProperty(source, kTISPropertyInputModeID)
        isComposingIMEActive = CotypingCompositionInputModeClassifier.isComposingInputMode(
            isKeyboardLayout: isKeyboardLayout,
            inputModeID: inputModeID)
    }

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}
