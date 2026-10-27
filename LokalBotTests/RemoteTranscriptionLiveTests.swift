import XCTest
@testable import LokalBot

/// Sends a synthetic two-voice `say` clip to OpenRouter. Runs only when
/// `OPENROUTER_API_KEY` is set (pass `TEST_RUNNER_OPENROUTER_API_KEY` through
/// xcodebuild); `LOKALBOT_OPENROUTER_TRANSCRIPTION_MODEL` overrides
/// `microsoft/mai-transcribe-2`.
final class RemoteTranscriptionLiveTests: XCTestCase {
    func testServerWordTimesSplitTwoVoicesOnTheTrackTimeline() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let key = environment["OPENROUTER_API_KEY"], !key.isEmpty else {
            throw XCTSkip("Set OPENROUTER_API_KEY to call OpenRouter's transcription API.")
        }
        let model = environment["LOKALBOT_OPENROUTER_TRANSCRIPTION_MODEL"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "microsoft/mai-transcribe-2"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-remote-asr-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // The second voice starts 5 s into a window that starts 1 s into the track.
        let first = try spoken("The quarterly plan is ready for review.", voice: "Samantha", in: directory)
        let second = try spoken("Thanks, I will send my notes tomorrow.", voice: "Daniel", in: directory)
        let rate = 16_000
        var samples = [Float](repeating: 0, count: rate)
        samples += first
        samples += [Float](repeating: 0, count: max(0, 6 * rate - samples.count))
        samples += second
        samples += [Float](repeating: 0, count: rate / 2)
        let track = directory.appendingPathComponent("track.wav")
        try OnnxTranscriptionEngine.writeWav(samples, to: track)
        let firstEnd = 1 + Double(first.count) / Double(rate)
        let secondEnd = 6 + Double(second.count) / Double(rate)

        let configuration = RemoteTranscriptionConfiguration(
            baseURL: "https://openrouter.ai/api/v1", model: model, approvedOrigins: ["https://openrouter.ai"])
        var engine = RemoteTranscriptionEngine(configuration: configuration, apiKey: { key })
        engine.wordTimingRejections = WordTimingRejections()
        let endpoint = try configuration.validatedEndpoint()
        let started = Date()
        let segments = try await RemoteTranscriptionEngine.segments(
            in: track, spans: [SpeechSpan(start: 0.9, end: secondEnd + 0.3, timingPrecision: .span)],
            maximumConcurrent: 1
        ) { wav in
            try await engine.upload(wav, endpoint: endpoint, apiKey: key, model: model, language: "en",
                                    prompt: "Quarterly plan", wordTimings: true)
        }
        let elapsed = Date().timeIntervalSince(started)

        let segment = try XCTUnwrap(segments.first)
        let words = try XCTUnwrap(segment.words, "\(model) returned no word times: \(segment.segment.text)")
        let thanks = try XCTUnwrap(words.first { $0.text.lowercased().hasPrefix("thanks") }, "\(words)")
        XCTAssertEqual(thanks.start, 6, accuracy: 0.4, "\(words)")
        XCTAssertLessThan(words.first?.start ?? 0, 1.6, "\(words)")
        XCTAssertNotNil(AttributedTrackTranscriber.engineWords(of: segment))
        XCTAssertFalse(engine.wordTimingRejections.contains(configuration.wordTimingKey))

        let attributed = AttributedTrackTranscriber.attribute(
            [.init(segment: segment.segment, words: words)], duration: secondEnd + 0.5,
            turns: [.init(start: 1, end: firstEnd, speakerId: "A"), .init(start: 6, end: secondEnd, speakerId: "B")],
            source: .system, contentRange: nil)
        XCTAssertEqual(attributed.map(\.speaker), ["them 1", "them 2"], "\(attributed.map(\.text))")
        XCTAssertTrue(attributed.first?.text.lowercased().contains("quarterly") == true)
        XCTAssertTrue(attributed.last?.text.lowercased().contains("notes") == true)
        print("remote-asr live: \(model) answered in \(String(format: "%.2f", elapsed)) s; "
            + "words \(words.map { "\($0.text)@\(String(format: "%.2f", $0.start))" }.joined(separator: " "))")
    }

    /// 16 kHz mono samples of `text` read by a built-in macOS voice.
    private func spoken(_ text: String, voice: String, in directory: URL) throws -> [Float] {
        let url = directory.appendingPathComponent("\(voice).wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-o", url.path, "--file-format=WAVE", "--data-format=LEI16@16000", text]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("The \(voice) voice is not installed.") }
        let reader = try SpanAudioReader(url: url)
        return try reader.samples(from: 0, to: reader.duration)
    }
}
