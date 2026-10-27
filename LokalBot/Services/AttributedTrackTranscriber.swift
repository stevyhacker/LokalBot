import Foundation

/// Diarization partitions AUDIO before ASR. Text is never divided proportionally
/// across speaker turns, and overlapping voices never inherit a majority label.
enum AttributedTrackTranscriber {
    /// A region shorter than this whose transcription fails is skipped rather
    /// than failing the track. Longer regions keep normal error handling, so a
    /// broken engine still surfaces.
    static let rejectableRegionSeconds: TimeInterval = 1

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
            // Preserve unclassified audio as well. Microphone speech follows
            // the “My microphone is me” default; overlapping voices remain unresolved.
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

    /// Fetches the forced aligner before it times words. Tests replace it to
    /// see whether the aligner is needed at all.
    typealias AlignerPreparation = @MainActor () async throws -> Void
    static let downloadAligner: AlignerPreparation = { try await QwenWordAligner.shared.downloadIfNeeded() }

    @MainActor
    static func transcribe(url: URL, duration: Double, diarization: [DiarizedSegment],
                           source: SpeakerAttribution.Source, engine: TranscriptionEngine,
                           language: String?, prompt: String?, contentRange: Meeting.ContentRange? = nil,
                           prepareAligner: AlignerPreparation = downloadAligner) async throws -> Transcript {
        var transcript = try await attributedTranscript(url: url, duration: duration, diarization: diarization,
            source: source, engine: engine, language: language, prompt: prompt, contentRange: contentRange,
            prepareAligner: prepareAligner)
        // A prompt-capable model answers a near-silent span with its
        // vocabulary hint, and forced alignment then packs those words into a
        // sub-second row of their own. Nothing downstream should see one.
        if let echo = TranscriptionPromptEcho(prompt: prompt) {
            let kept = echo.removing(from: transcript.segments)
            if kept.count < transcript.segments.count {
                lokalbotLog("speaker-asr: dropped \(transcript.segments.count - kept.count) row(s) echoing the vocabulary prompt")
                transcript.segments = kept
            }
        }
        return transcript
    }

    @MainActor
    private static func attributedTranscript(url: URL, duration: Double, diarization: [DiarizedSegment],
                                             source: SpeakerAttribution.Source, engine: TranscriptionEngine,
                                             language: String?, prompt: String?,
                                             contentRange: Meeting.ContentRange?,
                                             prepareAligner: AlignerPreparation) async throws -> Transcript {
        if engine.speakerAttribution == .alignedWords, !(diarization.isEmpty && contentRange == nil),
           let transcript = try await alignedWordTranscript(
               url: url, duration: duration, diarization: diarization, source: source, engine: engine,
               language: language, prompt: prompt, contentRange: contentRange, prepareAligner: prepareAligner) {
            return transcript
        }
        let regions = regions(duration: duration, turns: diarization, source: source).compactMap { region -> Region? in
            guard let contentRange else { return region }
            guard contentRange.isValid else { return nil }
            var clipped = region
            clipped.start = max(region.start, contentRange.start)
            clipped.end = min(region.end, contentRange.end)
            return clipped.end > clipped.start ? clipped : nil
        }
        // The microphone default also applies without speaker separation or
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
            let value: Transcript
            do {
#if LOKALBOT_TEST_HOOKS
                let slice = GoldenTranscriptionEngine.Region(track: url, start: region.start, end: region.end)
                value = try await GoldenTranscriptionEngine.$region.withValue(slice) {
                    try await engine.transcribe(audio: audio, language: language, prompt: prompt)
                }
#else
                value = try await engine.transcribe(audio: audio, language: language, prompt: prompt)
#endif
            } catch let error where !(error is CancellationError)
                        && region.end - region.start < Self.rejectableRegionSeconds {
                // Turn boundaries leave slivers shorter than some engines accept
                // (Parakeet rejects audio under 0.3 s). Losing one sliver is far
                // better than failing the track, and with it the whole meeting.
                lokalbotLog("speaker-asr: skipped a \(String(format: "%.2f", region.end - region.start)) s region "
                    + "the engine rejected: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: audio)
                continue
            }
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

    // MARK: - Transcribe first, attribute after

    /// One engine segment with its timed words (the engine's own, or forced-
    /// aligned) on the track timeline.
    struct AlignedSegment: Sendable {
        var segment: Transcript.Segment
        var words: [AlignedWordTiming]
    }

    /// Words this close to a speaker turn take that speaker. Diarizer turn
    /// edges and aligner word edges disagree by a few hundred milliseconds;
    /// on AMI a 1 s tolerance gave 34.5% cpWER against 51.1% for a strict
    /// midpoint rule (Benchmarks/QwenSpanLength).
    static let wordGapTolerance: TimeInterval = 1.0

    /// A pause this long between aligned words starts a new segment (FluidAudio
    /// VAD's own split), and no segment grows past `maxSegmentSeconds`. Long
    /// decode windows then keep the segment granularity of short ones.
    static let wordPauseSplit: TimeInterval = 0.75
    static let maxSegmentSeconds: TimeInterval = 15

    /// Transcribes the whole track, then attributes timed words, so speaker
    /// turns never cut the audio the model hears. Words come from the engine
    /// when it times them (`providesWordTimings`), otherwise from the forced
    /// aligner. Nil means "use regions": an unsupported language or an
    /// unavailable aligner with no engine word times to fall back on.
    @MainActor
    private static func alignedWordTranscript(url: URL, duration: Double, diarization: [DiarizedSegment],
                                              source: SpeakerAttribution.Source, engine: TranscriptionEngine,
                                              language: String?, prompt: String?,
                                              contentRange: Meeting.ContentRange?,
                                              prepareAligner: AlignerPreparation) async throws -> Transcript? {
        let engineTimesWords = engine.providesWordTimings
        if !engineTimesWords, !(try await alignerAvailable(for: language, prepare: prepareAligner)) { return nil }
        let transcript = try await engine.transcribeForWordAttribution(audio: url, language: language, prompt: prompt)
        guard !transcript.segments.isEmpty else { return transcript.transcript }
        let segments = transcript.segments
        let engineTimed = segments.map(engineWords(of:))
        let untimed = engineTimed.filter { $0 == nil }.count
        var alignLanguage: String?
        if untimed > 0 {
            if engineTimesWords {
                lokalbotLog("word attribution: the engine timed \(segments.count - untimed) of \(segments.count) "
                    + "segment(s); aligning the rest")
            }
            // Without engine word times the aligner was fetched before transcribing.
            let alignerReady = engineTimesWords ? try await alignerAvailable(for: language, prepare: prepareAligner) : true
            if alignerReady {
                alignLanguage = language ?? QwenWordAligner.detectedLanguage(of: segments.map(\.segment.text))
            }
            if alignLanguage == nil {
                guard untimed < segments.count else {
                    lokalbotLog("word attribution skipped: detected language unsupported, using speaker regions")
                    return nil
                }
                lokalbotLog("word attribution: \(untimed) segment(s) without word times keep one speaker each")
            }
        }
        let worker = Task.detached(priority: .utility) {
            var aligned = zip(segments, engineTimed).map { AlignedSegment(segment: $0.segment, words: $1 ?? []) }
            let needed = aligned.indices.filter { engineTimed[$0] == nil }
            if let alignLanguage, !needed.isEmpty {
                let timed = try await alignedSegments(needed.map { aligned[$0].segment }, url: url,
                                                      language: alignLanguage)
                for (index, item) in zip(needed, timed) { aligned[index] = item }
            }
            return attribute(aligned, duration: duration, turns: diarization, source: source,
                             contentRange: contentRange)
        }
        let attributed = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        return Transcript(segments: attributed, engine: transcript.engine)
    }

    /// The engine's own word times when `attribute` can cut the segment's
    /// text at them; otherwise the forced aligner times the segment.
    static func engineWords(of segment: WordTimedTranscript.Segment) -> [AlignedWordTiming]? {
        guard let words = segment.words, !words.isEmpty,
              wordStarts(words.map(\.text), in: segment.segment.text) != nil else { return nil }
        return words
    }

    /// Whether the forced aligner can time words in `language` (nil: decided
    /// after transcription), downloading it first if needed.
    @MainActor
    private static func alignerAvailable(for language: String?, prepare: AlignerPreparation) async throws -> Bool {
        if let language, !QwenWordAligner.supports(language) { return false }
        do {
            try await prepare()
            return true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lokalbotLog("word aligner unavailable: \(error.localizedDescription)")
            return false
        }
    }

    private static func alignedSegments(_ segments: [Transcript.Segment], url: URL,
                                        language: String) async throws -> [AlignedSegment] {
        let reader = try SpanAudioReader(url: url)
        var aligned: [AlignedSegment] = []
        for segment in segments {
            try Task.checkCancellation()
            let samples = try reader.samples(from: segment.start, to: segment.end)
            var words: [AlignedWordTiming] = []
            if !samples.isEmpty {
                do {
                    words = try await QwenWordAligner.shared.align(samples, text: segment.text, language: language)
                        .map { .init(text: $0.text, start: segment.start + $0.start, end: segment.start + $0.end) }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The segment keeps one speaker, chosen at its midpoint.
                    lokalbotLog("word alignment failed for one segment: \(error.localizedDescription)")
                }
            }
            aligned.append(.init(segment: segment, words: words))
        }
        await QwenWordAligner.shared.finishBatch()
        return aligned
    }

    /// Splits each engine segment where its aligned words change speaker,
    /// pause for `wordPauseSplit`, or would outgrow `maxSegmentSeconds`.
    /// Labels and attributions follow `regions`: one active turn names the
    /// speaker, overlapping turns are unclear, and words away from every turn
    /// keep the track label. Text is cut from the segment, never divided
    /// proportionally. Speaker pieces then widen to the edges of their own
    /// turns, without crossing a neighbour, so acoustic turns stay supported.
    static func attribute(_ aligned: [AlignedSegment], duration: Double, turns: [DiarizedSegment],
                          source: SpeakerAttribution.Source, contentRange: Meeting.ContentRange?,
                          gapTolerance: TimeInterval = wordGapTolerance) -> [Transcript.Segment] {
        struct Speaker: Equatable {
            var id: String?
            var label: String
            var attribution: SpeakerAttribution
        }
        struct Piece {
            var start: TimeInterval
            var end: TimeInterval
            var speaker: Speaker
            var text: String
            var precision: Transcript.Segment.TimingPrecision?
        }

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
        let lower = contentRange.map { $0.isValid ? $0.start : 0 } ?? 0
        let upper = contentRange.map { $0.isValid ? $0.end : 0 } ?? duration

        func speaker(at time: TimeInterval) -> Speaker {
            var active = Set(valid.filter { $0.start <= time && time < $0.end }.map(\.speakerId))
            if active.isEmpty, let nearest = valid.min(by: {
                max($0.start - time, time - $0.end) < max($1.start - time, time - $1.end)
            }), max(nearest.start - time, time - nearest.end) <= gapTolerance {
                active = [nearest.speakerId]
            }
            if active.count == 1, let id = active.first, let label = labels[id] {
                return Speaker(id: id, label: label, attribution: SpeakerAttribution(
                    source: source, identity: source == .system ? .other : .unresolved,
                    method: .diarization).applyingMicrophoneDefault)
            }
            if active.count > 1 {
                return Speaker(id: nil, label: "\(prefix) unclear", attribution: SpeakerAttribution(
                    source: source, identity: .unresolved, method: .overlappingSpeech).applyingMicrophoneDefault)
            }
            return Speaker(id: nil, label: prefix, attribution: SpeakerAttribution(
                source: source, identity: source == .system ? .other : .unresolved,
                method: .track).applyingMicrophoneDefault)
        }

        var pieces: [Piece] = []
        for item in aligned {
            let segment = item.segment
            let text = segment.text
            guard !item.words.isEmpty, let starts = wordStarts(item.words.map(\.text), in: text) else {
                let middle = (segment.start + segment.end) / 2
                if middle >= lower, middle <= upper {
                    pieces.append(Piece(start: segment.start, end: segment.end, speaker: speaker(at: middle),
                                        text: text, precision: segment.timingPrecision))
                }
                continue
            }
            var run: (first: Int, last: Int, speaker: Speaker)?
            func close(before next: Int?) {
                guard let current = run else { return }
                let from = current.first == 0 ? text.startIndex : starts[current.first]
                let to = next.map { starts[$0] } ?? text.endIndex
                var start = min(max(item.words[current.first].start, segment.start), segment.end)
                var end = min(max(item.words[current.last].end, segment.start), segment.end)
                if end <= start {
                    end = min(segment.end, start + 0.01)
                    start = min(start, max(segment.start, end - 0.01))
                }
                pieces.append(Piece(start: start, end: end, speaker: current.speaker,
                                    text: String(text[from..<to]), precision: .token))
                run = nil
            }
            for (index, word) in item.words.enumerated() {
                let middle = (word.start + word.end) / 2
                guard middle >= lower, middle <= upper else {
                    close(before: index)
                    continue
                }
                let who = speaker(at: middle)
                if let current = run, current.speaker == who,
                   word.start - item.words[current.last].end < wordPauseSplit,
                   word.end - item.words[current.first].start <= maxSegmentSeconds {
                    run?.last = index
                } else {
                    close(before: index)
                    run = (index, index, who)
                }
            }
            close(before: nil)
        }

        pieces.sort { $0.start < $1.start }
        for index in pieces.indices {
            guard let id = pieces[index].speaker.id else { continue }
            let floor = index > 0 ? pieces[index - 1].end : lower
            let ceiling = index + 1 < pieces.count ? pieces[index + 1].start : upper
            var start = pieces[index].start, end = pieces[index].end
            for turn in valid where turn.speakerId == id && turn.start < end && turn.end > start {
                start = max(floor, min(start, turn.start))
                end = min(ceiling, max(end, turn.end))
            }
            if end > start {
                pieces[index].start = start
                pieces[index].end = end
            }
        }
        return pieces.compactMap { piece in
            let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, piece.end > piece.start else { return nil }
            return Transcript.Segment(start: piece.start, end: piece.end, speaker: piece.speaker.label, text: text,
                                      timingPrecision: piece.precision, attribution: piece.speaker.attribution)
        }
    }

    /// Where each aligned word begins in `text`, matched in order on its
    /// letters and digits (the aligner keeps adjacent punctuation on its
    /// surface form). Nil when a word cannot be found, so the caller keeps
    /// the segment whole rather than guessing a cut.
    static func wordStarts(_ surfaces: [String], in text: String) -> [String.Index]? {
        var cursor = text.startIndex
        var starts: [String.Index] = []
        for surface in surfaces {
            let key = surface.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? surface
            let core = key.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            guard !core.isEmpty, let found = text.range(of: core, range: cursor..<text.endIndex) else { return nil }
            starts.append(found.lowerBound)
            cursor = found.upperBound
        }
        return starts
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
            // Call speech pauses between sentences; the voice model weighs only
            // the speaker's own frames, so a pause is not another person.
            guard sample.source == nil || sample.source == source,
                  let label = supportedSpeaker(in: sample.range, transcript: transcript, source: source,
                                               coverage: source == .system ? 0.6 : 0.95) else { return nil }
            var result = sample
            result.speaker = label
            result.source = source
            return result
        }
    }

    private static func supportedSpeaker(in range: SpeakerTurnAnchor, transcript: Transcript,
                                         source: SpeakerAttribution.Source, coverage: Double = 0.95) -> String? {
        guard range.isValid else { return nil }
        let overlaps = transcript.segments.filter {
            $0.resolvedAttribution.source == source && $0.start < range.end && $0.end > range.start
        }
        let labels = Set(overlaps.map(\.speaker))
        guard labels.count == 1, let label = labels.first,
              overlaps.allSatisfy({ $0.resolvedAttribution.method == .diarization }),
              VisualSpeakerMatcher.union(overlaps.map { .init(start: $0.start, end: $0.end) })
                .reduce(0, { $0 + $1.overlap(range) }) >= range.duration * coverage else { return nil }
        return label
    }
}
