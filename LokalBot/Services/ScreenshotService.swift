import Foundation
import AppKit
import ImageIO
import ScreenCaptureKit
import Vision
import CryptoKit

/// Plain-line diagnostics, now routed through swift-log (`AppLog`) which fans
/// out to stdout + the rotating `<storage>/debug.log`. Kept as a free function
/// so every existing call site stays unchanged.
func lokalbotLog(_ message: String) {
    AppLog.line(message)
}

/// What caused a screen context capture. Raw values are stored in the
/// `screenshots.capture_trigger` column and shown to search/chat consumers.
enum ScreenCaptureTrigger: String {
    /// User switched to a different application (sampler boundary).
    case appSwitch = "app_switch"
    /// Window/tab/title changed inside the same application.
    case windowChange = "window_change"
    /// A click completed; coordinates and button identity are never retained.
    case click
    /// Typing stopped briefly; no key code or typed string is observed here.
    case typingPause = "typing_pause"
    /// Scrolling settled; deltas and pointer position are not retained.
    case scrollSettled = "scroll_settled"
    /// The pasteboard generation changed; clipboard contents are never read.
    case clipboardChange = "clipboard_change"
    /// Idle fallback: nothing captured for the configured interval.
    case interval
    /// Explicit "Capture now" from the menu bar.
    case manual
}

/// A fully decoded, size-bounded image that can safely cross back from the
/// detached thumbnail worker. CGImage is immutable, but older SDK annotations
/// do not consistently mark it Sendable.
struct ScreenThumbnailImage: @unchecked Sendable {
    let image: CGImage

    var byteCost: Int {
        max(1, image.bytesPerRow * image.height)
    }
}

/// Pure rate-limiting policy for event-driven capture. Event triggers respect
/// a short cooldown so interaction bursts cannot spam extraction; the interval
/// trigger fires only after the user-configured idle window; manual always wins.
struct ScreenCapturePolicy {
    /// Minimum seconds between event-driven captures.
    var eventCooldown: TimeInterval
    /// When a capture (or dedup-confirmed unchanged screen) was last recorded.
    private(set) var lastCheck: Date?

    init(eventCooldown: TimeInterval = 20) {
        self.eventCooldown = eventCooldown
    }

    func shouldCapture(trigger: ScreenCaptureTrigger, idleInterval: TimeInterval,
                       now: Date = Date()) -> Bool {
        guard let last = lastCheck else { return true }
        switch trigger {
        case .manual:
            return true
        case .appSwitch, .windowChange, .click, .typingPause, .scrollSettled,
             .clipboardChange:
            return now.timeIntervalSince(last) >= eventCooldown
        case .interval:
            return now.timeIntervalSince(last) >= idleInterval
        }
    }

    mutating func noteCheck(at now: Date = Date()) { lastCheck = now }
}

/// Bounds retention work to once per day during normal operation while still
/// allowing explicit privacy changes to force an immediate pass. Keeping this
/// policy pure makes sleep/wake and clock-adjustment behavior deterministic in
/// tests; the service owns only the lightweight timer that asks it periodically.
struct ScreenshotRetentionSchedule {
    static let pruneInterval: TimeInterval = 86_400

    private(set) var lastPrune: Date?

    mutating func shouldPrune(at now: Date, force: Bool = false) -> Bool {
        if !force, let lastPrune {
            let elapsed = now.timeIntervalSince(lastPrune)
            guard elapsed < 0 || elapsed >= Self.pruneInterval else { return false }
        }
        lastPrune = now
        return true
    }

    static func requiresImmediatePrune(previousDays: Int, currentDays: Int) -> Bool {
        currentDays < previousDays
    }
}

/// Pure capture-layout selection. ScreenCaptureKit objects cannot be created
/// in unit tests, so production metadata is reduced to these value types before
/// binding pixels to the one focused window whose privacy metadata was read.
struct ScreenshotCaptureLayout {
    struct Window {
        let id: CGWindowID
        let processID: pid_t
        let appName: String
        let title: String
        let frame: CGRect
    }

    struct Selection: Equatable {
        let windowID: CGWindowID
    }

    static func selection(
        windows: [Window],
        frontmostProcessID: pid_t,
        focusedWindowTitle: String,
        focusedWindowFrame: CGRect?,
        excludedApps: [String],
        excludePrivateWindows: Bool = true
    ) -> Selection? {
        guard let focusedWindowFrame, !focusedWindowFrame.isEmpty,
              !focusedWindowFrame.isNull else { return nil }
        let matches = windows.filter {
            $0.processID == frontmostProcessID
                && $0.title == focusedWindowTitle
                && $0.frame == focusedWindowFrame
        }
        // A title alone can identify several windows. Never guess another
        // window or fall back to the display when AX cannot bind the source.
        guard matches.count == 1, let window = matches.first,
              !isExcluded(appName: window.appName, excludedApps: excludedApps),
              !(excludePrivateWindows && ScreenContextPrivacy.isPrivateWindow(title: window.title))
        else { return nil }
        return Selection(windowID: window.id)
    }

    static func isExcluded(appName: String, excludedApps: [String]) -> Bool {
        ScreenContextPrivacy.isExcluded(appName: appName, rules: excludedApps)
    }
}

/// ScreenCaptureKit allocates the requested frame before the background worker
/// can downsample it. Bound that first allocation so large/retina displays do
/// not briefly consume hundreds of megabytes on every context event.
struct ScreenshotCaptureDimensions: Equatable {
    static let maximumDimension = 1_500

    let width: Int
    let height: Int

    static func bounded(
        pixelWidth: Int,
        pixelHeight: Int,
        maximumDimension: Int = maximumDimension
    ) -> ScreenshotCaptureDimensions {
        let sourceWidth = max(1, pixelWidth)
        let sourceHeight = max(1, pixelHeight)
        let limit = max(1, maximumDimension)
        let longest = max(sourceWidth, sourceHeight)
        guard longest > limit else {
            return ScreenshotCaptureDimensions(width: sourceWidth, height: sourceHeight)
        }
        let scale = Double(limit) / Double(longest)
        return ScreenshotCaptureDimensions(
            width: max(1, Int((Double(sourceWidth) * scale).rounded())),
            height: max(1, Int((Double(sourceHeight) * scale).rounded())))
    }
}

/// Main-actor gate that prevents repeated menu clicks and simultaneous sampler
/// events from launching overlapping ScreenCaptureKit requests.
struct ScreenshotCaptureGate {
    private(set) var isCapturing = false

    mutating func begin() -> Bool {
        guard !isCapturing else { return false }
        isCapturing = true
        return true
    }

    mutating func end() {
        isCapturing = false
    }
}

enum ScreenshotWindowFocusValidation {
    static func matches(
        expected: ScreenAccessibilitySnapshot,
        current: ScreenAccessibilityCaptureResult
    ) -> Bool {
        guard !current.timedOut, let snapshot = current.snapshot,
              expected.windowTitle != nil, expected.windowFrame != nil,
              expected.focusedSecureField == false,
              snapshot.focusedSecureField == false else { return false }
        return snapshot.windowTitle == expected.windowTitle
            && snapshot.windowFrame == expected.windowFrame
            && snapshot.sourceURL == expected.sourceURL
            && snapshot.hasWebContent == expected.hasWebContent
    }
}

/// Immutable inputs passed across the main-actor/worker boundary. `CGImage` is
/// an immutable Core Foundation value and is safe to read concurrently, but it
/// is not annotated `Sendable` by every supported SDK, so the wrapper records
/// that invariant explicitly.
struct ScreenshotProcessingRequest: @unchecked Sendable {
    let image: CGImage
    let trigger: ScreenCaptureTrigger
    let key: SymmetricKey
    let fileURL: URL
    let accessibleText: String
    let accessibilityRedactionCount: Int

    init(
        image: CGImage,
        trigger: ScreenCaptureTrigger,
        key: SymmetricKey,
        fileURL: URL,
        accessibleText: String = "",
        accessibilityRedactionCount: Int = 0
    ) {
        self.image = image
        self.trigger = trigger
        self.key = key
        self.fileURL = fileURL
        self.accessibleText = accessibleText
        self.accessibilityRedactionCount = max(0, accessibilityRedactionCount)
    }
}

/// Injectable image/file operations keep the serial worker deterministic under
/// test without weakening the production path. Every closure runs only inside
/// `ScreenshotProcessingWorker`.
struct ScreenshotProcessingDependencies: @unchecked Sendable {
    let contentHash: @Sendable (CGImage) -> Data
    let heicData: @Sendable (CGImage) throws -> Data
    let recognizeText: @Sendable (CGImage) -> String
    let write: @Sendable (Data, URL) throws -> Void

    static let live = ScreenshotProcessingDependencies(
        contentHash: { image in ScreenshotImageProcessing.contentHash(of: image) },
        heicData: { image in try ScreenshotImageProcessing.heicData(from: image) },
        recognizeText: { image in ScreenshotImageProcessing.recognizeText(in: image) },
        write: { data, url in
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        })
}

/// CPU- and I/O-heavy screenshot processing. Actor isolation gives captures one
/// total order, so the content hash always compares with the last image that was
/// successfully encrypted and written. There are no suspension points inside
/// `process`, preventing actor reentrancy from interleaving two capture writes.
actor ScreenshotProcessingWorker {
    struct StoredCapture: Sendable {
        let contentHash: Data
        let text: String
        let textSource: String
        let hasPixels: Bool
        let privacyRedactionCount: Int
        let usedOCR: Bool
    }

    enum Outcome: Sendable {
        case unchanged
        case stored(StoredCapture)
    }

    private let dependencies: ScreenshotProcessingDependencies
    private var lastContentHash: Data?

    init(dependencies: ScreenshotProcessingDependencies = .live) {
        self.dependencies = dependencies
    }

    func process(_ request: ScreenshotProcessingRequest) throws -> Outcome {
        let preparedImage = ScreenshotImageProcessing.downscale(request.image, maxWidth: 1500)
        let contentHash = dependencies.contentHash(preparedImage)
        if request.trigger != .manual, contentHash == lastContentHash {
            return .unchanged
        }

        let accessible = ScreenContextPrivacy.redact(request.accessibleText)
        let accessibilityRedactions = request.accessibilityRedactionCount + accessible.count
        let hasRichAccessibility = ScreenContextPrivacy.hasRichAccessibleText(accessible.text)
        let ocr = hasRichAccessibility
            ? ScreenContextPrivacy.Redaction(text: "", count: 0)
            : ScreenContextPrivacy.redact(dependencies.recognizeText(preparedImage))

        let text: String
        let textSource: String
        if hasRichAccessibility {
            text = accessible.text
            textSource = accessibilityRedactions > 0
                ? "accessibility_redacted" : "accessibility"
        } else if !accessible.text.isEmpty, !ocr.text.isEmpty {
            text = String((accessible.text + "\n" + ocr.text).prefix(36_000))
            textSource = (accessibilityRedactions + ocr.count) > 0 ? "hybrid_redacted" : "hybrid"
        } else if !accessible.text.isEmpty {
            text = accessible.text
            textSource = accessibilityRedactions > 0
                ? "accessibility_redacted" : "accessibility"
        } else {
            text = ocr.text
            textSource = ocr.count > 0 ? "ocr_redacted" : "ocr"
        }

        let redactionCount = accessibilityRedactions + ocr.count
        // If extracted text reveals a credential, retain only its deterministic
        // redacted form. Dropping the entire pixel payload is safer than trying
        // to infer a precise on-screen rectangle from a text-only observation.
        let hasPixels = redactionCount == 0
        if hasPixels {
            let heic = try dependencies.heicData(preparedImage)
            let sealedBox = try AES.GCM.seal(heic, using: request.key)
            guard let sealed = sealedBox.combined else {
                throw CocoaError(.fileWriteUnknown)
            }
            try dependencies.write(sealed, request.fileURL)
        }
        lastContentHash = contentHash
        return .stored(StoredCapture(
            contentHash: contentHash,
            text: text,
            textSource: textSource,
            hasPixels: hasPixels,
            privacyRedactionCount: redactionCount,
            usedOCR: !hasRichAccessibility))
    }

    /// A file write is not a completed capture until its SQLite rows commit.
    /// Let an identical screen retry when that later persistence step fails.
    func discardStored(contentHash: Data) {
        if lastContentHash == contentHash {
            lastContentHash = nil
        }
    }
}

/// 64-bit difference hash (dHash) for visually similar-frame detection.
/// Unlike a byte SHA, this remains stable across tiny cursor/animation/codec
/// changes. Automatic captures within `defaultDistanceThreshold` are skipped;
/// explicit manual captures always bypass that decision in the worker above.
enum ScreenPerceptualHash {
    static let width = 9
    static let height = 8
    static let defaultDistanceThreshold = 6

    static func hash(of image: CGImage) -> UInt64 {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return 0 }

        var result: UInt64 = 0
        var bit: UInt64 = 1
        for row in 0..<height {
            let offset = row * width
            for column in 0..<(width - 1) {
                if pixels[offset + column] > pixels[offset + column + 1] {
                    result |= bit
                }
                bit <<= 1
            }
        }
        return result
    }

    static func data(of image: CGImage) -> Data {
        var value = hash(of: image).littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    static func value(from data: Data) -> UInt64? {
        guard data.count == MemoryLayout<UInt64>.size else { return nil }
        let littleEndian = data.withUnsafeBytes {
            $0.loadUnaligned(as: UInt64.self)
        }
        return UInt64(littleEndian: littleEndian)
    }

    static func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }

    static func isNearDuplicate(
        _ lhs: UInt64,
        _ rhs: UInt64,
        threshold: Int = defaultDistanceThreshold
    ) -> Bool {
        hammingDistance(lhs, rhs) <= max(0, threshold)
    }

    static func isNearDuplicate(
        _ lhs: Data,
        _ rhs: Data,
        threshold: Int = defaultDistanceThreshold
    ) -> Bool {
        guard let lhs = value(from: lhs), let rhs = value(from: rhs) else {
            // Test/custom processors historically supplied SHA-sized values.
            // Preserve exact-dedup behavior for those non-production inputs.
            return lhs == rhs
        }
        return isNearDuplicate(lhs, rhs, threshold: threshold)
    }
}

/// Pure image transforms used by the background worker. Keeping these outside
/// the `@MainActor` service is what makes Vision, Core Graphics, and ImageIO run
/// away from SwiftUI's executor.
private enum ScreenshotImageProcessing {
    /// Hash the downscaled pixels before HEIC/OCR. Only byte-identical frames
    /// are suppressed; the much coarser perceptual hash is persisted later for
    /// visual grouping and must never discard changed OCR evidence.
    static func contentHash(of image: CGImage) -> Data {
        var input = Data()
        var width = UInt64(image.width).littleEndian
        var height = UInt64(image.height).littleEndian
        withUnsafeBytes(of: &width) { input.append(contentsOf: $0) }
        withUnsafeBytes(of: &height) { input.append(contentsOf: $0) }
        if let pixels = image.dataProvider?.data {
            input.append(pixels as Data)
        }
        return Data(SHA256.hash(data: input))
    }

    static func recognizeText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate   // .fast is useless on dense UI text
        request.usesLanguageCorrection = false  // code/URLs shouldn't be "corrected"
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    static func downscale(_ image: CGImage, maxWidth: Int) -> CGImage {
        let dimensions = ScreenshotCaptureDimensions.bounded(
            pixelWidth: image.width,
            pixelHeight: image.height,
            maximumDimension: maxWidth)
        guard dimensions.width != image.width || dimensions.height != image.height else {
            return image
        }
        guard let context = CGContext(
            data: nil, width: dimensions.width, height: dimensions.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(
            x: 0, y: 0, width: dimensions.width, height: dimensions.height))
        return context.makeImage() ?? image
    }

    static func heicData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.heic" as CFString, 1, nil) else {
            throw NSError(domain: "LokalBot", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "HEIC encoder unavailable"])
        }
        CGImageDestinationAddImage(destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

/// Event-driven screen context: read bounded visible Accessibility text first,
/// optionally pair it with an encrypted focused-window image, and invoke local
/// OCR only when the accessible text is thin. Captured text is indexed; pixels
/// and, by default, text are retention-pruned. Privacy checks fail closed for
/// idle/lock states, excluded sources, secure fields, and detected credentials.
@MainActor
final class ScreenshotService: ObservableObject {

    @Published private(set) var lastCapture: Date?
    @Published private(set) var lastVisualCapture: Date?
    @Published private(set) var lastAccessibilityCapture: Date?
    @Published private(set) var lastOCRCapture: Date?
    @Published private(set) var lastTextSource: String?
    @Published private(set) var lastRetentionRun: Date?
    @Published private(set) var lastRetentionError: String?
    @Published private(set) var isCapturing = false
    @Published private(set) var lastError: String?

    /// AppState revokes derived evidence before the synchronous deletion runs.
    /// Throwing here leaves both pixels and retained text untouched.
    var mutateEvidence: ([Date], () throws -> Void) throws -> Void = { _, mutation in
        try mutation()
    }

    private let store: ActivityStore
    private let storage: StorageManager
    private let settings: () -> AppSettings
    private let isMeetingRecordingActive: () -> Bool
    private let activeMeetingID: () -> UUID?
    private let isHighPriorityInteractionActive: () -> Bool
    private let now: () -> Date
    private let sampler: ActivitySampler
    private let accessibilityReader: ScreenAccessibilityReader
    private let processingWorker = ScreenshotProcessingWorker()
    private let eventMonitor = ScreenContextEventMonitor()
    private var timer: Timer?
    private var retentionTimer: Timer?
    private var initialCaptureTask: Task<Void, Never>?
    private var captureGeneration = 0
    private var policy = ScreenCapturePolicy()
    private var retentionSchedule = ScreenshotRetentionSchedule()
    private var captureGate = ScreenshotCaptureGate()
    private var lastTextFingerprint: Data?
    private var lastMeetingCapture: Date?

    init(store: ActivityStore, storage: StorageManager, sampler: ActivitySampler,
         accessibilityReader: ScreenAccessibilityReader = .shared,
         isMeetingRecordingActive: @escaping () -> Bool = { false },
         activeMeetingID: @escaping () -> UUID? = { nil },
         isHighPriorityInteractionActive: @escaping () -> Bool = { false },
         now: @escaping () -> Date = Date.init,
         settings: @escaping () -> AppSettings) {
        self.store = store
        self.storage = storage
        self.sampler = sampler
        self.accessibilityReader = accessibilityReader
        self.isMeetingRecordingActive = isMeetingRecordingActive
        self.activeMeetingID = activeMeetingID
        self.isHighPriorityInteractionActive = isHighPriorityInteractionActive
        self.now = now
        self.settings = settings
    }

    func start() {
        startRetentionMaintenance()
        guard timer == nil else { return }
        captureGeneration &+= 1
        let generation = captureGeneration
        // Event-driven path: the sampler already detects app/window boundaries
        // every 5 s; captures ride those events instead of a fixed clock.
        sampler.onActivityBoundary = { [weak self] _, _, appChanged in
            Task { @MainActor in
                await self?.captureIfAppropriate(trigger: appChanged ? .appSwitch : .windowChange)
            }
        }
        eventMonitor.onTrigger = { [weak self] trigger in
            Task { @MainActor in await self?.captureIfAppropriate(trigger: trigger) }
        }
        eventMonitor.start()
        // Idle fallback: a 60 s tick that only captures when nothing has been
        // captured for the configured interval (the old slider semantics
        // become "at least every N minutes").
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.captureIfAppropriate(trigger: .interval) }
        }
        // First capture shortly after launch, not a full interval later.
        initialCaptureTask?.cancel()
        initialCaptureTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(20))
            } catch {
                return
            }
            guard let self, self.captureGeneration == generation else { return }
            await self.captureIfAppropriate(trigger: .interval)
            if self.captureGeneration == generation { self.initialCaptureTask = nil }
        }
    }

    func stop() {
        captureGeneration &+= 1
        initialCaptureTask?.cancel()
        initialCaptureTask = nil
        sampler.onActivityBoundary = nil
        eventMonitor.stop()
        timer?.invalidate()
        timer = nil
        retentionTimer?.invalidate()
        retentionTimer = nil
    }

    func restart() {
        stop()
        // Retention is a privacy lifecycle, not a capture lifecycle. Keep its
        // daily maintenance alive even when tracking/capture is disabled.
        startRetentionMaintenance()
        if settings().effectiveScreenContextCaptureMode.capturesText,
           settings().trackingEnabled { start() }
    }

    private func startRetentionMaintenance() {
        _ = runRetentionMaintenanceIfNeeded()
        guard retentionTimer == nil else { return }
        let maintenance = Timer.scheduledTimer(
            withTimeInterval: 60 * 60,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                _ = self?.runRetentionMaintenanceIfNeeded()
            }
        }
        maintenance.tolerance = 5 * 60
        retentionTimer = maintenance
    }

    private func captureIfAppropriate(trigger: ScreenCaptureTrigger) async {
        let config = settings()
        let mode = config.effectiveScreenContextCaptureMode
        guard mode.capturesText, config.trackingEnabled else {
            lokalbotLog("context skip: disabled"); return
        }
        guard !sampler.isPaused else { lokalbotLog("context skip: paused"); return }
        if trigger != .manual, isHighPriorityInteractionActive() {
            lokalbotLog("context skip: interactive capture has priority")
            return
        }
        let recordingActive = isMeetingRecordingActive()
        guard Self.shouldCaptureDuringMeetingRecording(
            trigger: trigger,
            recordingActive: recordingActive,
            visualContextEnabled: config.meetingVisualContextEnabled && mode.capturesPixels)
        else {
            lokalbotLog("context skip: recording active (\(trigger.rawValue))")
            return
        }
        guard policy.shouldCapture(trigger: trigger,
                                   idleInterval: max(60, config.screenshotIntervalMinutes * 60))
        else {
            if trigger != .interval { lokalbotLog("context skip: cooldown (\(trigger.rawValue))") }
            return
        }
        let current = now()
        if recordingActive, trigger != .manual,
           let lastMeetingCapture,
           current.timeIntervalSince(lastMeetingCapture) < 60 {
            lokalbotLog("context skip: meeting capture cooldown")
            return
        }
        let idle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle < 180 else { lokalbotLog("context skip: idle \(Int(idle))s"); return }
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              let frontmost = frontmostApp.localizedName,
              frontmost != "loginwindow" else { lokalbotLog("context skip: lock screen"); return }
        guard !Self.shouldSkipAutomaticSelfCapture(
            trigger: trigger,
            frontmostProcessID: frontmostApp.processIdentifier,
            ownProcessID: ProcessInfo.processInfo.processIdentifier
        ) else {
            lokalbotLog("context skip: LokalBot frontmost")
            return
        }
        guard !ScreenshotCaptureLayout.isExcluded(
            appName: frontmost, excludedApps: config.excludedAppList)
        else { lokalbotLog("context skip: excluded app (\(frontmost))"); return }

        guard captureGate.begin() else {
            lokalbotLog("context skip: capture already in flight (\(trigger.rawValue))")
            return
        }
        isCapturing = true
        defer {
            captureGate.end()
            isCapturing = false
        }

        let accessibility = await accessibilityReader.capture(
            processID: frontmostApp.processIdentifier)
        guard !accessibility.timedOut, let snapshot = accessibility.snapshot,
              NSWorkspace.shared.frontmostApplication?.processIdentifier
                == frontmostApp.processIdentifier,
              ScreenContextPrivacy.permitsContent(
                snapshot.privacyObservation(
                    appName: frontmost, bundleIdentifier: frontmostApp.bundleIdentifier),
                excludedApps: config.excludedAppList,
                excludedDomains: config.excludedScreenDomainList,
                capturePrivateWindows: config.capturePrivateWindows),
              let windowTitle = snapshot.windowTitle else {
            policy.noteCheck(at: current)
            lokalbotLog("context skip: excluded or unavailable focused-window privacy metadata")
            return
        }
        lastAccessibilityCapture = current
        let sourceURL = ScreenContextPrivacy.sanitizedURL(snapshot.sourceURL)
        let redactedAccessibility = ScreenContextPrivacy.redact(
            snapshot.text)
        let redactedWindowTitle = ScreenContextPrivacy.redact(windowTitle)
        let redactedSourceURL = ScreenContextPrivacy.redact(sourceURL ?? "")
        let redactedDocumentName = ScreenContextPrivacy.redact(
            snapshot.documentName ?? "")
        let preCaptureRedactions = redactedAccessibility.count
            + redactedWindowTitle.count
            + redactedSourceURL.count
            + redactedDocumentName.count
        let meetingID = recordingActive ? activeMeetingID()?.uuidString : nil
        let previousCapture = lastCapture
        let screenCaptureGranted = mode.capturesPixels && CGPreflightScreenCaptureAccess()

        do {
            if !mode.capturesPixels || preCaptureRedactions > 0
                || !screenCaptureGranted {
                try storeTextContext(
                    text: redactedAccessibility.text,
                    redactionCount: preCaptureRedactions,
                    sourceURL: redactedSourceURL.text,
                    documentName: redactedDocumentName.text,
                    frontApp: frontmost,
                    windowTitle: redactedWindowTitle.text,
                    trigger: trigger,
                    meetingID: meetingID,
                    timestamp: current)
                if mode.capturesPixels, !screenCaptureGranted {
                    lokalbotLog("context visual fallback: screen recording not granted")
                }
            } else {
                try await capture(
                    frontApp: frontmost,
                    frontmostProcessID: frontmostApp.processIdentifier,
                    bundleIdentifier: frontmostApp.bundleIdentifier,
                    windowTitle: windowTitle,
                    accessibilitySnapshot: snapshot,
                    storedWindowTitle: redactedWindowTitle.text,
                    excludedApps: config.excludedAppList,
                    excludedDomains: config.excludedScreenDomainList,
                    excludePrivateWindows: !config.capturePrivateWindows,
                    trigger: trigger,
                    accessibleText: redactedAccessibility.text,
                    accessibilityRedactionCount: preCaptureRedactions,
                    sourceURL: redactedSourceURL.text,
                    documentName: redactedDocumentName.text,
                    meetingID: meetingID)
            }
            if recordingActive, lastCapture != previousCapture { lastMeetingCapture = current }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            lokalbotLog("context FAILED: \(error)")
        }
    }

    private func storeTextContext(
        text: String,
        redactionCount: Int,
        sourceURL: String?,
        documentName: String?,
        frontApp: String,
        windowTitle: String,
        trigger: ScreenCaptureTrigger,
        meetingID: String?,
        timestamp: Date
    ) throws {
        let clipped = String(text.prefix(36_000))
        guard !clipped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            policy.noteCheck(at: timestamp)
            lokalbotLog("context skip: no accessible text")
            return
        }
        let fingerprint = Data(SHA256.hash(data: Data(
            "\(frontApp)\u{1f}\(windowTitle)\u{1f}\(clipped)".utf8)))
        if trigger != .manual, fingerprint == lastTextFingerprint {
            policy.noteCheck(at: timestamp)
            lokalbotLog("context skip: unchanged accessible text")
            return
        }
        let source = redactionCount > 0 ? "accessibility_redacted" : "accessibility"
        try store.insertScreenshot(
            ts: timestamp,
            path: "",
            app: frontApp,
            windowTitle: windowTitle,
            trigger: trigger.rawValue,
            textSource: source,
            ocr: clipped,
            sourceURL: sourceURL ?? "",
            documentName: documentName ?? "",
            meetingID: meetingID ?? "",
            privacyRedactions: redactionCount)
        lastTextFingerprint = fingerprint
        policy.noteCheck(at: timestamp)
        lastCapture = timestamp
        lastTextSource = source
        lokalbotLog("context ok: text-only (\(clipped.count) chars, app: \(frontApp), trigger: \(trigger.rawValue))")
    }

    private func capture(frontApp: String, frontmostProcessID: pid_t,
                         bundleIdentifier: String?, windowTitle: String,
                         accessibilitySnapshot: ScreenAccessibilitySnapshot,
                         storedWindowTitle: String,
                         excludedApps: [String],
                         excludedDomains: [String],
                         excludePrivateWindows: Bool,
                         trigger: ScreenCaptureTrigger,
                         accessibleText: String,
                         accessibilityRedactionCount: Int,
                         sourceURL: String?,
                         documentName: String?,
                         meetingID: String?) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostProcessID else {
            lokalbotLog("shot skip: focus changed while preparing capture")
            return
        }
        let layout = ScreenshotCaptureLayout.selection(
            windows: content.windows.compactMap { window in
                guard let application = window.owningApplication else { return nil }
                return .init(
                    id: window.windowID,
                    processID: application.processID,
                    appName: application.applicationName,
                    title: window.title ?? "",
                    frame: window.frame)
            },
            frontmostProcessID: frontmostProcessID,
            focusedWindowTitle: windowTitle,
            focusedWindowFrame: accessibilitySnapshot.windowFrame,
            excludedApps: excludedApps,
            excludePrivateWindows: excludePrivateWindows)
        guard let layout,
              let window = content.windows.first(where: { $0.windowID == layout.windowID })
        else { return }

        // Bound the source frame before ScreenCaptureKit allocates it. Vision
        // receives this same readable 1,500 px frame in the worker; requesting
        // a native 5K/6K IOSurface only inflated transient memory.
        let configuration = SCStreamConfiguration()
        // This filter contains only the AX-checked window. Display capture,
        // even with app exclusions, can include unchecked background domains.
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let dimensions = ScreenshotCaptureDimensions.bounded(
            pixelWidth: Int(filter.contentRect.width * CGFloat(filter.pointPixelScale)),
            pixelHeight: Int(filter.contentRect.height * CGFloat(filter.pointPixelScale)))
        configuration.width = dimensions.width
        configuration.height = dimensions.height
        configuration.showsCursor = false
        configuration.includeChildWindows = false
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration)
        let currentAccessibility = await accessibilityReader.capture(processID: frontmostProcessID)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostProcessID,
              ScreenshotWindowFocusValidation.matches(
                expected: accessibilitySnapshot,
                current: currentAccessibility),
              let currentSnapshot = currentAccessibility.snapshot,
              ScreenContextPrivacy.permitsContent(
                currentSnapshot.privacyObservation(appName: frontApp, bundleIdentifier: bundleIdentifier),
                excludedApps: excludedApps, excludedDomains: excludedDomains,
                capturePrivateWindows: !excludePrivateWindows) else {
            // The focused window, browser URL or secure-field state can change
            // while ScreenCaptureKit suspends. Discard its pixels on any change.
            lokalbotLog("shot skip: focused source or privacy state changed during capture")
            return
        }

        let timestamp = Date()

        // The worker keeps hash → text-source selection → optional OCR →
        // redaction → encryption/write serial and off the main actor.
        let file = Self.captureFileURL(rootURL: storage.rootURL, timestamp: timestamp)
        let outcome = try await processingWorker.process(ScreenshotProcessingRequest(
            image: image,
            trigger: trigger,
            key: try Self.encryptionKey(),
            fileURL: file,
            accessibleText: accessibleText,
            accessibilityRedactionCount: accessibilityRedactionCount))

        guard case .stored(let stored) = outcome else {
            policy.noteCheck(at: timestamp)
            lokalbotLog("context skip: unchanged frame (\(trigger.rawValue), app: \(frontApp))")
            return
        }

        let storedPath = stored.hasPixels ? file.path : ""
        do {
            try store.insertScreenshot(
                ts: timestamp,
                path: storedPath,
                app: frontApp,
                windowTitle: storedWindowTitle,
                trigger: trigger.rawValue,
                textSource: stored.textSource,
                ocr: stored.text,
                perceptualHash: ScreenPerceptualHash.hash(of: image),
                sourceURL: sourceURL ?? "",
                documentName: documentName ?? "",
                meetingID: meetingID ?? "",
                privacyRedactions: stored.privacyRedactionCount)
        } catch {
            if FileManager.default.fileExists(atPath: file.path) {
                do {
                    try FileManager.default.removeItem(at: file)
                } catch let cleanupError {
                    lokalbotLog("context rollback file cleanup failed: \(cleanupError.localizedDescription)")
                }
            }
            await processingWorker.discardStored(contentHash: stored.contentHash)
            throw error
        }
        policy.noteCheck(at: timestamp)
        lastCapture = timestamp
        lastTextSource = stored.textSource
        if stored.hasPixels { lastVisualCapture = timestamp }
        if stored.usedOCR { lastOCRCapture = timestamp }
        let payload = stored.hasPixels ? file.lastPathComponent : "text-only after redaction"
        lokalbotLog("context ok: \(payload) (\(stored.text.count) text chars, source: "
            + "\(stored.textSource), app: \(frontApp), trigger: \(trigger.rawValue))")
    }

    /// Manual trigger (menu bar) — the one non-onboarding place allowed to
    /// prompt, because the user explicitly asked for a capture.
    func captureNow() {
        Task { @MainActor in
            if settings().effectiveScreenContextCaptureMode.capturesPixels,
               !CGPreflightScreenCaptureAccess() {
                lokalbotLog("capture now: requesting screen recording access")
                _ = CGRequestScreenCaptureAccess()
            }
            await captureIfAppropriate(trigger: .manual)
        }
    }

    /// Decrypt a stored screenshot to raw image bytes. `nonisolated` and pure
    /// given the key, so the thumbnail worker can run file I/O and AES opening
    /// off the main actor before immediately downsampling the result.
    nonisolated static func decryptedData(path: String, key: SymmetricKey) -> Data? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    /// Decode only the pixels needed by the destination view. The immediate
    /// cache option forces HEIF/PNG decoding to finish on the detached worker
    /// instead of being deferred until SwiftUI draws on the main actor.
    nonisolated static func downsampledThumbnail(
        data: Data,
        maxPixelSize: Int
    ) -> ScreenThumbnailImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else { return nil }
        return ScreenThumbnailImage(image: image)
    }

    nonisolated static func decryptedThumbnail(
        path: String,
        key: SymmetricKey,
        maxPixelSize: Int
    ) -> ScreenThumbnailImage? {
        guard let data = decryptedData(path: path, key: key) else { return nil }
        return downsampledThumbnail(data: data, maxPixelSize: maxPixelSize)
    }

    /// Callers that already hold screenshot metadata avoid another synchronous
    /// SQLite lookup. File I/O, AES opening, and image decoding all stay off the
    /// main actor and only the bounded CGImage returns to SwiftUI.
    func decryptedThumbnail(
        for screenshot: ActivityStore.Screenshot,
        maxPixelSize: Int
    ) async -> ScreenThumbnailImage? {
        guard screenshot.hasPixels else { return nil }
        let path = screenshot.path
#if LOKALBOT_UI_TEST_HOST
        if ProcessInfo.processInfo.environment["LOKALBOT_SCREEN_MEMORY_DEMO"] == "1" {
            return await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                    return nil
                }
                return Self.downsampledThumbnail(data: data, maxPixelSize: maxPixelSize)
            }.value
        }
#endif
        guard let key = try? Self.encryptionKey() else { return nil }
        return await Task.detached(priority: .userInitiated) {
            Self.decryptedThumbnail(
                path: path,
                key: key,
                maxPixelSize: maxPixelSize)
        }.value
    }

    /// User-requested deletion removes pixels first, then the screenshot row
    /// and all linked OCR, bookmark, and semantic-vector state atomically.
    func deleteCapture(id: Int64) throws {
        guard let screenshot = try store.screenshotChecked(id: id) else { return }
        if !screenshot.path.isEmpty,
           FileManager.default.fileExists(atPath: screenshot.path) {
            try FileManager.default.removeItem(atPath: screenshot.path)
        }
        try store.deleteScreenshot(id: id)
    }

    @discardableResult
    func deleteCaptures(in interval: DateInterval) throws -> Int {
        guard interval.end > interval.start else { return 0 }
        let captures = store.screenshots(
            in: interval, app: nil, bookmarkedOnly: false,
            includingMissingFiles: true)
        for capture in captures {
            if !capture.path.isEmpty,
               FileManager.default.fileExists(atPath: capture.path) {
                try FileManager.default.removeItem(atPath: capture.path)
            }
        }
        try store.deleteScreenshots(ids: captures.map(\.id))
        return captures.count
    }

    /// Manual cleanup keeps successful row/file deletions consistent even if
    /// another item fails. Saved moments require an explicit reviewed scope.
    func applyCaptureDeletionReview(_ review: CaptureDeletionReview) throws -> [String] {
        let current = try store.captureDeletionReview(in: review.interval, includesSaved: review.includesSaved)
        guard review.covers(current) else { throw RetentionReviewError.scopeChanged }
        var failures: [String] = []
        for capture in current.captures {
            do {
                if !review.includesSaved, try store.isBookmarked(snapshotID: capture.id) { continue }
                try deleteCapture(id: capture.id)
            } catch {
                failures.append("\(capture.app) · \(capture.ts.formatted(date: .omitted, time: .standard)): \(error.localizedDescription)")
            }
        }
        return failures
    }

    /// Files older than the retention window are deleted. OCR text follows
    /// the same cutoff unless the user explicitly opted into keeping it —
    /// screen text can be as sensitive as the pixels it came from.
    /// Execute only the reviewed data set. Regular maintenance is separate.
    func applyRetentionReview(_ review: RetentionReview) throws -> [String] {
        let current = try store.retentionReview(days: review.days, keepTextForever: review.keepTextForever, now: now())
        guard review.covers(current) else { throw RetentionReviewError.scopeChanged }
        var failures: [String] = []
        for candidate in current.candidates {
            do {
                // Re-check saving immediately before the irreversible file step.
                guard try !store.isBookmarked(snapshotID: candidate.id) else { continue }
                if !candidate.path.isEmpty {
                    if FileManager.default.fileExists(atPath: candidate.path) {
                        try FileManager.default.removeItem(atPath: candidate.path)
                    }
                    try store.clearScreenshotPath(candidate.path)
                }
                if candidate.removeText || candidate.removeVector {
                    try store.clearRetainedText(ids: [candidate.id])
                }
            } catch {
                failures.append("Moment \(candidate.id): \(error.localizedDescription)")
            }
        }
        lastRetentionRun = now()
        lastRetentionError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        return failures
    }

    func pruneOldScreenshots() {
        _ = runRetentionMaintenanceIfNeeded(force: true)
    }

    /// Called by the hourly maintenance timer. The schedule guarantees the
    /// actual filesystem/SQLite pass runs at most daily unless a retention
    /// reduction or explicit privacy action forces it.
    @discardableResult
    func runRetentionMaintenanceIfNeeded(force: Bool = false) -> Bool {
        let current = now()
        guard retentionSchedule.shouldPrune(at: current, force: force) else { return false }
        performRetentionPrune(at: current)
        return true
    }

    private func performRetentionPrune(at current: Date) {
        var firstError: String?
        do {
            let configuration = settings()
            // Establish the exact affected source timestamps before revoking
            // memory or removing files. A failed read must never look empty.
            let review = try store.retentionReview(
                days: configuration.retentionDays,
                keepTextForever: configuration.keepOCRTextForever,
                now: current)
            let orphaned = configuration.keepOCRTextForever
                ? ActivityStore.OrphanedScreenEvidence()
                : try store.orphanedScreenEvidence(olderThan:
                    current.addingTimeInterval(-Double(configuration.retentionDays) * 86_400))
            if !review.candidates.isEmpty || !orphaned.isEmpty {
                let dates = Array(Set(review.candidates.map(\.timestamp) + orphaned.timestamps)).sorted()
                try mutateEvidence(dates) {
                    // Delete only the reviewed IDs; a broad cutoff query could
                    // remove additional evidence whose days were not revoked.
                    for candidate in review.candidates {
                        do {
                            guard try !store.isBookmarked(snapshotID: candidate.id) else { continue }
                        } catch {
                            if firstError == nil { firstError = error.localizedDescription }
                            continue
                        }
                        if !candidate.path.isEmpty {
                            do {
                                if FileManager.default.fileExists(atPath: candidate.path) {
                                    try FileManager.default.removeItem(atPath: candidate.path)
                                }
                                try store.clearScreenshotPath(candidate.path)
                            } catch {
                                // Preserve failed file references for retry;
                                // text still follows its own retention policy.
                                if firstError == nil { firstError = error.localizedDescription }
                            }
                        }
                        if candidate.removeText || candidate.removeVector {
                            do {
                                try store.clearRetainedText(ids: [candidate.id])
                            } catch {
                                if firstError == nil { firstError = error.localizedDescription }
                            }
                        }
                    }
                    do {
                        try store.clearOrphanedScreenEvidence(orphaned)
                    } catch {
                        if firstError == nil { firstError = error.localizedDescription }
                    }
                }
            }
        } catch {
            firstError = error.localizedDescription
            lokalbotLog("screen retention stopped before mutation: \(error.localizedDescription)")
        }
        lastRetentionRun = current
        lastRetentionError = firstError
    }

    // MARK: - Pieces

    nonisolated static func shouldCaptureDuringMeetingRecording(
        trigger: ScreenCaptureTrigger,
        recordingActive: Bool,
        visualContextEnabled: Bool = false
    ) -> Bool {
        !recordingActive || trigger == .manual || visualContextEnabled
    }

    nonisolated static func shouldSkipAutomaticSelfCapture(
        trigger: ScreenCaptureTrigger,
        frontmostProcessID: pid_t,
        ownProcessID: pid_t
    ) -> Bool {
        trigger != .manual && frontmostProcessID == ownProcessID
    }

    nonisolated static func captureFileURL(
        rootURL: URL,
        timestamp: Date,
        identifier: UUID = UUID()
    ) -> URL {
        let day = timestamp.formatted(.iso8601.year().month().day())
        let milliseconds = Int64((timestamp.timeIntervalSince1970 * 1_000).rounded(.down))
        return rootURL
            .appendingPathComponent("activity/\(day)/shots", isDirectory: true)
            .appendingPathComponent(
                "\(milliseconds)-\(identifier.uuidString.lowercased()).heic.enc")
    }

    /// Per-install AES-256 key in the user Keychain (design §3.4), via the
    /// shared scheme also used to seal chat history.
    static func encryptionKey() throws -> SymmetricKey {
        try KeychainSecrets.symmetricKey(account: "screenshot-key")
    }
}
