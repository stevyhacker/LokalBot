import Foundation

/// Ukrainian is a newly exposed choice. Keep existing language behavior,
/// including the separately benchmarked Serbian Qwen hint, unchanged.
/// Coverage comes from the pinned engines and their publishers' model cards;
/// a shared language picker is not evidence of model support.
enum UkrainianTranscriptionSupport: Equatable {
    case languageToken
    case scriptHint
    case serverDependent
    case unsupported

    var isAvailable: Bool { self != .unsupported }

    var explanation: String? {
        switch self {
        case .languageToken: nil
        case .scriptHint:
            "Parakeet uses a Cyrillic-script hint, which cannot distinguish Ukrainian from Russian. Choose Whisper to explicitly select Ukrainian."
        case .serverDependent:
            "Ukrainian is sent as the language hint. Support depends on your transcription server's model."
        case .unsupported:
            "This model does not support Ukrainian. Choose Whisper or multilingual Parakeet, or select another language."
        }
    }
}

extension TranscriptionModelChoice {
    var ukrainianSupport: UkrainianTranscriptionSupport {
        switch self {
        case .whisperLarge: .languageToken
        // FluidAudio 0.17.7 maps Ukrainian and Russian to the same script filter.
        case .parakeetUltra, .parakeetV3: .scriptHint
        case .remoteServer: .serverDependent
        case .parakeetV2, .qwenASR17B, .qwenASR06B, .graniteSpeech, .graniteTurbo,
             .funASRNano, .senseVoice, .gigaamRussian, .cohere: .unsupported
        }
    }

    func isLanguageSelectable(_ language: TranscriptionLanguage) -> Bool {
        if self == .graniteTurbo { return GraniteTurboEngine.accepts(language: language.code) }
        return language != .uk || ukrainianSupport.isAvailable
    }

    /// Preserve a deliberate Ukrainian choice even when selecting English-only
    /// fast mode. Its existing default-to-English behavior still applies otherwise.
    func languageOverrideOnSelection(current: TranscriptionLanguage) -> TranscriptionLanguage? {
        self == .graniteTurbo && current != .uk ? .en : nil
    }

    func languageSelectionMessage(for language: TranscriptionLanguage) -> String? {
        guard language == .uk || ukrainianSupport == .unsupported else { return nil }
        return ukrainianSupport.explanation
    }

    /// Validate before loading weights, reading audio, or falling back to auto
    /// detection. A saved Ukrainian choice must survive model switches, but an
    /// unsupported engine must not silently transcribe it in another language.
    func validateLanguage(_ code: String?) throws {
        guard code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "uk",
              !ukrainianSupport.isAvailable else { return }
        throw UnsupportedTranscriptionLanguage(language: "Ukrainian", model: displayName)
    }
}

struct UnsupportedTranscriptionLanguage: LocalizedError, Equatable {
    let language: String
    let model: String

    var errorDescription: String? {
        "\(model) does not support \(language). Choose Whisper or multilingual Parakeet, or select another language."
    }
}
