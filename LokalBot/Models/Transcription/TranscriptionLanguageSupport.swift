import Foundation

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
        case .whisperLarge, .appleSpeech: .languageToken
        case .parakeetUltra, .parakeetV3: .scriptHint
        case .remoteServer: .serverDependent
        case .speechRuntime: .unsupported
        case .parakeetV2, .qwenASR17BLokalBotV3, .qwenASR17B, .qwenASR06BLokalBotV1, .qwenASR06B,
             .graniteSpeech, .graniteSpeech5, .funASRNano, .senseVoice, .gigaamRussian, .cohere: .unsupported
        }
    }

    func isLanguageSelectable(_ language: TranscriptionLanguage) -> Bool {
        if self == .appleSpeech {
            return AppleSpeechLocaleResolver.isLanguageSupported(language)
        }
        return language != .uk || ukrainianSupport.isAvailable
    }

    func languageSelectionMessage(for language: TranscriptionLanguage) -> String? {
        if self == .appleSpeech {
            if language == .auto {
                return "Apple Speech uses your preferred macOS language when supported. Choose a language for recordings in another language."
            }
            guard language == .language(.sr) else { return nil }
            return "Apple Speech does not support Serbian. Choose Whisper or Qwen3-ASR, or select another language."
        }
        guard language == .uk || ukrainianSupport == .unsupported else { return nil }
        return ukrainianSupport.explanation
    }

    func languageDisplayName(for language: TranscriptionLanguage) -> String {
        self == .appleSpeech && language == .auto ? "System language" : language.displayName
    }

    func validateLanguage(_ code: String?) throws {
        if self == .appleSpeech {
            try AppleSpeechLocaleResolver.validateLanguage(code, modelName: displayName)
            return
        }
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
