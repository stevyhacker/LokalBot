import XCTest
@testable import LokalBot

/// Opt-in replay of call-voice naming on real recordings, for calibrating
/// `SpeakerVoiceMatcher.Call`. Names saved in each transcript act as the
/// people LokalBot remembers from the other meetings; every call voice is then
/// matched the way processing would. Nothing leaves this Mac.
final class SpeakerVoiceReplayTests: XCTestCase {
    private struct Manifest: Decodable {
        var meetings: [String]
        /// Report folder; keep it outside the repository.
        var output: String
    }

    private struct Voice {
        var meeting: String
        var label: String
        var name: String?
        var samples: [SpeakerVoiceSample]
    }

    func testCallVoicesAcrossSavedMeetings() async throws {
        guard let path = ProcessInfo.processInfo.environment["LOKALBOT_SPEAKER_REPLAY_MANIFEST"] else {
            throw XCTSkip("Set LOKALBOT_SPEAKER_REPLAY_MANIFEST to replay call-voice naming on saved meetings.")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let engine = NeuralDiarizationEngine()
        var voices: [Voice] = []
        for folderPath in manifest.meetings {
            let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
            let transcript = try JSONDecoder().decode(Transcript.self,
                from: Data(contentsOf: folder.appendingPathComponent("transcript.json")))
            let audio = try XCTUnwrap(MeetingAudioFiles.transcribableURL(for: .system, in: folder))
            let result = try await engine.diarizeDetailed(url: audio, model: .community1, includeVoiceSamples: true)
            // The same two steps as processing: samples kept per acoustic turn,
            // then the ones matching the transcript's turns.
            let samples = AttributedTrackTranscriber.samples(result.samples, transcript: transcript, source: .system)
            let acoustic = AttributedTrackTranscriber.turns(result.segments, transcript: transcript, source: .system)
            let timeline = transcript.segments.filter { $0.resolvedAttribution.source == .system }.map {
                SpeakerAudioTurn(speaker: Transcript.canonicalSpeakerKey($0.speaker),
                                 range: .init(start: $0.start, end: $0.end), source: .system)
            }
            let meeting = folder.deletingLastPathComponent().lastPathComponent + "/" + folder.lastPathComponent
            for label in Set(timeline.map(\.speaker)).sorted() {
                let stored = SpeakerVoiceMatcher.eligible(samples, turns: acoustic, speaker: label)
                let query = SpeakerVoiceMatcher.eligible(stored, turns: timeline, speaker: label)
                guard !query.isEmpty else { continue }
                voices.append(Voice(meeting: meeting, label: label, name: transcript.speakerAliases[label], samples: query))
            }
        }

        var report: [[String: Any]] = []
        var right = 0, wrong = 0, missed = 0
        for meeting in Array(NSOrderedSet(array: voices.map(\.meeting))) as? [String] ?? [] {
            // People remembered from every other meeting, one contribution per meeting.
            let remembered = Dictionary(grouping: voices.filter {
                $0.meeting != meeting && $0.name != nil && SpeakerVoiceMatcher.canEnroll($0.samples)
            }, by: { ParticipantObservation.nameKey($0.name ?? "") }).values.compactMap { group -> SpeakerVoiceProfile? in
                guard let name = group.first?.name else { return nil }
                return SpeakerVoiceProfile(name: name, confirmedNames: [name], contributions: group.map {
                    .init(meetingID: UUID(), audioRevision: $0.meeting, speakerID: UUID(), decisionID: UUID(), confirmedAt: Date(),
                          samples: Array($0.samples.prefix(1)), voiceprint: SpeakerVoiceMatcher.voiceprint($0.samples)?.vector)
                })
            }
            for voice in voices where voice.meeting == meeting {
                let consistency = SpeakerVoiceMatcher.voiceprint(voice.samples)?.consistency ?? 0
                let matches = SpeakerVoiceMatcher.matches(samples: voice.samples, profiles: remembered)
                let best = matches.first
                let known = remembered.contains { ParticipantObservation.nameKey($0.name) == ParticipantObservation.nameKey(voice.name ?? "") }
                if let saved = voice.name, best?.tier == .automatic {
                    if ParticipantObservation.nameKey(saved) == ParticipantObservation.nameKey(best?.name ?? "") { right += 1 } else { wrong += 1 }
                } else if voice.name != nil, known {
                    missed += 1
                }
                let line = "\(meeting) \(voice.label) saved=\(voice.name ?? "-") samples=\(voice.samples.count) "
                    + "consistency=\(String(format: "%.2f", consistency)) -> \(best?.name ?? "-") "
                    + "\(best?.tier.rawValue ?? "none") \(String(format: "%.2f", best?.supportFraction ?? 0))"
                print("speaker replay " + line)
                report.append(["meeting": meeting, "label": voice.label, "saved": voice.name ?? NSNull(),
                               "samples": voice.samples.count, "consistency": consistency,
                               "matches": matches.map { ["name": $0.name, "tier": $0.tier.rawValue, "score": $0.supportFraction] }])
            }
        }
        print("speaker replay automatic right=\(right) wrong=\(wrong) savedButNotAutomatic=\(missed)")
        let output = URL(fileURLWithPath: manifest.output, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONSerialization.data(withJSONObject: ["voices": report, "right": right, "wrong": wrong, "missed": missed],
                                   options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("speaker-replay.json"))
        XCTAssertEqual(wrong, 0, "An automatic name contradicted a name saved in that meeting")
    }
}
