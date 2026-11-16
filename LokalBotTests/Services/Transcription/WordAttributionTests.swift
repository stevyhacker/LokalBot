import Darwin
import XCTest
@testable import LokalBot

/// Transcribe-first speaker attribution: forced-aligned words are assigned
/// to diarized turns after whole-track ASR, instead of cutting audio first.
final class WordAttributionTests: XCTestCase {
    private func aligned(_ text: String, start: Double, end: Double,
                         words: [(String, Double, Double)]) -> AttributedTrackTranscriber.AlignedSegment {
        .init(segment: .init(start: start, end: end, speaker: "speaker", text: text, timingPrecision: .span),
              words: words.map { AlignedWordTiming(text: $0.0, start: $0.1, end: $0.2) })
    }

    func testSpeakerChangeSplitsASegmentWithoutRewritingItsText() {
        let segment = aligned("Hello there. Yes, I agree.", start: 0, end: 2.2, words: [
            ("Hello", 0.1, 0.4), ("there.", 0.4, 0.8), ("Yes,", 1.2, 1.5), ("I", 1.5, 1.6), ("agree.", 1.6, 2.0),
        ])
        let result = AttributedTrackTranscriber.attribute([segment], duration: 10, turns: [
            .init(start: 0, end: 1.0, speakerId: "A"), .init(start: 1.1, end: 2.5, speakerId: "B"),
        ], source: .system, contentRange: nil)
        XCTAssertEqual(result.map(\.text), ["Hello there.", "Yes, I agree."])
        XCTAssertEqual(result.map(\.speaker), ["them 1", "them 2"])
        XCTAssertEqual(result.map(\.resolvedAttribution.method), [.diarization, .diarization])
        XCTAssertEqual(result.map(\.resolvedAttribution.identity), [.other, .other])
        XCTAssertEqual(result.map(\.timingPrecision), [.token, .token])
        // Each piece widens to its own turn, never into its neighbour.
        XCTAssertEqual(result.map(\.start), [0, 1.1])
        XCTAssertEqual(result.map(\.end), [1.0, 2.5])
    }

    func testOverlapIsUnclearAndTheMicrophoneDefaultMatchesRegions() {
        let segment = aligned("one two three", start: 0, end: 3, words: [
            ("one", 0.2, 0.6), ("two", 1.2, 1.6), ("three", 2.2, 2.6),
        ])
        let result = AttributedTrackTranscriber.attribute([segment], duration: 3, turns: [
            .init(start: 0, end: 1.9, speakerId: "A"), .init(start: 1.0, end: 3, speakerId: "B"),
        ], source: .microphone, contentRange: nil)
        XCTAssertEqual(result.map(\.speaker), ["local 1", "local unclear", "local 2"])
        XCTAssertEqual(result.map(\.resolvedAttribution.method), [.diarization, .overlappingSpeech, .diarization])
        XCTAssertEqual(result.map(\.resolvedAttribution.identity), [.user, .unresolved, .user])
        XCTAssertEqual(result.map(\.start), [0, 1.2, 1.6])
        XCTAssertEqual(result.map(\.end), [1.2, 1.6, 3])
    }

    func testWordsNearATurnTakeItsSpeakerAndDistantWordsKeepTheTrackLabel() {
        let segment = aligned("near far", start: 1.1, end: 3.5, words: [("near", 1.2, 1.6), ("far", 3.0, 3.4)])
        let result = AttributedTrackTranscriber.attribute([segment], duration: 5, turns: [
            .init(start: 0, end: 1.0, speakerId: "A"),
        ], source: .system, contentRange: nil)
        XCTAssertEqual(result.map(\.speaker), ["them 1", "them"])
        XCTAssertEqual(result.map(\.resolvedAttribution.method), [.diarization, .track])
        XCTAssertEqual(result.map(\.resolvedAttribution.identity), [.other, .other])
    }

    func testContentRangeDropsWordsOutsideIt() {
        let segment = aligned("before inside after", start: 0, end: 3, words: [
            ("before", 0.2, 0.6), ("inside", 1.2, 1.6), ("after", 2.4, 2.8),
        ])
        let result = AttributedTrackTranscriber.attribute([segment], duration: 3, turns: [
            .init(start: 0, end: 3, speakerId: "A"),
        ], source: .system, contentRange: .init(start: 1, end: 2))
        XCTAssertEqual(result.map(\.text), ["inside"])
        XCTAssertEqual(result.map(\.start), [1])
        XCTAssertEqual(result.map(\.end), [2])
        XCTAssertTrue(AttributedTrackTranscriber.attribute([segment], duration: 3, turns: [], source: .system,
                                                           contentRange: .init(start: 2, end: 1)).isEmpty)
    }

    func testUnmatchedOrMissingAlignmentKeepsTheSegmentWhole() {
        let turns: [DiarizedSegment] = [.init(start: 0, end: 5, speakerId: "A")]
        for words in [[("zzz", 0.5, 0.9)], []] {
            let result = AttributedTrackTranscriber.attribute(
                [aligned("Unaligned words stay together.", start: 1, end: 3, words: words)],
                duration: 5, turns: turns, source: .system, contentRange: nil)
            XCTAssertEqual(result.map(\.text), ["Unaligned words stay together."])
            XCTAssertEqual(result.map(\.speaker), ["them 1"])
            XCTAssertEqual(result.map(\.timingPrecision), [.span])
        }
    }

    func testUnspacedTextIsCutAtCharacterBoundaries() {
        let segment = aligned("你好世界。", start: 0, end: 2, words: [
            ("你", 0, 0.2), ("好", 0.2, 0.4), ("世", 1.2, 1.4), ("界。", 1.4, 1.6),
        ])
        let result = AttributedTrackTranscriber.attribute([segment], duration: 2, turns: [
            .init(start: 0, end: 0.8, speakerId: "A"), .init(start: 1.0, end: 2, speakerId: "B"),
        ], source: .system, contentRange: nil)
        XCTAssertEqual(result.map(\.text), ["你好", "世界。"])
    }

    func testPausesAndLongMonologuesStartNewSegments() {
        let turns: [DiarizedSegment] = [.init(start: 0, end: 40, speakerId: "A")]
        let paused = aligned("One two. Three four.", start: 0, end: 5, words: [
            ("One", 0.1, 0.4), ("two.", 0.5, 0.9), ("Three", 2.9, 3.2), ("four.", 3.3, 3.6),
        ])
        XCTAssertEqual(AttributedTrackTranscriber.attribute([paused], duration: 40, turns: turns, source: .system,
                                                            contentRange: nil).map(\.text),
                       ["One two.", "Three four."])

        // 40 back-to-back half-second words: the 15 s cap splits after word 29.
        let words = (0..<40).map { ("w\($0)", Double($0) * 0.5, Double($0) * 0.5 + 0.5) }
        let monologue = aligned(words.map(\.0).joined(separator: " "), start: 0, end: 20, words: words)
        let pieces = AttributedTrackTranscriber.attribute([monologue], duration: 40, turns: turns, source: .system,
                                                          contentRange: nil)
        XCTAssertEqual(pieces.map { $0.text.split(separator: " ").count }, [30, 10])
        XCTAssertEqual(Set(pieces.map(\.speaker)), ["them 1"])
    }

    func testLongContextWindowsJoinShortPausesUpToTheLimit() {
        let spans = [(0.0, 10.0), (11, 20), (26, 30), (30.5, 50), (50.5, 70), (70.5, 90)]
            .map { SpeechSpan(start: $0.0, end: $0.1, timingPrecision: .span) }
        let windows = QwenASREngine.merged(spans, maxGap: 5, maxLength: 60)
        XCTAssertEqual(windows.map(\.start), [0, 26, 70.5])
        XCTAssertEqual(windows.map(\.end), [20, 70, 90])
        XCTAssertTrue(windows.allSatisfy { $0.timingPrecision == .span })
    }

    func testWordStartsMatchLettersPastAdjacentPunctuation() throws {
        let text = "\"Well, state-of-the-art isn't cheap.\""
        let starts = try XCTUnwrap(AttributedTrackTranscriber.wordStarts(
            ["\"Well,", "state-of-the-art", "isn't", "cheap.\""], in: text))
        XCTAssertEqual(starts.map { String(text[$0...].prefix(4)) }, ["Well", "stat", "isn'", "chea"])
        XCTAssertNil(AttributedTrackTranscriber.wordStarts(["missing"], in: text))
    }

    func testQwenTiersAttributeAlignedWordsWithTheirMeasuredWindows() {
        XCTAssertEqual(QwenASREngine.accuracy.speakerAttribution, .alignedWords)
        XCTAssertEqual(QwenASREngine.compact.speakerAttribution, .alignedWords)
        XCTAssertEqual(TranscriptionModelChoice.parakeetV3.engine.speakerAttribution, .regions)
        // 1.7B used 60 s with the MLX aligner; the CoreML aligner takes 30 s at most.
        XCTAssertEqual(QwenASREngine.wordAttributionWindows(for: .accuracy),
                       .init(maxSeconds: 30, maxGapSeconds: 5))
        // 0.6B stays at 15 s: longer windows decoded 5–10× slower for a small gain.
        XCTAssertEqual(QwenASREngine.wordAttributionWindows(for: .compact),
                       .init(maxSeconds: 15, maxGapSeconds: 5))
    }

    func testAlignerLanguagesAndPinnedSnapshot() throws {
        for code in ["en", "zh-Hant", "pt-PT", "yue", "ja"] { XCTAssertTrue(QwenWordAligner.supports(code), code) }
        for code in ["sr", "nl", "ar", ""] { XCTAssertFalse(QwenWordAligner.supports(code), code) }
        XCTAssertEqual(QwenWordAligner.detectedLanguage(of: ["This is an English sentence about the quarterly plan."]), "en")
        XCTAssertNil(QwenWordAligner.detectedLanguage(of: ["Dit is een Nederlandse zin over het kwartaalplan van het team."]))

        let snapshot = QwenWordAligner.snapshot
        XCTAssertEqual(snapshot.repository, "aufklarer/Qwen3-ForcedAligner-0.6B-CoreML-INT8")
        XCTAssertEqual(snapshot.revision.count, 40)
        for path in ["audio_encoder.mlmodelc/weights/weight.bin", "text_decoder.mlmodelc/weights/weight.bin",
                     "embed_tokens.fp16.bin"] {
            let weights = try XCTUnwrap(snapshot.files.first { $0.path == path }, path)
            XCTAssertFalse(weights.isGitBlob, path)
            XCTAssertEqual(weights.digest.count, 64, path)
        }
        // Compiled bundles only: an .mlpackage would compile on every load.
        XCTAssertFalse(snapshot.files.contains { $0.path.contains(".mlpackage") })
        XCTAssertEqual(Set(snapshot.files.filter { !$0.path.contains("/") }.map(\.path)),
                       ["config.json", "embed_tokens.fp16.bin", "merges.txt", "tokenizer_config.json", "vocab.json"])
        // Settings and PRIVACY.md describe this download as about 1.1 GB.
        XCTAssertEqual(Double(snapshot.files.reduce(0) { $0 + $1.bytes }) / 1e9, 1.08, accuracy: 0.02)
    }

    /// Every window handed to the aligner fits its 30 s encoder, including the
    /// extra sample that flooring both edges can add.
    func testWordAttributionWindowsFitTheAlignerEncoder() {
        let limits = [QwenASREngine.wordAttributionWindows(for: .accuracy).maxSeconds,
                      QwenASREngine.wordAttributionWindows(for: .compact).maxSeconds,
                      RemoteTranscriptionEngine.attributionWindows.maxSeconds]
        for limit in limits {
            XCTAssertLessThanOrEqual(limit, QwenWordAligner.maxSegmentSeconds)
            for start in [0.0, 0.000_03, 12.345_678, 3_599.999_97] {
                // SpanAudioReader floors both frame positions.
                let samples = Int((start + limit) * 16_000) - Int(start * 16_000)
                XCTAssertLessThanOrEqual(samples, QwenWordAligner.maxSamples, "\(limit) s from \(start)")
                XCTAssertLessThanOrEqual(samples / 160, 3_000, "mel frames for \(limit) s from \(start)")
            }
        }
    }

    /// A segment past the encoder's 30 s is refused before any model loads,
    /// so the caller's one-speaker fallback applies without a download.
    func testAlignerRefusesSegmentsLongerThanItsEncoder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-aligner-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples = [Float](repeating: 0, count: QwenWordAligner.maxSamples + 1)
        do {
            _ = try await QwenWordAligner(directory: directory).align(samples, text: "Too long.", language: "en")
            XCTFail("expected the aligner to refuse a segment over 30 s")
        } catch QwenWordAligner.AlignerError.segmentTooLong(let seconds) {
            XCTAssertEqual(seconds, 30.01, accuracy: 0.01)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    /// The MLX aligner's folder is deleted once the CoreML snapshot is
    /// verified; other folders and symlinked ones are left alone.
    func testObsoleteAlignerFolderIsRemovedByExactPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-aligner-root-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let obsolete = QwenASREngine.hubStyleCacheDir(base: root, modelID: "aufklarer/Qwen3-ForcedAligner-0.6B-4bit")
        let current = QwenASREngine.hubStyleCacheDir(base: root, modelID: QwenWordAligner.snapshot.repository)
        let asr = QwenASREngine.hubStyleCacheDir(base: root, modelID: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit")
        for folder in [obsolete, current, asr] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent("model.safetensors"))
        }
        try QwenWordAligner.removeObsoleteModels(in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: obsolete.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.appendingPathComponent("model.safetensors").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: asr.appendingPathComponent("model.safetensors").path))

        // A symlink in the obsolete folder's place is not followed or removed.
        try FileManager.default.createSymbolicLink(at: obsolete, withDestinationURL: asr)
        try QwenWordAligner.removeObsoleteModels(in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: asr.appendingPathComponent("model.safetensors").path))
    }

    // MARK: - Word times from the transcription server

    /// MAI-Transcribe-2's words for a synthetic clip: one voice, then another
    /// from 5.0 s (`RemoteTranscriptionEngineTests.recordedVerboseJSON`).
    private let twoVoices = WordTimedTranscript.Segment(
        segment: .init(start: 0, end: 8.2, speaker: "speaker",
                       text: "The quarterly plan is ready for review. Thanks. I will send my notes tomorrow.",
                       timingPrecision: .span),
        words: [("The", 0.08, 0.179), ("quarterly", 0.24, 0.62), ("plan", 0.72, 0.92), ("is", 0.98, 1.06),
                ("ready", 1.16, 1.36), ("for", 1.4, 1.519), ("review.", 1.64, 1.979), ("Thanks.", 5.16, 5.66),
                ("I", 5.96, 6.04), ("will", 6.08, 6.24), ("send", 6.36, 6.539), ("my", 6.6, 6.719),
                ("notes", 6.84, 7.08), ("tomorrow.", 7.16, 7.719)].map { AlignedWordTiming(text: $0.0, start: $0.1, end: $0.2) })
    private let twoTurns: [DiarizedSegment] = [.init(start: 0, end: 2.1, speakerId: "A"),
                                               .init(start: 5.1, end: 7.8, speakerId: "B")]

    @MainActor
    func testServerWordTimesSkipTheAligner() async throws {
        let engine = ServerTimedASR(providesWordTimings: true, segments: [twoVoices])
        let aligner = AlignerFetches()

        let result = try await AttributedTrackTranscriber.transcribe(
            url: URL(fileURLWithPath: "/nonexistent/track.wav"), duration: 10, diarization: twoTurns, source: .system,
            engine: engine, language: "en", prompt: nil, prepareAligner: { try aligner.fetch() })

        XCTAssertEqual(result.segments.map(\.text),
                       ["The quarterly plan is ready for review.", "Thanks. I will send my notes tomorrow."])
        XCTAssertEqual(result.segments.map(\.speaker), ["them 1", "them 2"])
        XCTAssertEqual(result.segments.map(\.start), [0, 5.1])
        XCTAssertEqual(result.segments.map(\.end), [2.1, 7.8])
        XCTAssertEqual(result.engine, "Server fixture")
        XCTAssertEqual(aligner.count, 0, "Not even downloaded")
        XCTAssertEqual(engine.calls.regions, 0)
    }

    @MainActor
    func testServerWordTimesAttributeLanguagesTheAlignerLacks() async throws {
        let serbian = WordTimedTranscript.Segment(
            segment: .init(start: 0, end: 8, speaker: "speaker",
                           text: "Plan je spreman za pregled. Hvala, poslaću beleške sutra.", timingPrecision: .span),
            words: [("Plan", 0.1, 0.4), ("je", 0.45, 0.55), ("spreman", 0.6, 1.0), ("za", 1.05, 1.15),
                    ("pregled.", 1.2, 1.8), ("Hvala,", 5.2, 5.6), ("poslaću", 5.7, 6.1), ("beleške", 6.2, 6.6),
                    ("sutra.", 6.7, 7.2)].map { AlignedWordTiming(text: $0.0, start: $0.1, end: $0.2) })
        let engine = ServerTimedASR(providesWordTimings: true, segments: [serbian])
        let aligner = AlignerFetches()

        let result = try await AttributedTrackTranscriber.transcribe(
            url: URL(fileURLWithPath: "/nonexistent/track.wav"), duration: 10, diarization: twoTurns, source: .system,
            engine: engine, language: "sr", prompt: nil, prepareAligner: { try aligner.fetch() })

        XCTAssertEqual(result.segments.map(\.text), ["Plan je spreman za pregled.", "Hvala, poslaću beleške sutra."])
        XCTAssertEqual(result.segments.map(\.speaker), ["them 1", "them 2"])
        XCTAssertEqual(aligner.count, 0)
        XCTAssertEqual(engine.calls.regions, 0, "Before server word times, Serbian fell back to speaker regions")
    }

    @MainActor
    func testSegmentsTheServerLeftUntimedAreAlignedOrKeptWhole() async throws {
        let untimed = WordTimedTranscript.Segment(
            segment: .init(start: 7.9, end: 8.6, speaker: "speaker", text: "Okay, see you then.", timingPrecision: .span))
        let engine = ServerTimedASR(providesWordTimings: true, segments: [twoVoices, untimed])
        let aligner = AlignerFetches(fails: true)

        let result = try await AttributedTrackTranscriber.transcribe(
            url: URL(fileURLWithPath: "/nonexistent/track.wav"), duration: 10, diarization: twoTurns, source: .system,
            engine: engine, language: "en", prompt: nil, prepareAligner: { try aligner.fetch() })

        XCTAssertEqual(aligner.count, 1, "Only the untimed segment needs the aligner")
        XCTAssertEqual(result.segments.map(\.text), ["The quarterly plan is ready for review.",
                                                     "Thanks. I will send my notes tomorrow.", "Okay, see you then."])
        XCTAssertEqual(result.segments.map(\.speaker), ["them 1", "them 2", "them 2"],
                       "Without the aligner the untimed segment keeps the speaker at its midpoint")
        XCTAssertEqual(engine.calls.regions, 0)
    }

    @MainActor
    func testWithoutAnyWordTimesAnUnsupportedLanguageStillUsesRegions() async throws {
        let url = try writeTrack(seconds: 10)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var untimed = twoVoices
        untimed.words = nil
        let engine = ServerTimedASR(providesWordTimings: true, segments: [untimed])
        let aligner = AlignerFetches()

        let result = try await AttributedTrackTranscriber.transcribe(
            url: url, duration: 10, diarization: twoTurns, source: .system,
            engine: engine, language: "sr", prompt: nil, prepareAligner: { try aligner.fetch() })

        XCTAssertEqual(aligner.count, 0)
        XCTAssertEqual(engine.calls.wordAttribution, 1)
        XCTAssertEqual(engine.calls.regions, 4)
        XCTAssertEqual(engine.calls.regionLanguages, Array(repeating: "sr", count: 4))
        XCTAssertEqual(Set(result.segments.map(\.speaker)), ["them", "them 1", "them 2"])
    }

    /// On auto-detect, a track the aligner cannot time falls back to speaker
    /// regions. Those regions are seconds long, too short to detect the
    /// language again: Qwen reads breaths and short replies in them as
    /// Chinese, Japanese or Russian. They decode in the language the whole
    /// track settled on instead.
    @MainActor
    func testRegionsFallbackDecodesInTheLanguageTheTrackSettledOn() async throws {
        let url = try writeTrack(seconds: 10)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let serbian = WordTimedTranscript.Segment(
            segment: .init(start: 0, end: 8.2, speaker: "speaker",
                           text: "Sastanak smo pomjerili za sljedeću sedmicu. Hvala.",
                           timingPrecision: .span),
            words: nil)
        let engine = ServerTimedASR(providesWordTimings: false, segments: [serbian], trackLanguage: "hr")
        let aligner = AlignerFetches()

        _ = try await AttributedTrackTranscriber.transcribe(
            url: url, duration: 10, diarization: twoTurns, source: .system,
            engine: engine, language: nil, prompt: nil, prepareAligner: { try aligner.fetch() })

        XCTAssertEqual(aligner.count, 1)
        XCTAssertEqual(engine.calls.wordAttribution, 1)
        XCTAssertEqual(engine.calls.regions, 4)
        XCTAssertEqual(engine.calls.regionLanguages, Array(repeating: "hr", count: 4))
    }

    /// Speaker regions also cover the pauses between turns. Given one with
    /// no speech, Whisper writes a stock phrase such as "Thank you.", so a
    /// region without detected speech is not decoded.
    @MainActor
    func testRegionsWithoutDetectedSpeechAreNotDecoded() async throws {
        let url = try writeTrack(seconds: 10)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var untimed = twoVoices
        untimed.words = nil
        // Turns A (0–2.1 s) and B (5.1–7.8 s), and the pauses after each.
        let speech: [ClosedRange<TimeInterval>] = [0.2...2.0, 5.2...7.6]

        let engine = ServerTimedASR(providesWordTimings: true, segments: [untimed])
        let result = try await AttributedTrackTranscriber.transcribe(
            url: url, duration: 10, diarization: twoTurns, source: .system,
            engine: engine, language: "sr", prompt: nil, speech: speech, prepareAligner: {})

        XCTAssertEqual(engine.calls.regions, 2, "Only the two turns hold speech")
        XCTAssertEqual(Set(result.segments.map(\.speaker)), ["them 1", "them 2"])

        let undetected = ServerTimedASR(providesWordTimings: true, segments: [untimed])
        _ = try await AttributedTrackTranscriber.transcribe(
            url: url, duration: 10, diarization: twoTurns, source: .system,
            engine: undetected, language: "sr", prompt: nil, speech: nil, prepareAligner: {})
        XCTAssertEqual(undetected.calls.regions, 4, "Without detection every region is decoded, as before")
    }

    @MainActor
    func testEnginesWithoutWordTimesFetchTheAlignerBeforeTranscribing() async throws {
        let url = try writeTrack(seconds: 10)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = ServerTimedASR(providesWordTimings: false, segments: [twoVoices])
        let aligner = AlignerFetches(fails: true)

        _ = try await AttributedTrackTranscriber.transcribe(
            url: url, duration: 10, diarization: twoTurns, source: .system,
            engine: engine, language: "en", prompt: nil, prepareAligner: { try aligner.fetch() })

        XCTAssertEqual(aligner.count, 1)
        XCTAssertEqual(engine.calls.wordAttribution, 0, "An unavailable aligner means speaker regions, as before")
        XCTAssertEqual(engine.calls.regions, 4)
    }

    func testServerWordsThatDoNotMatchTheTextGoToTheAligner() {
        XCTAssertEqual(AttributedTrackTranscriber.engineWords(of: twoVoices)?.count, 14)
        var mismatched = twoVoices
        mismatched.words?[3].text = "was"
        XCTAssertNil(AttributedTrackTranscriber.engineWords(of: mismatched))
        mismatched.words = []
        XCTAssertNil(AttributedTrackTranscriber.engineWords(of: mismatched))
    }

    private func writeTrack(seconds: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-word-attribution-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("track.wav")
        try OnnxTranscriptionEngine.writeWav([Float](repeating: 0.1, count: seconds * 16_000), to: url)
        return url
    }

    /// Opt-in hardware check: the pinned digests match the real files, which
    /// load offline and time every word. No network access is allowed.
    func testCachedAlignerVerifiesPinsAndTimesEveryWord() async throws {
        guard let path = ProcessInfo.processInfo.environment["LOKALBOT_QWEN_ALIGNER_TEST_DIR"] else {
            throw XCTSkip("Set LOKALBOT_QWEN_ALIGNER_TEST_DIR to a downloaded Qwen3-ForcedAligner-0.6B-CoreML-INT8 folder")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try await QwenWordAligner.snapshot.prepare(in: directory) { _ in throw URLError(.notConnectedToInternet) }
        let samples = (0..<48_000).map { Float(sin(Double($0) * 0.05) * 0.1) }
        let words = try await QwenWordAligner(directory: directory)
            .align(samples, text: "Three short words.", language: "en")
        XCTAssertEqual(words.map(\.text), ["Three", "short", "words."])
        XCTAssertTrue(words.allSatisfy { $0.start >= 0 && $0.start <= $0.end && $0.end <= 3.1 })
    }

    /// Opt-in hardware check: many passes over segments of different lengths
    /// keep the footprint flat. Each CoreML pass returns about 12 MB of
    /// autoreleased arrays; without a pool per pass, a long track's footprint
    /// grew from 0.8 GB to 4.6 GB.
    func testCachedAlignerKeepsFootprintFlatAcrossSegments() async throws {
        guard let path = ProcessInfo.processInfo.environment["LOKALBOT_QWEN_ALIGNER_TEST_DIR"] else {
            throw XCTSkip("Set LOKALBOT_QWEN_ALIGNER_TEST_DIR to a downloaded Qwen3-ForcedAligner-0.6B-CoreML-INT8 folder")
        }
        let aligner = QwenWordAligner(directory: URL(fileURLWithPath: path, isDirectory: true))
        let vocabulary = "The quarterly plan covers budget numbers, hiring, and the launch schedule for next month."
            .split(separator: " ")
        func pass(_ seconds: Int) async throws {
            // About 2.5 words a second, as in conversation.
            let text = (0..<(seconds * 5 / 2)).map { vocabulary[$0 % vocabulary.count] }.joined(separator: " ")
            let samples = (0..<(seconds * 16_000)).map { Float(sin(Double($0) * 0.05) * 0.1) }
            let words = try await aligner.align(samples, text: text, language: "en")
            XCTAssertFalse(words.isEmpty, "\(seconds) s")
        }
        try await pass(30)
        let baseline = Self.physicalFootprint()
        for _ in 0..<4 {
            for seconds in [4, 9, 13, 18, 22, 27, 30, 7, 24, 16] { try await pass(seconds) }
        }
        await aligner.finishBatch()
        let growth = Double(Self.physicalFootprint()) - Double(baseline)
        XCTAssertLessThan(growth, 150_000_000, "footprint grew \(Int(growth / 1_000_000)) MB over 40 passes")
    }

    private static func physicalFootprint() -> UInt64 {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? info.ri_phys_footprint : 0
    }
}

/// A word-attribution engine whose transcript carries the given word times.
/// Speaker regions, the fallback, answer each region with fixed text.
private struct ServerTimedASR: TranscriptionEngine {
    final class Calls: @unchecked Sendable {
        var wordAttribution = 0
        var regions = 0
        var regionLanguages: [String?] = []
    }

    var providesWordTimings: Bool
    var segments: [WordTimedTranscript.Segment]
    var trackLanguage: String?
    let calls = Calls()

    init(providesWordTimings: Bool, segments: [WordTimedTranscript.Segment], trackLanguage: String? = nil) {
        self.providesWordTimings = providesWordTimings
        self.segments = segments
        self.trackLanguage = trackLanguage
    }

    var displayName: String { "Server fixture" }
    var supportsStreaming: Bool { false }
    var speakerAttribution: SpeakerAttributionStrategy { .alignedWords }
    func prepare(progress: ModelPreparationProgressHandler?) async throws {}

    func transcribe(audio: URL, language: String?) async throws -> Transcript {
        calls.regions += 1
        calls.regionLanguages.append(language)
        return Transcript(segments: [.init(start: 0, end: 0.05, speaker: "", text: "Region text.")],
                          engine: displayName)
    }

    func transcribeForWordAttribution(audio: URL, language: String?, prompt: String?) async throws -> WordTimedTranscript {
        calls.wordAttribution += 1
        return WordTimedTranscript(segments: segments, engine: displayName, trackLanguage: trackLanguage)
    }
}

@MainActor
private final class AlignerFetches {
    private let fails: Bool
    private(set) var count = 0

    init(fails: Bool = false) { self.fails = fails }

    func fetch() throws {
        count += 1
        if fails { throw URLError(.notConnectedToInternet) }
    }
}
