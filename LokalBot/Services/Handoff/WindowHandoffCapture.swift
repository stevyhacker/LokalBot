import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// What Hand off read from the focused window on one press: its whole text,
/// a screenshot when Screen Recording is allowed, and where it came from.
/// It lives in memory until the person hands it off or closes the panel.
struct WindowHandoffCapture: Equatable, Sendable {
    enum Issue: Equatable, Sendable {
        /// LokalBot lacks Accessibility access, so it cannot read the window.
        case accessibilityNeeded
        /// The app is on the exclusion list; nothing was read.
        case excludedApp
        /// The page, or a page framed in it, is on the site exclusion list,
        /// or its address could not be read while site exclusions are set.
        case excludedSite
        /// A password field is focused or visible; nothing was kept.
        case secureField
        /// The window could not be read, or focus moved while reading it.
        case unreadable
    }

    var source: SelectionSource?
    var windowTitle: String?
    var sourceURL: String?
    var documentName: String?
    /// The window's text in reading order, with credentials, card numbers,
    /// and IBANs redacted.
    var text = ""
    /// What was selected in the window, redacted the same way.
    var selection: String?
    /// A PNG of the window. Dropped when anything was redacted, because the
    /// pixels would still show it.
    var screenshot: Data?
    /// The text came from reading the screenshot, because the app shares
    /// little or no text through Accessibility.
    var textFromScreenshot = false
    var redactions = 0
    var capturedAt = Date()
    var issue: Issue?

    var hasContent: Bool { issue == nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Reads the focused window once, on an explicit Hand off press. The same
/// exclusions and secure-field checks as screen memory apply; the read is
/// never stored in screen memory.
@MainActor
enum WindowHandoffCapturer {
    /// Below this many characters of Accessibility text, the screenshot's
    /// text is read instead.
    static let thinTextCharacters = 200

    struct Dependencies {
        var source: @MainActor () -> SelectionSource?
        var isTrusted: @MainActor () -> Bool
        var readDocument: @MainActor (pid_t) async -> ScreenAccessibilitySnapshot?
        var readVisible: @MainActor (pid_t) async -> ScreenAccessibilityCaptureResult
        var frontmostProcessID: @MainActor () -> pid_t?
        var screenCaptureGranted: @MainActor () -> Bool
        var windows: @MainActor () async throws -> [ScreenshotCaptureLayout.Window]
        var captureImage: @MainActor (CGWindowID) async throws -> CGImage
        var recognizeText: @MainActor (CGImage) async -> String

        static var live: Self {
            let environment = CaptureEnvironment.current
            return Self(
                source: SelectionCapture.currentSource,
                isTrusted: { environment.accessibility.isTrusted() },
                readDocument: { processID in
                    await Task.detached(priority: .userInitiated) {
                        ScreenAccessibilityReader.resolve(processID: processID, scope: .document)
                    }.value
                },
                readVisible: { await ScreenAccessibilityReader.shared.capture(processID: $0) },
                frontmostProcessID: { environment.workspace.frontmostApplication()?.processIdentifier },
                screenCaptureGranted: { environment.windows.screenCaptureGranted() },
                windows: { try await environment.windows.onScreenWindows() },
                captureImage: { try await environment.windows.captureImage(windowID: $0) },
                recognizeText: { image in
                    await Task.detached(priority: .userInitiated) {
                        ScreenshotImageProcessing.recognizeText(in: image)
                    }.value
                })
        }
    }

    static func capture(excludedApps: [String], excludedDomains: [String],
                        dependencies: Dependencies = .live) async -> WindowHandoffCapture {
        guard let source = dependencies.source() else {
            return WindowHandoffCapture(issue: .unreadable)
        }
        var result = WindowHandoffCapture(source: source)
        guard !ScreenContextPrivacy.isExcluded(
            appName: source.appName, bundleIdentifier: source.bundleID, rules: excludedApps) else {
            result.issue = .excludedApp
            return result
        }
        guard dependencies.isTrusted() else {
            result.issue = .accessibilityNeeded
            return result
        }
        guard let snapshot = await dependencies.readDocument(source.processID) else {
            result.issue = .unreadable
            return result
        }
        result.windowTitle = snapshot.windowTitle
        result.sourceURL = ScreenContextPrivacy.sanitizedURL(snapshot.sourceURL)
        result.documentName = snapshot.documentName
        if let issue = issue(for: snapshot, source: source,
                             excludedApps: excludedApps, excludedDomains: excludedDomains) {
            result.issue = issue
            return result
        }

        let text = ScreenContextPrivacy.redact(snapshot.text)
        result.text = text.text
        result.redactions = text.count
        if let selected = snapshot.selectedText {
            let selection = ScreenContextPrivacy.redact(selected)
            result.selection = selection.text
            result.redactions += selection.count
        }

        if dependencies.screenCaptureGranted(),
           let image = await screenshot(of: snapshot, source: source, excludedApps: excludedApps,
                                        excludedDomains: excludedDomains, dependencies: dependencies) {
            if result.text.count < thinTextCharacters {
                let read = ScreenContextPrivacy.redact(await dependencies.recognizeText(image))
                if read.text.count > result.text.count {
                    result.text = read.text
                    result.redactions += read.count
                    result.textFromScreenshot = true
                }
            }
            if result.redactions == 0 { result.screenshot = pngData(image) }
        }
        return result
    }

    /// Why the window's content must not be read, or nil. Unlike screen
    /// memory, an unknown focus with no secure field in the window is fine:
    /// the person pressed the shortcut on purpose.
    static func issue(for snapshot: ScreenAccessibilitySnapshot, source: SelectionSource,
                      excludedApps: [String], excludedDomains: [String]) -> WindowHandoffCapture.Issue? {
        guard ScreenContextPrivacy.focusPermitsCapture(
            focusedSecureField: snapshot.focusedSecureField,
            containsSecureField: snapshot.containsSecureField) else { return .secureField }
        let observation = snapshot.privacyObservation(appName: source.appName, bundleIdentifier: source.bundleID)
        guard ScreenContextPrivacy.permitsContent(
            observation, excludedApps: excludedApps, excludedDomains: excludedDomains,
            allowsUnknownFocus: true) else {
            return snapshot.windowTitle == nil ? .unreadable : .excludedSite
        }
        return nil
    }

    /// The focused window's pixels, kept only when the same window is still
    /// focused afterwards and still passes the privacy checks.
    private static func screenshot(of snapshot: ScreenAccessibilitySnapshot, source: SelectionSource,
                                   excludedApps: [String], excludedDomains: [String],
                                   dependencies: Dependencies) async -> CGImage? {
        guard let title = snapshot.windowTitle,
              let windows = try? await dependencies.windows(),
              let layout = ScreenshotCaptureLayout.selection(
                windows: windows, frontmostProcessID: source.processID,
                focusedWindowTitle: title, focusedWindowFrame: snapshot.windowFrame,
                excludedApps: excludedApps),
              let image = try? await dependencies.captureImage(layout.windowID) else { return nil }
        let current = await dependencies.readVisible(source.processID)
        guard dependencies.frontmostProcessID() == source.processID,
              ScreenshotWindowFocusValidation.matches(expected: snapshot, current: current),
              let currentSnapshot = current.snapshot,
              issue(for: currentSnapshot, source: source,
                    excludedApps: excludedApps, excludedDomains: excludedDomains) == nil else { return nil }
        return image
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
