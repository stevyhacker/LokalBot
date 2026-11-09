# Muse Voice Transcribe versus LokalBot diarization — 27 October 2026

**Recommendation: keep Nemotron 3 for speaker labels, both after meetings (`offline`) and live (`low`).** On the eight AMI recording conditions of the [Nemotron study](../../../NemotronDiarization/results/2026-09-23/REPORT.md), Muse Voice Transcribe's realtime diarization had **60.36%** DER as delivered, against **16.48%** for the local Nemotron streaming preset. Even with every system cut to the reference's speech, it gave **5.33%** of speaker time to the wrong person, against 3.47% and 1.77%. Where it stands out is speed: each turn's final text and speaker label arrived together **0.74 s** (median) after the turn ended. Its word accuracy was not measured here. The app was not changed.

## Measured quality

Four independent English AMI test meetings, each as headset mix (MHM) and distant microphone (SDM): **8 conditions, 184.55 minutes of audio**, every reference with four speakers. The audio is byte-identical to the Nemotron study's, checked by SHA-256, and scored against its checked-in references with its settings: pyannote.metrics, overlap scored, whole recording, optimal label mapping, pooled by reference speaker time. The local rows are the study's checked-in predictions re-scored by this harness; the full view reproduces the study's published totals exactly.

Muse ran through `wss://api.meta.ai/v1/asr/realtime` in `DIARIZATION` mode with `PCM_16KHZ` audio and an English language hint, streamed in 100 ms frames on a real-time schedule as from a live microphone, all eight sessions at once. The API reports turns, not word timings; each turn gets the label of its speaker event.

DER adds missed speech, false alarms and speaker confusion, divided by reference speaker time. Components below are percentage points of reference speaker time at zero collar.

### As delivered

| System | DER, zero collar ↓ | DER, 250 ms collar ↓ | Missed | False alarm | Confusion | Correct speaker count |
|---|---:|---:|---:|---:|---:|---:|
| Muse Voice Transcribe 1.0, realtime (cloud) | 60.36% | 53.13% | 16.40 | 38.63 | 5.33 | 5/8 |
| Nemotron 3 `low`, streaming API (local) | 16.48% | 10.45% | 8.81 | 4.19 | 3.47 | 8/8 |
| Nemotron 3 `offline` (local, LokalBot default) | 14.56% | 8.34% | 8.40 | 4.38 | 1.77 | 8/8 |
| LokalBot before Nemotron (FluidAudio 0.15.8) | 43.44% | 30.45% | 15.34 | 19.23 | 8.87 | 5/8 |

Most of Muse's error is false alarm. Its turns are endpointing turns that keep pauses inside them: median **3.0 s**, 95th percentile **16.3 s**, longest **85.9 s**. In TS3003a's headset mix, its 174 turns covered 1,282 of 1,506 seconds while the reference has 682 seconds of speech, which put that recording at 98.29%.

### Cut to reference speech

Every system's output is first intersected with the reference's speech regions. This is not a deployable setup; it removes speech-detection errors to show labelling. The local systems keep a small false alarm because they sometimes add a second simultaneous speaker where the reference has one.

| System | DER, zero collar ↓ | DER, 250 ms collar ↓ | Missed | False alarm | Confusion |
|---|---:|---:|---:|---:|---:|
| Muse Voice Transcribe 1.0, realtime (cloud) | 21.73% | 13.60% | 16.40 | 0.00 | 5.33 |
| Nemotron 3 `low`, streaming API (local) | 13.86% | 9.04% | 8.81 | 1.57 | 3.47 |
| Nemotron 3 `offline` (local, LokalBot default) | 11.78% | 6.83% | 8.40 | 1.60 | 1.77 |
| LokalBot before Nemotron (FluidAudio 0.15.8) | 24.21% | 16.00% | 15.34 | 0.00 | 8.87 |

Overlapping talk is **12.92%** of reference speaker time in these recordings. A system that names one speaker at a time, as Muse does, cannot cover it, so 12.92 points is a floor for its missed speech; Muse's 16.40 is 3.48 points above it. The Nemotron presets output overlap and miss less. Muse's confusion sits between the old pipeline and Nemotron.

Muse found the right number of speakers in five of eight recordings. It reported six speakers in ES2004a's distant-microphone recording and five in both TS3003a conditions. Ten of 2,014 turns arrived without a speaker event and count as speech with an unmatched label.

## Live latency

| Event after the end of a turn | Median | 95th percentile | Max | Turns |
|---|---:|---:|---:|---:|
| Final turn text (`speechComplete`) | 0.74 s | 0.83 s | 1.75 s | 2,014 |
| Speaker label | 0.74 s | 0.83 s | 1.75 s | 2,004 |

The delay runs from the moment the client sent the audio at the turn's `speechEnd` position to the event's arrival, so it includes network time from a home connection in Montenegro. The label and the final text arrived in the same burst. The Nemotron study did not measure end-to-end delay this way; its `low` preset has a configured audio-buffer latency of 1.04 s before compute, ASR and delivery.

## Per-recording zero-collar DER

| Recording | Muse as delivered | Muse, reference speech | Nemotron `low`, reference speech | Nemotron `offline`, reference speech |
|---|---:|---:|---:|---:|
| EN2002a_mhm | 52.86% | 25.93% | 13.03% | 11.94% |
| EN2002a_sdm | 53.46% | 28.18% | 14.74% | 13.65% |
| ES2004a_mhm | 53.39% | 15.27% | 7.68% | 7.42% |
| ES2004a_sdm | 55.57% | 21.80% | 26.13% | 14.69% |
| IS1009a_mhm | 50.10% | 18.89% | 16.07% | 16.85% |
| IS1009a_sdm | 48.82% | 20.70% | 10.49% | 9.55% |
| TS3003a_mhm | 98.29% | 9.61% | 7.16% | 7.20% |
| TS3003a_sdm | 92.23% | 14.83% | 15.28% | 9.84% |

On reference speech, Muse was better than the streaming Nemotron preset on ES2004a's and TS3003a's distant-microphone recordings and worse on the other six.

## About Meta's figure

Launch coverage cites a Meta-reported 17.5% average DER across AMI-IHM, AMI-SDM and VoxConverse. This protocol does not reproduce it: 60.36% as delivered, 21.73% on reference speech at zero collar, and 13.60% on reference speech with a 250 ms collar. The sources found do not state Meta's collar, overlap handling, speech-activity source, test subset or endpoint, so the gap does not show that the figure is wrong. It shows that the realtime endpoint's turns, scored this way, are not comparable to it.

## LokalBot implications

1. **Speaker labels stay local.** Nemotron is more accurate on this set, outputs overlap, keeps the audio on the Mac, and costs nothing per hour.
2. **Live meeting work can keep audio local.** Speaker-attributed live text can come from Nemotron `low` and the app's own ASR, and only text needs to reach a remote model, behind the existing remote-origin approval.
3. **Muse's case rests on its text.** Final text in 0.74 s is fast enough for live prompts, but its word error rate is untested. The [CloudSTT](../../../CloudSTT/README.md) AMI set can measure it against the APIs and local engines already scored there before any adoption.

## Run record

The eight scored sessions all ended with a server close, code 1000, "No more transcript segments". A first attempt at EN2002a_sdm lost its connection 2,065 s into 2,143 s (code 1006, no close frame) and was rerun in full; only the complete rerun is scored. Streamed audio, including that attempt and a one-minute smoke test, came to about 220 minutes, roughly $0.66 at $0.18 per hour, paid from hackathon credits. Under those credits Meta may use the submitted content for product improvement; only public AMI audio was sent.

Software: Python 3.13.13, websockets 15.0.1, pyannote.metrics 4.0.0, macOS 27.0.1 on an Apple M4 Max. Model `muse-voice-transcribe-1.0`, run on 27 October 2026. The service is versionless from the client's side, so a later run may differ.

## Evidence

[Harness and protocol](../../README.md), [scores, latency and session record](scores.json), [Muse segments](predictions/muse-voice-transcribe/), [manifest](manifest.json). Raw events, including transcripts, stay outside the repository; `run.py` and `score.py` regenerate them and these files.
