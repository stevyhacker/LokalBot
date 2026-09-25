import Foundation

enum VisualSpeakerMatcher {
    static func union(_ ranges: [SpeakerTurnAnchor]) -> [SpeakerTurnAnchor] {
        var result: [SpeakerTurnAnchor] = []
        for range in ranges.filter(\.isValid).sorted(by: { $0.start < $1.start }) {
            if let last = result.last, range.start <= last.end {
                result[result.count - 1].end = max(last.end, range.end)
            } else { result.append(range) }
        }
        return result
    }

    static func mergedTurns(_ turns: [SpeakerAudioTurn]) -> [SpeakerAudioTurn] {
        var result: [SpeakerAudioTurn] = []
        for turn in turns.filter({ $0.range.isValid }).sorted(by: { $0.range.start < $1.range.start }) {
            if let last = result.last, last.speaker == turn.speaker, turn.range.start - last.range.end <= 0.5 {
                result[result.count - 1].range.end = max(last.range.end, turn.range.end)
            } else { result.append(turn) }
        }
        return result
    }
}
