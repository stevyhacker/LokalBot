import SwiftUI
import UIKit

/// Shows the lock cover above everything each of the app's windows presents.
/// The cover in a window's own view tree lies under that window's sheets, the
/// recording screen, alerts and menus, which would stay readable while the app
/// is locked and in the app switcher. This one sits in a window of its own,
/// above all of them.
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

    /// iOS shows a window in the app switcher from here on, and takes its
    /// picture once it's in the background, so the cover goes up before this
    /// returns instead of waiting for the next view update.
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

    /// With App Lock on, covers every window while the app is locked or none
    /// of its windows is in use, and any window that is in the background.
    /// "In use" is read from the windows themselves as well as from `AppLock`,
    /// whose own state arrives with the next view update. A window named here
    /// is changing state and doesn't report it yet: `leaving` is about to stop
    /// being active, `entering` is coming to the foreground and `active` has
    /// just become active.
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
                // A keyboard left up would float above the cover and still type into the page under it.
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
        // VoiceOver reads this window and nothing under it.
        window.accessibilityViewIsModal = true
        covers[ObjectIdentifier(scene)] = window
        return window
    }
}
