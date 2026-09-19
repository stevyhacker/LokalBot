import Foundation

/// A `TextEngine` decorator that runs every call under an inference lease.
/// Construction stays cheap; the runtime boots on first use and remains
/// pinned against eviction only while a call is active.
struct LeasedTextEngine: TextEngine {
    let base: TextEngine
    let broker: InferenceBroker
    let role: InferenceRole
    let modelURL: URL
    let priority: InferencePriority
    let purpose: String

    var displayName: String { base.displayName }
    var accountsForGenerationRequests: Bool { base.accountsForGenerationRequests }
    var minimumStructuredOutputTokens: Int { base.minimumStructuredOutputTokens }

    func tokenCount(_ text: String) async throws -> Int? {
        try await withLease { try await base.tokenCount(text) }
    }

    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        try await withManagedRecovery {
            try await base.generate(system: system, prompt: prompt, context: context)
        }
    }

    func generate(system: String, prompt: String, context: [String],
                  options: TextGenerationOptions) async throws -> String {
        try await withManagedRecovery {
            try await base.generate(system: system, prompt: prompt, context: context,
                                    options: options)
        }
    }

    func generate(system: String, prompt: String, context: [String],
                  schema: [String: Any]) async throws -> String {
        try await withManagedRecovery {
            try await base.generate(system: system, prompt: prompt, context: context,
                                    schema: schema)
        }
    }

    func generate(system: String, prompt: String, context: [String],
                  schema: [String: Any],
                  options: TextGenerationOptions) async throws -> String {
        try await withManagedRecovery {
            try await base.generate(system: system, prompt: prompt, context: context,
                                    schema: schema, options: options)
        }
    }

    func complete(_ request: CompletionRequest) async throws -> String {
        try await broker.withLease(role, model: modelURL, priority: priority, purpose: purpose) {
            try await base.complete(request)
        }
    }

    func generateStreaming(system: String, prompt: String, context: [String],
                           options: TextGenerationOptions,
                           onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        // Streaming remains single-shot: a recovery replay could duplicate text
        // the user has already seen. Keep the model leased through the stream.
        try await withLease {
            try await base.generateStreaming(system: system, prompt: prompt, context: context,
                                             options: options, onPartial: onPartial)
        }
    }

    func completeStreaming(_ request: CompletionRequest,
                           onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        try await broker.withLease(role, model: modelURL, priority: priority, purpose: purpose) {
            try await base.completeStreaming(request, onPartial: onPartial)
        }
    }

    /// A managed localhost runtime can disappear after lease acquisition but
    /// before its HTTP response arrives. Releasing and reacquiring the lease
    /// runs the broker's existing health/configuration check, which starts a
    /// replacement server when needed. Generation is side-effect free, so one
    /// replay is safe; raw/streaming completions deliberately stay single-shot
    /// because callers may already have displayed partial text.
    private func withManagedRecovery<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await withLease(operation)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TextEngineError {
            guard case .serverUnreachable(_, let transportCode) = error else { throw error }
            lokalbotLog(
                "managed inference recovery starting role=\(role.rawValue) "
                    + "purpose=\(purpose) transportCode=\(transportCode.map(String.init) ?? "unknown")")
            do {
                let value = try await withLease(operation)
                lokalbotLog(
                    "managed inference recovery succeeded role=\(role.rawValue) purpose=\(purpose)")
                return value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lokalbotLog(
                    "managed inference recovery failed role=\(role.rawValue) "
                        + "purpose=\(purpose) error=\(error.localizedDescription)")
                throw error
            }
        }
    }

    private func withLease<T>(_ operation: () async throws -> T) async throws -> T {
        try await broker.withLease(
            role,
            model: modelURL,
            priority: priority,
            purpose: purpose
        ) {
            try await operation()
        }
    }
}
