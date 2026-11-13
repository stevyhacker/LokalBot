import XCTest
@testable import LokalBot

/// Records real responses to `SyntheticModelPrompts` for the drift models.
/// Runs only when `LOKALBOT_RECORD_MODELS=1` with `OPENROUTER_API_KEY`,
/// `LOKALBOT_RECORD_MODEL_IDS` (comma-separated), and
/// `LOKALBOT_RECORDINGS_OUT` set — i.e. in the nightly `model-drift` job.
final class ModelRecordingTests: XCTestCase {
    func testRecordDriftModels() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LOKALBOT_RECORD_MODELS"] == "1",
              let key = environment["OPENROUTER_API_KEY"], !key.isEmpty,
              let ids = environment["LOKALBOT_RECORD_MODEL_IDS"],
              let out = environment["LOKALBOT_RECORDINGS_OUT"] else {
            throw XCTSkip("Set LOKALBOT_RECORD_MODELS=1 and the recording variables to record.")
        }
        let models = ids.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        let perModelLimit = 40 / max(1, models.count)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        for model in models {
            let base = OpenAICompatibleEngine(
                baseURL: URL(string: "https://openrouter.ai/api/v1")!, model: model, apiKey: key,
                chatDialect: .openRouter, openRouterDataPolicy: .privateOnly)
            let folder = URL(fileURLWithPath: out).appendingPathComponent(ModelRecording.directoryName(for: model))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            let digest = RecordingTextEngine(base: base, requestLimit: perModelLimit)
            _ = try? await DayDigestOverviewGenerator.generateResult(
                evidence: SyntheticModelPrompts.digestEvidence(calendar: calendar),
                engine: digest, customPrompt: "", calendar: calendar)
            try save(model: model, caseName: "digest-day", calls: digest.calls, in: folder)

            let notes = RecordingTextEngine(base: base, requestLimit: perModelLimit - digest.requestCount)
            let meetingFolder = FileManager.default.temporaryDirectory
                .appendingPathComponent("recording-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: meetingFolder, withIntermediateDirectories: true)
            _ = try? await MeetingNotesGenerator.generate(
                transcript: SyntheticModelPrompts.standupTranscript(), engine: notes, template: .meeting,
                language: .matchTranscript, context: [], contextTokens: 32_768, meetingID: UUID(), folder: meetingFolder)
            try save(model: model, caseName: "notes-design-review", calls: notes.calls, in: folder)

            let runOn = RecordingTextEngine(base: base, requestLimit: perModelLimit - digest.requestCount - notes.requestCount)
            let runOnFolder = FileManager.default.temporaryDirectory
                .appendingPathComponent("recording-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: runOnFolder, withIntermediateDirectories: true)
            _ = try? await MeetingNotesGenerator.generate(
                transcript: SyntheticModelPrompts.runOnStandupTranscript(), engine: runOn, template: .meeting,
                language: .matchTranscript, context: [], contextTokens: 32_768, meetingID: UUID(), folder: runOnFolder)
            try save(model: model, caseName: "notes-run-on-standup", calls: runOn.calls, in: folder)

            let ask = RecordingTextEngine(
                base: base,
                requestLimit: perModelLimit - digest.requestCount - notes.requestCount - runOn.requestCount)
            _ = try? await MainActor.run {
                ChatAgent(engine: ask, runner: EmptyToolRunner())
            }.respond(history: [], latest: SyntheticModelPrompts.askQuestion) { _ in }
            try save(model: model, caseName: "ask-answer", calls: ask.calls, in: folder)
        }
    }

    private func save(model: String, caseName: String, calls: [ModelRecording.Call], in folder: URL) throws {
        let recording = ModelRecording(model: model, caseName: caseName, recordedAt: Date(), calls: calls)
        try ModelRecording.encoder.encode(recording)
            .write(to: folder.appendingPathComponent("\(caseName).json"), options: .atomic)
    }
}
