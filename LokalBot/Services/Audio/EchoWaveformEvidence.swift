import Foundation

/// A narrow fallback for near-identical digital echoes. Normal room echoes
/// are handled by AEC; lexical similarity cannot authorize deleting speech.
enum EchoWaveformEvidence {
    struct Analysis {
        var verified: Set<Int> = []
        var suspected: Set<Int> = []
    }

    static func verified(in transcript: Transcript, folder: URL) async throws -> Set<Int> {
        try await analyze(in: transcript, folder: folder).verified
    }

    static func analyze(in transcript: Transcript, folder: URL) async throws -> Analysis {
        let removable = SpeakerBleedFilter.filter(transcript).acousticCandidateIndices
        let indices = transcript.segments.indices.filter {
            let segment = transcript.segments[$0]
            return segment.resolvedAttribution.source == .microphone
                && !segment.resolvedAttribution.hasIdentityDecision
                && segment.start.isFinite && segment.end.isFinite
                && segment.end - segment.start >= 1 && segment.end - segment.start <= 30
        }
        guard !indices.isEmpty else { return Analysis() }
        let worker = Task.detached(priority: .utility) { () -> Analysis in
            guard let micURL = MeetingAudioFiles.transcribableURL(for: .mic, in: folder),
                  let remoteURL = MeetingAudioFiles.transcribableURL(for: .system, in: folder) else { return Analysis() }
            let timing = (try? Data(contentsOf: folder.appendingPathComponent(RecordingAudioTiming.fileName)))
                .flatMap { try? JSONDecoder().decode(RecordingAudioTiming.self, from: $0) }
            var result = Analysis()
            let micReader = try SpanAudioReader(url: micURL)
            let remoteReader = try SpanAudioReader(url: remoteURL)
            for index in indices {
                try Task.checkCancellation()
                let segment = transcript.segments[index]
                let mapped = timing?.referenceRange(start: segment.start, end: segment.end)
                if timing != nil && mapped == nil { continue }
                let referenceRange = mapped ?? SpeakerTurnAnchor(start: segment.start, end: segment.end)
                guard let microphone = try? micReader.samples(from: segment.start, to: segment.end),
                      let reference = try? remoteReader.samples(from: referenceRange.start, to: referenceRange.end) else { continue }
                // Acoustic suspicion does not require ASR to choose identical
                // words (or even the same language). It never deletes speech.
                if suspectedEcho(microphone: microphone, reference: reference) { result.suspected.insert(index) }
                if removable.contains(index), nearIdentical(microphone: microphone, reference: reference) {
                    result.verified.insert(index)
                }
            }
            return result
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    static func suspectedEcho(microphone: [Float], reference: [Float]) -> Bool {
        guard microphone.count >= 16_000, abs(microphone.count - reference.count) <= 32,
              microphone.allSatisfy(\.isFinite), reference.allSatisfy(\.isFinite) else { return false }
        let power = reference.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(reference.count)
        guard power > 0.000_001 else { return false }
        // The loudness contour tolerates room coloration and playback delay.
        // This uncalibrated conservative flag means uncertainty, never identity.
        return EchoDelayEstimator.estimate(microphone: microphone, reference: reference, sampleRate: 16_000).correlation >= 0.75
    }

    static func nearIdentical(microphone: [Float], reference: [Float]) -> Bool {
        guard microphone.count >= 16_000, abs(microphone.count - reference.count) <= 32 else { return false }
        let estimate = EchoDelayEstimator.estimate(microphone: microphone, reference: reference, sampleRate: 16_000)
        guard estimate.isReliable else { return false }
        // Decimated waveform comparison keeps the bounded fallback inexpensive.
        // The threshold deliberately accepts only near-exact copies, not two
        // people speaking the same words, or a mixture containing a quiet reply.
        let mic = stride(from: 0, to: microphone.count, by: 16).map { Double(microphone[$0]) }
        let remote = stride(from: 0, to: reference.count, by: 16).map { Double(reference[$0]) }
        let center = estimate.samples / 16
        return (center - 20...center + 20).contains { shift in
            EchoDelayEstimator.correlation(mic, remote, shift: shift) >= 0.999
        }
    }
}
