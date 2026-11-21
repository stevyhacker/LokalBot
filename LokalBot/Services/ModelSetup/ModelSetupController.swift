import Foundation

@MainActor
final class ModelSetupController: ObservableObject {
    typealias Prepare = @MainActor (ModelSelectionPatch, AppSettings) async throws -> Void

    struct Change: Equatable {
        let title: String
        let patch: ModelSelectionPatch
        let previous: ModelSelectionPatch
    }

    @Published private(set) var pending: Change?
    @Published private(set) var completed: Change?
    @Published private(set) var failure: String?
    @Published private(set) var failedChange: Change?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let settings: () -> AppSettings
    private let update: (AppSettings) -> Void
    private let prepare: Prepare

    init(settings: @escaping () -> AppSettings,
         update: @escaping (AppSettings) -> Void,
         prepare: @escaping Prepare) {
        self.settings = settings
        self.update = update
        self.prepare = prepare
    }

    func apply(_ patch: ModelSelectionPatch, title: String) {
        cancelSwitch()
        let current = settings()
        let change = Change(title: title, patch: patch, previous: patch.inverse(in: current))
        let token = UUID()
        generation = token
        pending = change
        completed = nil
        failure = nil
        failedChange = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await prepare(patch, current)
                try Task.checkCancellation()
                guard generation == token else { return }
                let latest = settings()
                guard change.previous.matches(latest) else {
                    throw ModelDownloadManager.PreparationError.failed(
                        "The model selection changed while preparing. Your newer selection was kept. Choose the model again to switch.")
                }
                guard patch.preparationContextMatches(latest, original: current) else {
                    throw ModelDownloadManager.PreparationError.failed(
                        "The model files or connection changed while preparing. Your changes were kept. Choose the model again to switch.")
                }
                if patch.backend != nil {
                    let destination = InferencePresentation(settings: patch.applying(to: latest))
                    if case .blocked(let reason) = destination {
                        throw ModelDownloadManager.PreparationError.failed(reason)
                    }
                }
                update(patch.applying(to: latest))
                completed = change
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                failure = error.localizedDescription
                let retryable = (error as? ModelDownloadManager.PreparationError)?.isRetryable ?? true
                failedChange = retryable ? change : nil
            }
            guard generation == token else { return }
            pending = nil
            task = nil
        }
    }

    func cancelSwitch() {
        generation = UUID()
        task?.cancel()
        task = nil
        pending = nil
    }

    func retry() {
        guard let failedChange else { return }
        apply(failedChange.patch, title: failedChange.title)
    }

    func undo() {
        guard let completed else { return }
        guard completed.patch.matches(settings()) else {
            self.completed = nil
            return
        }
        apply(completed.previous, title: "Previous model setup")
    }

    func dismissFeedback() {
        completed = nil
        failure = nil
        failedChange = nil
    }
}
