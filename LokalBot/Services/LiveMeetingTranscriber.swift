import AVFoundation
import Foundation

struct LiveMeetingPreparedAudioChunk: Equatable, Sendable {
    let url: URL
    let processedFrames: Int64
    let startTime: TimeInterval
}

enum LiveMeetingAudioPreparation: Equatable, Sendable {
    case noWork
    case advance(toFrame: Int64)
    case ready(LiveMeetingPreparedAudioChunk)
}

/// Serializes the filesystem and PCM work for both live meeting tracks away
/// from the main actor. The source CAF is append-safe, so preparation opens a
/// point-in-time reader and seeks directly to the unprocessed suffix; it never
/// copies the full, ever-growing meeting file.
actor LiveMeetingAudioPreparationWorker {
    private let storageRoot: URL

    init(storageRoot: URL) {
        self.storageRoot = storageRoot
    }

    func prepareNextChunk(source: URL, processedFrames: Int64) throws
        -> LiveMeetingAudioPreparation {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: source.path) else { return .noWork }

        // One bounded reader supplies both availability and the audio suffix.
        let reader = try AVAudioFile(forReading: source)
        let sampleRate = reader.fileFormat.sampleRate
        guard let range = LiveTranscriptChunker.nextChunk(
            processedFrames: processedFrames,
            totalFrames: reader.length,
            sampleRate: sampleRate) else {
            return .noWork
        }

        try Task.checkCancellation()
        let frames = AVAudioFrameCount(range.upperBound - range.lowerBound)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: reader.processingFormat,
            frameCapacity: frames) else {
            return .noWork
        }
        reader.framePosition = range.lowerBound
        try reader.read(into: buffer, frameCount: frames)
        try Task.checkCancellation()
        guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else {
            return .noWork
        }
        var samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))

        let searchCount = min(
            samples.count,
            Int(LiveTranscriptChunker.cutSearchSeconds * sampleRate))
        if searchCount > 0 {
            let tail = Array(samples.suffix(searchCount))
            let cut = LiveTranscriptChunker.refinedCutOffset(tail: tail, sampleRate: sampleRate)
            samples.removeLast(searchCount - cut)
        }
        guard !samples.isEmpty else { return .noWork }
        let chunkEnd = range.lowerBound + Int64(samples.count)

        try Task.checkCancellation()
        guard let speechSamples = LiveTranscriptChunker.speechCandidate(
            from: samples,
            sampleRate: sampleRate
        ) else {
            return .advance(toFrame: chunkEnd)
        }
        samples = speechSamples

        let chunk = try scratchDirectory()
            .appendingPathComponent("chunk-\(UUID().uuidString).caf")
        var keepChunk = false
        defer {
            if !keepChunk { try? FileManager.default.removeItem(at: chunk) }
        }
        try Self.writeChunk(samples, format: reader.processingFormat, to: chunk)
        try Task.checkCancellation()
        keepChunk = true
        return .ready(LiveMeetingPreparedAudioChunk(
            url: chunk,
            processedFrames: chunkEnd,
            startTime: Double(range.lowerBound) / sampleRate))
    }

    func removePreparedChunk(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Whole voice-activity chunks recorded on a track since `frame`, at most
    /// `maximumChunks` of them. Empty while less than one chunk is waiting or
    /// the track has no file yet.
    func readChunks(source: URL, from frame: Int64, chunkFrames: Int, maximumChunks: Int) throws -> [Float] {
        try Task.checkCancellation()
        guard frame >= 0, chunkFrames > 0, FileManager.default.fileExists(atPath: source.path) else { return [] }
        let reader = try AVAudioFile(forReading: source)
        try Self.requireTurnFormat(reader)
        let whole = min(Int64(maximumChunks), (reader.length - frame) / Int64(chunkFrames))
        guard whole > 0 else { return [] }
        // The recorder may be mid-append, so fewer frames can come back than the file reports.
        let samples = try Self.read(reader, from: frame, frames: whole * Int64(chunkFrames))
        return Array(samples.prefix(samples.count / chunkFrames * chunkFrames))
    }

    /// Frames `start..<end` of a track as a file the model can read, or nil
    /// when the track holds none of them.
    func prepareSpan(source: URL, start: Int64, end: Int64) throws -> URL? {
        try Task.checkCancellation()
        guard start >= 0, FileManager.default.fileExists(atPath: source.path) else { return nil }
        let reader = try AVAudioFile(forReading: source)
        try Self.requireTurnFormat(reader)
        let last = min(end, reader.length)
        guard last > start else { return nil }
        let samples = try Self.read(reader, from: start, frames: last - start)
        guard !samples.isEmpty else { return nil }
        let span = try scratchDirectory().appendingPathComponent("turn-\(UUID().uuidString).caf")
        do {
            try Self.writeChunk(samples, format: reader.processingFormat, to: span)
        } catch {
            try? FileManager.default.removeItem(at: span)
            throw error
        }
        return span
    }

    private struct UnsupportedTurnFormat: LocalizedError {
        var errorDescription: String? { "The live audio file isn't 16 kHz mono." }
    }

    /// Turn cutting counts frames at the rate speech detection hears them.
    private static func requireTurnFormat(_ reader: AVAudioFile) throws {
        guard reader.processingFormat.sampleRate == LiveMeetingTranscriber.turnSampleRate,
              reader.processingFormat.channelCount == 1 else { throw UnsupportedTurnFormat() }
    }

    /// One read may stop short of what was asked for, so this reads until it
    /// has the frames or the file has no more.
    private static func read(_ reader: AVAudioFile, from frame: Int64, frames: Int64) throws -> [Float] {
        var samples: [Float] = []
        samples.reserveCapacity(Int(frames))
        reader.framePosition = frame
        while Int64(samples.count) < frames, reader.framePosition < reader.length {
            let wanted = AVAudioFrameCount(frames - Int64(samples.count))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: wanted) else { break }
            try reader.read(into: buffer, frameCount: wanted)
            guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        return samples
    }

    /// Recent preview uses one shared time origin, even when one track is
    /// shorter or temporarily missing. Lagging tracks wait for that origin so
    /// they cannot backfill audio older than the disclosed preview start.
    func initialCursors(in folder: URL, fileNames: [String], recent: Bool) throws -> [Int64] {
        try Task.checkCancellation()
        guard recent else { return Array(repeating: 0, count: fileNames.count) }
        let readers = fileNames.map { try? AVAudioFile(forReading: folder.appendingPathComponent($0)) }
        let duration = readers.compactMap { reader -> Double? in
            guard let reader, reader.processingFormat.sampleRate > 0 else { return nil }
            return Double(reader.length) / reader.processingFormat.sampleRate
        }.max() ?? 0
        let start = max(0, duration - LiveTranscriptChunker.targetChunkSeconds)
        return readers.map { reader in
            let sampleRate = reader?.processingFormat.sampleRate ?? 16_000
            return Int64(start * sampleRate)
        }
    }

    private func scratchDirectory() throws -> URL {
        let dir = storageRoot.appendingPathComponent(
            LiveMeetingTranscriber.scratchDirectoryName,
            isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func writeChunk(
        _ samples: [Float],
        format: AVAudioFormat,
        to url: URL
    ) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw CocoaError(.fileWriteUnknown)
        }
        samples.withUnsafeBufferPointer { pointer in
            channel.update(from: pointer.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
    }
}

/// Explicitly enabled preview. Cursors belong to a recording, rather than to
/// a polling task, so pause/retry cannot replay already accepted chunks.
@MainActor
final class LiveMeetingTranscriber: ObservableObject {
    struct Line: Identifiable, Equatable {
        let id = UUID()
        let time: TimeInterval
        let speaker: String
        let text: String
    }

    enum State: Equatable {
        case off, running, paused
        case failed(String)
    }

    enum StartPosition { case recent, beginning }

    /// Where the preview's text comes from: the Transcribe model in windows
    /// of 4 to 12 seconds, the same model one turn at a time (opt-in), or
    /// Muse Voice Transcribe streaming turn by turn (opt-in).
    enum Engine: Equatable { case local, turns, muse }

    struct Timing {
        var idlePoll: Duration = .seconds(1)
        var retryBaseSeconds: Double = 1
        /// How often turn-by-turn text looks for newly recorded audio.
        var turnPoll: Duration = .milliseconds(100)
        /// A turn still being spoken is shown again after this much more audio.
        var interimEverySeconds = 2.0
        /// It is shown only while the model answers this quickly, so a
        /// finished turn never waits long behind a courtesy.
        var interimBudgetSeconds = 0.25
    }

    typealias SpeechDetector = @MainActor (URL) async throws -> Bool
    typealias Transcribe = @MainActor (URL, AppSettings) async throws -> Transcript
    /// How likely the next 256 ms of a track are speech, with the model's
    /// memory of that track handed back and forth.
    typealias VoiceActivity = @Sendable ([Float], LiveVoiceState) async throws
        -> (probability: Float, state: LiveVoiceState)
    typealias MuseTrack = (URL) -> MuseLiveTextTrack
    /// The key and keywords for fast live text, or nil when it can't run.
    typealias MuseConnection = (AppSettings) -> (key: String, keywords: [String])?

    @Published private(set) var lines: [Line] = []
    @Published private(set) var state: State = .off
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var previewStartTime: TimeInterval?
    /// Turns still being spoken, at most one per track, with fast live text.
    @Published private(set) var partials: [Line] = []
    @Published private(set) var engine: Engine = .local

    var isRunning: Bool { state == .running }
    var errorMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    private let settings: () -> AppSettings
    private let audioPreparationWorker: LiveMeetingAudioPreparationWorker
    private let detectSpeech: SpeechDetector
    private let transcribe: Transcribe
    private let voiceActivity: VoiceActivity
    private let timing: Timing
    private let museTrack: MuseTrack
    private let museConnection: MuseConnection
    private var task: Task<Void, Never>?
    private var generation = 0
    private var pendingFolder: URL?
    private var hasTranscribedOnce = false
    private var initializedCursors = false
    private var resumeAfterHandoff = false
    private var tracks: [TrackState]
    /// Turns that have closed and wait for the model, oldest first. They
    /// belong to the recording like the cursors, so a pause loses none.
    private var pendingTurns: [PendingTurn] = []
    /// How long the model took last time, to judge whether it is quick
    /// enough to also show a turn that is still being spoken.
    private var lastDecodeSeconds: Double?
    private static let maxLines = 400
    private static let maxConsecutiveFailures = 3
    /// Speech detection hears 16 kHz, the rate both live files are written at.
    nonisolated static let turnSampleRate = 16_000.0
    /// At most 8 s of one track per look, so neither track waits on a backlog.
    private static let chunksPerLook = 32

    nonisolated static let scratchDirectoryName = "live-previews"

    init(storageRoot: URL,
         detectSpeech: SpeechDetector? = nil,
         transcribe: Transcribe? = nil,
         voiceActivity: VoiceActivity? = nil,
         timing: Timing = Timing(),
         museTrack: MuseTrack? = nil,
         museConnection: MuseConnection? = nil,
         settings: @escaping () -> AppSettings) {
        self.settings = settings
        self.museTrack = museTrack ?? { MuseLiveTextTrack(source: $0) }
        self.museConnection = museConnection ?? { settings in
            MuseLiveText.unavailableReason(settings) == nil
                ? (settings.effectiveMetaModelAPIKey, LiveMeetingTranscriber.keywords(settings)) : nil
        }
        self.tracks = Self.newTracks()
        self.audioPreparationWorker = LiveMeetingAudioPreparationWorker(storageRoot: storageRoot)
        self.detectSpeech = detectSpeech ?? { url in
            let seconds = await SpeechActivity.shared.speechSeconds(in: url)
            try Task.checkCancellation()
            guard let seconds else { throw PreviewError.speechDetectionUnavailable }
            return seconds > 0
        }
        self.transcribe = transcribe ?? { url, config in
            try await config.transcriptionEngine().transcribe(
                audio: url, language: config.transcriptionLanguage.code,
                prompt: config.transcriptionPrompt)
        }
        self.voiceActivity = voiceActivity ?? { chunk, state in
            do {
                return try await SpeechActivity.shared.liveProbability(of: chunk, state: state)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw PreviewError.speechDetectionUnavailable
            }
        }
        self.timing = timing
    }

    private enum PreviewError: LocalizedError {
        case speechDetectionUnavailable
        var errorDescription: String? {
            "Speech detection is unavailable. Retry preview when the speech model is ready."
        }
    }

    static func sweepOrphanedSnapshots(storageRoot: URL) {
        try? FileManager.default.removeItem(
            at: storageRoot.appendingPathComponent(scratchDirectoryName, isDirectory: true))
    }

    func prepare(folder: URL) {
        let resume = isRunning || resumeAfterHandoff
        cancelWork()
        pendingFolder = folder
        tracks = Self.newTracks()
        pendingTurns = []
        initializedCursors = false
        hasTranscribedOnce = false
        resumeAfterHandoff = false
        lines = []
        previewStartTime = nil
        state = .off
        if resume { activate(from: .beginning) }
    }

    /// The start choice applies only to the first activation. Retry and resume
    /// retain their cursors even if the recording has grown in the meantime.
    func activate(from position: StartPosition = .recent) {
#if LOKALBOT_UI_TEST_HOST
        if let script = Self.uiTestScript, !isRunning {
            generation += 1
            let session = generation
            state = .running
            statusMessage = nil
            engine = museConnection(settings()) == nil ? .local : .muse
            let typing = engine == .muse
            task = Task { [weak self] in await self?.play(script, session: session, typing: typing) }
            return
        }
#endif
        guard !isRunning, let folder = pendingFolder else { return }
        generation += 1
        let session = generation
        for index in tracks.indices {
            tracks[index].failures = 0
            tracks[index].retryAfter = nil
        }
        state = .running
        statusMessage = nil
        if let connection = museConnection(settings()) {
            engine = .muse
            statusMessage = "Connecting to \(MuseLiveText.displayName)…"
            task = Task { [weak self] in
                await self?.runMuse(folder: folder, session: session, key: connection.key, keywords: connection.keywords)
            }
        } else if settings().turnByTurnLiveTextEnabled {
            engine = .turns
            task = Task { [weak self] in
                await self?.runTurns(folder: folder, session: session, position: position)
            }
        } else {
            engine = .local
            // Windows carry on from the cursor, past any turn left waiting.
            pendingTurns = []
            task = Task { [weak self] in
                await self?.run(folder: folder, session: session, position: position)
            }
        }
    }

    func pause() {
        guard isRunning else { return }
        cancelWork()
        state = .paused
    }

    /// Only a known calendar stop/start may carry the opt-in forward. An idle
    /// transition after a failed start or an ordinary stop clears it again.
    func stop(preservingHandoff: Bool = false) {
        let resume = preservingHandoff && isRunning
        cancelWork()
        resumeAfterHandoff = resume
        pendingFolder = nil
        tracks = Self.newTracks()
        pendingTurns = []
        initializedCursors = false
        lines = []
        previewStartTime = nil
        state = .off
    }

    private func cancelWork() {
        task?.cancel()
        task = nil
        generation += 1
        isWorking = false
        statusMessage = nil
        partials = []
    }

#if LOKALBOT_UI_TEST_HOST
    /// UI-test host only: `LOKALBOT_UI_TEST_LIVE_SCRIPT` names a JSON array of
    /// `{time, speaker, text}`. Each line appears `time` seconds after the
    /// preview starts, as transcribed chunks would, with no audio or model.
    /// With fast live text on, each line is first typed out word by word as a
    /// partial, the way Muse Voice Transcribe's turns arrive; the words are
    /// the script's, since the runner has no meeting audio.
    private static var uiTestScript: [Line]? {
        guard let path = ProcessInfo.processInfo.environment["LOKALBOT_UI_TEST_LIVE_SCRIPT"],
              let data = FileManager.default.contents(atPath: path),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let time = row["time"] as? Double, let speaker = row["speaker"] as? String,
                  let text = row["text"] as? String else { return nil }
            return Line(time: time, speaker: speaker, text: text)
        }
    }

    private func play(_ script: [Line], session: Int, typing: Bool) async {
        let start = ContinuousClock.now
        var previous = 0.0
        for line in script.sorted(by: { $0.time < $1.time }) {
            if typing {
                let words = line.text.split(separator: " ")
                let from = max(previous + 0.3, line.time - 2)
                for count in 1..<max(words.count, 1) {
                    let at = from + (line.time - from) * Double(count) / Double(words.count)
                    try? await Task.sleep(until: start + .seconds(at), clock: .continuous)
                    guard isCurrent(session) else { return }
                    partials = [Line(time: line.time, speaker: line.speaker, text: words.prefix(count).joined(separator: " "))]
                }
            }
            try? await Task.sleep(until: start + .seconds(line.time), clock: .continuous)
            guard isCurrent(session) else { return }
            partials = []
            lines.append(line)
            previous = line.time
        }
    }
#endif

    private struct TrackState {
        let fileName: String
        let speaker: String
        var processedFrames: Int64 = 0
        var failures = 0
        var retryAfter: ContinuousClock.Instant?
        /// Fast live text: the file frame sent so far, and when the current
        /// session was accepted.
        var museCursor: Int64?
        var museConnectedAt: ContinuousClock.Instant?
        /// Turn by turn: the cutter and speech detection's memory of this
        /// track up to `processedFrames`, the last 1.5 s heard (where a
        /// length cut looks for quiet), and the frame the turn in progress
        /// was last shown at.
        var cutter: LiveTurnCutter?
        var voice = LiveVoiceState()
        var tail: [Float] = []
        var interimAt: Int64 = 0
    }

    private static func newTracks() -> [TrackState] {
        [TrackState(fileName: AudioPreviewTee.micFileName, speaker: "local"),
         TrackState(fileName: AudioPreviewTee.systemFileName, speaker: "them")]
    }

    private func isCurrent(_ session: Int) -> Bool {
        !Task.isCancelled && generation == session && isRunning
    }

    private func run(folder: URL, session: Int, position: StartPosition) async {
        do {
            guard try await initializeCursors(folder: folder, session: session, position: position) else { return }
            while isCurrent(session) {
                var didWork = false
                for index in tracks.indices {
                    guard isCurrent(session) else { return }
                    if let deadline = tracks[index].retryAfter, ContinuousClock.now < deadline { continue }
                    do {
                        let result = try await transcribeNextChunk(of: tracks[index], folder: folder, session: session)
                        guard isCurrent(session) else { return }
                        if let result {
                            tracks[index].processedFrames = result.frame
                            if !result.fresh.isEmpty {
                                lines = Array(((lines + result.fresh).sorted { $0.time < $1.time }).suffix(Self.maxLines))
                            }
                            didWork = true
                            if result.transcribed {
                                tracks[index].failures = 0
                                tracks[index].retryAfter = nil
                            }
                        }
                    } catch {
                        guard isCurrent(session) else { return }
                        if fail(track: index, error: error) { return }
                    }
                }
                // Already-buffered audio can be processed immediately. Once
                // caught up, poll without spinning; backoff is per track.
                if !didWork { try await Task.sleep(for: timing.idlePoll) }
            }
        } catch {
            guard isCurrent(session) else { return }
            let message = "Live preview was interrupted. Retry to continue; recording is still running."
            state = .failed(message)
            statusMessage = message
        }
    }

    /// The start choice sets each track's cursor once per recording. Returns
    /// false when the session ended meanwhile.
    private func initializeCursors(folder: URL, session: Int, position: StartPosition) async throws -> Bool {
        guard !initializedCursors else { return true }
        let cursors = try await audioPreparationWorker.initialCursors(
            in: folder, fileNames: tracks.map(\.fileName), recent: position == .recent)
        guard isCurrent(session) else { return false }
        for index in tracks.indices { tracks[index].processedFrames = cursors[index] }
        // Both tee formats are fixed at 16 kHz. Actual chunk timestamps
        // still use the reader's sample rate.
        previewStartTime = Double(cursors.max() ?? 0) / 16_000
        initializedCursors = true
        return true
    }

    /// Counts a failed step against its track and backs off. Returns true
    /// when the preview has given up.
    private func fail(track index: Int, error: Error) -> Bool {
        tracks[index].failures += 1
        let failures = tracks[index].failures
        lokalbotLog("live transcript failed track=\(tracks[index].fileName) attempt=\(failures) error=\(error.localizedDescription)")
        if failures >= Self.maxConsecutiveFailures {
            let message = "Live preview could not continue. Retry from this point; recording is still running."
            state = .failed(message)
            statusMessage = message
            partials = []
            return true
        }
        let delay = timing.retryBaseSeconds * pow(2, Double(failures - 1))
        tracks[index].retryAfter = ContinuousClock.now.advanced(by: .seconds(delay))
        statusMessage = "Retrying live preview… (\(failures)/\(Self.maxConsecutiveFailures))"
        return false
    }

    // MARK: - Turn by turn on this Mac

    private struct PendingTurn {
        let track: Int
        let turn: LiveTurnCutter.Turn
    }

    /// Hears both tracks as they are recorded, cuts them at pauses
    /// (`LiveTurnCutter`), and transcribes each turn once its pause is long
    /// enough: about half a second after the speaker stops, against the
    /// several seconds a window takes to fill. Turns are transcribed one at a
    /// time in the order they closed. In between, a model that answers
    /// quickly also shows the turn still being spoken.
    private func runTurns(folder: URL, session: Int, position: StartPosition) async {
        do {
            guard try await initializeCursors(folder: folder, session: session, position: position) else { return }
            var listening = false
            if !hasTranscribedOnce { statusMessage = "Preparing speech detection…" }
            while isCurrent(session) {
                var didWork = false
                for index in tracks.indices {
                    guard isCurrent(session) else { return }
                    if let deadline = tracks[index].retryAfter, ContinuousClock.now < deadline { continue }
                    do {
                        guard try await hear(track: index, folder: folder, session: session) else { continue }
                        didWork = true
                        if !listening {
                            listening = true
                            statusMessage = nil
                        }
                    } catch {
                        guard isCurrent(session) else { return }
                        if fail(track: index, error: error) { return }
                    }
                }
                guard isCurrent(session) else { return }
                dropFinishedPartials()
                if let next = pendingTurns.first {
                    if let deadline = tracks[next.track].retryAfter, ContinuousClock.now < deadline {
                        // Backing off after a failure; keep hearing meanwhile.
                    } else {
                        do {
                            let fresh = try await decode(next, folder: folder, session: session)
                            guard isCurrent(session) else { return }
                            pendingTurns.removeFirst()
                            publish(fresh, for: next)
                            tracks[next.track].failures = 0
                            tracks[next.track].retryAfter = nil
                            didWork = true
                        } catch {
                            guard isCurrent(session) else { return }
                            if fail(track: next.track, error: error) { return }
                        }
                    }
                } else if try await showTurnInProgress(folder: folder, session: session) {
                    didWork = true
                }
                if !didWork { try await Task.sleep(for: timing.turnPoll) }
            }
        } catch {
            guard isCurrent(session) else { return }
            let message = "Live preview was interrupted. Retry to continue; recording is still running."
            state = .failed(message)
            statusMessage = message
        }
    }

    /// Runs what one track recorded since the last look through speech
    /// detection and the turn cutter. Returns whether there was anything.
    /// The track's state moves only when the whole look succeeded, so a
    /// failed one is heard again from the same frame.
    private func hear(track index: Int, folder: URL, session: Int) async throws -> Bool {
        let chunkFrames = SpeechActivity.liveChunkFrames
        let samples = try await audioPreparationWorker.readChunks(
            source: folder.appendingPathComponent(tracks[index].fileName),
            from: tracks[index].processedFrames, chunkFrames: chunkFrames, maximumChunks: Self.chunksPerLook)
        guard isCurrent(session), !samples.isEmpty else { return false }
        var cutter = tracks[index].cutter ?? LiveTurnCutter(startingAt: tracks[index].processedFrames)
        var voice = tracks[index].voice
        var tail = tracks[index].tail
        let tailFrames = Int(LiveTranscriptChunker.cutSearchSeconds * Self.turnSampleRate)
        var closed: [LiveTurnCutter.Turn] = []
        for offset in stride(from: 0, to: samples.count, by: chunkFrames) {
            let chunk = Array(samples[offset..<(offset + chunkFrames)])
            let verdict = try await voiceActivity(chunk, voice)
            guard isCurrent(session) else { return false }
            voice = verdict.state
            tail.append(contentsOf: chunk)
            if tail.count > tailFrames { tail.removeFirst(tail.count - tailFrames) }
            let turn = cutter.consume(probability: verdict.probability) { from, to in
                let search = Array(tail.suffix(Int(min(to - from, Int64(tail.count)))))
                let quiet = LiveTranscriptChunker.refinedCutOffset(tail: search, sampleRate: Self.turnSampleRate)
                return to - Int64(search.count) + Int64(quiet)
            }
            if let turn { closed.append(turn) }
        }
        tracks[index].cutter = cutter
        tracks[index].voice = voice
        tracks[index].tail = tail
        tracks[index].processedFrames += Int64(samples.count)
        pendingTurns.append(contentsOf: closed.map { PendingTurn(track: index, turn: $0) })
        return true
    }

    private func decode(_ pending: PendingTurn, folder: URL, session: Int) async throws -> [Line] {
        let track = tracks[pending.track]
        guard let span = try await audioPreparationWorker.prepareSpan(
            source: folder.appendingPathComponent(track.fileName),
            start: pending.turn.start, end: pending.turn.end) else { return [] }
        do {
            guard isCurrent(session) else {
                await audioPreparationWorker.removePreparedChunk(at: span)
                return []
            }
            isWorking = true
            defer { if generation == session { isWorking = false } }
            if !hasTranscribedOnce { statusMessage = "Preparing the transcription model…" }
            let started = ContinuousClock.now
            let transcript = try await transcribe(span, settings())
            await audioPreparationWorker.removePreparedChunk(at: span)
            guard isCurrent(session) else { return [] }
            lastDecodeSeconds = Self.seconds(since: started)
            hasTranscribedOnce = true
            statusMessage = nil
            let origin = Double(pending.turn.start) / Self.turnSampleRate
            return transcript.segments.compactMap { segment in
                let text = segment.displayText
                return text.isEmpty ? nil : Line(time: origin + segment.start, speaker: track.speaker, text: text)
            }
        } catch {
            await audioPreparationWorker.removePreparedChunk(at: span)
            throw error
        }
    }

    private func publish(_ fresh: [Line], for pending: PendingTurn) {
        let speaker = tracks[pending.track].speaker
        // What was shown of this turn while it was spoken gives way to its text.
        let start = Double(pending.turn.start) / Self.turnSampleRate
        partials.removeAll { $0.speaker == speaker && $0.time <= start }
        guard !fresh.isEmpty else { return }
        lines = Array(((lines + fresh).sorted { $0.time < $1.time }).suffix(Self.maxLines))
    }

    /// A turn that closed without text (too short to keep) leaves nothing to
    /// replace what was shown of it.
    private func dropFinishedPartials() {
        guard !partials.isEmpty else { return }
        for (index, track) in tracks.enumerated()
        where track.cutter?.openStart == nil && !pendingTurns.contains(where: { $0.track == index }) {
            partials.removeAll { $0.speaker == track.speaker }
        }
    }

    /// With nothing waiting for the model, and a model on this Mac that has
    /// just answered quickly, shows what the longest-running open turn says
    /// so far. Its failure costs nothing: the turn's own text follows when
    /// the speaker pauses. A transcription server hears each turn once, when
    /// it is finished: showing it sooner would upload the same audio again
    /// every two seconds.
    private func showTurnInProgress(folder: URL, session: Int) async throws -> Bool {
        guard let last = lastDecodeSeconds, last <= timing.interimBudgetSeconds,
              !settings().transcriptionModel.isRemote else { return false }
        let every = Int64(timing.interimEverySeconds * Self.turnSampleRate)
        let candidates = tracks.indices.compactMap { index -> (track: Int, start: Int64, end: Int64)? in
            guard let cutter = tracks[index].cutter, let start = cutter.openStart, !cutter.isPausing,
                  cutter.processed - max(start, tracks[index].interimAt) >= every else { return nil }
            return (index, start, cutter.processed)
        }
        guard let open = candidates.min(by: { $0.start < $1.start }) else { return false }
        tracks[open.track].interimAt = open.end
        let track = tracks[open.track]
        guard let span = try await audioPreparationWorker.prepareSpan(
            source: folder.appendingPathComponent(track.fileName), start: open.start, end: open.end) else { return false }
        do {
            guard isCurrent(session) else {
                await audioPreparationWorker.removePreparedChunk(at: span)
                return false
            }
            let started = ContinuousClock.now
            let transcript = try await transcribe(span, settings())
            await audioPreparationWorker.removePreparedChunk(at: span)
            guard isCurrent(session) else { return false }
            lastDecodeSeconds = Self.seconds(since: started)
            let text = transcript.segments.map(\.displayText).filter { !$0.isEmpty }.joined(separator: " ")
            partials.removeAll { $0.speaker == track.speaker }
            if !text.isEmpty {
                let line = Line(time: Double(open.start) / Self.turnSampleRate, speaker: track.speaker, text: text)
                partials = (partials + [line]).sorted { $0.time < $1.time }
            }
            return true
        } catch is CancellationError {
            await audioPreparationWorker.removePreparedChunk(at: span)
            throw CancellationError()
        } catch {
            await audioPreparationWorker.removePreparedChunk(at: span)
            lokalbotLog("live text so far failed track=\(track.fileName) error=\(error.localizedDescription)")
            return false
        }
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = (ContinuousClock.now - start).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    // MARK: - Fast live text

    /// Your name, so Muse spells it as you do.
    nonisolated static func keywords(_ settings: AppSettings) -> [String] {
        let name = settings.cotypingUserName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? [] : [name]
    }

    private func runMuse(folder: URL, session: Int, key: String, keywords: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            for index in tracks.indices {
                group.addTask { [weak self] in
                    await self?.streamMuse(track: index, folder: folder, session: session, key: key, keywords: keywords)
                }
            }
        }
    }

    /// One track's sessions. A session the server ends after running a while
    /// (its 60-minute cap) reconnects at once; one that fails to start or
    /// drops early counts as a failure and backs off, as local chunks do.
    private func streamMuse(track index: Int, folder: URL, session: Int, key: String, keywords: [String]) async {
        let stream = museTrack(folder.appendingPathComponent(tracks[index].fileName))
        let speaker = tracks[index].speaker
        while isCurrent(session) {
            tracks[index].museConnectedAt = nil
            do {
                try await stream.run(key: key, keywords: keywords, resumeFrom: tracks[index].museCursor) { [weak self] output in
                    guard let self, self.isCurrent(session) else { return }
                    self.receive(output, track: index, speaker: speaker)
                }
                // The track's file doesn't exist yet (no call audio so far).
                try await Task.sleep(for: timing.idlePoll)
                continue
            } catch {
                guard isCurrent(session) else { return }
                let ranFor = tracks[index].museConnectedAt.map { ContinuousClock.now - $0 } ?? .zero
                partials.removeAll { $0.speaker == speaker }
                if ranFor >= .seconds(30) {
                    tracks[index].failures = 0
                    lokalbotLog("live text session ended track=\(tracks[index].fileName) error=\(error.localizedDescription)")
                    continue
                }
                tracks[index].failures += 1
                let failures = tracks[index].failures
                lokalbotLog("live text failed track=\(tracks[index].fileName) attempt=\(failures) error=\(error.localizedDescription)")
                if failures >= Self.maxConsecutiveFailures {
                    let message = "Fast live text stopped: \(error.localizedDescription) Retry from this point; recording is still running."
                    task?.cancel()
                    task = nil
                    state = .failed(message)
                    statusMessage = message
                    partials = []
                    return
                }
                statusMessage = "Reconnecting to \(MuseLiveText.displayName)… (\(failures)/\(Self.maxConsecutiveFailures))"
                try? await Task.sleep(for: .seconds(timing.retryBaseSeconds * pow(2, Double(failures - 1))))
            }
        }
    }

    private func receive(_ output: MuseLiveTextTrack.Output, track index: Int, speaker: String) {
        switch output {
        case .connected(let origin):
            tracks[index].museConnectedAt = .now
            if previewStartTime == nil { previewStartTime = origin }
            statusMessage = nil
        case .partial(let time, let text):
            partials.removeAll { $0.speaker == speaker }
            if let text { partials = (partials + [Line(time: time, speaker: speaker, text: text)]).sorted { $0.time < $1.time } }
        case .line(let time, let text):
            partials.removeAll { $0.speaker == speaker }
            statusMessage = nil
            lines = Array((lines + [Line(time: time, speaker: speaker, text: text)]).sorted { $0.time < $1.time }
                .suffix(Self.maxLines))
        case .progress(let cursor):
            tracks[index].museCursor = cursor
        }
    }

    private struct Advance {
        let frame: Int64
        let transcribed: Bool
        var fresh: [Line] = []
    }

    private func transcribeNextChunk(of track: TrackState, folder: URL, session: Int) async throws -> Advance? {
        let preparation = try await audioPreparationWorker.prepareNextChunk(
            source: folder.appendingPathComponent(track.fileName), processedFrames: track.processedFrames)
        switch preparation {
        case .noWork: return nil
        case .advance(let frame): return Advance(frame: frame, transcribed: false)
        case .ready(let prepared):
            do {
                guard isCurrent(session) else {
                    await audioPreparationWorker.removePreparedChunk(at: prepared.url)
                    return nil
                }
                let result = try await transcribePreparedChunk(prepared, track: track, session: session)
                await audioPreparationWorker.removePreparedChunk(at: prepared.url)
                return result
            } catch {
                await audioPreparationWorker.removePreparedChunk(at: prepared.url)
                throw error
            }
        }
    }

    private func transcribePreparedChunk(_ prepared: LiveMeetingPreparedAudioChunk,
                                         track: TrackState, session: Int) async throws -> Advance? {
        guard isCurrent(session) else { return nil }
        isWorking = true
        defer { if generation == session { isWorking = false } }
        if !hasTranscribedOnce { statusMessage = "Preparing speech detection…" }
        let hasSpeech = try await detectSpeech(prepared.url)
        guard isCurrent(session) else { return nil }
        guard hasSpeech else {
            statusMessage = nil
            return Advance(frame: prepared.processedFrames, transcribed: false)
        }
        if !hasTranscribedOnce { statusMessage = "Preparing the transcription model…" }
        let transcript = try await transcribe(prepared.url, settings())
        guard isCurrent(session) else { return nil }
        hasTranscribedOnce = true
        statusMessage = nil
        let fresh = transcript.segments.compactMap { segment -> Line? in
            let text = segment.displayText
            guard !text.isEmpty else { return nil }
            return Line(time: prepared.startTime + segment.start, speaker: track.speaker, text: text)
        }
        return Advance(frame: prepared.processedFrames, transcribed: true, fresh: fresh)
    }
}
