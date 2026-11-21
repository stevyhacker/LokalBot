import DigUpKit
import Foundation

struct FileSearchHit: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case screenshot, image, pdf, doc, audio, video, code
    }

    let id: Int64
    let path: String
    let kind: Kind
    let page: Int?
    let seconds: Double?
    let excerpt: String?
    let modified: Date
    let taken: Date?
    let size: Int64
    let isSemantic: Bool

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var folder: String { (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath }
    var date: Date { taken ?? modified }

    var kindLabel: String {
        switch kind {
        case .screenshot: "Screenshot"
        case .image: "Picture"
        case .pdf: page.map { "PDF · page \($0)" } ?? "PDF"
        case .doc: "Document"
        case .audio: seconds.map { "Recording · \(Transcript.stamp($0))" } ?? "Recording"
        case .video: seconds.map { "Video · \(Transcript.stamp($0))" } ?? "Video"
        case .code: "Code"
        }
    }

    var icon: String {
        switch kind {
        case .screenshot: "camera.viewfinder"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .doc: "doc.text"
        case .audio: "waveform"
        case .video: "film"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }

    init(id: Int64, path: String, kind: Kind, page: Int? = nil, seconds: Double? = nil, excerpt: String?,
         modified: Date, taken: Date? = nil, size: Int64 = 0, isSemantic: Bool) {
        self.id = id
        self.path = path
        self.kind = kind
        self.page = page
        self.seconds = seconds
        self.excerpt = excerpt
        self.modified = modified
        self.taken = taken
        self.size = size
        self.isSemantic = isSemantic
    }

    init(_ hit: SearchHit) {
        let kind = Kind(rawValue: hit.kind.rawValue) ?? .doc
        self.init(
            id: hit.segmentID, path: hit.path, kind: kind,
            page: kind == .pdf ? hit.loc.map { Int($0) } : nil,
            seconds: kind == .audio || kind == .video ? hit.loc : nil,
            excerpt: hit.excerpt, modified: Date(timeIntervalSince1970: hit.modified),
            taken: hit.info["taken"].flatMap(Self.exifDate), size: hit.size,
            isSemantic: hit.keywordRank == nil)
    }

    static func exifDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }
}

@MainActor
final class FileSearchService: ObservableObject {
    enum PauseReason: Equatable, Sendable {
        case recording, lowPower, warm
    }

    enum State: Equatable, Sendable {
        case off
        case noFolders
        case downloading(Double?)
        case indexing(done: Int, total: Int)
        case finishingLongFiles(left: Int)
        case paused(PauseReason)
        case waitingForPower(left: Int)
        case ready
        case failed(String)
    }

    struct Totals: Equatable, Sendable {
        var searchable = 0
        var pending = 0
        var failed = 0
        var skipped = 0
        var byKind: [String: Int] = [:]
        var indexBytes: Int64 = 0
    }

    struct PassReport: Equatable, Sendable {
        var finished: Date
        var filesRead: Int
        var modelSeconds: Double
        var wallSeconds: Double
        var restedSeconds: Double = 0
    }

    struct Configuration: Equatable, Sendable {
        var enabled = false
        var folders: [String] = []
        var includesMedia = true
        var readsOnBattery = false
    }

    struct EmbedderSession: Sendable {
        let source: String
        let makeEmbedder: @Sendable () throws -> any Embedder
        let end: @Sendable () async -> Void
    }

    typealias StartEmbedder = @MainActor (_ progress: @escaping @Sendable (Double) -> Void) async throws
        -> EmbedderSession

    nonisolated static let mediaExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "wav", "wave", "aif", "aiff", "aifc", "caf", "flac", "ogg", "oga", "opus",
        "wma", "amr", "mka", "ape", "ac3", "eac3", "mp4", "m4v", "mov", "qt", "avi", "mkv", "webm", "wmv", "flv",
        "mpg", "mpeg", "m2v", "mts", "m2ts", "3gp", "3g2", "ogv", "mxf", "dv", "vob",
    ]
    nonisolated static let indexFolderName = "files-index.noindex"
    nonisolated static let leftUnread = "pending"
    nonisolated static let newFilesLimit = 50
    static let vectorIdleSeconds: TimeInterval = 600

    @Published private(set) var state: State = .off
    @Published private(set) var totals = Totals()
    @Published private(set) var lastPass: PassReport?
    @Published private(set) var secondsLeft: Double?

    private(set) var configuration = Configuration()
    var changeDelay: Duration = .seconds(5)
    var isRecording: () -> Bool = { false }
    var transcribeMoment: (@MainActor (FileSearchHit) async -> String?)?
    var isOnBattery: @Sendable () -> Bool = { false }
    var pacing = IndexPacing.unpaced

    private let worker: FileIndexWorker
    private let reader: FileSearchReader
    private let startEmbedder: StartEmbedder
    private let stopFlag = FileIndexStopFlag()
    private var passTask: Task<Void, Never>?
    private var passWanted = false
    private var changeTask: Task<Void, Never>?
    private var watcher: FileFolderWatcher?
    private var observers: [NSObjectProtocol] = []
    private var releaseTimer: Timer?
    private var readingStarted: Date?

    init(indexFolder: URL, startEmbedder: @escaping StartEmbedder) {
        worker = FileIndexWorker(folder: indexFolder)
        reader = FileSearchReader(folder: indexFolder)
        self.startEmbedder = startEmbedder
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange,
                     ProcessInfo.thermalStateDidChangeNotification, .powerSourceDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.conditionsDidChange() }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    static func live(storage: StorageManager) -> FileSearchService {
        PowerSourceMonitor.postSourceChanges()
        FileTextRecognition.route()
        let service = FileSearchService(
            indexFolder: storage.rootURL.appendingPathComponent(indexFolderName, isDirectory: true),
            startEmbedder: { progress in
                let model = try await EmbeddingIndex.preparedModel(storage: storage)
                let projector = try await FileSearchModels.preparedProjector(
                    storageRoot: storage.rootURL, progress: progress)
                let started = try await FileMediaEmbedderRuntime.shared.begin(model: model, projector: projector)
                let endpoint = started.endpoint, pass = started.pass
                return EmbedderSession(
                    source: FileMediaEmbedder.workerInfo.vectorSource,
                    makeEmbedder: { FileMediaEmbedder(endpoint: endpoint) },
                    end: { await FileMediaEmbedderRuntime.shared.end(pass) })
            })
        service.isOnBattery = { PowerSourceMonitor.currentlyOnBattery() }
        service.pacing = .live
        return service
    }

    var isAvailable: Bool { configuration.enabled && !configuration.folders.isEmpty }

    func apply(_ next: Configuration) {
        let previous = configuration
        configuration = next
        guard next.enabled else {
            if previous.enabled || state != .off { turnOff() }
            return
        }
        if next.folders != previous.folders || next.includesMedia != previous.includesMedia || watcher == nil {
            watcher?.stop()
            watcher = FileFolderWatcher(folders: next.folders,
                                        options: Self.indexOptions(includesMedia: next.includesMedia)) { [weak self] _ in
                Task { @MainActor in self?.foldersDidChange() }
            }
        }
        if next.folders.isEmpty {
            stopFlag.set()
            state = .noFolders
            return
        }
        if previous.readsOnBattery, !next.readsOnBattery { stopFlag.set() }
        if releaseTimer == nil {
            releaseTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.reader.releaseIfIdle(after: Self.vectorIdleSeconds) }
            }
        }
        requestPass()
    }

    func conditionsDidChange() {
        guard isAvailable else { return }
        if let reason = pauseReason {
            stopFlag.set()
            if passTask == nil { state = .paused(reason) }
        } else if case .waitingForPower = state {
            if !bigReadsWaitForPower { requestPass() }
        } else if case .paused = state {
            requestPass()
        } else if passWanted {
            requestPass()
        }
    }

    func stop() {
        stopFlag.set()
        changeTask?.cancel()
        watcher?.stop()
        watcher = nil
        releaseTimer?.invalidate()
        releaseTimer = nil
    }

    var pauseReason: PauseReason? { PauseReason.current(isRecording: isRecording()) }

    var bigReadsWaitForPower: Bool { !configuration.readsOnBattery && isOnBattery() }

    private func turnOff() {
        stop()
        passWanted = false
        state = .off
        totals = Totals()
        lastPass = nil
        let running = passTask
        Task { [reader, worker] in
            await running?.value
            await reader.close()
            await worker.deleteIndex()
        }
    }

    private func foldersDidChange() {
        guard isAvailable else { return }
        changeTask?.cancel()
        let delay = changeDelay
        changeTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.requestPass()
        }
    }

    func requestPass() {
        guard isAvailable else { return }
        passWanted = true
        guard passTask == nil else { return }
        passTask = Task { [weak self] in
            await self?.runPasses()
        }
    }

    func waitUntilIdle() async {
        while let running = passTask { await running.value }
    }

    private func runPasses() async {
        while passWanted, isAvailable {
            passWanted = false
            if let reason = pauseReason {
                state = .paused(reason)
                break
            }
            await runOnePass()
        }
        passTask = nil
        secondsLeft = nil
        if case .indexing = state { state = .ready }
        if case .finishingLongFiles = state { state = .ready }
    }

    private func runOnePass() async {
        stopFlag.clear()
        let started = Date()
        let roots = configuration.folders
        let options = Self.indexOptions(includesMedia: configuration.includesMedia)
        let stop = stopFlag

        let synced: FileSyncResult
        do {
            synced = try await worker.perform { store in
                try Self.sync(store: store, roots: roots, options: options)
            }
        } catch {
            state = .failed("Couldn’t read the chosen folders: \(error)")
            return
        }
        await refreshTotals()
        guard synced.waiting > 0 else {
            state = .ready
            return
        }
        guard !stop.isSet else {
            state = pauseReason.map(State.paused) ?? .ready
            return
        }
        let readsOnBattery = configuration.readsOnBattery
        let onBattery = isOnBattery
        let waitsForPower: @Sendable () -> Bool = { !readsOnBattery && onBattery() }
        var only: Set<Int64>?
        if waitsForPower() {
            guard !synced.fresh.isEmpty else {
                state = .waitingForPower(left: synced.waiting)
                return
            }
            only = synced.fresh
        }
        let pacer = FileIndexPacer(pacing: pacing)

        let session: EmbedderSession
        do {
            if FileSearchModels.missingDownloadBytes(storageRoot: worker.folder.deletingLastPathComponent()) > 0 {
                state = .downloading(nil)
            }
            session = try await startEmbedder { [weak self] fraction in
                Task { @MainActor in
                    if case .downloading = self?.state { self?.state = .downloading(fraction) }
                }
            }
        } catch {
            lokalbotLog("file search: the media embedder did not start: \(error)")
            state = .failed("The image and text model couldn’t start: \(error.localizedDescription)")
            return
        }

        state = .indexing(done: 0, total: only?.count ?? synced.waiting)
        readingStarted = Date()
        secondsLeft = nil
        let relay = FilePassProgress { [weak self] update in
            Task { @MainActor in self?.apply(update) }
        }
        let outcome: Result<FilePassOutcome, Error>
        do {
            outcome = .success(try await worker.perform { [only] store in
                try Self.index(store: store, options: options, session: session, only: only, stop: stop,
                               waitsForPower: waitsForPower, pacer: pacer, progress: relay)
            })
        } catch {
            outcome = .failure(error)
        }
        await session.end()
        reader.markStale()
        readingStarted = nil
        secondsLeft = nil
        await refreshTotals()

        switch outcome {
        case .success(let result):
            lastPass = PassReport(finished: Date(), filesRead: result.filesRead, modelSeconds: result.seconds,
                                  wallSeconds: Date().timeIntervalSince(started), restedSeconds: pacer.rested)
            if result.filesRead > 0, let pass = lastPass {
                lokalbotLog("file search: read \(pass.filesRead) files in \(Int(pass.wallSeconds)) s "
                            + "(model \(Int(pass.modelSeconds)) s, rested \(Int(pass.restedSeconds)) s)")
            }
            if result.unanswered > 0 {
                lokalbotLog("file search: \(result.unanswered) files wait for a later pass: "
                            + "text recognition gave no answer")
            }
            if stop.isSet {
                state = pauseReason.map(State.paused) ?? .ready
            } else if result.left > 0, waitsForPower() {
                state = .waitingForPower(left: result.left)
            } else {
                state = .ready
            }
        case .failure(let error):
            lokalbotLog("file search: pass stopped: \(error)")
            state = .failed("Indexing stopped: \(error)")
        }
    }

    private func apply(_ update: FilePassProgress.Update) {
        switch update {
        case .files(let done, let total):
            guard case .indexing = state else { return }
            state = .indexing(done: done, total: total)
            if let readingStarted, done >= 10, total > done {
                secondsLeft = Date().timeIntervalSince(readingStarted) / Double(done) * Double(total - done)
            } else if done >= total {
                secondsLeft = nil
            }
        case .longFiles(let left):
            if case .indexing = state { state = .finishingLongFiles(left: left) }
            if case .finishingLongFiles = state { state = .finishingLongFiles(left: left) }
        }
    }

    private func refreshTotals() async {
        let counts = try? await worker.perform { store -> (IndexStore.Counts, Int64) in
            (try store.counts(), IndexStore.size(of: store.file))
        }
        guard let (counts, bytes) = counts else { return }
        var totals = Totals(indexBytes: bytes)
        for (kind, states) in counts.byKindAndState {
            let searchable = (states["done"] ?? 0) + (states["partial"] ?? 0)
            totals.searchable += searchable
            totals.pending += states["pending"] ?? 0
            totals.failed += states["failed"] ?? 0
            totals.skipped += states["skipped"] ?? 0
            if searchable > 0 { totals.byKind[kind] = searchable }
        }
        self.totals = totals
    }

    nonisolated static func indexOptions(includesMedia: Bool = true) -> IndexOptions {
        var options = IndexOptions()
        if !includesMedia { options.excludedExtensions = mediaExtensions }
        return options
    }

    nonisolated static func sync(store: IndexStore, roots: [String], options: IndexOptions) throws -> FileSyncResult {
        _ = try store.prune(keepingUnder: roots)
        let readable = roots.filter(isReadableFolder)
        let indexer = try Indexer(store: store, options: options, makeEmbedder: {
            throw WorkerError.failed("syncing never embeds")
        })
        defer { indexer.finish() }
        let summary = try indexer.sync(readable.map { URL(fileURLWithPath: $0, isDirectory: true) })
        return FileSyncResult(
            waiting: try store.pendingCount() + store.unfinishedCount().files,
            fresh: summary.queued.count <= newFilesLimit ? Set(summary.queued) : [])
    }

    nonisolated static func index(store: IndexStore, options: IndexOptions, session: EmbedderSession,
                                  only: Set<Int64>? = nil, stop: FileIndexStopFlag,
                                  waitsForPower: @escaping @Sendable () -> Bool = { false },
                                  pacer: FileIndexPacer = FileIndexPacer(pacing: .unpaced),
                                  progress: FilePassProgress) throws -> FilePassOutcome {
        let indexer = try Indexer(store: store, options: options, makeEmbedder: session.makeEmbedder)
        defer { indexer.finish() }
        indexer.embedderSource = session.source
        indexer.resetOnModelChange = { indexed, now in
            lokalbotLog("file search: vectors changed (\(indexed) → \(now)); reading every file again")
        }
        indexer.costsFolder = store.directory
        try indexer.checkModel()
        var outcome = FilePassOutcome()
        let bigRead = only == nil
        let shouldStop: () -> Bool = {
            if stop.isSet || bigRead && waitsForPower() { return true }
            pacer.restBetweenJobs { stop.isSet }
            return stop.isSet
        }
        let read = try indexer.run(only: only, shouldStop: shouldStop) { event in
            outcome.seconds += event.seconds
            progress.files(done: event.done, total: event.total)
        }
        outcome.unanswered = read[Self.leftUnread] ?? 0
        outcome.filesRead = read.values.reduce(0, +) - outcome.unanswered
        if bigRead, !shouldStop() {
            try indexer.finishLongFiles(shouldStop: shouldStop) { step in
                outcome.seconds += step.seconds
                if step.state == Self.leftUnread { outcome.unanswered += 1 }
                progress.longFiles(left: step.files)
            }
        }
        outcome.left = try store.pendingCount() + store.unfinishedCount().files
        return outcome
    }

    func estimate(of folders: [String], progress: @escaping @MainActor (Int) -> Void = { _ in })
        async -> FileFolderEstimate {
        let options = Self.indexOptions(includesMedia: configuration.includesMedia)
        let chosen = configuration.folders
        let costsFolder = worker.folder
        let relay = FileCountProgress { checked in Task { @MainActor in progress(checked) } }
        var estimate = await Task.detached(priority: .utility) {
            Self.estimate(of: folders, excluding: chosen, options: options, costsFolder: costsFolder,
                          progress: relay.checked)
        }.value
        estimate.downloadBytes = FileSearchModels.missingDownloadBytes(storageRoot: costsFolder.deletingLastPathComponent())
        return estimate
    }

    nonisolated static func estimate(of folders: [String], excluding chosen: [String], options: IndexOptions,
                                     costsFolder: URL, checksSpeed: Bool = true,
                                     progress: @escaping (Int) -> Void = { _ in }) -> FileFolderEstimate {
        let unreadable = folders.filter { !isReadableFolder($0) }
        let readable = folders.filter { !unreadable.contains($0) }
        let report = Crawler.crawl(readable.map { URL(fileURLWithPath: $0, isDirectory: true) }, options: options) {
            progress($0.checked)
        }
        let indexed = chosen.flatMap { [$0, FolderSelection.realPath($0)] }
        let candidates = report.candidates.filter { file in
            !indexed.contains { FolderSelection.isInside(file.path, $0) }
        }
        var measured = MeasuredCosts.load(from: costsFolder)
        if checksSpeed, !candidates.isEmpty, measured.speed == nil, measured.tallies.isEmpty,
           let speed = MeasuredCosts.Speed.measure() {
            MeasuredCosts.setSpeed(speed, in: costsFolder)
            measured.speed = speed
        }
        var estimate = FileFolderEstimate(candidates, options: options, costs: measured.costs)
        estimate.unreadable = unreadable
        return estimate
    }

    nonisolated static func isReadableFolder(_ path: String) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
            && Crawler.canList(URL(fileURLWithPath: path))
    }

    nonisolated static func suggestedFolders(excluding chosen: [String]) -> [FileFolderSuggestion] {
        let fileManager = FileManager.default
        let common: [(FileManager.SearchPathDirectory, String, String)] = [
            (.documentDirectory, "Documents", "doc"),
            (.desktopDirectory, "Desktop", "menubar.dock.rectangle"),
            (.downloadsDirectory, "Downloads", "arrow.down.circle"),
        ]
        return common.compactMap { directory, name, symbol in
            guard let path = fileManager.urls(for: directory, in: .userDomainMask).first?.standardizedFileURL.path,
                  fileManager.fileExists(atPath: path),
                  !chosen.contains(where: { $0 == path || FolderSelection.isInside(path, $0) }) else { return nil }
            return FileFolderSuggestion(name: name, path: path, symbol: symbol)
        }
    }

    func search(_ text: String, queryVector: [Float]?, interval: DateInterval? = nil,
                limit: Int = 40) async -> [FileSearchHit] {
        guard isAvailable, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let roots = configuration.folders.flatMap { [$0, FolderSelection.realPath($0)] }
        let found = await reader.search(text, queryVector: queryVector,
                                        limit: interval == nil ? limit : limit * 4)
        return found.lazy.filter { hit in
            roots.contains { FolderSelection.isInside(hit.path, $0) }
                && FileManager.default.fileExists(atPath: hit.path)
        }
        .map(FileSearchHit.init)
        .filter { hit in interval.map { $0.contains(hit.date) } ?? true }
        .prefix(limit)
        .map { $0 }
    }

    func passage(of hit: FileSearchHit) async -> String? {
        if hit.kind == .audio || hit.kind == .video {
            return await transcribeMoment?(hit)
        }
        return await reader.passage(segment: hit.id)
    }

    func hit(segment id: Int64) async -> FileSearchHit? {
        guard configuration.enabled else { return nil }
        return await reader.hit(segment: id)
    }
}

extension FileSearchService.PauseReason {
    static func current(isRecording: Bool) -> Self? {
        if isRecording { return .recording }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return .lowPower }
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { return .warm }
        return nil
    }
}

struct FileFolderEstimate: Equatable, Sendable {
    var files = 0
    var pictures = 0
    var documents = 0
    var recordings = 0
    var playingSeconds = 0.0
    var seconds = 0.0
    var laterSeconds = 0.0
    var indexBytes = 0.0
    var downloadBytes: Int64 = 0
    var unreadable: [String] = []

    init() {}

    init(_ candidates: [Candidate], options: IndexOptions, costs: Costs) {
        var estimate = Estimate()
        for (kind, group) in Dictionary(grouping: candidates, by: \.kind) {
            switch kind {
            case .pdf:
                let pdfs = Estimator.estimate(group, options: options, costs: costs)
                estimate = estimate + pdfs
                let later = costs.pdfPage > 0 ? (pdfs.laterSeconds / costs.pdfPage).rounded() : 0
                indexBytes += (Double(pdfs.pdfPages) + later) * FileIndexSize.pdfPage
            case .video:
                for file in group {
                    let video = Estimator.estimate([file], options: options, costs: costs)
                    estimate = estimate + video
                    indexBytes += FileIndexSize.video(seconds: video.videoSeconds, options: options)
                }
            default:
                let part = Estimator.estimate(group, options: options, costs: costs)
                estimate = estimate + part
                switch kind {
                case .image: indexBytes += Double(group.count) * FileIndexSize.picture
                case .screenshot: indexBytes += Double(group.count) * FileIndexSize.screenshot
                case .doc:
                    let chunks = group.reduce(0) { $0 + max(1, min(options.maxChunks, Int($1.size / 2000))) }
                    indexBytes += Double(chunks) * FileIndexSize.docChunk
                case .audio: indexBytes += FileIndexSize.sound(seconds: part.audioSeconds, options: options)
                default: indexBytes += part.bytes
                }
            }
        }
        files = estimate.files.values.reduce(0, +)
        pictures = (estimate.files[.image] ?? 0) + (estimate.files[.screenshot] ?? 0)
        documents = (estimate.files[.pdf] ?? 0) + (estimate.files[.doc] ?? 0)
        recordings = (estimate.files[.audio] ?? 0) + (estimate.files[.video] ?? 0)
        playingSeconds = estimate.audioSeconds + estimate.videoSeconds
        seconds = estimate.seconds
        laterSeconds = estimate.laterSeconds
    }
}

struct FileFolderSuggestion: Identifiable, Equatable, Sendable {
    let name: String
    let path: String
    let symbol: String
    var id: String { path }
}

enum FileIndexSize {
    static let picture = 2_700.0
    static let screenshot = 6_700.0
    static let pdfPage = 7_700.0
    static let docChunk = 8_700.0
    static let soundWindow = 2_000.0
    static let videoFrame = 2_000.0
    static let framesPerVideo = 1_200.0

    static func sound(seconds: Double, options: IndexOptions) -> Double {
        (seconds / options.audioHop).rounded(.up) * soundWindow
    }

    static func video(seconds: Double, options: IndexOptions) -> Double {
        min(seconds / options.frameInterval, framesPerVideo) * videoFrame + sound(seconds: seconds, options: options)
    }
}

final class FileCountProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private let send: @Sendable (Int) -> Void

    init(send: @escaping @Sendable (Int) -> Void) {
        self.send = send
    }

    func checked(_ count: Int) {
        let due = lock.withLock {
            guard Date().timeIntervalSince(last) > 0.2 else { return false }
            last = Date()
            return true
        }
        if due { send(count) }
    }
}

struct FilePassOutcome: Sendable {
    var filesRead = 0
    var unanswered = 0
    var seconds = 0.0
    var left = 0
}

struct FileSyncResult: Sendable {
    var waiting: Int
    var fresh: Set<Int64>
}

final class FilePassProgress: @unchecked Sendable {
    enum Update: Sendable {
        case files(done: Int, total: Int)
        case longFiles(left: Int)
    }

    private let lock = NSLock()
    private var last = Date.distantPast
    private let send: @Sendable (Update) -> Void

    init(send: @escaping @Sendable (Update) -> Void) {
        self.send = send
    }

    func files(done: Int, total: Int) { forward(.files(done: done, total: total), force: done == total) }
    func longFiles(left: Int) { forward(.longFiles(left: left), force: left == 0) }

    private func forward(_ update: Update, force: Bool) {
        let due = lock.withLock {
            guard force || Date().timeIntervalSince(last) > 0.25 else { return false }
            last = Date()
            return true
        }
        if due { send(update) }
    }
}
