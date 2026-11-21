import Combine
import Foundation
import os

private let logger = Logger(subsystem: AppIdentifiers.bundleID, category: "HuggingFaceSearch")

@MainActor
final class HuggingFaceSearchService: ObservableObject {

    @Published private(set) var results: [HFModelSummary] = []

    @Published private(set) var isSearching = false

    @Published var query = ""

    @Published private(set) var errorMessage: String?

    private let client: HuggingFaceAPIClient
    private let resultLimit: Int

    private var searchTask: Task<Void, Never>?

    init(client: HuggingFaceAPIClient = HuggingFaceAPIClient(), resultLimit: Int = 20) {
        self.client = client
        self.resultLimit = resultLimit
    }

    func search() async {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            errorMessage = nil
            isSearching = false
            return
        }

        let task = Task { await performSearch(query: trimmed) }
        searchTask = task
        await task.value
    }

    func ggufFiles(for modelID: String) async -> [HFFile] {
        do {
            let files = try await client.files(modelID: modelID)
            errorMessage = nil
            return files
        } catch is CancellationError {
            return []
        } catch {
            errorMessage = error.localizedDescription
            logger.error("File list failed for \(modelID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func performSearch(query: String) async {
        isSearching = true
        errorMessage = nil
        do {
            let found = try await client.searchModels(query: query, limit: resultLimit)
            guard !Task.isCancelled else { return }
            results = found
            isSearching = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            errorMessage = error.localizedDescription
            isSearching = false
            logger.error("Search for \(query, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
