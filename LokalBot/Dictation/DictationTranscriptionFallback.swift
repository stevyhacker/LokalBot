import Foundation

enum DictationTranscriptionFallback {
    struct Use: Equatable, Sendable {
        let choice: TranscriptionModelChoice
        let reason: String
    }

    struct Spoken {
        let transcript: Transcript
        let fallback: Use?
    }

    static let multilingual: [TranscriptionModelChoice] = [
        .qwenASR17B, .whisperLarge, .qwenASR06B, .parakeetV3, .parakeetUltra, .graniteSpeech5, .graniteSpeech,
    ]
    static let englishOnly: [TranscriptionModelChoice] = [.parakeetV2]

    static let nothingDownloadedHint =
        "Download a speech model in Settings → Models to dictate without the server."

    static func localChoice(
        for settings: AppSettings,
        isDownloaded: (TranscriptionModelChoice) -> Bool
    ) -> TranscriptionModelChoice? {
        guard settings.transcriptionModel.isRemote else { return nil }
        let language = settings.transcriptionLanguage
        let candidates = language == .en ? multilingual + englishOnly : multilingual
        return candidates.first { $0.isLanguageSelectable(language) && isDownloaded($0) }
    }

    static func localChoice(for settings: AppSettings) -> TranscriptionModelChoice? {
        localChoice(for: settings) { choice in
            TranscriptionModelStore.isDownloaded(choice, graniteConfiguration: settings.graniteSpeechModel)
        }
    }

    @MainActor
    static func transcribe(
        settings: AppSettings,
        localChoice: (AppSettings) -> TranscriptionModelChoice? = { localChoice(for: $0) },
        selected: () async throws -> Transcript,
        onThisMac: (AppSettings) async throws -> Transcript
    ) async throws -> Spoken {
        do {
            return Spoken(transcript: try await selected(), fallback: nil)
        } catch let serverError as RemoteTranscriptionError {
            guard let choice = localChoice(settings) else { throw serverError }
            let use = Use(choice: choice, reason: serverError.localizedDescription)
            lokalbotLog("dictation transcription server failed; transcribing on this Mac "
                        + "model=\(choice.rawValue): \(use.reason)")
            var local = settings
            local.transcriptionModel = choice
            do {
                return Spoken(transcript: try await onThisMac(local), fallback: use)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lokalbotLog("dictation on this Mac FAILED model=\(choice.rawValue): \(error.localizedDescription)")
                throw serverError
            }
        }
    }
}

struct DictationProblemNotice: Equatable, Sendable {
    let title: String
    var detail: String?

    static let noSpeech = DictationProblemNotice(title: "No speech detected")

    static func failed(_ detail: String) -> DictationProblemNotice {
        DictationProblemNotice(title: "Dictation failed", detail: detail)
    }

    static func transcribedOnThisMac(_ use: DictationTranscriptionFallback.Use) -> DictationProblemNotice {
        DictationProblemNotice(title: "Transcribed on this Mac", detail: use.reason)
    }
}
