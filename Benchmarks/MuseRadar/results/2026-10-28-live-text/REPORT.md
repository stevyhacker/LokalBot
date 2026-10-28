# Fast live text on a voiced meeting — 28 October 2026

**Result:** with fast live text, Live Radar showed each planted item a median **8.0 s** after the sentence began, about **3 s after the speaker finished**. With the local preview's 12-second chunks and 20-second passes, the text replays of this meeting showed items 15–25 s after they were said, and the AMI replays a median 23 s ([AMI evaluation](../2026-10-27/REPORT.md)). It caught all six planted items from the audio, including both contradictions with the earlier meeting, and rejected nothing.

## Setup

- **Meeting.** `fixtures/synthetic-launch-sync.json`, voiced by `voice_fixture.py` with macOS `say`: Samantha on the microphone track, Daniel on the call track, each line at its fixture time. 109 s per track ([line timings](voiced-lines.json)).
- **Run.** `LokalBot Dev --radar-replay fixtures/synthetic-launch-sync.json --audio <folder>`, built from the `meta-hackathon` branch after `8942c16` with fast live text. Both tracks streamed in real time to `muse-voice-transcribe-1.0` (`ENDPOINTING` mode) through `MuseLiveTextTrack`, and each pass went to `muse-spark-1.3` (minimal reasoning) at most every 3 s.
- **Measure.** `shownAfter` is seconds on the wall clock from the start of the quoted turn to the end of the pass that added the item. Machine: Apple M4 Max, home connection in Montenegro.

## Items

| Item | Said at | Shown after | After the speaker stopped |
|---|---:|---:|---:|
| Commitment: send the revised pricing deck to "Marco" by Friday | 21.7 s | 6.2 s | 2.7 s |
| Open question: annual plan discount | 30.8 s | 8.0 s | 3.8 s |
| Contradiction: launch moved from Monday 3 November to Friday the 7th | 48.9 s | 10.1 s | 4.1 s |
| Contradiction: free tier from three projects to one | 65.7 s | 8.0 s | 2.6 s |
| Commitment: "Marco" reviews the onboarding emails before Wednesday | 83.8 s | 6.6 s | 3.2 s |
| Decision: 20% off annual plans | 92.7 s | 7.5 s | 3.1 s |

## Transcription

- **Arrival.** Each turn's final text arrived 0.2–1.1 s after its last word (median 0.9 s), measured against the voiced timings.
- **Accuracy.** The text matched the script except for names and one stutter. Marko came back as "Marco" and Ana as "Anna", even with the names sent as `keywords` in a separate probe. "decide" was doubled once. "Hm," was dropped, and that turn split into two.
- **Speakers.** Each line takes its speaker from its track, so the split turn and the misspelt names didn't change who owned anything.

## Cost and speed

- **Passes.** 14 passes, a median 2.16 s each (max 3.08 s), $0.025 in all, about $0.81 per meeting hour at this pace of turns.
- **Audio.** Muse Voice Transcribe is $0.18 per audio hour per track, $0.36 per meeting hour for two tracks.

## Limits

One synthetic meeting, two synthetic voices, clean audio with no crosstalk or echo, and one run. Real calls bring overlap, echo on the microphone track, and accents. The run sent only synthetic speech and text to Meta.
