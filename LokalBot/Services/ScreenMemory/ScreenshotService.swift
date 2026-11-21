import Foundation
import AppKit
import ApplicationServices
import ImageIO
import Vision
import CryptoKit

func lokalbotLog(_ message: String) {
    AppLog.line(message)
}

enum ScreenCaptureTrigger: String {
    case appSwitch = "app_switch"
    case windowChange = "window_change"
    case click
    case typingPause = "typing_pause"
    case scrollSettled = "scroll_settled"
    case clipboardChange = "clipboard_change"
    case interval
    case manual
}

struct ScreenThumbnailImage: @unchecked Sendable {
    let image: CGImage

    var byteCost: Int {
        max(1, image.bytesPerRow * image.height)
    }
}

struct ScreenCapturePolicy {
    var eventCooldown: TimeInterval
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

struct ScreenshotRetentionSchedule {
    static let pruneInterval: TimeInterval = 86_400
    static let checkInterval: TimeInterval = 3_600
    static let retryInterval: TimeInterval = checkInterval - 600
    static let maximumRetries = 3
    static let markerFileName = ".screen-retention-last-pass"

    private(set) var lastPrune: Date?
    private var failedPasses = 0
    private(set) var markerURL: URL?

    init(lastPrune: Date? = nil, markerURL: URL? = nil) {
        self.lastPrune = lastPrune
        self.markerURL = markerURL
    }

    static func load(markerURL: URL) -> ScreenshotRetentionSchedule {
        let text = try? String(contentsOf: markerURL, encoding: .utf8)
        let last = text.flatMap {
            try? Date($0.trimmingCharacters(in: .whitespacesAndNewlines), strategy: .iso8601)
        }
        return ScreenshotRetentionSchedule(lastPrune: last, markerURL: markerURL)
    }

    mutating func shouldPrune(at now: Date, force: Bool = false) -> Bool {
        if !force, let lastPrune {
            let elapsed = now.timeIntervalSince(lastPrune)
            guard elapsed < 0 || elapsed >= Self.pruneInterval else { return false }
        }
        record(now)
        return true
    }

    mutating func passFailed(at now: Date) {
        failedPasses += 1
        guard failedPasses <= Self.maximumRetries else {
            failedPasses = 0
            return
        }
        record(now.addingTimeInterval(Self.retryInterval - Self.pruneInterval))
    }

    mutating func passSucceeded() {
        failedPasses = 0
    }

    private mutating func record(_ date: Date) {
        lastPrune = date
        if let markerURL {
            try? Data(date.formatted(.iso8601).utf8).write(to: markerURL, options: .atomic)
        }
    }

    static func requiresImmediatePrune(previousDays: Int, currentDays: Int) -> Bool {
        currentDays < previousDays
    }
}

struct ScreenshotCaptureLayout {
    struct Window: Codable, Equatable, Sendable {
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
        excludedApps: [String]
    ) -> Selection? {
        guard let focusedWindowFrame, !focusedWindowFrame.isEmpty,
              !focusedWindowFrame.isNull else { return nil }
        let framed = windows.filter {
            $0.processID == frontmostProcessID && $0.frame == focusedWindowFrame
        }
        let matches = framed.count == 1 ? framed : framed.filter { $0.title == focusedWindowTitle }
        guard matches.count == 1, let window = matches.first,
              !isExcluded(appName: window.appName, excludedApps: excludedApps)
        else { return nil }
        return Selection(windowID: window.id)
    }

    static func isExcluded(appName: String, bundleIdentifier: String? = nil, excludedApps: [String]) -> Bool {
        ScreenContextPrivacy.isExcluded(appName: appName, bundleIdentifier: bundleIdentifier, rules: excludedApps)
    }

    static func mismatchSummary(
        windows: [Window],
        frontmostProcessID: pid_t,
        focusedWindowTitle: String,
        focusedWindowFrame: CGRect?
    ) -> String {
        let own = windows.filter { $0.processID == frontmostProcessID }
        let titles = own.filter { $0.title == focusedWindowTitle }.count
        let frames = own.filter { $0.frame == focusedWindowFrame }.count
        let both = own.filter { $0.title == focusedWindowTitle && $0.frame == focusedWindowFrame }.count
        let emptyTitles = own.filter { $0.title.isEmpty }.count
        let related = own.filter {
            !$0.title.isEmpty && $0.title != focusedWindowTitle
                && ($0.title.contains(focusedWindowTitle) || focusedWindowTitle.contains($0.title))
        }.count
        let nearestFrameDelta = focusedWindowFrame.map { focused in
            own.map { window in
                [window.frame.minX - focused.minX, window.frame.minY - focused.minY,
                 window.frame.width - focused.width, window.frame.height - focused.height]
                    .map(abs).max() ?? 0
            }.min()
        } ?? nil
        return "appWindows=\(own.count) titleMatches=\(titles) frameMatches=\(frames) bothMatch=\(both) "
            + "emptyTitles=\(emptyTitles) containedTitles=\(related) "
            + "nearestFrameDelta=\(nearestFrameDelta.map { String(format: "%.1f", $0) } ?? "none") "
            + "axFrame=\(focusedWindowFrame == nil ? "none" : "known")"
    }
}

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

struct ScreenshotCaptureConsent: Equatable {
    let generation: Int
    let pauseRevision: Int
    let tracking: Bool
    let text: Bool
    let pixels: Bool
    let excludedApps: [String]
    let excludedDomains: [String]
    let meetingVisualContext: Bool

    init(generation: Int, pauseRevision: Int, settings: AppSettings) {
        self.generation = generation
        self.pauseRevision = pauseRevision
        tracking = settings.trackingEnabled
        text = settings.effectiveScreenContextCaptureMode.capturesText
        pixels = settings.effectiveScreenContextCaptureMode.capturesPixels
        excludedApps = settings.excludedAppList
        excludedDomains = settings.excludedScreenDomainList
        meetingVisualContext = settings.meetingVisualContextEnabled
    }

    func permits(current: Self, paused: Bool, cancelled: Bool) -> Bool {
        self == current && tracking && text && !paused && !cancelled
    }
}

extension ScreenshotService {
    static func accessibilitySkipReason(
        _ result: ScreenAccessibilityCaptureResult, app: String, processID: pid_t
    ) -> String {
        if result.timedOut { return "\(app): accessibility timed out" }
        guard let snapshot = result.snapshot else {
            let detail = ScreenAccessibilityReader.lastTextReadFailure(for: processID)
                .map { " (\($0.reason))" } ?? ""
            return "\(app): no accessibility snapshot\(detail)"
        }
        if snapshot.windowTitle == nil { return "\(app): no window title" }
        let focus = snapshot.focusedSecureField.map { $0 ? "secure" : "plain" } ?? "unknown"
        return "\(app): focus=\(focus) secureVisible=\(snapshot.containsSecureField) "
            + "web=\(snapshot.hasWebContent) url=\(snapshot.sourceURL == nil ? "unknown" : "known")"
    }
}

enum ScreenshotWindowFocusValidation {
    static func matches(
        expected: ScreenAccessibilitySnapshot,
        current: ScreenAccessibilityCaptureResult
    ) -> Bool {
        guard !current.timedOut, let snapshot = current.snapshot,
              expected.windowTitle != nil, expected.windowFrame != nil,
              ScreenContextPrivacy.focusPermitsCapture(
                focusedSecureField: expected.focusedSecureField,
                containsSecureField: expected.containsSecureField),
              ScreenContextPrivacy.focusPermitsCapture(
                focusedSecureField: snapshot.focusedSecureField,
                containsSecureField: snapshot.containsSecureField) else { return false }
        return snapshot.windowTitle == expected.windowTitle
            && snapshot.windowFrame == expected.windowFrame
            && snapshot.sourceURL == expected.sourceURL
            && snapshot.hasWebContent == expected.hasWebContent
            && snapshot.containsSecureField == expected.containsSecureField
            && ScreenAccessibilityReader.settledFocus(
                before: expected.focusedSecureField, after: snapshot.focusedSecureField).accepted
    }
}

final class RecheckNodeLimit: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int?
    var value: Int? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

struct ScreenshotProcessingRequest: @unchecked Sendable {
    let image: CGImage
    let trigger: ScreenCaptureTrigger
    let key: SymmetricKey
    let fileURL: URL
    let accessibleText: String
    let accessibilityRedactionCount: Int
    let stageOnly: Bool
    let source: String

    init(
        image: CGImage,
        trigger: ScreenCaptureTrigger,
        key: SymmetricKey,
        fileURL: URL,
        accessibleText: String = "",
        accessibilityRedactionCount: Int = 0,
        stageOnly: Bool = false,
        source: String = ""
    ) {
        self.image = image
        self.trigger = trigger
        self.key = key
        self.fileURL = fileURL
        self.accessibleText = accessibleText
        self.accessibilityRedactionCount = max(0, accessibilityRedactionCount)
        self.stageOnly = stageOnly
        self.source = source
    }
}

private struct ScreenshotProcessingImage: @unchecked Sendable {
    let image: CGImage
}

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

actor ScreenshotProcessingWorker {
    struct StoredCapture: Sendable {
        let contentHash: Data
        let perceptualHash: UInt64
        let text: String
        let textSource: String
        let hasPixels: Bool
        let privacyRedactionCount: Int
        let usedOCR: Bool
        let missedOCR: Bool
        let sealedPixels: Data?
    }

    enum Outcome: Sendable {
        case unchanged
        case stored(StoredCapture)
        case unreadable
    }

    static let textRecognitionLimit: TimeInterval = 20

    private let dependencies: ScreenshotProcessingDependencies
    private let textRecognition: TextRecognitionQueue
    private let textRecognitionLimit: TimeInterval
    private var lastContentHash: Data?
    private var lastStored: (contentHash: Data, source: String, text: String, perceptualHash: UInt64)?
    static let nearDuplicateDistance = 2

    init(dependencies: ScreenshotProcessingDependencies = .live,
         textRecognition: TextRecognitionQueue = .shared,
         textRecognitionLimit: TimeInterval = ScreenshotProcessingWorker.textRecognitionLimit) {
        self.dependencies = dependencies
        self.textRecognition = textRecognition
        self.textRecognitionLimit = textRecognitionLimit
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
        let recognized: String? = hasRichAccessibility ? "" : recognizeText(in: preparedImage)
        if recognized == nil, accessible.text.isEmpty { return .unreadable }
        let ocr = ScreenContextPrivacy.redact(recognized ?? "")

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

        let perceptualHash = ScreenPerceptualHash.hash(of: request.image)
        if request.trigger != .manual, !request.source.isEmpty, let lastStored,
           lastStored.source == request.source, lastStored.text == text,
           (lastStored.perceptualHash ^ perceptualHash).nonzeroBitCount <= Self.nearDuplicateDistance {
            lastContentHash = contentHash
            return .unchanged
        }
        let redactionCount = accessibilityRedactions + ocr.count
        let hasPixels = redactionCount == 0 && recognized != nil
        var stagedPixels: Data?
        if hasPixels {
            let heic = try dependencies.heicData(preparedImage)
            let sealedBox = try AES.GCM.seal(heic, using: request.key)
            guard let sealed = sealedBox.combined else {
                throw CocoaError(.fileWriteUnknown)
            }
            if request.stageOnly {
                stagedPixels = sealed
            } else {
                try dependencies.write(sealed, request.fileURL)
            }
        }
        lastContentHash = contentHash
        lastStored = (contentHash, request.source, text, perceptualHash)
        return .stored(StoredCapture(
            contentHash: contentHash,
            perceptualHash: perceptualHash,
            text: text,
            textSource: textSource,
            hasPixels: hasPixels,
            privacyRedactionCount: redactionCount,
            usedOCR: !hasRichAccessibility && recognized != nil,
            missedOCR: recognized == nil,
            sealedPixels: stagedPixels))
    }

    private func recognizeText(in image: CGImage) -> String? {
        let input = ScreenshotProcessingImage(image: image)
        return textRecognition.runAndWait("screen capture", within: textRecognitionLimit) { [dependencies] in
            dependencies.recognizeText(input.image)
        }
    }

    func discardStored(contentHash: Data) {
        if lastContentHash == contentHash {
            lastContentHash = nil
        }
        if lastStored?.contentHash == contentHash {
            lastStored = nil
        }
    }
}

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
            return lhs == rhs
        }
        return isNearDuplicate(lhs, rhs, threshold: threshold)
    }
}

enum ScreenshotImageProcessing {
    static func contentHash(of image: CGImage) -> Data {
        var hasher = SHA256()
        var width = UInt64(image.width).littleEndian
        var height = UInt64(image.height).littleEndian
        withUnsafeBytes(of: &width) { hasher.update(bufferPointer: $0) }
        withUnsafeBytes(of: &height) { hasher.update(bufferPointer: $0) }
        if let pixels = image.dataProvider?.data, let bytes = CFDataGetBytePtr(pixels) {
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: bytes, count: CFDataGetLength(pixels)))
        }
        return Data(hasher.finalize())
    }

    static func recognizeText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
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

@MainActor
final class ScreenshotService: ObservableObject {

    private var environment: CaptureEnvironment { .current }

    @Published private(set) var lastCapture: Date?
    @Published private(set) var lastVisualCapture: Date?
    @Published private(set) var lastAccessibilityCapture: Date?
    @Published private(set) var lastOCRCapture: Date?
    @Published private(set) var lastTextSource: String?
    @Published private(set) var lastRetentionRun: Date?
    @Published private(set) var lastRetentionError: String?
    @Published private(set) var isCapturing = false
    @Published private(set) var lastError: String?

    var mutateEvidence: ([Date], () throws -> Void) throws -> Void = { _, mutation in
        try mutation()
    }
    var onTextStored: () -> Void = {}

    private let store: ActivityStore
    private let storage: StorageManager
    private let settings: () -> AppSettings
    private let isMeetingRecordingActive: () -> Bool
    private let activeMeetingID: () -> UUID?
    private let isHighPriorityInteractionActive: () -> Bool
    private let now: () -> Date
    private let sampler: ActivitySampler
    private let accessibilityReader: ScreenAccessibilityReader
    private let recheckNodeLimit = RecheckNodeLimit()
    private lazy var privacyRecheckReader = ScreenAccessibilityReader.privacyRecheck { [recheckNodeLimit] in
        recheckNodeLimit.value
    }
    private let processingWorker: ScreenshotProcessingWorker
    private let captureKey: @MainActor () throws -> SymmetricKey
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
         processingWorker: ScreenshotProcessingWorker = ScreenshotProcessingWorker(),
         captureKey: @escaping @MainActor () throws -> SymmetricKey = { try ScreenshotService.encryptionKey() },
         settings: @escaping () -> AppSettings) {
        self.store = store
        self.storage = storage
        self.sampler = sampler
        self.processingWorker = processingWorker
        self.captureKey = captureKey
        self.accessibilityReader = accessibilityReader
        self.isMeetingRecordingActive = isMeetingRecordingActive
        self.activeMeetingID = activeMeetingID
        self.isHighPriorityInteractionActive = isHighPriorityInteractionActive
        self.now = now
        self.settings = settings
        retentionSchedule = .load(markerURL: storage.rootURL.appendingPathComponent(
            ScreenshotRetentionSchedule.markerFileName, isDirectory: false))
    }

    func start() {
        startRetentionMaintenance()
        guard timer == nil else { return }
        captureGeneration &+= 1
        let generation = captureGeneration
        sampler.onActivityBoundary = { [weak self] _, _, appChanged in
            Task { @MainActor in
                await self?.captureIfAppropriate(trigger: appChanged ? .appSwitch : .windowChange)
            }
        }
        eventMonitor.onTrigger = { [weak self] trigger in
            Task { @MainActor in await self?.captureIfAppropriate(trigger: trigger) }
        }
        eventMonitor.start()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.captureIfAppropriate(trigger: .interval) }
        }
        initialCaptureTask?.cancel()
        initialCaptureTask = Task { @MainActor [weak self] in
            do {
                try await environment.clock.sleep(seconds: 20)
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
        startRetentionMaintenance()
        if settings().effectiveScreenContextCaptureMode.capturesText,
           settings().trackingEnabled { start() }
    }

    private func startRetentionMaintenance() {
        _ = runRetentionMaintenanceIfNeeded()
        guard retentionTimer == nil else { return }
        let maintenance = Timer.scheduledTimer(
            withTimeInterval: ScreenshotRetentionSchedule.checkInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                _ = self?.runRetentionMaintenanceIfNeeded()
            }
        }
        maintenance.tolerance = 5 * 60
        retentionTimer = maintenance
    }

    private var lastRepeatedSkip: String?

    private func logRepeatedSkip(_ reason: String, detail: String? = nil) {
        guard reason != lastRepeatedSkip else { return }
        lastRepeatedSkip = reason
        lokalbotLog("context skip: \(reason)" + (detail.map { " (\($0))" } ?? ""))
    }

    func captureIfAppropriate(trigger: ScreenCaptureTrigger) async {
        let config = settings()
        let consent = ScreenshotCaptureConsent(
            generation: captureGeneration, pauseRevision: sampler.capturePauseRevision, settings: config)
        let mode = config.effectiveScreenContextCaptureMode
        guard mode.capturesText, config.trackingEnabled else {
            logRepeatedSkip("disabled"); return
        }
        guard !sampler.isPaused else { logRepeatedSkip("paused"); return }
        if trigger != .manual, isHighPriorityInteractionActive() {
            logRepeatedSkip("interactive capture has priority")
            return
        }
        let recordingActive = isMeetingRecordingActive()
        guard Self.shouldCaptureDuringMeetingRecording(
            trigger: trigger,
            recordingActive: recordingActive,
            visualContextEnabled: config.meetingVisualContextEnabled && mode.capturesPixels)
        else {
            logRepeatedSkip("recording active", detail: trigger.rawValue)
            return
        }
        guard policy.shouldCapture(trigger: trigger,
                                   idleInterval: max(60, config.screenshotIntervalMinutes * 60))
        else {
            if trigger != .interval { logRepeatedSkip("cooldown", detail: trigger.rawValue) }
            return
        }
        lastRepeatedSkip = nil
        let current = now()
        if recordingActive, trigger != .manual,
           let lastMeetingCapture,
           current.timeIntervalSince(lastMeetingCapture) < 60 {
            lokalbotLog("context skip: meeting capture cooldown")
            return
        }
        let idle = environment.workspace.secondsSinceLastInput()
        guard idle < 180 else { lokalbotLog("context skip: idle \(Int(idle))s"); return }
        guard let frontmostApp = environment.workspace.frontmostApplication(),
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
            appName: frontmost, bundleIdentifier: frontmostApp.bundleIdentifier, excludedApps: config.excludedAppList)
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

        var accessibility = await accessibilityReader.capture(
            processID: frontmostApp.processIdentifier)
        if accessibility.snapshot == nil, !accessibility.timedOut,
           ScreenAccessibilityReader.lastTextReadFailure(
            for: frontmostApp.processIdentifier)?.isTransient == true {
            try? await environment.clock.sleep(seconds: 0.75)
            if environment.workspace.frontmostApplication()?.processIdentifier == frontmostApp.processIdentifier {
                accessibility = await accessibilityReader.capture(processID: frontmostApp.processIdentifier)
            }
        }
        guard captureIsAuthorized(consent), !accessibility.timedOut, let snapshot = accessibility.snapshot,
              environment.workspace.frontmostApplication()?.processIdentifier
                == frontmostApp.processIdentifier,
              ScreenContextPrivacy.permitsContent(
                snapshot.privacyObservation(
                    appName: frontmost, bundleIdentifier: frontmostApp.bundleIdentifier),
                excludedApps: config.excludedAppList,
                excludedDomains: config.excludedScreenDomainList,
                allowsUnknownFocus: true),
              let windowTitle = snapshot.windowTitle else {
            policy.noteCheck(at: current)
            lokalbotLog("context skip: excluded or unavailable focused-window privacy metadata ("
                + Self.accessibilitySkipReason(
                    accessibility, app: frontmost, processID: frontmostApp.processIdentifier) + ")")
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
        let screenCaptureGranted = mode.capturesPixels && environment.windows.screenCaptureGranted()

        do {
            if !mode.capturesPixels || preCaptureRedactions > 0
                || !screenCaptureGranted {
                guard captureIsAuthorized(consent) else { return }
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
                    consent: consent,
                    windowTitle: windowTitle,
                    accessibilitySnapshot: snapshot,
                    storedWindowTitle: redactedWindowTitle.text,
                    excludedApps: config.excludedAppList,
                    excludedDomains: config.excludedScreenDomainList,
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
        onTextStored()
    }

    private func capture(frontApp: String, frontmostProcessID: pid_t,
                         bundleIdentifier: String?, consent: ScreenshotCaptureConsent, windowTitle: String,
                         accessibilitySnapshot: ScreenAccessibilitySnapshot,
                         storedWindowTitle: String,
                         excludedApps: [String],
                         excludedDomains: [String],
                         trigger: ScreenCaptureTrigger,
                         accessibleText: String,
                         accessibilityRedactionCount: Int,
                         sourceURL: String?,
                         documentName: String?,
                         meetingID: String?) async throws {
        let clock = ContinuousClock()
        let started = clock.now
        var stages: [String] = []
        func mark(_ stage: String) {
            let elapsed = (clock.now - started).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            stages.append("\(stage)=\(String(format: "%.2f", seconds))s")
        }
        defer { lokalbotLog("shot timing app=\(frontApp) \(stages.joined(separator: " "))") }
        let candidateWindows = try await environment.windows.onScreenWindows()
        mark("windows")
        guard captureIsAuthorized(consent),
              environment.workspace.frontmostApplication()?.processIdentifier == frontmostProcessID else {
            lokalbotLog("shot skip: focus changed while preparing capture")
            return
        }
        let layout = ScreenshotCaptureLayout.selection(
            windows: candidateWindows,
            frontmostProcessID: frontmostProcessID,
            focusedWindowTitle: windowTitle,
            focusedWindowFrame: accessibilitySnapshot.windowFrame,
            excludedApps: excludedApps)
        guard let layout else {
            policy.noteCheck(at: environment.clock.now())
            let summary = ScreenshotCaptureLayout.mismatchSummary(
                windows: candidateWindows,
                frontmostProcessID: frontmostProcessID,
                focusedWindowTitle: windowTitle,
                focusedWindowFrame: accessibilitySnapshot.windowFrame)
            lokalbotLog("shot skip: no on-screen window matched the focused window (\(frontApp): \(summary))")
            return
        }

        let image = try await environment.windows.captureImage(windowID: layout.windowID)
        mark("image")
        guard captureIsAuthorized(consent), environment.windows.screenCaptureGranted() else {
            lokalbotLog("shot skip: consent or screen recording access changed during capture")
            return
        }
        recheckNodeLimit.value = accessibilitySnapshot.inspectedNodes
        let currentAccessibility = await privacyRecheckReader.capture(processID: frontmostProcessID)
        mark("recheck")
        guard captureIsAuthorized(consent),
              environment.workspace.frontmostApplication()?.processIdentifier == frontmostProcessID,
              ScreenshotWindowFocusValidation.matches(
                expected: accessibilitySnapshot,
                current: currentAccessibility),
              let currentSnapshot = currentAccessibility.snapshot,
              ScreenContextPrivacy.permitsContent(
                currentSnapshot.privacyObservation(appName: frontApp, bundleIdentifier: bundleIdentifier),
                excludedApps: excludedApps, excludedDomains: excludedDomains,
                allowsUnknownFocus: true) else {
            lokalbotLog("shot skip: focused source or privacy state changed during capture")
            return
        }

        let timestamp = environment.clock.now()

        let file = Self.captureFileURL(rootURL: storage.rootURL, timestamp: timestamp)
        let outcome = try await processingWorker.process(ScreenshotProcessingRequest(
            image: image,
            trigger: trigger,
            key: try captureKey(),
            fileURL: file,
            accessibleText: accessibleText,
            accessibilityRedactionCount: accessibilityRedactionCount,
            stageOnly: true,
            source: "\(frontApp)\u{1f}\(storedWindowTitle)"))
        mark("process")

        guard case .stored(let stored) = outcome else {
            policy.noteCheck(at: timestamp)
            if case .unreadable = outcome {
                lokalbotLog("context skip: no accessible text and text recognition did not answer "
                    + "(\(trigger.rawValue), app: \(frontApp))")
            } else {
                lokalbotLog("context skip: unchanged frame (\(trigger.rawValue), app: \(frontApp))")
            }
            return
        }

        guard captureIsAuthorized(consent), environment.windows.screenCaptureGranted() else {
            await processingWorker.discardStored(contentHash: stored.contentHash)
            return
        }
        let storedPath = stored.hasPixels ? file.path : ""
        do {
            if let pixels = stored.sealedPixels {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try pixels.write(to: file, options: .atomic)
            }
            try store.insertScreenshot(
                ts: timestamp,
                path: storedPath,
                app: frontApp,
                windowTitle: storedWindowTitle,
                trigger: trigger.rawValue,
                textSource: stored.textSource,
                ocr: stored.text,
                perceptualHash: stored.perceptualHash,
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
        let payload = stored.hasPixels ? file.lastPathComponent
            : stored.missedOCR ? "text-only, text recognition did not answer" : "text-only after redaction"
        lokalbotLog("context ok: \(payload) (\(stored.text.count) text chars, source: "
            + "\(stored.textSource), app: \(frontApp), trigger: \(trigger.rawValue))")
        if !stored.text.isEmpty { onTextStored() }
    }

    private func captureIsAuthorized(_ consent: ScreenshotCaptureConsent) -> Bool {
        consent.permits(current: ScreenshotCaptureConsent(
            generation: captureGeneration, pauseRevision: sampler.capturePauseRevision, settings: settings()),
                        paused: sampler.isPaused, cancelled: Task.isCancelled)
            && environment.accessibility.isTrusted()
    }

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

    nonisolated static func decryptedData(path: String, key: SymmetricKey) -> Data? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

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

    func deleteCapture(id: Int64) throws {
        guard let screenshot = try store.screenshotChecked(id: id) else { return }
        if !screenshot.path.isEmpty,
           FileManager.default.fileExists(atPath: screenshot.path) {
            try FileManager.default.removeItem(atPath: screenshot.path)
        }
        try store.deleteScreenshot(id: id)
    }

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

    func applyRetentionReview(_ review: RetentionReview) throws -> [String] {
        let current = try store.retentionReview(days: review.days, keepTextForever: review.keepTextForever,
                                                now: now(), measuringBytes: false)
        guard review.covers(current) else { throw RetentionReviewError.scopeChanged }
        var failures: [String] = []
        var retainedTextIDs: [Int64] = []
        let saved: Set<Int64>
        do {
            saved = try store.bookmarkedSnapshotIDs()
        } catch {
            failures.append("Saved moments: \(error.localizedDescription)")
            saved = Set(current.candidates.map(\.id))
        }
        for candidate in current.candidates {
            do {
                guard !saved.contains(candidate.id) else { continue }
                if !candidate.path.isEmpty {
                    if FileManager.default.fileExists(atPath: candidate.path) {
                        try FileManager.default.removeItem(atPath: candidate.path)
                    }
                    try store.clearScreenshotPath(candidate.path)
                }
                if candidate.removeText || candidate.removeVector || candidate.removeMetadata {
                    retainedTextIDs.append(candidate.id)
                }
            } catch {
                failures.append("Moment \(candidate.id): \(error.localizedDescription)")
            }
        }
        do {
            try store.clearRetainedText(ids: retainedTextIDs)
        } catch {
            failures.append("Screen text and metadata: \(error.localizedDescription)")
        }
        do {
            try store.clearRetainedActivityTitles(current.activityTitles)
        } catch {
            failures.append("Activity titles: \(error.localizedDescription)")
        }
        do {
            try store.deleteCodingAgentBursts(ids: current.codingAgentBursts.map(\.id))
        } catch {
            failures.append("Coding agent sessions: \(error.localizedDescription)")
        }
        lastRetentionRun = now()
        lastRetentionError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        return failures
    }

    func pruneOldScreenshots() {
        _ = runRetentionMaintenanceIfNeeded(force: true)
    }

    @discardableResult
    func runRetentionMaintenanceIfNeeded(force: Bool = false) -> Bool {
        let current = now()
        guard retentionSchedule.shouldPrune(at: current, force: force) else { return false }
        performRetentionPrune(at: current)
        if lastRetentionError == nil {
            retentionSchedule.passSucceeded()
        } else {
            retentionSchedule.passFailed(at: current)
        }
        WindowHandoffPackage.prune(root: WindowHandoffPackage.root(library: storage.rootURL), now: current)
        return true
    }

    private func performRetentionPrune(at current: Date) {
        var firstError: String?
        do {
            let configuration = settings()
            let review = try store.retentionReview(
                days: configuration.retentionDays,
                keepTextForever: configuration.keepOCRTextForever,
                now: current, measuringBytes: false)
            let orphaned = configuration.keepOCRTextForever
                ? ActivityStore.OrphanedScreenEvidence()
                : try store.orphanedScreenEvidence(olderThan:
                    current.addingTimeInterval(-Double(configuration.retentionDays) * 86_400))
            if !review.candidates.isEmpty || !review.activityTitles.isEmpty
                || !review.codingAgentBursts.isEmpty || !orphaned.isEmpty {
                let dates = review.distinctEvidenceDays(adding: orphaned.timestamps)
                try mutateEvidence(dates) {
                    var retainedTextIDs: [Int64] = []
                    let saved: Set<Int64>
                    do {
                        saved = try store.bookmarkedSnapshotIDs()
                    } catch {
                        if firstError == nil { firstError = error.localizedDescription }
                        saved = Set(review.candidates.map(\.id))
                    }
                    for candidate in review.candidates {
                        guard !saved.contains(candidate.id) else { continue }
                        if !candidate.path.isEmpty {
                            do {
                                if FileManager.default.fileExists(atPath: candidate.path) {
                                    try FileManager.default.removeItem(atPath: candidate.path)
                                }
                                try store.clearScreenshotPath(candidate.path)
                            } catch {
                                if firstError == nil { firstError = error.localizedDescription }
                            }
                        }
                        if candidate.removeText || candidate.removeVector || candidate.removeMetadata {
                            retainedTextIDs.append(candidate.id)
                        }
                    }
                    do {
                        try store.clearRetainedText(ids: retainedTextIDs)
                        try store.clearRetainedActivityTitles(review.activityTitles)
                        try store.deleteCodingAgentBursts(ids: review.codingAgentBursts.map(\.id))
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

    static func encryptionKey() throws -> SymmetricKey {
        try KeychainSecrets.symmetricKey(account: "screenshot-key")
    }
}
