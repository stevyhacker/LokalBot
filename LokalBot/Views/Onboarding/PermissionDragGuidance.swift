import AppKit
import Foundation
import QuartzCore
import SwiftUI

/// The installed app identity macOS expects as the drag payload.
struct PermissionHostApp {
    let displayName: String
    let bundleURL: URL
    let icon: NSImage

    static func current(bundle: Bundle = .main) -> PermissionHostApp {
        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String
            ?? bundle.bundleURL.deletingPathExtension().lastPathComponent
        let icon = NSWorkspace.shared.icon(forFile: bundle.bundleURL.path)
        icon.size = NSSize(width: 48, height: 48)
        return PermissionHostApp(
            displayName: displayName,
            bundleURL: bundle.bundleURL,
            icon: icon)
    }
}

/// Reports a SwiftUI control's global frame to the AppKit overlay controller.
struct PermissionScreenFrameReader: NSViewRepresentable {
    @Binding var frameInScreen: CGRect

    func makeNSView(context: Context) -> PermissionScreenFrameTrackingView {
        let view = PermissionScreenFrameTrackingView()
        view.onFrameChange = { frameInScreen = $0 }
        return view
    }

    func updateNSView(_ nsView: PermissionScreenFrameTrackingView, context: Context) {
        nsView.onFrameChange = { frameInScreen = $0 }
        nsView.reportFrame()
    }
}

final class PermissionScreenFrameTrackingView: NSView {
    var onFrameChange: ((CGRect) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportFrame()
    }

    override func layout() {
        super.layout()
        reportFrame()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        reportFrame()
    }

    func reportFrame() {
        guard let window else { return }
        let frame = window.convertToScreen(convert(bounds, to: nil))
        DispatchQueue.main.async { [onFrameChange] in onFrameChange?(frame) }
    }
}

/// Native file-URL drag source accepted by System Settings privacy lists.
final class PermissionDragSourceView: NSView, NSDraggingSource {
    private let hostApp: PermissionHostApp
    private let rowView = NSView()
    private let iconChrome = NSView()
    private let titleLabel = NSTextField(labelWithString: "")

    init(hostApp: PermissionHostApp) {
        self.hostApp = hostApp
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // NSURL supplies every native file-URL pasteboard representation that
        // System Settings expects for a real application bundle.
        let item = NSDraggingItem(pasteboardWriter: hostApp.bundleURL as NSURL)
        item.setDraggingFrame(draggingFrame(), contents: draggingImage())
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        rowView.isHidden = true
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        rowView.isHidden = false
    }

    private func setup() {
        wantsLayer = true

        rowView.wantsLayer = true
        rowView.layer?.cornerRadius = 7
        rowView.layer?.borderWidth = 1
        rowView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowView)

        iconChrome.wantsLayer = true
        iconChrome.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        iconChrome.layer?.cornerRadius = 6
        iconChrome.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(iconChrome)

        let iconView = NSImageView(image: hostApp.icon)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconChrome.addSubview(iconView)

        titleLabel.stringValue = hostApp.displayName
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = NSColor.labelColor.withAlphaComponent(0.82)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            rowView.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowView.topAnchor.constraint(equalTo: topAnchor),
            rowView.bottomAnchor.constraint(equalTo: bottomAnchor),
            rowView.heightAnchor.constraint(equalToConstant: 43),

            iconChrome.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: 10),
            iconChrome.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            iconChrome.widthAnchor.constraint(equalToConstant: 26),
            iconChrome.heightAnchor.constraint(equalToConstant: 26),

            iconView.centerXAnchor.constraint(equalTo: iconChrome.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconChrome.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            titleLabel.leadingAnchor.constraint(equalTo: iconChrome.trailingAnchor, constant: 11),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: rowView.trailingAnchor,
                constant: -12),
            titleLabel.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
        ])
    }

    private func updateAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            rowView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            rowView.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        } else {
            rowView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.65).cgColor
            rowView.layer?.borderColor = NSColor(
                red: 0.87451,
                green: 0.866667,
                blue: 0.862745,
                alpha: 1).cgColor
        }
    }

    private func draggingFrame() -> NSRect {
        convert(rowView.bounds, from: rowView)
    }

    private func draggingImage() -> NSImage {
        let image = NSImage(size: rowView.bounds.size)
        image.lockFocus()
        if let context = NSGraphicsContext.current {
            rowView.displayIgnoringOpacity(rowView.bounds, in: context)
        }
        image.unlockFocus()
        return image
    }
}

/// Non-activating helper panel that flies from the pressed Allow button into
/// System Settings and follows that window while it is open.
final class PermissionOverlayWindowController: NSWindowController {
    private let windowSize = NSSize(width: 540, height: 112)
    private let launchAnimationDuration: TimeInterval = 0.72
    private let launchAnimationResponse: Double = 0.72
    private let initialAlpha: CGFloat = 0.9

    private var launchDisplayLink: CADisplayLink?
    private var launchStartTime: CFTimeInterval = 0
    private var launchFromFrame = NSRect.zero
    private var launchToFrame = NSRect.zero
    private var isAnimatingLaunch = false

    init(
        hostApp: PermissionHostApp,
        permission: AppPermission,
        onDismiss: @escaping () -> Void
    ) {
        let window = PermissionOverlayPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        super.init(window: window)
        configureWindow(window)
        window.contentView = PermissionOverlayContentView(
            hostApp: hostApp,
            permission: permission,
            onDismiss: onDismiss)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func close() {
        stopLaunchAnimation()
        window?.orderOut(nil)
        super.close()
    }

    func present(from source: CGRect?, settingsFrame: CGRect, visibleFrame: CGRect) {
        stopLaunchAnimation()
        guard let window else { return }

        let target = NSRect(
            origin: anchoredOrigin(for: settingsFrame, visibleFrame: visibleFrame),
            size: windowSize)
        guard let source, !source.isEmpty else {
            isAnimatingLaunch = false
            window.alphaValue = 1
            window.setFrame(target, display: false)
            window.orderFrontRegardless()
            return
        }

        isAnimatingLaunch = true
        launchFromFrame = source
        launchToFrame = target
        launchStartTime = CACurrentMediaTime()
        window.alphaValue = initialAlpha
        window.setFrame(source, display: false)
        window.orderFrontRegardless()
        stepLaunchAnimation()

        let displayLink = window.displayLink(
            target: self,
            selector: #selector(displayLinkDidFire(_:)))
        displayLink.add(to: .main, forMode: .common)
        launchDisplayLink = displayLink
    }

    func updatePosition(with settingsFrame: CGRect, visibleFrame: CGRect) {
        guard let window else { return }
        let origin = anchoredOrigin(for: settingsFrame, visibleFrame: visibleFrame)
        launchToFrame.origin = origin
        guard !isAnimatingLaunch else { return }
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()
    }

    func hide() {
        isAnimatingLaunch = false
        stopLaunchAnimation()
        window?.orderOut(nil)
    }

    private func configureWindow(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]
        window.animationBehavior = .none
    }

    private func stepLaunchAnimation() {
        guard let window else {
            stopLaunchAnimation()
            return
        }

        let elapsed = max(0, CACurrentMediaTime() - launchStartTime)
        guard elapsed < launchAnimationDuration else {
            isAnimatingLaunch = false
            stopLaunchAnimation()
            window.alphaValue = 1
            window.setFrame(launchToFrame, display: true)
            return
        }

        let progress = springProgress(at: elapsed)
        window.alphaValue = initialAlpha + ((1 - initialAlpha) * progress)
        window.setFrame(
            curvedFrame(from: launchFromFrame, to: launchToFrame, progress: progress),
            display: true)
    }

    @objc private func displayLinkDidFire(_ displayLink: CADisplayLink) {
        stepLaunchAnimation()
    }

    private func stopLaunchAnimation() {
        launchDisplayLink?.invalidate()
        launchDisplayLink = nil
    }

    private func springProgress(at elapsed: TimeInterval) -> CGFloat {
        let omega = (2 * Double.pi) / launchAnimationResponse
        let progress = 1 - exp(-omega * max(0, elapsed)) * (1 + (omega * max(0, elapsed)))
        return min(max(progress, 0), 1)
    }

    private func curvedFrame(from: NSRect, to: NSRect, progress: CGFloat) -> NSRect {
        let size = NSSize(
            width: from.width + ((to.width - from.width) * progress),
            height: from.height + ((to.height - from.height) * progress))
        let start = CGPoint(x: from.midX, y: from.midY)
        let end = CGPoint(x: to.midX, y: to.midY)
        let distance = hypot(end.x - start.x, end.y - start.y)
        let control = CGPoint(
            x: (start.x + end.x) * 0.5,
            y: max(start.y, end.y) + min(140, max(44, distance * 0.18)))
        let inverse = 1 - progress
        let center = CGPoint(
            x: (inverse * inverse * start.x)
                + (2 * inverse * progress * control.x)
                + (progress * progress * end.x),
            y: (inverse * inverse * start.y)
                + (2 * inverse * progress * control.y)
                + (progress * progress * end.y))

        return NSRect(
            x: center.x - (size.width * 0.5),
            y: center.y - (size.height * 0.5),
            width: size.width,
            height: size.height)
    }

    private func anchoredOrigin(for settingsFrame: CGRect, visibleFrame: CGRect) -> NSPoint {
        let sidebarWidth: CGFloat = 170
        let contentMinX = settingsFrame.minX + sidebarWidth
        let contentWidth = max(settingsFrame.width - sidebarWidth, windowSize.width)
        let preferredX = contentMinX + ((contentWidth - windowSize.width) / 2) - 8
        let preferredY = settingsFrame.minY + 14
        return NSPoint(
            x: min(
                max(preferredX, visibleFrame.minX + 8),
                visibleFrame.maxX - windowSize.width - 8),
            y: min(
                max(preferredY, visibleFrame.minY + 8),
                visibleFrame.maxY - windowSize.height - 8))
    }
}

private final class PermissionOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PermissionOverlayContentView: NSView {
    private let onDismiss: () -> Void

    init(
        hostApp: PermissionHostApp,
        permission: AppPermission,
        onDismiss: @escaping () -> Void
    ) {
        self.onDismiss = onDismiss
        super.init(frame: NSRect(x: 0, y: 0, width: 540, height: 112))
        translatesAutoresizingMaskIntoConstraints = false
        setup(hostApp: hostApp, permission: permission)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(hostApp: PermissionHostApp, permission: AppPermission) {
        let materialView = NSVisualEffectView()
        materialView.translatesAutoresizingMaskIntoConstraints = false
        materialView.material = .popover
        materialView.blendingMode = .behindWindow
        materialView.state = .active
        materialView.wantsLayer = true
        materialView.layer?.cornerRadius = 18
        materialView.layer?.masksToBounds = true
        materialView.layer?.borderWidth = 0.5
        materialView.layer?.borderColor = NSColor.separatorColor
            .withAlphaComponent(0.18).cgColor
        addSubview(materialView)

        let tintView = NSView()
        tintView.translatesAutoresizingMaskIntoConstraints = false
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = NSColor.windowBackgroundColor
            .withAlphaComponent(0.78).cgColor
        materialView.addSubview(tintView)

        let dismissChrome = NSView()
        dismissChrome.translatesAutoresizingMaskIntoConstraints = false
        dismissChrome.wantsLayer = true
        dismissChrome.layer?.backgroundColor = NSColor.controlBackgroundColor
            .withAlphaComponent(0.95).cgColor
        dismissChrome.layer?.cornerRadius = 16
        materialView.addSubview(dismissChrome)

        let dismissButton = NSButton()
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.isBordered = false
        dismissButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Dismiss")
        dismissButton.contentTintColor = NSColor.labelColor.withAlphaComponent(0.72)
        dismissButton.target = self
        dismissButton.action = #selector(dismissPressed)
        (dismissButton.cell as? NSButtonCell)?.imagePosition = .imageOnly
        dismissChrome.addSubview(dismissButton)

        let arrowView = NSImageView()
        arrowView.translatesAutoresizingMaskIntoConstraints = false
        arrowView.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)
        arrowView.symbolConfiguration = .init(pointSize: 28, weight: .bold)
        arrowView.contentTintColor = NSColor(
            calibratedRed: 0.075,
            green: 0.522,
            blue: 0.455,
            alpha: 1)
        materialView.addSubview(arrowView)

        let titleLabel = NSTextField(labelWithString:
            "Drag \(hostApp.displayName) to the list above to allow \(permission.title)")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = NSColor.labelColor.withAlphaComponent(0.82)
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        materialView.addSubview(titleLabel)

        let dragSource = PermissionDragSourceView(hostApp: hostApp)
        materialView.addSubview(dragSource)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 540),
            heightAnchor.constraint(equalToConstant: 112),

            materialView.leadingAnchor.constraint(equalTo: leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: trailingAnchor),
            materialView.topAnchor.constraint(equalTo: topAnchor),
            materialView.bottomAnchor.constraint(equalTo: bottomAnchor),

            tintView.leadingAnchor.constraint(equalTo: materialView.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: materialView.trailingAnchor),
            tintView.topAnchor.constraint(equalTo: materialView.topAnchor),
            tintView.bottomAnchor.constraint(equalTo: materialView.bottomAnchor),

            dismissChrome.leadingAnchor.constraint(
                equalTo: materialView.leadingAnchor,
                constant: 18),
            dismissChrome.topAnchor.constraint(equalTo: materialView.topAnchor, constant: 52),
            dismissChrome.widthAnchor.constraint(equalToConstant: 32),
            dismissChrome.heightAnchor.constraint(equalToConstant: 32),

            dismissButton.centerXAnchor.constraint(equalTo: dismissChrome.centerXAnchor),
            dismissButton.centerYAnchor.constraint(equalTo: dismissChrome.centerYAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: 14),
            dismissButton.heightAnchor.constraint(equalToConstant: 14),

            arrowView.leadingAnchor.constraint(equalTo: materialView.leadingAnchor, constant: 35),
            arrowView.topAnchor.constraint(equalTo: materialView.topAnchor, constant: 10),
            arrowView.widthAnchor.constraint(equalToConstant: 28),
            arrowView.heightAnchor.constraint(equalToConstant: 28),

            titleLabel.leadingAnchor.constraint(equalTo: arrowView.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: arrowView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: materialView.trailingAnchor, constant: -22),

            dragSource.leadingAnchor.constraint(equalTo: materialView.leadingAnchor, constant: 64),
            dragSource.trailingAnchor.constraint(equalTo: materialView.trailingAnchor, constant: -21),
            dragSource.topAnchor.constraint(equalTo: materialView.topAnchor, constant: 47),
            dragSource.heightAnchor.constraint(equalToConstant: 43),
        ])
    }

    @objc private func dismissPressed() {
        onDismiss()
    }
}
