import XCTest
@testable import LokalBot

/// Runs the day digest over `Benchmarks/think/DayDigest/cases.json` against a live
/// OpenAI-compatible server and writes every digest and model call for
/// `Benchmarks/think/DayDigest/score.py`. Skipped unless `LOKALBOT_DIGEST_BENCH=1`;
/// `Benchmarks/think/DayDigest/run.sh` starts the server and sets the variables.
final class DayDigestBenchmarkTests: XCTestCase {
    private struct Cases: Decodable { var days: [Day] }

    private struct Day: Decodable {
        struct Block: Decodable { var app, title, start, end: String }
        struct Context: Decodable {
            var id: Int64
            var at, app, title, text: String
        }
        var id: String
        var date: String
        var blocks: [Block]
        var contexts: [Context]
    }

    /// Forwards to the production engine unchanged and keeps each reply, so
    /// streaming, truncation, and retries behave as they do in the app.
    private final class CapturingEngine: TextEngine, @unchecked Sendable {
        struct Call { var stage: String; var output: String; var seconds: Double }
        let base: OpenAICompatibleEngine
        private let lock = NSLock()
        private(set) var calls: [Call] = []

        init(base: OpenAICompatibleEngine) { self.base = base }

        var displayName: String { base.displayName }
        var checkpointIdentity: String { base.checkpointIdentity }
        var accountsForGenerationRequests: Bool { base.accountsForGenerationRequests }
        var minimumStructuredOutputTokens: Int { base.minimumStructuredOutputTokens }
        var handlesTransientRetries: Bool { base.handlesTransientRetries }
        func tokenCount(_ text: String) async throws -> Int? { try await base.tokenCount(text) }

        func generate(system: String, prompt: String, context: [String]) async throws -> String {
            try await record(system) { try await self.base.generate(system: system, prompt: prompt, context: context) }
        }

        func generate(system: String, prompt: String, context: [String],
                      options: TextGenerationOptions) async throws -> String {
            try await record(system) {
                try await self.base.generate(system: system, prompt: prompt, context: context, options: options)
            }
        }

        func generateStreaming(system: String, prompt: String, context: [String], options: TextGenerationOptions,
                               onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
            try await record(system) {
                try await self.base.generateStreaming(system: system, prompt: prompt, context: context,
                                                      options: options, onPartial: onPartial)
            }
        }

        func generate(system: String, prompt: String, context: [String],
                      schema: [String: Any]) async throws -> String {
            try await record(system) {
                try await self.base.generate(system: system, prompt: prompt, context: context, schema: schema)
            }
        }

        func generate(system: String, prompt: String, context: [String], schema: [String: Any],
                      options: TextGenerationOptions) async throws -> String {
            try await record(system) {
                try await self.base.generate(system: system, prompt: prompt, context: context,
                                             schema: schema, options: options)
            }
        }

        private func record(_ system: String, _ body: () async throws -> String) async throws -> String {
            let started = Date()
            let stage = system == PromptTemplates.dayDigestFocusSystem ? "segment" : "digest"
            do {
                let output = try await body()
                append(Call(stage: stage, output: output, seconds: Date().timeIntervalSince(started)))
                return output
            } catch {
                append(Call(stage: stage, output: "error: \(error.localizedDescription)",
                            seconds: Date().timeIntervalSince(started)))
                throw error
            }
        }

        private func append(_ call: Call) {
            lock.lock()
            calls.append(call)
            lock.unlock()
        }
    }

    func testDigestBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LOKALBOT_DIGEST_BENCH"] == "1",
              let casesPath = environment["LOKALBOT_DIGEST_BENCH_CASES"],
              let outPath = environment["LOKALBOT_DIGEST_BENCH_OUT"],
              let url = environment["LOKALBOT_DIGEST_BENCH_URL"].flatMap(URL.init(string:)) else {
            throw XCTSkip("Set LOKALBOT_DIGEST_BENCH=1 and the benchmark variables to run.")
        }
        let model = environment["LOKALBOT_DIGEST_BENCH_MODEL"] ?? "qwen3.5-4b"
        let runs = max(1, Int(environment["LOKALBOT_DIGEST_BENCH_RUNS"] ?? "") ?? 1)
        let base = OpenAICompatibleEngine(
            baseURL: url, model: model, apiKey: environment["LOKALBOT_DIGEST_BENCH_KEY"],
            extraBody: MainLLMRuntimePolicy.requestOverrides(for: model),
            chatDialect: .llamaServer,
            defaultThinkingBudgetTokens: MainLLMRuntimePolicy.highReasoningBudgetTokens)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let cases = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: URL(fileURLWithPath: casesPath)))

        var results: [[String: Any]] = []
        for run in 1...runs {
            for day in cases.days {
                let engine = CapturingEngine(base: base)
                let evidence = try evidence(for: day, calendar: calendar)
                let started = Date()
                var entry: [String: Any] = ["day": day.id, "run": run,
                                            "segments": evidence.summarySegments().count]
                do {
                    let generated = try await DayDigestOverviewGenerator.generateResult(
                        evidence: evidence, engine: engine, customPrompt: "", calendar: calendar)
                    entry["summary"] = generated.summary
                    entry["quality"] = String(describing: generated.quality)
                    if let coverage = generated.coverage {
                        entry["covered_seconds"] = coverage.coveredSeconds
                        entry["tracked_seconds"] = coverage.trackedSeconds
                    }
                } catch {
                    entry["error"] = error.localizedDescription
                }
                entry["seconds"] = Date().timeIntervalSince(started)
                entry["calls"] = engine.calls.map {
                    ["stage": $0.stage, "output": $0.output, "seconds": $0.seconds] as [String: Any]
                }
                results.append(entry)
                // Write after every day so a capped run keeps what finished.
                let data = try JSONSerialization.data(withJSONObject: ["model": model, "results": results],
                                                      options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: outPath), options: .atomic)
            }
        }
    }

    private func evidence(for day: Day, calendar: Calendar) throws -> DayDigestEvidence {
        func time(_ clock: String) throws -> Date {
            let parts = (day.date + "-" + clock).split(whereSeparator: { $0 == "-" || $0 == ":" }).compactMap { Int($0) }
            guard parts.count == 5, let value = calendar.date(from: DateComponents(
                year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4])) else {
                throw CocoaError(.coderInvalidValue)
            }
            return value
        }
        var blocks: [ActivityBlock] = []
        for (index, block) in day.blocks.enumerated() {
            blocks.append(ActivityBlock(id: Int64(index + 1), app: block.app, title: block.title,
                                        start: try time(block.start), end: try time(block.end)))
        }
        var contexts: [DayScreenContext] = []
        for context in day.contexts {
            contexts.append(DayScreenContext(snapshotID: context.id, capturedAt: try time(context.at),
                                             app: context.app, windowTitle: context.title, text: context.text))
        }
        return DayDigestEvidence.build(day: try time("12:00"), blocks: blocks, screenContexts: contexts,
                                       meetings: [], calendar: calendar)
    }
}
