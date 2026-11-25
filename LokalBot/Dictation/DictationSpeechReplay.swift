import Foundation

enum DictationSpeechReplay {
    struct Request: Equatable {
        var input: URL
        var model: TranscriptionModelChoice
        var language: TranscriptionLanguage
        var passes: Int
    }

    struct Input: Decodable {
        var cases: [Case]
    }

    struct Case: Decodable {
        var id: String
        var audio: String
    }

    struct Observation: Encodable {
        var id: String
        var pass: Int
        var seconds: Double
        var text: String
    }

    static let argument = "--dictation-speech-replay"
    static let usage = "usage: --dictation-speech-replay CASES.json --model ID [--language auto|CODE] [--passes 1-10]"

    static func isRequested(_ args: [String]) -> Bool {
        args.contains(argument)
    }

    static func parse(_ args: [String]) -> Request? {
        guard let flag = args.firstIndex(of: argument), args.count > flag + 1,
              let modelFlag = args.firstIndex(of: "--model"), args.count > modelFlag + 1,
              let model = TranscriptionModelChoice(rawValue: args[modelFlag + 1]), !model.isRemote,
              model != .appleSpeech else { return nil }
        var language = TranscriptionLanguage.auto
        if let index = args.firstIndex(of: "--language") {
            guard args.count > index + 1, let value = TranscriptionLanguage(rawValue: args[index + 1]) else { return nil }
            language = value
        }
        var passes = 3
        if let index = args.firstIndex(of: "--passes") {
            guard args.count > index + 1, let value = Int(args[index + 1]) else { return nil }
            passes = value
        }
        return Request(input: URL(fileURLWithPath: args[flag + 1]), model: model, language: language,
                       passes: min(max(passes, 1), 10))
    }

    static func order(count: Int, pass: Int) -> [Int] {
        pass % 2 == 1 ? Array((0..<count).reversed()) : Array(0..<count)
    }

    static func settings(for request: Request) -> AppSettings {
        var settings = AppSettings()
        settings.transcriptionModel = request.model
        settings.transcriptionLanguage = request.language
        settings.transcriptionPrompt = ""
        return settings
    }

    @MainActor
    static func run(_ request: Request) async -> Int32 {
        do {
            let data = try Data(contentsOf: request.input)
            let input = try JSONDecoder().decode(Input.self, from: data)
            guard !input.cases.isEmpty, input.cases.count <= 500,
                  Set(input.cases.map(\.id)).count == input.cases.count else { throw ReplayError.invalidInput }
            let folder = request.input.deletingLastPathComponent()
            let config = settings(for: request)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let warmup = ContinuousClock.now
            _ = try await DictationCoordinator.transcribe(
                folder.appendingPathComponent(input.cases[0].audio), config: config, retriesWithoutVocabulary: false)
            try write(["warmupSeconds": seconds(ContinuousClock.now - warmup)])
            for pass in 0..<request.passes {
                for index in order(count: input.cases.count, pass: pass) {
                    let item = input.cases[index]
                    let start = ContinuousClock.now
                    let transcript = try await DictationCoordinator.transcribe(
                        folder.appendingPathComponent(item.audio), config: config, retriesWithoutVocabulary: false)
                    let observation = Observation(
                        id: item.id, pass: pass, seconds: seconds(ContinuousClock.now - start),
                        text: transcript.segments.map(\.displayText).joined(separator: " "))
                    try FileHandle.standardOutput.write(contentsOf: encoder.encode(observation) + Data([10]))
                }
            }
            return 0
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("Dictation speech replay failed: \(error)\n".utf8))
            return 1
        }
    }

    private enum ReplayError: Error { case invalidInput }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func write(_ value: [String: Double]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    }
}
