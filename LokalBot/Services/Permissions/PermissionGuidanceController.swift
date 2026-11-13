import AppKit
import Foundation

/// Owns the cross-app permission walkthrough while `PermissionManager` remains
/// the single source of truth for grant state.
@MainActor
final class PermissionGuidanceController {
    static let shared = PermissionGuidanceController(permissionManager: .shared)

    private let permissionManager: PermissionManager
    private let hostApp: PermissionHostApp

    private var overlayController: PermissionOverlayWindowController?
    private var trackingTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var activePermission: AppPermission?
    private var pendingSourceFrameInScreen: CGRect?
    private var hasPresentedOverlay = false
    private var isOverlayVisible = false
    private var lastSettingsFrame: CGRect?
    private var trackingStarted: Date?

    init(
        permissionManager: PermissionManager,
        hostApp: PermissionHostApp? = nil
    ) {
        self.permissionManager = permissionManager
        self.hostApp = hostApp ?? .current()
    }

    deinit {
        trackingTimer?.invalidate()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    /// Requests the native grant first, then adds Cotabby-style drag guidance
    /// only for privacy panes that accept an application bundle as a file URL.
    func requestAccess(for permission: AppPermission, sourceFrameInScreen: CGRect? = nil) {
        permissionManager.refresh()
        guard permissionManager.granted[permission] != true else { return }

        switch permission.guidanceStyle {
        case .nativePrompt:
            dismiss()
            if permission.requiresSettingsRecovery {
                permissionManager.openSettings(for: permission)
            } else {
                permissionManager.request(permission)
            }

        case .guidedOverlay:
            permissionManager.request(permission)
            permissionManager.refresh()
            guard permissionManager.granted[permission] != true else { return }
            presentGuidance(for: permission, sourceFrameInScreen: sourceFrameInScreen)
        }
    }

    func dismiss() {
        trackingTimer?.invalidate()
        trackingTimer = nil

        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }

        overlayController?.close()
        overlayController = nil
        activePermission = nil
        pendingSourceFrameInScreen = nil
        hasPresentedOverlay = false
        isOverlayVisible = false
        lastSettingsFrame = nil
        trackingStarted = nil
    }

    private func presentGuidance(
        for permission: AppPermission,
        sourceFrameInScreen: CGRect?
    ) {
        dismiss()
        permissionManager.refresh()
        guard permissionManager.granted[permission] != true else { return }

        activePermission = permission
        pendingSourceFrameInScreen = sourceFrameInScreen
        overlayController = PermissionOverlayWindowController(
            hostApp: hostApp,
            permission: permission,
            onDismiss: { [weak self] in self?.dismiss() })

        permissionManager.openSettings(for: permission)
        startTracking()
    }

    private func startTracking() {
        trackingTimer?.invalidate()
        trackingStarted = Date()
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.refreshPosition() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer

        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.refreshPosition() }
        }

        refreshPosition()
    }

    private func refreshPosition() {
        guard let activePermission else {
            dismiss()
            return
        }

        permissionManager.refresh()
        guard permissionManager.granted[activePermission] != true else {
            dismiss()
            return
        }

        // Callers that are not a view (a setting changed from the command
        // line) never dismiss, so the walkthrough has to end itself.
        if PermissionOverlayTracker.shouldEnd(
            settingsRunning: SystemSettingsWindowLocator.isRunning,
            hasPresented: hasPresentedOverlay,
            secondsTracked: trackingStarted.map { Date().timeIntervalSince($0) } ?? 0) {
            dismiss()
            return
        }

        let snapshot = SystemSettingsWindowLocator.frontmostWindow()
        switch PermissionOverlayTracker.transition(
            settingsFrame: snapshot?.frame,
            hasPresented: hasPresentedOverlay,
            isVisible: isOverlayVisible,
            lastFrame: lastSettingsFrame
        ) {
        case .present:
            guard let snapshot else { return }
            overlayController?.present(
                from: pendingSourceFrameInScreen,
                settingsFrame: snapshot.frame,
                visibleFrame: snapshot.visibleFrame)
            hasPresentedOverlay = true
            isOverlayVisible = true
            lastSettingsFrame = snapshot.frame

        case .reposition:
            guard let snapshot else { return }
            overlayController?.updatePosition(
                with: snapshot.frame,
                visibleFrame: snapshot.visibleFrame)
            isOverlayVisible = true
            lastSettingsFrame = snapshot.frame

        case .hide:
            overlayController?.hide()
            isOverlayVisible = false
            lastSettingsFrame = nil

        case .none:
            break
        }
    }
}
