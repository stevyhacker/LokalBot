import Foundation

/// Runs the optional meeting note export. A pass starts when the export is
/// configured and after meeting evidence, People, or Projects change, at most
/// once a minute and never while `canRun` says processing is busy. Each pass
/// re-renders only the meetings whose sources changed since the last one, so
/// following corrections does not reread the whole library.
@MainActor
final class MeetingNoteExportScheduler {
    struct Configuration: Equatable, Sendable {
        var enabled: Bool
        /// Folder, format, and transcript choice. Changing any of them
        /// exports every meeting again into the chosen folder.
        var destinationID: String
    }

    typealias Export = @Sendable ([UUID: String]) async throws -> MeetingNoteExportReport

    /// A failed pass waits this long before it is tried again, which gives a
    /// removable or network volume time to return.
    nonisolated static let retryInterval: TimeInterval = 15 * 60

    private let now: () -> Date
    private let canRun: () -> Bool
    private var configuration: Configuration?
    private var export: Export?
    private var errorHandler: ((String) -> Void)?
    private var timer: Timer?
    private var task: Task<Void, Never>?
    /// Source fingerprints from the last pass, by meeting.
    private var fingerprints: [UUID: String] = [:]
    private var pending = false
    private var retryAfter: Date?
    private var generation = 0

    init(now: @escaping () -> Date = Date.init, canRun: @escaping () -> Bool = { true }) {
        self.now = now
        self.canRun = canRun
    }

    var isRunning: Bool { task != nil }

    func configure(
        _ configuration: Configuration,
        export: @escaping Export,
        onError: @escaping (String) -> Void
    ) {
        if self.configuration != configuration {
            cancel()
            fingerprints = [:]
            retryAfter = nil
            pending = true
        }
        self.configuration = configuration
        self.export = export
        errorHandler = onError
        timer?.invalidate()
        timer = nil
        guard configuration.enabled, !configuration.destinationID.isEmpty else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        cancel()
        timer?.invalidate()
        timer = nil
    }

    /// Something a note shows may have changed. The next tick looks.
    func reconsider() {
        pending = true
    }

    func tick() {
        guard task == nil, pending,
              let configuration, configuration.enabled,
              !configuration.destinationID.isEmpty,
              let export, canRun() else { return }
        if let retryAfter, now() < retryAfter { return }
        pending = false
        let previous = fingerprints
        let runGeneration = generation
        task = Task { @MainActor [weak self] in
            let result: Result<MeetingNoteExportReport, Error>
            do {
                result = .success(try await Self.run(export, previous: previous))
            } catch {
                result = .failure(error)
            }
            self?.finish(result, generation: runGeneration)
        }
    }

    private func finish(_ result: Result<MeetingNoteExportReport, Error>, generation runGeneration: Int) {
        guard generation == runGeneration else { return }
        task = nil
        switch result {
        case .success(let report):
            fingerprints = report.fingerprints
            if let failure = report.failures.first {
                scheduleRetry()
                errorHandler?("Meeting note export failed for \(failure)")
            } else {
                retryAfter = nil
            }
        case .failure(let error) where error is CancellationError:
            pending = true
        case .failure(let error):
            scheduleRetry()
            errorHandler?("Meeting note export failed: \(error.localizedDescription)")
        }
    }

    private func scheduleRetry() {
        pending = true
        retryAfter = now().addingTimeInterval(Self.retryInterval)
    }

    /// A cancelled pass may have left notes behind; the next start redoes it.
    private func cancel() {
        generation &+= 1
        if let task {
            task.cancel()
            pending = true
        }
        task = nil
    }

    /// A structured utility-priority child, so cancelling the pass reaches
    /// the filesystem worker itself.
    private nonisolated static func run(
        _ export: @escaping Export,
        previous: [UUID: String]
    ) async throws -> MeetingNoteExportReport {
        try await withThrowingTaskGroup(of: MeetingNoteExportReport.self) { group in
            group.addTask(priority: .utility) {
                try Task.checkCancellation()
                return try await export(previous)
            }
            guard let report = try await group.next() else { throw CancellationError() }
            return report
        }
    }
}
