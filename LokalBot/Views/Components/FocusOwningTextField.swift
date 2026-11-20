import AppKit
import SwiftUI

final class FocusOwningTextField: NSTextField {
    private var focusRequestToken = 0

    func apply(layoutDirection: LayoutDirection) {
        let rightToLeft = layoutDirection == .rightToLeft
        userInterfaceLayoutDirection = rightToLeft ? .rightToLeft : .leftToRight
        alignment = rightToLeft ? .right : .left
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestFocus()
    }

    func requestFocus() {
        focusRequestToken &+= 1
        attemptFocus(token: focusRequestToken, attempt: 0)
    }

    private func attemptFocus(token: Int, attempt: Int) {
        let delay = attempt == 0 ? 0 : min(0.05 * Double(attempt), 0.2)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard token == focusRequestToken else { return }
            guard let window else {
                retryFocus(token: token, after: attempt)
                return
            }
            if let editor = currentEditor(),
               window.firstResponder === editor,
               NSApp.isActive,
               window.isKeyWindow {
                return
            }

            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            if window.canBecomeMain {
                window.makeMain()
            }

            guard NSApp.isActive, window.isKeyWindow else {
                retryFocus(token: token, after: attempt)
                return
            }
            guard window.makeFirstResponder(self) else {
                retryFocus(token: token, after: attempt)
                return
            }
            selectText(nil)
            uiTestDiagnosticLog(
                "text field focus acquired id=\(identifier?.rawValue ?? "unknown")")
        }
    }

    private func retryFocus(token: Int, after attempt: Int) {
        guard attempt < 6 else {
            uiTestDiagnosticLog(
                "text field focus failed id=\(identifier?.rawValue ?? "unknown")")
            return
        }
        attemptFocus(token: token, attempt: attempt + 1)
    }
}
