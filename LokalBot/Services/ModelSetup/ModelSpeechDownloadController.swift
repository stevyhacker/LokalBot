import Foundation

@MainActor
final class ModelSpeechDownloadController: ObservableObject {
    @Published private(set) var isDownloaded = KokoroSpeechEngine.isModelDownloaded
    @Published private(set) var isPreparing = false
    @Published private(set) var progress: Double?
    @Published private(set) var status: String?
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?

    func refresh() { isDownloaded = KokoroSpeechEngine.isModelDownloaded }

    func download() {
        guard !isPreparing else { return }
        isPreparing = true
        error = nil
        status = "Preparing…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { isPreparing = false; progress = nil; status = nil; task = nil; refresh() }
            do {
                try await KokoroSpeechEngine.shared.prepare { [weak self] update in
                    self?.progress = update.fractionCompleted
                    self?.status = update.status
                }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func cancel() { task?.cancel() }

    func delete() {
        guard !isPreparing else { return }
        do {
            try KokoroSpeechEngine.deleteModel()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }
}
