import SwiftUI
import UIKit

@MainActor
final class LockCoverWindows: NSObject {
    private weak var appLock: AppLock?
    private var covers: [ObjectIdentifier: UIWindow] = [:]

    func attach(to appLock: AppLock) {
        self.appLock = appLock
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(sceneWillDeactivate), name: UIScene.willDeactivateNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneDidEnterBackground), name: UIScene.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneWillEnterForeground), name: UIScene.willEnterForegroundNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneDidActivate), name: UIScene.didActivateNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneDidDisconnect), name: UIScene.didDisconnectNotification, object: nil)
    }

    @objc private func sceneWillDeactivate(_ notification: Notification) {
        refresh(leaving: notification.object as? UIScene)
    }

    @objc private func sceneDidEnterBackground(_ notification: Notification) {
        refresh()
    }

    @objc private func sceneWillEnterForeground(_ notification: Notification) {
        refresh(entering: notification.object as? UIScene)
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        refresh(active: notification.object as? UIScene)
    }

    @objc private func sceneDidDisconnect(_ notification: Notification) {
        guard let scene = notification.object as? UIScene else { return }
        covers.removeValue(forKey: ObjectIdentifier(scene))?.isHidden = true
    }

    func refresh(leaving: UIScene? = nil, entering: UIScene? = nil, active: UIScene? = nil) {
        guard let appLock, appLock.isEnabled else {
            covers.values.forEach { $0.isHidden = true }
            covers = [:]
            return
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let inUse = active != nil || scenes.contains { $0 !== leaving && $0.activationState == .foregroundActive }
        for scene in scenes {
            let inBackground = scene.activationState == .background && scene !== entering && scene !== active
            if appLock.isLocked || appLock.isObscured || !inUse || inBackground {
                if appLock.isLocked { scene.windows.forEach { $0.endEditing(true) } }
                cover(for: scene, appLock: appLock).isHidden = false
            } else {
                covers[ObjectIdentifier(scene)]?.isHidden = true
            }
        }
    }

    private func cover(for scene: UIWindowScene, appLock: AppLock) -> UIWindow {
        if let window = covers[ObjectIdentifier(scene)] { return window }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: LockCover().environment(appLock).brandTinted())
        window.accessibilityViewIsModal = true
        covers[ObjectIdentifier(scene)] = window
        return window
    }
}
