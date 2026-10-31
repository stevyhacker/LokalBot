import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

/// Captures the focused window and reads its text on device for
/// `CotypingWindowText`. Never on the keystroke path: the first request in a
/// field starts a read and goes without it; later requests use the result,
/// which is reread in the background every few seconds while the field keeps
/// focus. One read runs at a time. The image is dropped as soon as it is read,
/// and the text is held for the focused field only.
final class CotypingWindowTextCapture: @unchecked Sendable {
    static let shared = CotypingWindowTextCapture()

    /// Everything a read needs, resolved through Accessibility when it starts.
    struct Request: Sendable {
        var key: String
        var processID: pid_t
        var target: CotypingVisibleContext.Target
    }

    typealias Reader = @Sendable (Request) async -> [CotypingWindowText.Line]?

    /// A read costs about 150–250 ms of background work on a full window.
    static let refreshInterval: TimeInterval = 4

    private struct Entry {
        var key: String
        var snapshot: CotypingVisibleContext.Snapshot?
        var startedAt: TimeInterval
        var adoptedAt: TimeInterval
    }

    private let lock = NSLock()
    private var entry: Entry?
    private var reading = false
    private var generation: UInt64 = 0
    private var updateHandler: (@Sendable () -> Void)?
    private let clock: @Sendable () -> TimeInterval
    private let reader: Reader

    init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         reader: @escaping Reader = { await CotypingWindowTextCapture.read($0) }) {
        self.clock = clock
        self.reader = reader
    }

    /// Called after a read changes the text in use, so the model can read the
    /// new prompt before the next keystroke needs it.
    func setUpdateHandler(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { updateHandler = handler }
    }

    /// The window text for `key`, or nil until the first read finishes. A
    /// missing or old read starts one in the background; `request` runs there
    /// too, never on the keystroke, and returning nil (not permitted, no
    /// window) skips the read.
    func snapshot(forKey key: String,
                  request: @escaping @Sendable () -> Request?) -> CotypingVisibleContext.Snapshot? {
        let now = clock()
        lock.lock()
        if let entry, entry.key != key {
            // Another field, window or document: forget the old text.
            self.entry = nil
            generation &+= 1
            Self.recognized.clear()
        }
        let snapshot = entry?.snapshot
        let due = entry.map { now - $0.startedAt >= Self.refreshInterval } ?? true
        guard due, !reading else {
            lock.unlock()
            return snapshot
        }
        reading = true
        // Counted from the start, so a read that fails is not retried per keystroke.
        if entry == nil {
            entry = Entry(key: key, snapshot: nil, startedAt: now, adoptedAt: now)
        } else {
            entry?.startedAt = now
        }
        let generation = generation
        lock.unlock()

        Task.detached(priority: .utility) { [self] in
            guard let request = request(), request.key == key else {
                lock.withLock { reading = false }
                return
            }
            let started = ContinuousClock.now
            let lines = await reader(request)
            let elapsed = started.duration(to: .now).components
            let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
            finish(request, lines: lines, generation: generation, milliseconds: milliseconds)
        }
        return snapshot
    }

    /// Forgets the text in use. A read already running cannot put its result back.
    func removeAll() {
        lock.withLock {
            entry = nil
            generation &+= 1
        }
        Self.recognized.clear()
    }

    /// The text in use without starting a read. For tests.
    func cachedSnapshot() -> CotypingVisibleContext.Snapshot? {
        lock.withLock { entry?.snapshot }
    }

    private func finish(_ request: Request, lines: [CotypingWindowText.Line]?, generation: UInt64,
                        milliseconds: Int64 = 0) {
        // Filtering runs a few expressions per line; keep it outside the lock
        // that a keystroke takes.
        let target = request.target
        let snapshot = lines.map {
            CotypingVisibleContext.Snapshot(
                target: target,
                excerpts: CotypingWindowText.excerpts(
                    from: $0, fieldFrame: target.fieldFrame, windowFrame: target.windowFrame),
                source: .windowText)
        }
        var adopted = false
        let handler: (@Sendable () -> Void)? = lock.withLock {
            reading = false
            guard generation == self.generation, var current = entry, current.key == request.key,
                  let snapshot else { return nil }
            let now = clock()
            guard CotypingWindowText.shouldReplace(
                current.snapshot, with: snapshot, heldFor: now - current.adoptedAt) else { return nil }
            adopted = true
            let changed = current.snapshot?.text != snapshot.text
            current.snapshot = snapshot.excerpts.isEmpty ? nil : snapshot
            current.adoptedAt = now
            entry = current
            return changed ? updateHandler : nil
        }
        if let lines, let snapshot {
            Self.log("read \(lines.count) lines in \(milliseconds) ms, kept \(snapshot.excerpts.count) lines "
                + "(\(snapshot.text?.count ?? 0) characters); \(adopted ? "using them" : "kept the text in use")")
        }
        handler?()
    }

    // MARK: - Diagnostics

    private static let logLock = NSLock()
    private nonisolated(unsafe) static var lastLogged: String?

    /// One debug-log line per change of outcome, with counts only: window
    /// text never reaches the log.
    static func log(_ message: String) {
        let changed = logLock.withLock {
            defer { lastLogged = message }
            return lastLogged != message
        }
        if changed { lokalbotLog("cotyping window text: \(message)") }
    }

    // MARK: - Reading the screen

    private struct Image: @unchecked Sendable {
        let image: CGImage
    }

    private static let recognitionQueue = DispatchQueue(
        label: "me.dotenv.LokalBot.cotyping.window-text", qos: .utility)

    /// The last lines recognized for the field in use, outside the field, with
    /// the fingerprint of the image they came from. Held and cleared with the
    /// text in use, so it keeps no text the field's prompt could not.
    final class RecognizedLines: @unchecked Sendable {
        private let lock = NSLock()
        private var entry: (key: String, fingerprint: Data, lines: [CotypingWindowText.Line])?
        private var clears: UInt64 = 0

        var generation: UInt64 { lock.withLock { clears } }

        func lines(forKey key: String, fingerprint: Data) -> [CotypingWindowText.Line]? {
            lock.withLock { entry.flatMap { $0.key == key && $0.fingerprint == fingerprint ? $0.lines : nil } }
        }

        /// Dropped when the text was forgotten while recognition ran.
        func store(_ lines: [CotypingWindowText.Line], forKey key: String, fingerprint: Data,
                   ifGeneration generation: UInt64) {
            lock.withLock {
                guard clears == generation else { return }
                entry = (key, fingerprint, lines)
            }
        }

        func clear() {
            lock.withLock {
                entry = nil
                clears &+= 1
            }
        }
    }

    static let recognized = RecognizedLines()

    /// Captures only the focused window, while its app is still in front.
    /// Never asks for Screen Recording: without it there is no window text.
    static func read(_ request: Request) async -> [CotypingWindowText.Line]? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let candidates = content.windows.map {
                CotypingWindowText.WindowCandidate(
                    processID: $0.owningApplication?.processID ?? 0, title: $0.title,
                    frame: $0.frame, layer: $0.windowLayer)
            }
            guard let index = CotypingWindowText.windowIndex(
                in: candidates, processID: request.processID,
                title: request.target.windowTitle, frame: request.target.windowFrame) else {
                log("no single on-screen window matches the focused one")
                return nil
            }
            let window = content.windows[index]
            let filter = SCContentFilter(desktopIndependentWindow: window)
            guard let size = DictationCaptureSizing.pixels(
                for: window.frame, pointPixelScale: CGFloat(filter.pointPixelScale),
                maximumDimension: 3_000) else { return nil }
            let configuration = SCStreamConfiguration()
            configuration.width = size.width
            configuration.height = size.height
            configuration.showsCursor = false
            configuration.capturesAudio = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration)
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == request.processID else { return nil }
            let fingerprint = CotypingWindowText.fingerprint(
                of: image, windowFrame: window.frame, fieldFrame: request.target.fieldFrame)
            if let fingerprint, let lines = recognized.lines(forKey: request.key, fingerprint: fingerprint) {
                log("window unchanged outside the field; reused the last reading")
                return lines
            }
            let generation = recognized.generation
            let lines = await recognizeLines(in: image, windowFrame: window.frame)
            if let fingerprint {
                // The draft is never prompt context, so it is not kept either.
                let field = request.target.fieldFrame.insetBy(
                    dx: -CotypingWindowText.fieldMargin, dy: -CotypingWindowText.fieldMargin)
                recognized.store(lines.filter { !$0.frame.intersects(field) }, forKey: request.key,
                                 fingerprint: fingerprint, ifGeneration: generation)
            }
            return lines
        } catch {
            log("capture failed (\((error as NSError).domain) \((error as NSError).code))")
            return nil
        }
    }

    static func recognizeLines(in image: CGImage, windowFrame: CGRect) async -> [CotypingWindowText.Line] {
        await recognize(Image(image: image), windowFrame: windowFrame)
    }

    /// The same recognizer as screen memory and Compose: `.fast` drops every
    /// accent and all Cyrillic, and the en-US default cannot read CJK.
    private static func recognize(_ input: Image, windowFrame: CGRect) async -> [CotypingWindowText.Line] {
        await withCheckedContinuation { continuation in
            recognitionQueue.async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.automaticallyDetectsLanguage = true
                try? VNImageRequestHandler(cgImage: input.image).perform([request])
                let lines = (request.results ?? []).compactMap { observation -> CotypingWindowText.Line? in
                    guard let text = observation.topCandidates(1).first?.string else { return nil }
                    return .init(text: text, frame: CotypingWindowText.frame(
                        ofNormalized: observation.boundingBox, in: windowFrame))
                }
                continuation.resume(returning: lines)
            }
        }
    }
}
