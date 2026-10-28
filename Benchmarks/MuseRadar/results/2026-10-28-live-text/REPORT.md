# Fast live text and screen answers on voiced meetings — 28 October 2026

**Result:** with fast live text, Live Radar showed each planted item a median **8.0 s** after the sentence began, about **3 s after the speaker finished**. With the local preview's 12-second chunks and 20-second passes, the text replays of this meeting showed items 15–25 s after they were said, and the AMI replays a median 23 s ([AMI evaluation](../2026-10-27/REPORT.md)). It caught all six planted items from the audio, including both contradictions with the earlier meeting, and rejected nothing.

**Screen answers:** on the demo call, a question asked out loud was answered from a synthetic capture of a metrics dashboard 2.6 s after the radar caught it, with the quote checked against the capture's own text. The radar also caught the launch-date check as a question, and screen answers answered it from a synthetic launch plan: "No, Monday November 3".

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

## Screen answers on the demo call

- **Run.** `--radar-replay fixtures/synthetic-demo-call.json --audio <voiced folder> --screens fixtures/screens`: the demo video's call, voiced the same way (87 s per track, [line timings](voiced-demo-call-lines.json)), with two synthetic captures standing in for screen memory: a Safari metrics dashboard and a Notion launch plan, both from the week before ([output](synthetic-demo-call-audio-screens.jsonl)).
- **Radar.** All six planted items again (two commitments, two contradictions, the decision, and the open question), a median 7.0 s after each sentence began, none rejected. It also caught "Is the launch now Friday the 7th?" as a question.
- **Answers.**

  | Question | Answer | Quote, found in the crop's text | Crop | Request | Shown after the question began |
  |---|---|---|---:|---:|---:|
  | What was trial-to-paid conversion last month? | 4.1% (Safari) | "Trial to paid, September 4.1%" | 0.26 s | 2.3 s | 10.6 s |
  | Is the launch now Friday the 7th? | No, Monday November 3 (Notion) | "Launch Monday, November 3" | 0.17 s | 4.2 s | 14.6 s |

  Each request sent one crop: a full-width band around the matching rows, not the whole capture. They cost $0.006 together.
- **Cold start.** An earlier run the same morning took 28.7 s for the first answer: the first use of Vision's accurate text recognizer on this Mac took 26 s to load, and later uses took 0.07–0.15 s, in a fresh process too. That run's quote was only "4.1%"; the prompt now asks for the whole line, label and value. Start Radar now warms the recognizer up in the background when screen answers are on.

## Limits

Two synthetic meetings, two synthetic voices, clean audio with no crosstalk or echo, one run each with the current code, and two synthetic captures in place of a real screen history, where many more captures would match a question's words. Real calls bring overlap, echo on the microphone track, and accents. The runs sent only synthetic speech, text, and images to Meta.
