import Foundation

/// What dictation does when the transcription server cannot transcribe: a
/// speech model already on this Mac transcribes the same audio, and the HUD
/// says why (`DictationProblemNotice`).
///
/// On 2026-11-10 OpenRouter stopped accepting a saved key. Every dictation
/// recorded, got HTTP 401, and ended with a message only LokalBot's own window
/// shows, so in any other app the shortcut seemed to do nothing.
enum DictationTranscriptionFallback {
    /// The model on this Mac that stood in, and the server's failure.
    struct Use: Equatable, Sendable {
        let choice: TranscriptionModelChoice
        let reason: String
    }

    struct Spoken {
        let transcript: Transcript
        /// Nil when the selected model transcribed.
        let fallback: Use?
    }

    /// Multilingual models, best first. The narrow ones (SenseVoice, GigaAM,
    /// Fun-ASR-Nano, Cohere) are left out: a stand-in must not turn speech in
    /// another language into wrong text in someone's document.
    static let multilingual: [TranscriptionModelChoice] = [
        .qwenASR17B, .whisperLarge, .qwenASR06B, .parakeetV3, .parakeetUltra, .graniteSpeech5, .graniteSpeech,
    ]
    /// Used only when the language is set to English.
    static let englishOnly: [TranscriptionModelChoice] = [.parakeetV2, .graniteTurbo]

    /// Added to the message when the server failed and nothing could take over.
    static let nothingDownloadedHint =
        "Download a speech model in Settings → Models to dictate without the server."

    /// The downloaded model that transcribes when the server fails. Nil when
    /// the selected model is not the server, or nothing suitable is on disk:
    /// a failed dictation never starts a multi-gigabyte download.
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

    /// Transcribes with the selected model (`selected`). When the server
    /// fails, `onThisMac` transcribes with settings that name the stand-in.
    /// If that fails too, the server's error is the one reported: it is the
    /// one the person has to fix.
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

/// Shown in the dictation HUD when a dictation ended without its text, or when
/// a model on this Mac transcribed it because the server could not. These
/// messages used to reach only LokalBot's own window, which is rarely in front
/// while dictating into another app.
struct DictationProblemNotice: Equatable, Sendable {
    /// A catalog key.
    let title: String
    /// The reason, shown as written: it can quote a server's own words.
    var detail: String?

    static let noSpeech = DictationProblemNotice(title: "No speech detected")

    static func failed(_ detail: String) -> DictationProblemNotice {
        DictationProblemNotice(title: "Dictation failed", detail: detail)
    }

    static func transcribedOnThisMac(_ use: DictationTranscriptionFallback.Use) -> DictationProblemNotice {
        DictationProblemNotice(title: "Transcribed on this Mac", detail: use.reason)
    }
}
