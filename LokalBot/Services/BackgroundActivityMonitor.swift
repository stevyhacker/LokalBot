import Combine
import Foundation

/// Publishes the ordered list of long-running work shown by the sidebar
/// progress card. It only combines state the owners already publish, so a
/// cancelled or failed run disappears as soon as its owner clears it.
@MainActor
final class BackgroundActivityMonitor: ObservableObject {
    struct Sources {
        var pipeline: ProcessingPipeline
        var dayDigest: DayDigestLifecycle
        var dreaming: DreamScheduler
        var downloads: ModelDownloadManager
        var reindex: AnyPublisher<BackgroundCount?, Never>
        var meetingTitle: @MainActor (UUID) -> String?
        var modelName: @MainActor (String) -> String
    }

    @Published private(set) var activities: [BackgroundActivity] = []
    private var subscription: AnyCancellable?

    func bind(_ sources: Sources) {
        let dream = sources.dreaming.$activeDayKey
            .combineLatest(sources.dreaming.$remainingCatchUpDays)
        subscription = Publishers.CombineLatest4(
            sources.pipeline.$stages,
            sources.dayDigest.$activeRuns,
            dream,
            sources.downloads.$progress)
            .combineLatest(sources.reindex)
            // @Published emits before the owner's property changes; deliver
            // on the next main-queue turn so views never update mid-update.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] owned, reindex in
                let (stages, runs, dream, downloads) = owned
                MainActor.assumeIsolated {
                    self?.activities = BackgroundActivity.derive(Self.inputs(
                        stages: stages, runs: runs, dream: dream,
                        downloads: downloads, reindex: reindex, sources: sources))
                }
            }
    }

    private static func inputs(
        stages: [Meeting.ID: ProcessingPipeline.Stage],
        runs: [DayDigestLifecycle.ActiveRun],
        dream: (dayKey: String?, remaining: Int),
        downloads: [String: Double],
        reindex: BackgroundCount?,
        sources: Sources
    ) -> BackgroundActivity.Inputs {
        let calendar = Calendar.current
        var inputs = BackgroundActivity.Inputs(calendar: calendar)
        inputs.meetings = stages
            .filter { $0.value.isActiveWork || $0.value == .queued }
            .map { .init(id: $0.key, title: sources.meetingTitle($0.key) ?? "Meeting", stage: $0.value) }
            .sorted { ($0.title, $0.id.uuidString) < ($1.title, $1.id.uuidString) }
        inputs.digests = runs.map { .init(id: $0.id, day: $0.day, progress: $0.progress) }
        if let key = dream.dayKey, let day = DreamDay.date(fromKey: key, calendar: calendar) {
            inputs.dream = .init(day: day, remainingDays: dream.remaining)
        }
        inputs.downloads = downloads.map {
            .init(id: $0.key, name: sources.modelName($0.key), fraction: $0.value)
        }
        inputs.reindex = reindex
        return inputs
    }
}
