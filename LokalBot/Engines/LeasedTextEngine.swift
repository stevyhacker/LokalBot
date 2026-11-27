import Foundation

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
    var handlesTransientRetries: Bool { true }
    var structuredOutputEnumLimit: Int? { base.structuredOutputEnumLimit }
    var maxConcurrentRequests: Int { base.maxConcurrentRequests }

    func reasoningAllowance(for options: TextGenerationOptions?) -> Int {
        base.reasoningAllowance(for: options)
    }

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
