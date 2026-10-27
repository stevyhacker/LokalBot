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

    struct Timing {
        var idlePoll: Duration = .seconds(1)
        var retryBaseSeconds: Double = 1
    }

    typealias SpeechDetector = @MainActor (URL) async throws -> Bool
    typealias Transcribe = @MainActor (URL, AppSettings) async throws -> Transcript

    @Published private(set) var lines: [Line] = []
    @Published private(set) var state: State = .off
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var previewStartTime: TimeInterval?

    var isRunning: Bool { state == .running }
    var errorMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    private let settings: () -> AppSettings
    private let audioPreparationWorker: LiveMeetingAudioPreparationWorker
    private let detectSpeech: SpeechDetector
    private let transcribe: Transcribe
    private let timing: Timing
    private var task: Task<Void, Never>?
    private var generation = 0
    private var pendingFolder: URL?
    private var hasTranscribedOnce = false
    private var initializedCursors = false
    private var resumeAfterHandoff = false
    private var tracks: [TrackState]
    private static let maxLines = 400
    private static let maxConsecutiveFailures = 3

    nonisolated static let scratchDirectoryName = "live-previews"

    init(storageRoot: URL,
         detectSpeech: SpeechDetector? = nil,
         transcribe: Transcribe? = nil,
         timing: Timing = Timing(),
         settings: @escaping () -> AppSettings) {
        self.settings = settings
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
            task = Task { [weak self] in await self?.play(script, session: session) }
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
        task = Task { [weak self] in
            await self?.run(folder: folder, session: session, position: position)
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
    }

#if LOKALBOT_UI_TEST_HOST
    /// UI-test host only: `LOKALBOT_UI_TEST_LIVE_SCRIPT` names a JSON array of
    /// `{time, speaker, text}`. Each line appears `time` seconds after the
    /// preview starts, as transcribed chunks would, with no audio or model.
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

    private func play(_ script: [Line], session: Int) async {
        let start = ContinuousClock.now
        for line in script.sorted(by: { $0.time < $1.time }) {
            try? await Task.sleep(until: start + .seconds(line.time), clock: .continuous)
            guard isCurrent(session) else { return }
            lines.append(line)
        }
    }
#endif

    private struct TrackState {
        let fileName: String
        let speaker: String
        var processedFrames: Int64 = 0
        var failures = 0
        var retryAfter: ContinuousClock.Instant?
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
            if !initializedCursors {
                let cursors = try await audioPreparationWorker.initialCursors(
                    in: folder, fileNames: tracks.map(\.fileName), recent: position == .recent)
                guard isCurrent(session) else { return }
                for index in tracks.indices { tracks[index].processedFrames = cursors[index] }
                // Both tee formats are fixed at 16 kHz. Actual chunk timestamps
                // still use the reader's sample rate.
                previewStartTime = Double(cursors.max() ?? 0) / 16_000
                initializedCursors = true
            }
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
                        tracks[index].failures += 1
                        let failures = tracks[index].failures
                        lokalbotLog("live transcript failed track=\(tracks[index].fileName) attempt=\(failures) error=\(error.localizedDescription)")
                        if failures >= Self.maxConsecutiveFailures {
                            let message = "Live preview could not continue. Retry from this point; recording is still running."
                            state = .failed(message)
                            statusMessage = message
                            return
                        }
                        let delay = timing.retryBaseSeconds * pow(2, Double(failures - 1))
                        tracks[index].retryAfter = ContinuousClock.now.advanced(by: .seconds(delay))
                        statusMessage = "Retrying live preview… (\(failures)/\(Self.maxConsecutiveFailures))"
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
