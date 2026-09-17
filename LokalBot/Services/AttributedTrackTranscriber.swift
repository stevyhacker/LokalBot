import Foundation

/// Diarization partitions AUDIO before ASR. Text is never divided proportionally
/// across speaker turns, and overlapping voices never inherit a majority label.
enum AttributedTrackTranscriber {
    struct Region: Equatable {
        var start: Double
        var end: Double
        var speaker: String
        var attribution: SpeakerAttribution
    }

    static func regions(duration: Double, turns: [DiarizedSegment], source: SpeakerAttribution.Source) -> [Region] {
        guard duration.isFinite, duration > 0 else { return [] }
        let prefix = source == .microphone ? "local" : "them"
        let valid = turns.filter {
            $0.start.isFinite && $0.end.isFinite && $0.end > $0.start && $0.end > 0 && $0.start < duration
        }.sorted { $0.start < $1.start }
        let order = valid.reduce(into: [String]()) { ids, turn in
            if !ids.contains(turn.speakerId) { ids.append(turn.speakerId) }
        }
        let labels = Dictionary(uniqueKeysWithValues: order.enumerated().map {
            ($0.element, "\(prefix) \($0.offset + 1)")
        })
        let bounds = Array(Set([0, duration] + valid.flatMap { [max(0, $0.start), min(duration, $0.end)] })).sorted()
        var regions: [Region] = []
        for (start, end) in zip(bounds, bounds.dropFirst()) where end > start {
            let speakers = Set(valid.filter { $0.start < end && $0.end > start }.map(\.speakerId))
            let overlapping = speakers.count > 1
            let label = speakers.count == 1 ? labels[speakers.first!]! : overlapping ? "\(prefix) unclear" : prefix
            let method: SpeakerAttribution.Method = overlapping ? .overlappingSpeech : speakers.isEmpty ? .track : .diarization
            // Preserve unclassified audio as well. Microphone speech
            // remains unidentified; overlapping voices remain unresolved.
            let attribution = SpeakerAttribution(source: source,
                identity: source == .system && !overlapping ? .other : .unresolved, method: method).applyingMicrophoneDefault
            if let last = regions.last, last.speaker == label, last.attribution == attribution {
                regions[regions.count - 1].end = end
            } else {
                regions.append(Region(start: start, end: end, speaker: label, attribution: attribution))
            }
        }
        return regions.flatMap { region in
            stride(from: region.start, to: region.end, by: 30).map { start in
                Region(start: start, end: min(start + 30, region.end), speaker: region.speaker, attribution: region.attribution)
            }
        }
    }

    @MainActor
    static func transcribe(url: URL, duration: Double, diarization: [DiarizedSegment],
                           source: SpeakerAttribution.Source, engine: TranscriptionEngine,
                           language: String?, prompt: String?, contentRange: Meeting.ContentRange? = nil) async throws -> Transcript {
        let regions = regions(duration: duration, turns: diarization, source: source).compactMap { region -> Region? in
            guard let contentRange else { return region }
            guard contentRange.isValid else { return nil }
            var clipped = region
            clipped.start = max(region.start, contentRange.start)
            clipped.end = min(region.end, contentRange.end)
            return clipped.end > clipped.start ? clipped : nil
        }
        // Unconfirmed microphone identity also applies without speaker separation or
        // remembered voice profiles, using the optimized whole-file VAD path.
        if diarization.isEmpty && contentRange == nil {
            var transcript = try await engine.transcribe(audio: url, language: language, prompt: prompt)
            for index in transcript.segments.indices {
                transcript.segments[index].speaker = source == .microphone ? "local" : "them"
                transcript.segments[index].attribution = SpeakerAttribution(source: source,
                    identity: source == .system ? .other : .unresolved, method: .track).applyingMicrophoneDefault
            }
            return transcript
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lokalbot-speaker-asr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var segments: [Transcript.Segment] = []
        var engineName = engine.displayName
        for (index, region) in regions.enumerated() {
            try Task.checkCancellation()
            let audio = directory.appendingPathComponent("\(index).wav")
            let worker = Task.detached(priority: .utility) {
                let samples = try SpanAudioReader(url: url).samples(from: region.start, to: region.end)
                let writer = try WavWriter(url: audio, sampleRate: 16_000)
                try writer.append(samples)
                try writer.finish()
            }
            try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            let value = try await engine.transcribe(audio: audio, language: language, prompt: prompt)
            engineName = value.engine
            segments += value.segments.compactMap { segment in
                guard !segment.displayText.isEmpty, segment.start.isFinite, segment.end.isFinite else { return nil }
                var result = segment
                result.start = max(region.start, min(region.end, region.start + segment.start))
                result.end = max(result.start, min(region.end, region.start + segment.end))
                guard result.end > result.start else { return nil }
                result.speaker = region.speaker
                result.attribution = region.attribution
                return result
            }
            try? FileManager.default.removeItem(at: audio)
        }
        return Transcript(segments: segments, engine: engineName)
    }

    /// Recomputed embeddings (including crash resumes) map through retained
    /// audio intervals, never through a diarizer's ordinal speaker names.
    static func turns(_ turns: [DiarizedSegment], transcript: Transcript,
                      source: SpeakerAttribution.Source) -> [SpeakerAudioTurn] {
        turns.compactMap { turn in
            let range = SpeakerTurnAnchor(start: turn.start, end: turn.end)
            guard range.isValid, !turns.contains(where: {
                $0.speakerId != turn.speakerId && $0.start < turn.end && $0.end > turn.start
            }), let label = supportedSpeaker(in: range, transcript: transcript, source: source) else { return nil }
            return SpeakerAudioTurn(speaker: label, range: range, source: source)
        }
    }

    static func samples(_ samples: [SpeakerVoiceSample], transcript: Transcript,
                        source: SpeakerAttribution.Source) -> [SpeakerVoiceSample] {
        samples.compactMap { sample in
            guard sample.source == nil || sample.source == source,
                  let label = supportedSpeaker(in: sample.range, transcript: transcript, source: source) else { return nil }
            var result = sample
            result.speaker = label
            result.source = source
            return result
        }
    }

    private static func supportedSpeaker(in range: SpeakerTurnAnchor, transcript: Transcript,
                                         source: SpeakerAttribution.Source) -> String? {
        guard range.isValid else { return nil }
        let overlaps = transcript.segments.filter {
            $0.resolvedAttribution.source == source && $0.start < range.end && $0.end > range.start
        }
        let labels = Set(overlaps.map(\.speaker))
        guard labels.count == 1, let label = labels.first,
              overlaps.allSatisfy({ $0.resolvedAttribution.method == .diarization }),
              VisualSpeakerMatcher.union(overlaps.map { .init(start: $0.start, end: $0.end) })
                .reduce(0, { $0 + $1.overlap(range) }) >= range.duration * 0.95 else { return nil }
        return label
    }
}
