import Foundation
import FluidAudio

struct SpeechSpan: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let timingPrecision: Transcript.Segment.TimingPrecision

    init(start: TimeInterval, end: TimeInterval,
         timingPrecision: Transcript.Segment.TimingPrecision = .coarse) {
        self.start = start
        self.end = end
        self.timingPrecision = timingPrecision
    }
}

extension SpeechActivity {

    static let spanSampleRate = 16_000

    func spans(in url: URL, maxSegmentSeconds: Double?) async throws -> [SpeechSpan] {
        if let spans = await vadSpans(in: url, maxSegmentSeconds: maxSegmentSeconds) {
            return spans
        }
        let duration = try SpanAudioReader(url: url).duration
        return Self.split(start: 0, end: duration, maxSegmentSeconds: maxSegmentSeconds)
    }

    func vadSpans(in url: URL, maxSegmentSeconds: Double?) async -> [SpeechSpan]? {
        Self.vadSpans(from: await speechSegments(in: url), maxSegmentSeconds: maxSegmentSeconds)
    }

    static func vadSpans(from segments: [VadSegment]?, maxSegmentSeconds: Double?) -> [SpeechSpan]? {
        guard let segments else { return nil }
        guard !segments.isEmpty else { return [] }
        var spans: [SpeechSpan] = []
        for segment in segments {
            guard segment.startTime.isFinite, segment.endTime.isFinite else { continue }
            let start = max(0, segment.startTime)
            guard segment.endTime > start else { continue }
            spans.append(contentsOf: Self.split(
                start: start, end: segment.endTime,
                maxSegmentSeconds: maxSegmentSeconds,
                timingPrecision: .span))
        }
        return spans.isEmpty ? nil : spans
    }

    static func split(start: TimeInterval, end: TimeInterval,
                      maxSegmentSeconds: Double?,
                      timingPrecision: Transcript.Segment.TimingPrecision = .coarse
    ) -> [SpeechSpan] {
        guard end > start else { return [] }
        let minLength = 1.0 / Double(spanSampleRate)
        let maxLength = maxSegmentSeconds.map { max($0, minLength) } ?? (end - start)
        var spans: [SpeechSpan] = []
        var cursor = start
        while cursor < end {
            let next = min(cursor + maxLength, end)
            spans.append(.init(start: cursor, end: next,
                               timingPrecision: timingPrecision))
            cursor = next
        }
        return spans
    }
}

enum SpanTranscription {

    static func segments(
        in url: URL,
        spans: [SpeechSpan],
        speaker: String = "speaker",
        transcribe: (_ samples: [Float], _ index: Int) async throws -> String
    ) async throws -> [Transcript.Segment] {
        guard !spans.isEmpty else { return [] }
        let reader = try SpanAudioReader(url: url)
        var segments: [Transcript.Segment] = []
        for (index, span) in spans.enumerated() {
            let samples = try reader.samples(from: span.start, to: span.end)
            guard !samples.isEmpty else { continue }
            let normalized = Transcript.normalizedText(try await transcribe(samples, index))
            guard !normalized.isEmpty else { continue }
            segments.append(.init(start: span.start, end: span.end,
                                  speaker: speaker, text: normalized, confidence: nil,
                                  timingPrecision: span.timingPrecision))
        }
        return segments
    }

    static func segments(pairing spans: [SpeechSpan], with texts: [String],
                         speaker: String = "speaker") -> [Transcript.Segment] {
        zip(spans, texts).compactMap { span, text in
            let normalized = Transcript.normalizedText(text)
            guard !normalized.isEmpty else { return nil }
            return .init(start: span.start, end: span.end,
                         speaker: speaker, text: normalized, confidence: nil,
                         timingPrecision: span.timingPrecision)
        }
    }
}
