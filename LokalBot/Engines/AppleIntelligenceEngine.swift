import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

struct AppleIntelligenceEngine: TextEngine {
    var displayName: String { "Apple Intelligence" }

    static let maxPromptCharacters = 12_000

    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        let availability = await FoundationModelAvailability.current()
        guard case .available = availability else {
            throw TextEngineError.unavailable(
                availability.reason ?? FoundationModelAvailability.unsupportedMessage
            )
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let user = Self.composePrompt(prompt: prompt, context: context)
            return try await Self.respond(instructions: system, prompt: user)
        }
        #endif
        throw TextEngineError.unavailable(FoundationModelAvailability.unsupportedMessage)
    }

    nonisolated static func composePrompt(prompt: String, context: [String]) -> String {
        let joined = (context + [prompt])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return cappedToTail(joined, limit: maxPromptCharacters)
    }

    nonisolated static func cappedToTail(_ text: String, limit: Int) -> String {
        guard limit > 0, text.count > limit else { return text }
        let start = text.index(text.endIndex, offsetBy: -limit)
        return String(text[start...])
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func respond(instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(to: prompt)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as LanguageModelSession.GenerationError {
            throw TextEngineError.badResponse(message(for: error))
        } catch {
            throw TextEngineError.badResponse(error.localizedDescription)
        }
    }

    @available(macOS 26.0, *)
    private static func message(for error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize:
            return "The transcript was too long for the on-device model."
        case .assetsUnavailable:
            return "Apple Intelligence assets are unavailable right now."
        case .guardrailViolation:
            return "Apple Intelligence blocked this content with its safety guardrails."
        case .unsupportedGuide:
            return "Apple Intelligence rejected the request format."
        case .unsupportedLanguageOrLocale:
            return "Apple Intelligence does not support this language or locale."
        case .decodingFailure:
            return "Apple Intelligence returned a response that could not be decoded."
        case .rateLimited:
            return "Apple Intelligence is busy right now. Try again in a moment."
        case .concurrentRequests:
            return "Apple Intelligence is already handling another request."
        case .refusal:
            return "Apple Intelligence declined to answer this prompt."
        @unknown default:
            return error.localizedDescription
        }
    }
    #endif
}
