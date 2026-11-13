import Foundation

/// One outstanding pair of reads even when a writer stalls or recording changes.
/// Views consume the last sample and never touch an audio writer queue.
@MainActor
final class RecordingHealthSampler {
    struct Sample: Sendable {
        let microphone: MicRecorder.CaptureHealth
        let system: SystemAudioRecorder.CaptureHealth
    }

    private(set) var latest: Sample?
    private var generation = UUID()
    private var pending: Task<Void, Never>?

    func request(
        microphone: @escaping @MainActor () async -> MicRecorder.CaptureHealth,
        system: @escaping @MainActor () async -> SystemAudioRecorder.CaptureHealth,
        receive: @escaping @MainActor (Sample) -> Void
    ) {
        guard pending == nil else { return }
        let generation = generation
        pending = Task { [weak self] in
            async let mic = microphone()
            async let audio = system()
            let sample = await Sample(microphone: mic, system: audio)
            guard let self else { return }
            self.pending = nil
            guard !Task.isCancelled, self.generation == generation else { return }
            self.latest = sample
            receive(sample)
        }
    }

    func waitForPendingSample() async { await pending?.value }

    func invalidate() {
        generation = UUID()
        latest = nil
        pending?.cancel()
        // Keep the slot occupied until the queued reads finish. Cancellation
        // cannot remove a read already waiting behind filesystem I/O.
    }
}
