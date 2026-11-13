import AVFoundation
import CoreML
import FluidAudio
import XCTest
@testable import LokalBot

/// Opt-in measurement, run by hand: how soon after a speaker stops could the
/// live preview show that turn's text with a model on this Mac?
///
/// It replays a finished recording as if it were being recorded. A "turns"
/// pass cuts each track at pauses with the voice-activity model and the app's
/// `LiveTurnCutter`, and transcribes a turn once its pause is long enough. A "windows" pass repeats
/// what the preview does today: 4 to 12 second windows, track after track.
/// Decoding is timed for real; the recording's clock is simulated, so a
/// 3½-minute recording takes as long as its decoding.
///
/// A recording is `label=mixed[|track|track]`: the mixed file alone stands for
/// one track that carries several voices, and the optional files are the same
/// call with one voice per track, as the microphone and call audio are
/// recorded. Benchmarks/transcribe/LiveTurns has the scripts and the last results.
///
///     TEST_RUNNER_LOKALBOT_LIVE_TURN_BENCH=/folder/for/results \
///     TEST_RUNNER_LOKALBOT_LIVE_TURN_AUDIO='en=/p/mixed.m4a|/p/a.wav|/p/b.wav' \
///     TEST_RUNNER_LOKALBOT_LIVE_TURN_MODELS=parakeet-v3,qwen3-asr-1.7b \
///     TEST_RUNNER_LOKALBOT_LIVE_TURN_LANGUAGES=sr=hr \
///     TEST_RUNNER_LOKALBOT_LIVE_TURN_RULES=2:4,2:off \
///     xcodebuild test-without-building ... \
///       -only-testing:LokalBotTests/LiveTurnLatencyBenchmarkTests
///
/// Only models already downloaded are run; nothing is fetched.
final class LiveTurnLatencyBenchmarkTests: XCTestCase {

    /// A turn or a window: one piece of one track handed to the model.
    struct Piece: Codable {
        var track: Int
        var start: Double
        var end: Double
        /// Recording time at which the piece could be handed over: the pause
        /// was long enough, or the window was full.
        var decision: Double
        /// Cut by length, not by a pause.
        var forced: Bool
        var decodeSeconds = 0.0
        var cpuSeconds = 0.0
        /// Recording time at which the text exists, pieces decoded one at a time.
        var ready = 0.0
        var text = ""
    }

    /// How turns are closed: quiet chunks in a row, and the turn length from
    /// which one quiet chunk is enough (nil: never).
    struct Rule: Codable, Hashable {
        var quietChunks: Int
        var eagerAfterSeconds: Double?

        /// `2:4` is two quiet chunks, one once the turn is 4 s long; `2:off` never.
        init?(_ text: Substring) {
            let parts = text.split(separator: ":")
            guard let chunks = parts.first.flatMap({ Int($0) }), chunks > 0 else { return nil }
            quietChunks = chunks
            eagerAfterSeconds = parts.count > 1 ? Double(parts[1]) : nil
        }

        init(_ settings: LiveTurnCutter.Settings) {
            quietChunks = settings.quietChunksToClose
            eagerAfterSeconds = settings.eagerAfterSeconds
        }

        var settings: LiveTurnCutter.Settings {
            var settings = LiveTurnCutter.Settings()
            settings.quietChunksToClose = quietChunks
            settings.eagerAfterSeconds = eagerAfterSeconds
            return settings
        }

        /// Safe in a file name on every system.
        var label: String { "\(quietChunks)q" + (eagerAfterSeconds.map { "-\(String(format: "%g", $0))s" } ?? "") }
    }

    struct Cut: Codable {
        var recording: String
        var layout: String
        var rule: Rule
        var vadSecondsPerChunk: Double
        var pieces: [Piece]
    }

    struct Pass: Codable {
        var layout: String
        var kind: String
        var rule: Rule?
        var pieces: [Piece]
    }

    struct Run: Codable {
        var model: String
        var modelName: String
        var recording: String
        var language: String
        var audioSeconds: Double
        var loadSeconds: Double
        var firstDecodeSeconds: Double
        var footprintMegabytes: Double
        var optimized: Bool
        var passes: [Pass]
    }

    struct Stream: Codable {
        var model: String
        var recording: String
        var language: String
        var layout: String
        var audioSeconds: Double
        var loadSeconds: Double
        var chunkMilliseconds: Int
        /// Time to take in 160 ms of audio; most steps only buffer, one in every few runs the model.
        var stepSeconds: [Double]
        /// Seconds from the end of a word to its text existing, one entry per token.
        var tokenAges: [Double]
        var footprintMegabytes: Double
        var optimized: Bool
        var pieces: [Piece]
    }

    struct Replay: Codable {
        struct Arrival: Codable {
            /// Seconds into the replay at which the preview showed this.
            var at: Double
            /// Where the line starts in the recording.
            var time: Double
            var speaker: String
            var text: String
            /// A turn still being spoken, not a finished line.
            var partial: Bool
        }

        var model: String
        var recording: String
        var language: String
        var seconds: Double
        var optimized: Bool
        var arrivals: [Arrival]
    }

    private struct Recording {
        var label: String
        /// "mixed" and, when the per-voice files were given, "tracks".
        var layouts: [(name: String, tracks: [[Float]])]
        var language: String { label.split(separator: "-").first.map(String.init) ?? label }
    }

    private static let rate = Double(VadManager.sampleRate)
    /// Pause rules compared without a model, beside the app's own.
    private static let studied = ["1:off", "2:off", "3:off", "4:off", "2:3", "2:4", "2:6"].compactMap { Rule($0[...]) }
    private static let englishOnly: Set<TranscriptionModelChoice> = [.parakeetV2, .graniteTurbo, .graniteSpeech]
    private static let candidates: [TranscriptionModelChoice] = [
        .parakeetV3, .parakeetUltra, .parakeetV2, .qwenASR17B, .qwenASR06B,
        .whisperLarge, .graniteTurbo, .graniteSpeech,
    ]

    func testTurnByTurnDelay() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let outputPath = environment["LOKALBOT_LIVE_TURN_BENCH"],
              let audio = environment["LOKALBOT_LIVE_TURN_AUDIO"] else {
            throw XCTSkip("Set LOKALBOT_LIVE_TURN_BENCH and LOKALBOT_LIVE_TURN_AUDIO to run this measurement.")
        }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scratch = output.appendingPathComponent("scratch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let wanted = environment["LOKALBOT_LIVE_TURN_MODELS"].map { Set($0.split(separator: ",").map(String.init)) }
        // The rules a model is timed with; the app's own unless others are named.
        let rules = Self.rules(environment)

        let recordings = try Self.recordings(audio)
        XCTAssertFalse(recordings.isEmpty)
        guard let vad = try Self.voiceActivity() else {
            throw XCTSkip("The voice-activity model is not downloaded.")
        }
        let hints = Self.hints(environment)

        // Pause detection alone, for every setting: no model involved.
        var cuts: [String: [Piece]] = [:]
        for recording in recordings {
            for layout in recording.layouts {
                for rule in Set(Self.studied + rules).sorted(by: { $0.label < $1.label }) {
                    let cut = try await Self.cut(layout.tracks, vad: vad, rule: rule)
                    cuts["\(recording.label)/\(layout.name)/\(rule.label)"] = cut.pieces
                    try Self.write(Cut(recording: recording.label, layout: layout.name, rule: rule,
                                       vadSecondsPerChunk: cut.secondsPerChunk, pieces: cut.pieces),
                                   to: output.appendingPathComponent("cut-\(recording.label)-\(layout.name)-\(rule.label).json"))
                    print("live-turn cut \(recording.label) \(layout.name) rule=\(rule.label) pieces=\(cut.pieces.count) "
                          + "vad=\(String(format: "%.2f", cut.secondsPerChunk * 1000)) ms/chunk")
                }
            }
        }

        for choice in Self.candidates where wanted?.contains(choice.rawValue) ?? true {
            guard TranscriptionModelStore.isDownloaded(choice) else {
                print("live-turn skip \(choice.rawValue): not downloaded")
                continue
            }
            let engine = choice.engine
            let loadStart = ContinuousClock.now
            try await engine.prepare(progress: nil)
            let loadSeconds = Self.seconds(since: loadStart)
            for recording in recordings {
                if Self.englishOnly.contains(choice), recording.language != "en" { continue }
                let hint = hints[recording.label] ?? recording.language
                let language: String? = hint == "auto" ? nil : hint
                guard let mixed = recording.layouts.first?.tracks.first else { continue }
                // The first decode after a load pays for compilation and caches.
                let warm = try await Self.decode(Array(mixed.prefix(Int(6 * Self.rate))), engine: engine,
                                                 language: language, scratch: scratch)
                var passes: [Pass] = []
                for layout in recording.layouts {
                    for rule in rules {
                        guard var pieces = cuts["\(recording.label)/\(layout.name)/\(rule.label)"] else { continue }
                        var previousReady = 0.0
                        for index in pieces.indices {
                            let piece = pieces[index]
                            let result = try await Self.decode(
                                Self.slice(layout.tracks[piece.track], piece.start, piece.end),
                                engine: engine, language: language, scratch: scratch)
                            previousReady = max(piece.decision, previousReady) + result.seconds
                            pieces[index].decodeSeconds = result.seconds
                            pieces[index].cpuSeconds = result.cpu
                            pieces[index].ready = previousReady
                            pieces[index].text = result.text
                        }
                        passes.append(Pass(layout: layout.name, kind: "turns", rule: rule, pieces: pieces))
                    }
                    if layout.name == "tracks" {
                        passes.append(Pass(layout: layout.name, kind: "windows", rule: nil,
                                           pieces: try await Self.windows(layout.tracks, engine: engine,
                                                                          language: language, scratch: scratch)))
                    }
                }
                let run = Run(model: choice.rawValue, modelName: choice.displayName, recording: recording.label,
                              language: hint, audioSeconds: Double(mixed.count) / Self.rate,
                              loadSeconds: loadSeconds, firstDecodeSeconds: warm.seconds,
                              footprintMegabytes: Self.footprintMegabytes(), optimized: Self.isOptimized, passes: passes)
                let suffix = hint == recording.language ? "" : "@\(hint)"
                try Self.write(run, to: output.appendingPathComponent("run-\(choice.rawValue)-\(recording.label)\(suffix).json"))
                for pass in passes {
                    let decodes = pass.pieces.map(\.decodeSeconds).sorted()
                    guard !decodes.isEmpty else { continue }
                    print("live-turn run \(choice.rawValue) \(recording.label) \(pass.layout) \(pass.kind) "
                          + "rule=\(pass.rule?.label ?? "-") pieces=\(decodes.count) "
                          + "decode median=\(String(format: "%.2f", decodes[decodes.count / 2])) s "
                          + "max=\(String(format: "%.2f", decodes[decodes.count - 1])) s "
                          + "load=\(String(format: "%.1f", loadSeconds)) s first=\(String(format: "%.2f", warm.seconds)) s")
                }
            }
        }
    }

    /// The same replay through a streaming recognizer, which reads the audio
    /// as it arrives and puts words out while the speaker is still talking.
    /// The speech library the app links has one (Nemotron 3.5 streaming); the
    /// app does not use or download it, so point this at a folder that holds
    /// one variant's compiled models (Benchmarks/transcribe/LiveTurns/fetch_stream_model.py):
    ///
    ///     TEST_RUNNER_LOKALBOT_LIVE_STREAM_MODEL=/folder/multilingual-560ms \
    ///     TEST_RUNNER_LOKALBOT_LIVE_TURN_LANGUAGES=en=en-US,sr=hr-HR
    ///
    /// Each turn is a fresh stream, opened a little before its first word and
    /// closed when the pause after it is long enough.
    func testStreamingRecognizerDelay() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let outputPath = environment["LOKALBOT_LIVE_TURN_BENCH"],
              let audio = environment["LOKALBOT_LIVE_TURN_AUDIO"],
              let modelPath = environment["LOKALBOT_LIVE_STREAM_MODEL"] else {
            throw XCTSkip("Set LOKALBOT_LIVE_TURN_BENCH, LOKALBOT_LIVE_TURN_AUDIO and LOKALBOT_LIVE_STREAM_MODEL to run this measurement.")
        }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let rule = Self.rules(environment)[0]
        let recordings = try Self.recordings(audio)
        guard let vad = try Self.voiceActivity() else {
            throw XCTSkip("The voice-activity model is not downloaded.")
        }
        let hints = Self.hints(environment)
        let model = URL(fileURLWithPath: modelPath, isDirectory: true)

        let manager = StreamingNemotronMultilingualAsrManager()
        let loadStart = ContinuousClock.now
        try await manager.loadModels(from: model)
        let loadSeconds = Self.seconds(since: loadStart)
        let chunkMilliseconds = await manager.config.chunkMs
        let step = Int(0.16 * Self.rate)

        for recording in recordings {
            guard let layout = recording.layouts.last else { continue }
            let hint = hints[recording.label] ?? recording.language
            var pieces = try await Self.cut(layout.tracks, vad: vad, rule: rule).pieces
            var ages: [Double] = []
            var steps: [Double] = []
            for index in pieces.indices {
                let piece = pieces[index]
                let samples = layout.tracks[piece.track]
                await manager.reset()
                await manager.setLanguage(hint == "auto" ? nil : hint)
                let from = max(0, Int((piece.start - 0.3) * Self.rate))
                let to = min(samples.count, Int(piece.decision * Self.rate))
                let origin = Double(from) / Self.rate
                var offset = from
                var seen = 0
                let cpuStart = Self.cpuSeconds()
                while offset < to {
                    let end = min(offset + step, to)
                    let started = ContinuousClock.now
                    _ = try await manager.process(samples: Array(samples[offset..<end]))
                    let compute = Self.seconds(since: started)
                    steps.append(compute)
                    let timings = await manager.getTokenTimings()
                    let shown = Double(end) / Self.rate + compute
                    for timing in timings.dropFirst(seen) { ages.append(shown - (origin + timing.endTime)) }
                    seen = timings.count
                    offset = end
                }
                let started = ContinuousClock.now
                let final = try await manager.finishWithTokenTimings()
                let flush = Self.seconds(since: started)
                for timing in final.timings.dropFirst(seen) {
                    ages.append(piece.decision + flush - (origin + timing.endTime))
                }
                pieces[index].decodeSeconds = flush
                pieces[index].cpuSeconds = Self.cpuSeconds() - cpuStart
                pieces[index].ready = piece.decision + flush
                pieces[index].text = Transcript.normalizedText(final.text)
            }
            let run = Stream(model: model.lastPathComponent, recording: recording.label, language: hint,
                             layout: layout.name,
                             audioSeconds: Double(layout.tracks.first?.count ?? 0) / Self.rate,
                             loadSeconds: loadSeconds, chunkMilliseconds: chunkMilliseconds, stepSeconds: steps,
                             tokenAges: ages, footprintMegabytes: Self.footprintMegabytes(),
                             optimized: Self.isOptimized, pieces: pieces)
            try Self.write(run, to: output.appendingPathComponent("stream-\(model.lastPathComponent)-\(recording.label).json"))
            let sortedAges = ages.sorted()
            let sortedSteps = steps.sorted()
            guard !sortedAges.isEmpty, !sortedSteps.isEmpty else { continue }
            print("live-turn stream \(model.lastPathComponent) \(recording.label) \(hint) pieces=\(pieces.count) "
                  + "word age median=\(String(format: "%.2f", sortedAges[sortedAges.count / 2])) s "
                  + "p90=\(String(format: "%.2f", sortedAges[sortedAges.count * 9 / 10])) s "
                  + "step max=\(String(format: "%.3f", sortedSteps[sortedSteps.count - 1])) s "
                  + "load=\(String(format: "%.1f", loadSeconds)) s")
        }
    }

    /// The call played into the app's own live preview at the speed it was
    /// recorded. The two tracks grow as the recorder writes them, and
    /// `LiveMeetingTranscriber` runs turn by turn as it does in a meeting,
    /// with the real speech detection and the first model named. It shows
    /// that the feature works end to end and when each line reached the
    /// preview; it takes as long as the stretch it plays.
    ///
    ///     TEST_RUNNER_LOKALBOT_LIVE_REPLAY_SECONDS=90
    @MainActor
    func testPreviewReplayInRealTime() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let outputPath = environment["LOKALBOT_LIVE_TURN_BENCH"],
              let audio = environment["LOKALBOT_LIVE_TURN_AUDIO"],
              let seconds = environment["LOKALBOT_LIVE_REPLAY_SECONDS"].flatMap(Double.init),
              let choice = environment["LOKALBOT_LIVE_TURN_MODELS"]?.split(separator: ",").first
                .flatMap({ TranscriptionModelChoice(rawValue: String($0)) }) else {
            throw XCTSkip("Set LOKALBOT_LIVE_TURN_BENCH, LOKALBOT_LIVE_TURN_AUDIO, LOKALBOT_LIVE_TURN_MODELS and LOKALBOT_LIVE_REPLAY_SECONDS to run this replay.")
        }
        guard TranscriptionModelStore.isDownloaded(choice) else { throw XCTSkip("\(choice.rawValue) is not downloaded.") }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let hints = Self.hints(environment)
        // A meeting's first line pays for loading the model; this measures the ones after it.
        try await choice.engine.prepare(progress: nil)
        _ = try await SpeechActivity.shared.liveProbability(
            of: [Float](repeating: 0, count: SpeechActivity.liveChunkFrames), state: LiveVoiceState())

        for recording in try Self.recordings(audio) {
            guard let layout = recording.layouts.last, layout.name == "tracks", layout.tracks.count == 2 else { continue }
            if Self.englishOnly.contains(choice), recording.language != "en" { continue }
            let hint = hints[recording.label] ?? recording.language
            var settings = AppSettings()
            settings.turnByTurnLiveTextEnabled = true
            settings.transcriptionModel = choice
            settings.transcriptionLanguage = TranscriptionLanguage(rawValue: hint) ?? .auto
            let folder = output.appendingPathComponent("replay-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let warm = folder.appendingPathComponent("warm.caf")
            try Self.write(Array(layout.tracks[0].prefix(Int(3 * Self.rate))), to: warm)
            _ = try await settings.transcriptionEngine().transcribe(
                audio: warm, language: settings.transcriptionLanguage.code, prompt: nil)

            let names = [AudioPreviewTee.micFileName, AudioPreviewTee.systemFileName]
            let files = try names.map { try Self.liveFile(at: folder.appendingPathComponent($0)) }
            let transcriber = LiveMeetingTranscriber(storageRoot: folder) { settings }
            transcriber.prepare(folder: folder)
            transcriber.activate(from: .beginning)
            XCTAssertEqual(transcriber.engine, .turns)

            var arrivals: [Replay.Arrival] = []
            var seen = Set<UUID>()
            var shown: [String: String] = [:]
            var written = 0
            let total = min(layout.tracks[0].count, Int(seconds * Self.rate))
            let started = ContinuousClock.now
            // Three more seconds after the last sample, for the last turn's text.
            while Self.seconds(since: started) < Double(total) / Self.rate + 3 {
                let due = min(total, Int(Self.seconds(since: started) * Self.rate))
                if due > written {
                    for (file, track) in zip(files, layout.tracks) {
                        try Self.append(Array(track[written..<due]), to: file)
                    }
                    written = due
                }
                let now = Self.seconds(since: started)
                for line in transcriber.lines where seen.insert(line.id).inserted {
                    arrivals.append(.init(at: now, time: line.time, speaker: line.speaker, text: line.text, partial: false))
                }
                for line in transcriber.partials where shown[line.speaker] != line.text {
                    arrivals.append(.init(at: now, time: line.time, speaker: line.speaker, text: line.text, partial: true))
                }
                shown = Dictionary(transcriber.partials.map { ($0.speaker, $0.text) }, uniquingKeysWith: { $1 })
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNil(transcriber.errorMessage)
            transcriber.stop()
            let lines = arrivals.filter { !$0.partial }
            XCTAssertFalse(lines.isEmpty, "the preview showed nothing")
            let suffix = hint == recording.language ? "" : "@\(hint)"
            try Self.write(Replay(model: choice.rawValue, recording: recording.label, language: hint,
                                  seconds: Double(total) / Self.rate, optimized: Self.isOptimized, arrivals: arrivals),
                           to: output.appendingPathComponent("replay-\(choice.rawValue)-\(recording.label)\(suffix).json"))
            print("live-turn replay \(choice.rawValue) \(recording.label) seconds=\(Double(total) / Self.rate) "
                  + "lines=\(lines.count) shown while speaking=\(arrivals.count - lines.count)")
        }
    }

    /// A growing 16 kHz file like the ones the recorder keeps for the preview.
    private static func liveFile(at url: URL) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ]
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    private static func append(_ samples: [Float], to file: AVAudioFile) throws {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
    }

    // MARK: - Setup

    private static func recordings(_ audio: String) throws -> [Recording] {
        var recordings: [Recording] = []
        for pair in audio.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            // A second of quiet after the last word, so the last turn can close
            // as it would while a recording goes on.
            let files = try parts[1].split(separator: "|").map {
                try AudioConverter().resampleAudioFile(URL(fileURLWithPath: String($0)))
                    + [Float](repeating: 0, count: Int(rate))
            }
            guard let mixed = files.first else { continue }
            var layouts = [(name: "mixed", tracks: [mixed])]
            if files.count > 1 { layouts.append((name: "tracks", tracks: Array(files.dropFirst()))) }
            recordings.append(Recording(label: String(parts[0]), layouts: layouts))
        }
        return recordings
    }

    /// The voice-activity model the app already has, or nil before its first download.
    private static func voiceActivity() throws -> VadManager? {
        let file = TranscriptionModelStore.Environment.live.fluidAudioModelsRoot
            .appendingPathComponent(Repo.vad.folderName)
            .appendingPathComponent(ModelNames.VAD.sileroVadFile)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = VadConfig.default.computeUnits
        return VadManager(vadModel: try MLModel(contentsOf: file, configuration: configuration))
    }

    /// `LOKALBOT_LIVE_TURN_RULES=2:4,1:off` times those pause rules; without it, the app's own.
    private static func rules(_ environment: [String: String]) -> [Rule] {
        let named = (environment["LOKALBOT_LIVE_TURN_RULES"] ?? "").split(separator: ",").compactMap { Rule($0) }
        return named.isEmpty ? [Rule(LiveTurnCutter.Settings())] : named
    }

    /// `sr=hr` hands the model another language code for a recording; `sr=auto` hands it none.
    private static func hints(_ environment: [String: String]) -> [String: String] {
        var hints: [String: String] = [:]
        for pair in (environment["LOKALBOT_LIVE_TURN_LANGUAGES"] ?? "").split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { hints[String(parts[0])] = String(parts[1]) }
        }
        return hints
    }

    // MARK: - Turns

    /// Streams each track through the voice-activity model one 256 ms chunk
    /// at a time, as a live feed arrives, and lets the app's `LiveTurnCutter`
    /// close the turns. A turn that runs to the maximum length is cut at the
    /// quietest point of its last 1.5 s, as the preview cuts its windows.
    /// Pieces come back in the order they close.
    private static func cut(_ tracks: [[Float]], vad: VadManager,
                            rule: Rule) async throws -> (pieces: [Piece], secondsPerChunk: Double) {
        var pieces: [Piece] = []
        var chunks = 0
        let started = ContinuousClock.now
        for (track, samples) in tracks.enumerated() {
            var state = await vad.makeStreamState()
            var cutter = LiveTurnCutter(settings: rule.settings)
            var offset = 0
            while offset + VadManager.chunkSize <= samples.count {
                let end = offset + VadManager.chunkSize
                let result = try await vad.processStreamingChunk(Array(samples[offset..<end]), state: state)
                state = result.state
                chunks += 1
                let turn = cutter.consume(probability: result.probability) { from, to in
                    let search = min(to - from, Int64(LiveTranscriptChunker.cutSearchSeconds * rate))
                    let tail = Array(samples[Int(to - search)..<Int(to)])
                    return to - search + Int64(LiveTranscriptChunker.refinedCutOffset(tail: tail, sampleRate: rate))
                }
                if let turn {
                    // The verdict on a chunk exists once the whole chunk has been recorded.
                    pieces.append(Piece(track: track, start: Double(turn.start) / rate, end: Double(turn.end) / rate,
                                        decision: Double(end) / rate, forced: turn.forced))
                }
                offset = end
            }
        }
        pieces.sort { $0.decision < $1.decision }
        return (pieces, seconds(since: started) / Double(max(1, chunks)))
    }

    // MARK: - Windows, as the preview cuts them today

    /// `LiveMeetingTranscriber.run` and
    /// `LiveMeetingAudioPreparationWorker.prepareNextChunk` on a simulated
    /// clock: each track in turn gives up a window once 4 s are waiting (12 s
    /// at most), cut at a quiet point and checked for speech; with nothing to
    /// do the preview looks again a second later.
    private static func windows(_ tracks: [[Float]], engine: TranscriptionEngine, language: String?,
                                scratch: URL) async throws -> [Piece] {
        var pieces: [Piece] = []
        var clock = 0.0
        var processed = [Int64](repeating: 0, count: tracks.count)
        while true {
            var didWork = false
            var waiting = false
            for (track, samples) in tracks.enumerated() {
                let total = Int64(samples.count)
                let available = min(total, Int64(clock * rate))
                if available < total { waiting = true }
                guard let range = LiveTranscriptChunker.nextChunk(
                    processedFrames: processed[track], totalFrames: available, sampleRate: rate) else { continue }
                var chunk = Array(samples[Int(range.lowerBound)..<Int(range.upperBound)])
                let searchCount = min(chunk.count, Int(LiveTranscriptChunker.cutSearchSeconds * rate))
                if searchCount > 0 {
                    let offset = LiveTranscriptChunker.refinedCutOffset(
                        tail: Array(chunk.suffix(searchCount)), sampleRate: rate)
                    chunk.removeLast(searchCount - offset)
                }
                guard !chunk.isEmpty else { continue }
                let chunkEnd = range.lowerBound + Int64(chunk.count)
                didWork = true
                processed[track] = chunkEnd
                guard let candidate = LiveTranscriptChunker.speechCandidate(from: chunk, sampleRate: rate) else { continue }
                let wallStart = ContinuousClock.now
                let cpuStart = cpuSeconds()
                let file = scratch.appendingPathComponent("window-\(UUID().uuidString).caf")
                defer { try? FileManager.default.removeItem(at: file) }
                try write(candidate, to: file)
                var text = ""
                if (await SpeechActivity.shared.speechSeconds(in: file) ?? 1) > 0 {
                    let transcript = try await engine.transcribe(audio: file, language: language, prompt: nil)
                    text = transcript.segments.map(\.displayText).filter { !$0.isEmpty }.joined(separator: " ")
                }
                let decode = seconds(since: wallStart)
                pieces.append(Piece(track: track, start: Double(range.lowerBound) / rate, end: Double(chunkEnd) / rate,
                                    decision: clock, forced: false, decodeSeconds: decode,
                                    cpuSeconds: cpuSeconds() - cpuStart, ready: clock + decode, text: text))
                clock += decode
            }
            if !didWork {
                // The last few seconds of a track wait for the recording to stop.
                guard waiting else { break }
                clock += 1
            }
        }
        return pieces
    }

    // MARK: - Helpers

    private static func slice(_ samples: [Float], _ start: Double, _ end: Double) -> [Float] {
        let lower = max(0, min(samples.count, Int(start * rate)))
        let upper = max(lower, min(samples.count, Int(end * rate)))
        return Array(samples[lower..<upper])
    }

    private static func decode(_ samples: [Float], engine: TranscriptionEngine, language: String?,
                               scratch: URL) async throws -> (text: String, seconds: Double, cpu: Double) {
        let file = scratch.appendingPathComponent("turn-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: file) }
        let wallStart = ContinuousClock.now
        let cpuStart = cpuSeconds()
        try write(samples, to: file)
        let transcript = try await engine.transcribe(audio: file, language: language, prompt: nil)
        let text = transcript.segments.map(\.displayText).filter { !$0.isEmpty }.joined(separator: " ")
        return (text, seconds(since: wallStart), cpuSeconds() - cpuStart)
    }

    /// 16 kHz mono float, the format the preview hands a model.
    private static func write(_ samples: [Float], to url: URL) throws {
        guard !samples.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        try append(samples, to: try liveFile(at: url))
    }

    private static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = (ContinuousClock.now - start).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    /// CPU time this process has used, all threads. A model that runs in a
    /// helper process (Granite Speech) is not counted.
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    private static func footprintMegabytes() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// `assert` is compiled out of optimized builds, whatever flags are set.
    private static var isOptimized: Bool {
        var unoptimized = false
        assert({ unoptimized = true; return true }())
        return !unoptimized
    }
}
