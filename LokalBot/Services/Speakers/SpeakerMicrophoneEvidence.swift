import Foundation

/// A microphone is an audio source, not a person. Echo removal is optional:
/// independently verified quiet reference windows can also support a voice
/// suggestion or a later, explicit enrollment.
enum SpeakerMicrophoneEvidence {
    struct Selection: Sendable {
        var samples: [SpeakerVoiceSample] = []
        var counts: [String: Int] = [:]
    }

    static func select(samples: [SpeakerVoiceSample], transcript: Transcript,
                       turns: [SpeakerAudioTurn], folder: URL) async -> Selection {
        let worker = Task.detached(priority: .utility) {
            selectSynchronously(samples: samples, transcript: transcript, turns: turns, folder: folder)
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    private static func selectSynchronously(samples: [SpeakerVoiceSample], transcript: Transcript,
                                            turns: [SpeakerAudioTurn], folder: URL) -> Selection {
        let remoteURL = MeetingAudioFiles.transcribableURL(for: .system, in: folder)
        let hasRemote = remoteURL != nil || transcript.segments.contains { $0.resolvedAttribution.source == .system }
        let timing = (try? Data(contentsOf: folder.appendingPathComponent(RecordingAudioTiming.fileName)))
            .flatMap { try? JSONDecoder().decode(RecordingAudioTiming.self, from: $0) }
        let reader = remoteURL.flatMap { try? SpanAudioReader(url: $0) }
        let remoteTurns = turns.filter { $0.resolvedSource == .system }.map(\.range)
            + transcript.segments.filter { $0.resolvedAttribution.source == .system }
                .map { SpeakerTurnAnchor(start: $0.start, end: $0.end) }
        var result = Selection()
        for sample in samples {
            guard !Task.isCancelled else { return Selection() }
            guard sample.source == .microphone else { result.samples.append(sample); continue }
            let reason: String
            if !sample.range.isValid || sample.range.duration < 3 || sample.range.duration > 30 {
                reason = "invalidSample"
            } else if transcript.segments.contains(where: {
                $0.resolvedAttribution.source == .microphone && $0.start < sample.range.end && $0.end > sample.range.start
                    && (Transcript.canonicalSpeakerKey($0.speaker) != sample.speaker
                        || ![.diarization, .confirmation, .profile].contains($0.resolvedAttribution.method))
            }) {
                reason = "ambiguousMicrophone"
            } else if !hasRemote || transcript.echoReport?.alignmentVerified == true {
                result.samples.append(sample)
                reason = hasRemote ? "verifiedEchoRemoval" : "microphoneOnly"
            } else if let timing, let reader,
                      let reference = timing.referenceRange(start: max(0, sample.range.start - 0.5), end: sample.range.end + 0.25) {
                // The padding includes plausible playback-to-microphone delay.
                // A diarizer miss is not silence; verify the actual waveform too.
                if remoteTurns.contains(where: { $0.overlap(reference) > 0 }) {
                    reason = "remoteSpeech"
                } else if let pcm = try? reader.samples(from: reference.start, to: reference.end),
                          referenceIsQuiet(pcm, expectedDuration: reference.duration) {
                    result.samples.append(sample)
                    reason = "quietReference"
                } else {
                    reason = "remoteAudioOrMissingSamples"
                }
            } else {
                reason = "missingClockOrReference"
            }
            result.counts[reason, default: 0] += 1
        }
        return result
    }

    static func referenceIsQuiet(_ samples: [Float], expectedDuration: Double) -> Bool {
        guard expectedDuration.isFinite, expectedDuration >= 3, !samples.isEmpty,
              abs(Double(samples.count) - expectedDuration * SpanAudioReader.sampleRate) <= 32,
              samples.allSatisfy(\.isFinite) else { return false }
        // Test short windows as well as the peak so a brief remote syllable
        // cannot disappear in the mean of a long silent interval.
        for start in stride(from: 0, to: samples.count, by: 320) {
            let window = samples[start..<min(samples.count, start + 320)]
            let power = window.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(window.count)
            guard power <= 0.000_000_01, window.allSatisfy({ abs($0) <= 0.001 }) else { return false }
        }
        return true
    }
}
