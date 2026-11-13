# Qwen3-ASR span length and the app's transcription gap — 30 September 2026

`QwenASREngine.maxSegmentSeconds = 15.0` does not hurt accuracy, because it never takes effect: FluidAudio's voice-activity detection already ends every speech region at about 13.5 s, and production decode windows are much shorter still (median 1.3 s, longest 11 s). The app's saved transcripts disagree with the multi-vendor consensus more than the benchmark's mlx-audio run (7.9% versus 4.2%). About 2.8 points of that gap come from how the app cuts each track into speaker regions before transcription, and about 1 point from the engine's short (≤14 s) windows. The runtime and the weights repository contribute nothing measurable. Longer windows help only when speech-swift's automatic repetition blocking is switched off. The token-cap formula never truncated anything. A follow-up with the app's own diarizer confirmed the speaker-region cost: 3.0 points on meetings and 8.1 on AMI. Most of it traces to pauses inside one person's speech, each of which starts a new region. Transcribing the whole track first and then assigning forced-aligned words to speakers removes that cost without hurting attribution. Because words are re-timed afterwards, the decode windows can also grow to 60 s with repetition blocking off. Together, for diarized Qwen3-ASR 1.7B tracks:
- meeting disagreement fell from 8.30% to 4.41%;
- AMI WER fell from 26.49% to 17.69%;
- AMI cpWER fell from 36.52% to 33.90%;
- more diarizer turns stay usable for speaker memory.

The same change helps Qwen3-ASR 0.6B even more, with merged ≤15 s windows. Meeting disagreement fell from 10.02% to 6.77%, AMI WER from 30.49% to 21.40%, and AMI cpWER from 40.18% to 36.56%. LokalBot now uses this path for both Qwen3-ASR tiers.

**Setup.** Every condition used the app's runtime and weights: speech-swift 0.0.26, FluidAudio 0.17.1, mlx-swift 0.31.4 and `aufklarer/Qwen3-ASR-1.7B-MLX-8bit`, run headless by `../../harness` on an Apple M4 Max. The audio was the CloudSTT benchmark's own chunks from 30 September:

- **AMI:** 16 Mix-Headset windows (27.4 minutes, 4,201 normalized reference words), scored against the human reference.
- **Meetings:** the owner's three meetings, 99 chunks and 69.9 minutes, scored against the same leave-family-out consensus (OpenAI, Google and NVIDIA voters) that the CloudSTT report used for the local Qwen run and the app transcript. This measures agreement, not accuracy.

The scorer reproduces the CloudSTT report exactly: 17.64% AMI WER for mlx-audio, 4.20% meeting disagreement for mlx-audio and 7.91% for the saved app transcript. Intervals are 95% paired chunk-bootstrap intervals of the difference from today's engine path (`engine-15`).

## The 15 s constant is inert

`QwenASREngine` asks `SpeechActivity` for spans and splits any span longer than 15 s. `SpeechActivity` gets its regions from `VadManager.segmentSpeech` with FluidAudio's default `VadSegmentationConfig`, whose `maxSpeechDuration` is 14 s. After subtracting one 256 ms VAD frame and padding, regions end at about 13.5 s, so the 15 s split never runs. When a region reaches that limit without a pause, FluidAudio cuts at the current frame, which can fall mid-word.

Production windows are shorter again. All three meetings used the speaker-region path. Their 1,827 saved segments have per-meeting medians of 0.9–1.4 s and a maximum of 11 s, and 41–58% last under a second. The app's log records `language=en` for all five tracks, and echo cancellation was disabled, so the app transcribed the same raw microphone audio the benchmark used.

## Where the gap comes from

| Decode windows (same runtime and weights unless noted) | Meetings disagreement | Meetings substitutions | AMI WER |
|---|---:|---:|---:|
| Saved app transcript (full pipeline) | 7.91% | 3.56% | — |
| Production's own windows, re-decoded (median 1.3 s) | 8.09% | 3.74% | — |
| AMI reference speaker turns → app region path | — | — | 23.92% |
| Engine path on the whole chunk, no speaker regions (≤14 s windows) | 5.30% | 2.40% | 18.38% |
| VAD regions merged across ≤5 s pauses into ≤60 s, repetition blocking off | 4.33% | 1.90% | 17.64% |
| Whole chunk, `English`, repetition blocking off, 8,192 tokens | 4.27% | 1.77% | 17.47% |
| mlx-audio with `mlx-community/Qwen3-ASR-1.7B-8bit` (CloudSTT run) | 4.20% | 1.82% | 17.64% |

- **Runtime and weights: about zero.** On identical chunks, speech-swift with the aufklarer weights scored 4.27% on meetings and 17.47% on AMI, against mlx-audio's 4.20% and 17.64%. Both repositories quantize the same 197 decoder matrices to 8-bit affine with group size 64 and keep the audio encoder in floating point.
- **Post-processing, vocabulary prompt and midpoint mapping: about 0.2 points.** Re-decoding production's own windows gave 8.09%, against 7.91% for the saved transcript.
- **Speaker regions: about 2.8 points** (8.09% versus 5.30%, interval +2.06 to +3.66). Substitutions rose from 2.40% to 3.74% and insertions from 1.56% to 2.89%. On AMI, building regions from the reference speaker turns raised WER by 5.55 points (+4.27 to +6.68), mostly through deletions (17.7% versus 13.8%). `AttributedTrackTranscriber` cuts each track at every speaker turn, unlabeled gap and overlap, plus a fixed cut every 30 s. It then writes each region to its own file, and the engine runs VAD on it again from a cold state. [Speaker regions with the app's diarizer](#speaker-regions-with-the-apps-diarizer) repeats this with real diarizer turns and tests fixes.
- **Short engine windows: about 1 point** (5.30% versus 4.23–4.33% for long windows with repetition blocking off).

## Longer windows need repetition blocking off

speech-swift 0.0.26 automatically sets `noRepeatNgramSize = 3` for any input longer than 15 s (`Qwen3DecodingOptions.longInputThresholdSeconds`). The block is token-level and covers the whole generated sequence, so ordinary repeated phrases in a long window are forced into substitutions. The app's legacy `transcribe(audio:sampleRate:language:maxTokens:context:)` call gets this behaviour by default.

| Windows | Meetings | Δ (95% CI) | AMI | Δ (95% CI) |
|---|---:|---:|---:|---:|
| Today: VAD ≤14 s, split 15 s (`engine-15`) | 5.30% | — | 18.38% | — |
| VAD cap and split raised to 30 s | 5.29% | −0.01 (−0.35…+0.32) | 19.09% | +0.71 (−0.27…+1.92) |
| … to 60 s | 5.27% | −0.03 (−0.44…+0.37) | 19.07% | +0.69 (−0.41…+1.90) |
| … to 120 s | 5.32% | +0.02 (−0.37…+0.41) | 19.02% | +0.64 (−0.44…+1.85) |
| Merged across ≤5 s pauses, ≤15 s | 4.94% | −0.36 (−0.60…−0.11) | 18.07% | −0.31 (−0.79…+0.14) |
| Merged, ≤30 s, runtime default | 5.00% | −0.30 (−0.77…+0.12) | 19.83% | +1.45 (+0.32…+2.64) |
| Merged, ≤60 s, runtime default | 5.05% | −0.25 (−0.67…+0.15) | 18.90% | +0.52 (−0.55…+1.82) |
| Merged, ≤120 s, runtime default | 5.34% | +0.04 (−0.40…+0.53) | 18.88% | +0.50 (−0.57…+1.59) |
| Merged, ≤30 s, blocking off | 4.59% | −0.71 (−1.10…−0.35) | 17.83% | −0.55 (−1.38…+0.12) |
| Merged, ≤60 s, blocking off | **4.33%** | −0.97 (−1.35…−0.59) | **17.64%** | −0.74 (−1.47…−0.05) |
| Merged, ≤120 s, blocking off | 4.36% | −0.94 (−1.37…−0.53) | 17.78% | −0.60 (−1.47…+0.44) |
| Whole chunk, runtime default | 5.32% | +0.02 (−0.51…+0.56) | 18.47% | +0.10 (−0.96…+1.15) |
| Whole chunk, blocking off | 4.23% | −1.07 (−1.49…−0.68) | 17.73% | −0.64 (−1.33…+0.03) |

Raising the VAD cap and the split together, which is the literal "raise `maxSegmentSeconds`" change, did nothing on meetings. It trended worse on AMI because VAD still ends regions at 0.75 s pauses (median windows 6–8 s), and the few windows over 15 s get repetition blocking. Merging regions across pauses gives the model real context, but only helps once blocking is off. With blocking off, 60 s and 120 s windows performed about the same as a whole chunk. Merging to ≤15 s stays under the blocking threshold and gave a small gain without any decoder change. It was clear of zero on meetings but not on AMI.

Longer windows did not slow decoding: merged ≤60 s windows ran at 47–51× real time, today's path at 44–48×, and production's short windows at 31×.

## Token cap

No window reached `min(768, max(128, seconds × 18))` in any of the 20 conditions. The highest use was 56% of the cap, on ≤120 s windows. Rerunning merged ≤120 s windows with a 4,096-token cap produced identical WER on both sets. mlx-audio's uncapped CloudSTT outputs peak at 4.1 tokens per second of chunk. At that rate the 768 ceiling binds only beyond about 188 s, and the 18 tokens/s slope leaves about 4× headroom. The formula needs no change for windows up to 120 s.

## Language hint

The app passes the language code verbatim, so Qwen is prompted with `language en` rather than the model's `language English`. On today's path, `English` made no measurable difference: 5.38% versus 5.30% on meetings (−0.07 to +0.25) and 18.35% versus 18.38% on AMI. Auto-detect was worse on meetings: 5.93%, with 73 words in inserted runs against 22, and one window ran to the token cap. On AMI it was slightly better (18.11%), within the interval. Merged ≤120 s windows with `English` scored 4.48% on meetings against 4.36% with `en`. That run was stopped before its AMI half finished.

## Speaker regions with the app's diarizer

This follow-up reran the owner's current settings without the app: Nemotron 3 diarization, multi-speaker diarization on and echo cancellation off. The harness's `diarize` mode applied `NeuralDiarizationEngine`'s Nemotron 3 path (offline preset, activity threshold 0.5, minimum 0.2 s) to the full recordings, which were the four AMI Mix-Headset files and the meeting tracks. The `AttributedTrackTranscriber` regions and each variant were built on every recording's full timeline, clipped to the benchmark chunks, and then transcribed by the engine path with `language en`.

AMI also gets cpWER (concatenated minimum-permutation WER). Each speaker's words are joined in time order, and each hypothesis stream is matched one-to-one to a reference speaker so that total errors are minimal. Words that land in an unlabeled or overlap region form their own stream, so cpWER counts attribution errors as well as recognition errors. Speakers are matched separately in each AMI window.

| Layout | Meetings | Δ vs production (95% CI) | AMI WER | Δ vs production (95% CI) | AMI cpWER | Δ cpWER (95% CI) | Windows (meetings) |
|---|---:|---:|---:|---:|---:|---:|---:|
| Production regions (`diar-prod`) | 8.30% | — | 26.49% | — | 36.52% | — | 1,684, median 1.3 s |
| Production regions, VAD once per recording (`diar-trackvad`) | 25.43% | +17.13 (+16.17…+18.25) | 35.99% | +9.50 (+7.31…+12.64) | 48.58% | +12.07 (+10.23…+14.66) | 3,552, median 0.5 s |
| No speaker regions (`engine-15`) | 5.30% | −3.01 (−3.85…−2.29) | 18.38% | −8.12 (−10.25…−6.40) | — | — | 553, median 7.1 s |
| AMI reference-turn regions | — | — | 23.92% | −2.57 (−4.28…−1.18) | 39.44% | +2.93 (+0.36…+5.29) | — |

- **The replica matches production.** Regions rebuilt from fresh Nemotron turns scored 8.30% on meetings. Production's own saved windows scored 8.09% and the saved transcript 7.91%, and the window counts and lengths match (1,684 versus 1,653, median 1.3 s, longest 11 s).
- **With the real diarizer, regions cost 3.0 points on meetings and 8.1 on AMI.** That is more than the 5.5-point AMI estimate from reference turns. In the AMI windows, substitutions rose from 4.02% to 7.09% and deletions from 13.76% to 17.50%.
- **Unlabeled gaps split one person's speech.** Nemotron reports a pause inside one speaker's speech as a gap between two turns. `regions()` makes that gap its own unlabeled region, so the same speaker's speech on either side lands in separate regions. The meeting chunks have 3,263 regions, and 1,644 of them are unlabeled gaps covering 26% of the time. The AMI windows have 1,493 regions, 553 of them gaps covering 37% of the time. Folding gaps of 2 s or less into their neighbours reduces the chunks' 4,756 regions to 1,317.
- **Running VAD once per recording is much worse.** In theory it avoids restarting VAD at every region edge. In practice, clipping whole-recording VAD windows to every region cut the speech into slivers with a median of 0.5 s. On meetings it put 2,063 windows and 2,069 words into unlabeled gaps. Production's per-region VAD found speech in only 201 of those gaps (210 words). Most of the extra words were invented, and insertions rose to 20% on meetings. The per-region VAD protects production from this.
- **The fixed 30 s region cut is irrelevant here.** Removing it changes only 2 of the 4,756 regions in the chunks.
- **Reference-turn regions look worse on cpWER despite lower WER.** AMI's reference utterances overlap for long stretches, so more speech lands in "unclear" regions, which cpWER counts as unattributed.

Four region variants were built but not scored, because the run was stopped after the first two:
- no 30 s cut (64 of 122 chunks finished);
- short unlabeled gaps folded into neighbouring regions;
- that fold together with no 30 s cut and one VAD pass per recording;
- the same combination with ≤60 s windows and repetition blocking off.

## Transcribe first, attribute after

This approach keeps the engine path's text, which is transcribed with no speaker regions (`engine-15`), and assigns speakers afterwards. speech-swift's Qwen3 forced aligner (`aufklarer/Qwen3-ForcedAligner-0.6B-4bit`, pinned at `f0e9f12a`) times the words of each engine window. Each word then takes the Nemotron speaker active at its midpoint. Overlapping turns make the word unclear, and a word outside every turn takes the nearest turn within a tolerance, or the track label beyond it.

| Attribution | AMI cpWER | Δ vs production regions (95% CI) |
|---|---:|---:|
| Production regions (`diar-prod`) | 36.52% | — |
| Engine windows, each given to its majority speaker (no aligner) | 40.73% | +4.21 (+0.66…+7.51) |
| Aligned words, strict midpoint (no tolerance) | 51.11% | +14.59 (+11.83…+18.47) |
| Aligned words, 0.5 s tolerance | 34.90% | −1.62 (−3.45…−0.06) |
| **Aligned words, 1 s tolerance** | **34.54%** | −1.98 (−3.96…−0.36) |
| Aligned words, 2 s tolerance | 34.56% | −1.95 (−3.90…−0.33) |

- **Text is unchanged by alignment.** The aligned words score exactly the engine path's 18.38% AMI WER, against 26.49% for production regions. On meetings the text is the engine path's 5.30%, against 8.30% for production regions.
- **Attribution improves slightly, with a tolerance.** Nemotron leaves short gaps between turns and the aligner's word edges don't line up with them, so a strict midpoint rule leaves many words unattributed. Any tolerance from 0.5 s up recovers them. The app uses 1 s.
- **The aligner is needed.** Giving each whole engine window to its majority speaker loses 4.2 points of cpWER, because speaker changes fall inside windows.
- **Speaker memory keeps more turns if pieces snap to turns.** `AttributedTrackTranscriber.turns()` and `samples()` accept a diarizer turn only when a single diarized label covers at least 95% of it. Word pieces are narrower than regions, so on their own they support fewer turns. They split at speaker changes, at pauses of 0.75 s or more between words, and at 15 s. Widening each speaker's piece to the edges of that speaker's turns, never across a neighbouring piece, fixes that. The table uses ≤14 s windows; the shipped ≤60 s windows are in the hill-climb below:

| Turns accepted for speaker memory | AMI | Meetings |
|---|---:|---:|
| Production regions | 286 of 417 | 1,319 of 1,501 |
| Aligned words | 212 of 417 | 862 of 1,501 |
| Aligned words, snapped to turns | 371 of 417 | 1,418 of 1,501 |

- **The aligner is cheap.** It timed all 101 minutes of chunks in 34 s, 179× real time. The model is a 983 MB download, and the app keeps it loaded only while aligning, like the ASR models.

## Hill-climb on the word-attribution path

With speakers assigned from aligned words, decode windows no longer set segment boundaries, so the window layout and the aligner could be tuned freely. Every candidate below keeps the same attribution rules and is compared with the first version by paired chunk bootstrap. The first version used ≤14 s windows with the 4-bit aligner.

| Candidate | Meetings | Δ (95% CI) | AMI WER | Δ (95% CI) | AMI cpWER | Δ (95% CI) | Speaker memory, AMI and meetings |
|---|---:|---:|---:|---:|---:|---:|---:|
| ≤14 s windows, 4-bit aligner (first version) | 5.30% | — | 18.38% | — | 34.54% | — | 371/417, 1,418/1,501 |
| ≤14 s windows, 8-bit aligner | 5.30% | 0.00 | 18.38% | 0.00 | 34.52% | −0.02 (−0.48…+0.50) | 372/417, 1,416/1,501 |
| Merged ≤15 s | 4.94% | −0.36 (−0.60…−0.11) | 18.07% | −0.31 (−0.79…+0.14) | 34.59% | +0.05 (−1.05…+1.12) | 358/417, 1,400/1,501 |
| Merged ≤30 s, blocking off | 4.59% | −0.71 (−1.10…−0.35) | 17.83% | −0.55 (−1.38…+0.12) | 33.49% | −1.05 (−2.15…+0.32) | 360/417, 1,418/1,501 |
| Merged ≤60 s, blocking off | 4.33% | −0.97 (−1.35…−0.59) | 17.64% | −0.74 (−1.47…−0.05) | 33.80% | −0.74 (−1.76…+0.36) | 369/417, 1,413/1,501 |
| **Merged ≤60 s from the 14 s VAD regions, blocking off (shipped)** | **4.41%** | −0.89 (−1.26…−0.51) | **17.69%** | −0.69 (−1.54…+0.16) | **33.90%** | −0.64 (−1.86…+0.57) | 364/417, 1,405/1,501 |
| Whole chunk, blocking off | 4.23% | −1.07 (−1.49…−0.68) | 17.73% | −0.64 (−1.33…+0.03) | 35.04% | +0.50 (−0.67…+2.12) | 354/417, 1,410/1,501 |

- **The 8-bit aligner adds nothing** over the 4-bit one, so the smaller model stays.
- **Longer windows help, but only with repetition blocking off.** Merged ≤60 s windows gave the best balance: the clearest meeting gain, and AMI WER and cpWER both lower, though their intervals include zero. Whole chunks were best on meetings, but their cpWER was higher.
- **The shipped variant is the one the app can build today.** It merges the app's existing ≤14 s VAD regions instead of re-running VAD with a 60 s cap, so `SpeechActivity`'s segment cache and the other engines are untouched. It scores within a tenth of a point of the 60 s VAD variant.
- **Segments keep their size.** With pause and 15 s splits on the aligned words, merged windows produce segments with a median of 2.6 s, a 95th percentile of 14.8 s and a maximum of 16 s. The first version produced 2.2 s, 12.2 s and 14 s. Speaker memory dips about 1–2% from the first version but stays well above production regions (286/417, 1,319/1,501).
- **Only diarized or trimmed Qwen3-ASR 1.7B tracks use long windows.** Tracks without speaker separation or a content range keep the ≤15 s path, whose segment boundaries come straight from the decode windows.

## Qwen3-ASR 0.6B

The compact tier (`aufklarer/Qwen3-ASR-0.6B-MLX-4bit`, the app's pinned revision) ran through the same steps. The baseline is what diarized 0.6B tracks got before this change: production regions from the same Nemotron turns. Two extra columns track degeneration, because speech-swift added its long-input repetition blocking for 0.6B:
- words in invented runs of four or more, across both sets;
- windows whose output reached the token cap.

| Candidate | Meetings | Δ vs regions (95% CI) | AMI WER | Δ (95% CI) | AMI cpWER | Δ (95% CI) | Speaker memory, AMI and meetings | Invented-run words | Cap hits | ASR speed |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Production regions (before) | 10.02% | — | 30.49% | — | 40.18% | — | 286/417, 1,320/1,501 | 120 | 0 | 27× |
| Words, ≤14 s windows | 7.21% | −2.82 (−3.67…−2.04) | 21.45% | −9.05 (−13.07…−6.06) | 36.28% | −3.90 (−7.33…−1.22) | 372/417, 1,440/1,501 | 39 | 0 | 112× |
| **Words, merged ≤15 s (shipped)** | **6.77%** | −3.26 (−4.16…−2.45) | **21.40%** | −9.09 (−13.10…−6.16) | **36.56%** | −3.62 (−7.15…−1.01) | 360/417, 1,422/1,501 | 33 | 0 | 116× |
| Words, merged ≤30 s, blocking off | 6.45% | −3.57 (−4.67…−2.62) | 20.73% | −9.76 (−13.43…−6.50) | 35.28% | −4.90 (−7.92…−2.03) | 355/417, 1,407/1,501 | 30 | 0 | 11× |
| Words, merged ≤60 s, blocking off | 6.37% | −3.65 (−4.73…−2.71) | 20.73% | −9.76 (−13.61…−6.71) | 36.35% | −3.83 (−7.44…−0.88) | 344/417, 1,413/1,501 | 34 | 0 | 22× |
| Words, merged ≤60 s, blocking on | 7.81% | −2.21 (−3.46…−1.01) | 21.71% | −8.78 (−12.59…−5.67) | 36.97% | −3.21 (−6.40…−0.63) | 343/417, 1,409/1,501 | 59 | 0 | 35× |
| 1.7B shipped (reference) | 4.41% | −5.61 (−6.98…−4.45) | 17.69% | −12.81 (−16.66…−9.54) | 33.90% | −6.28 (−10.15…−2.89) | 364/417, 1,405/1,501 | 27 | 0 | 48× |

- **Speaker regions hurt 0.6B more than 1.7B.** Moving from regions to word attribution cut meeting disagreement by 2.8 points and AMI WER by 9.0 points, even at the same ≤14 s windows. The regions also produced more invented runs (120 words, against 39).
- **Merged ≤15 s windows are the right size for 0.6B.** They add another 0.4 points on meetings, and the merge stays under speech-swift's 15 s threshold, so decoding is unchanged. They are also 4× faster than regions, because fewer, longer windows replace many sub-second ones.
- **Longer windows cost too much time for 0.6B.** With blocking off, 30 s and 60 s windows gained only 0.3–0.4 points more on meetings, while decoding at 11× and 22× real time instead of 116×. Neither reached the token cap, so the slowdown is not runaway looping. With blocking on, 60 s windows were worse than ≤15 s.
- **The 0.6B still trails 1.7B by about 2.4 points on meetings and 3.7 on AMI** after the change.
- **The aligner (about 1 GB) is larger than the 0.6B model it accompanies (0.7 GB).** Compact-tier users with speaker separation now download both. The accuracy gain is large enough to justify this, but it changes the tier's size story.

## End to end in the app

The three owner meetings were also processed by the app itself, built from this branch (commit `26b13d2`). The run used the `LokalBot Dev` identity, Debug configuration, with `LokalBot --process <meeting> --no-summary`. It was isolated from the installed app:
- a scratch library (`LOKALBOT_STORAGE_ROOT`) holding copies of each meeting's `meta.json` and audio;
- a disposable settings suite with `transcriptionLanguage = en`, where every other default already matches the owner's settings (Nemotron 3, speaker separation on, voice memory off, echo cancellation off);
- models cloned into the Dev identity's own Application Support.

All six tracks decoded merged windows and assigned aligned words; the aligner never fell back to regions. The new `transcript.json` files were scored against the same consensus as the saved production transcripts:

| Saved production transcript vs new app transcript | Saved | New |
|---|---:|---:|
| Disagreement, each track's chunks joined | 7.89% | **4.59%** |
| Substitutions / deletions / insertions | 3.55% / 1.51% / 2.83% | 2.01% / 1.11% / 1.46% |
| Words in invented runs | 56 | 29 |
| Disagreement, per chunk by segment midpoint | 7.91% | 6.66% |
| Segments (three meetings) | 1,827 | 766 |
| Median segment, 57-minute meeting | 1.4 s | 4.0 s |

- **The app reproduces the harness result.** Each of the five scored tracks improved:
  - 63e27646 system: 14.4% to 7.7%;
  - 84fd7a3e mic: 8.9% to 4.6%;
  - 84fd7a3e system: 5.4% to 3.1%;
  - the two short mic tracks also improved.
- **Per-chunk midpoint scoring understates the gain.** Longer segments straddle the benchmark's cuts inside continuous speech, so that scoring counts words both as inserted in one chunk and dropped from its neighbour. Joining each track's chunks removes this artifact.
- **Speaker groupings stay consistent.** After the best one-to-one mapping of labels, the new speakers agree with the saved transcripts on 94% of overlapping time: 93–96% on system tracks and 88% on microphone tracks. Label numbers themselves differ between the two runs.
- **Segments are fewer and longer.** The longest was 23.5 s, where snapping widened a 15 s piece to its speaker's turn.
- **Timings come from a Debug build**: 90 s for the 16-minute meeting and 329 s for the 57-minute one, including diarization and alignment. They are not production timings.

## Language auto-detection

New installs default to automatic language detection; the owner's settings use `en`. With auto, Qwen detects the language again in every decode window. Two data sets were used:
- **English:** the benchmark's meetings and AMI chunks. The app decides per track, so track-level strategies are emulated from the auto and pinned-English runs. A window re-decoded pinned to English is exactly the pinned run's window, because decoding is greedy.
- **FLEURS:** 5–7 minute tracks built from FLEURS dev utterances in German, Japanese, Russian and Serbian, plus a code-switched English/German track. These are real runs.

| English meetings, word-attribution path | Meetings | Δ vs auto (95% CI) | AMI WER | Invented-run words | Windows re-decoded |
|---|---:|---:|---:|---:|---:|
| 1.7B auto | 5.01% | — | 17.69% | 79 | 0 |
| 1.7B auto, wrong-script windows re-decoded | 4.91% | −0.10 (−0.19…−0.04) | 17.69% | 79 | 23 |
| **1.7B vote and pin (shipped)** | **4.41%** | −0.60 (−2.01…+0.08) | 17.69% | 27 | 187 |
| 1.7B pinned `en` | 4.41% | −0.60 (−2.01…+0.08) | 17.69% | 27 | — |
| 0.6B auto | 7.58% | — | 21.35% | 104 | 0 |
| 0.6B vote and pin (shipped) | 7.51% | −0.07 (−0.26…+0.09) | 21.40% | 108 | 558 |
| 0.6B pinned `en` | 6.77% | −0.81 (−2.59…+0.07) | 21.40% | 33 | — |

| FLEURS, 1.7B, merged ≤60 s | German | Japanese (CER) | Russian | Serbian | English + German |
|---|---:|---:|---:|---:|---:|
| Pinned to the true language | 4.4% | 7.1% | 10.2% | 14.1% | — |
| Auto | 4.4% | 6.8% | 10.2% | 17.1% | 14.9% |
| Detect once (longest windows) | 4.4% | 7.1% | 10.2% | 17.1% | **19.3%** (pinned German) |
| **Vote and pin (shipped)** | 4.4% (de) | 7.1% (ja) | 10.2% (ru) | 17.1% (auto) | 14.9% (auto) |

- **Auto misfires on real meetings.** On English meetings, auto put 23 windows on the shipped path, and 62 on the plain ≤14 s path, in the wrong script. Examples from the two layouts include Chinese for a laugh, Hindi for "Um, society", and a 2-second English clip that became a German "Ja, ja, ja…" loop. Accented English sometimes came out as Polish or Portuguese.
- **Fixing only the misfired windows is not enough.** Re-decoding wrong-script or minority-language windows recovers at most 0.15 points. Pinning the whole track recovers 0.6, because pinning also improves windows that auto already put in English.
- **Detecting once from the longest windows is unsafe.** On the code-switched track those windows happened to be German, so the whole track was pinned to German (19.3% against 14.9%). On short benchmark chunks the probe itself misfired.
- **Apple's recognizer judges long text by its opening.** One Polish-looking first window made a whole English track read as Polish at 0.9995. This had also broken the word-attribution path in auto mode: an unsupported "detected" language sent the track back to speaker regions. Both uses now vote per segment by text length.
- **The shipped rule is vote and pin.** Decode with auto and vote the language over segments of three or more words. When one Qwen-supported language holds at least 80% of the text, decode the track again pinned to it.
  - On English, 1.7B then matches pinned `en` exactly.
  - Single-language FLEURS tracks match the true language within noise.
  - The code-switched track (German 59–66% by text length) stays on auto, as does Serbian, which the recognizer reads as Croatian, a language Qwen does not support.
  - Tracks on auto decode twice.
- **0.6B gains little from vote and pin.** Its accented-English meeting track votes 78% English and 22% Portuguese, so it stays on auto. Setting the language explicitly remains best: 6.77% against 7.58%.
- **An explicit `sr` helps Serbian** even though Qwen does not list it: 14.1% against 17.1% on 1.7B, and 44.3% against 54.2% on 0.6B.

The English meeting gains have intervals that include zero, because a handful of misfired chunks drive them. The invented-run and wrong-script counts show the same effect more directly. FLEURS is read speech, and the code-switched track is synthetic.

## Voice-activity gate

FluidAudio's Silero gate decides what audio is decoded at all. It uses an entry threshold of 0.85, 256 ms frames and 0.1 s of padding. The sweep measured recall on the benchmark sets and false alarms on 32 minutes of speech-free audio from the owner's meeting tracks: the gaps between benchmark chunks, which the benchmark's more sensitive VAD found silent.

| 1.7B word-attribution path | Meetings | AMI WER | Δ AMI (95% CI) | AMI deletions | Invented words per 10 min of silence |
|---|---:|---:|---:|---:|---:|
| **Threshold 0.85, padding 0.1 s (shipped)** | 4.41% | 17.69% | — | 13.43% | 10 |
| 0.7 | 4.41% | 17.57% | −0.12 (−0.29…0.00) | 13.38% | 18 |
| 0.5 | 4.39% | 17.42% | −0.26 (−0.59…−0.02) | 13.19% | 30 |
| 0.35 | 4.31% | 17.31% | −0.38 (−0.89…+0.08) | 12.81% | 30 |
| 0.85, padding 0.3 s | 4.28% | 17.54% | −0.14 (−0.82…+0.30) | 13.14% | 12 |
| No gate (whole chunk) | 4.23% | 17.73% | +0.05 (−0.73…+0.81) | 12.95% | — |

- **The gate is not the bottleneck.** On the shipped path, the decode windows already hold 99% of the meeting chunks' audio and 86% of AMI's. Even removing the gate entirely gains only 0.18 points on meetings and nothing on AMI. Most of AMI's 13% deletions are overlapping speakers on one mixed channel.
- **Lowering the threshold trades little recall for more invented text.**
  - At 0.5, AMI improves by 0.26 points, and false alarms in silence triple, from 10 to 30 words per 10 minutes. They are mostly "Oh. Okay. Hmm." fillers, plus the odd invented sentence.
  - On the plain ≤14 s path, 0.5 is not better (5.34% vs 5.30%, 18.50% vs 18.38%).
  - On 0.6B, 0.5 trades an uncertain AMI gain (−0.64, interval crosses zero) for five times the false alarms: 66 against 12 words per 10 minutes.
- **Wider padding is the only balanced lever, and it is unproven.** 0.3 s of padding lowers every error rate slightly and cuts invented-run words from 27 to 18, for 1.6 more false-alarm words per 10 minutes. No interval excludes zero, though. FluidAudio's Debug builds also assert that padding stays within the minimum speech duration (0.15 s), so shipping it would mean raising that as well, and that change was not tested.

No gate setting changed. The benchmark's meeting chunks were pre-cut by a VAD, so speech that every gate misses cannot show up here. The noise set is also the owner's room and system audio only.

## Recommendations

1. **Leave `maxSegmentSeconds` as it is.** It is inert. Raising it together with the VAD cap gave no gain and moves windows into speech-swift's repetition-blocking range.
2. **Transcribe first, then attribute (implemented for Qwen3-ASR 1.7B).** Speaker regions were the largest measured cost: 3.0 points on meetings and 8.1 on AMI with the app's diarizer. Assigning aligned words afterwards removes that cost and improves cpWER (see the section above). Running VAD once per recording is not a fix, and removing the 30 s cut does nothing. Two routes were considered:
   - **Fold short unlabeled gaps (not taken).** In `AttributedTrackTranscriber.regions`, each unlabeled gap of about 2 s or less would go to its neighbours. That keeps audio partitioned by speaker before ASR and cuts the chunks' regions from 4,756 to 1,317, but it was never scored. It remains the fallback idea for engines that keep the region path.
   - **Transcribe first, then attribute (taken).** Transcribe each track with the engine path alone, as `engine-15` does, then assign aligned words to speakers as described above. Text accuracy matches the engine path by construction, and longer windows (recommendation 3) become an independent gain.

     It needs an extra aligner model of about 1 GB, and for Qwen3-ASR 1.7B it replaces the rule of partitioning audio by speaker before ASR. The alignment is acoustic rather than proportional, so the rule that text is never divided proportionally still holds. Other engines and languages the aligner does not support (anything outside zh, en, yue, fr, de, it, ja, ko, pt, ru and es) keep the region path. Qwen3-ASR 0.6B uses word attribution with ≤15 s windows (see its section). The app also falls back to regions if the aligner cannot be downloaded.
3. **Long windows (implemented for the word-attribution path).** Merge VAD regions across ≤5 s pauses into ≤60 s windows, and call `transcribe(audio:sampleRate:options:)` with `Qwen3DecodingOptions(longInputThresholdSeconds: .infinity)`. The app now does this for diarized or trimmed Qwen3-ASR 1.7B tracks (see the hill-climb above). Extending it to the plain path would need:
   - key `SpeechActivity`'s one-entry segment cache by VAD configuration as well as file;
   - rerun on Qwen3-ASR 0.6B 4-bit, the model speech-swift's blocking was written for;
   - accept that segments get up to 60 s long, which coarsens timestamps.

   The plain path would also need its own segment re-split, because it has no word timings. Merging to ≤15 s is the step there that needs no decoder change.
4. **Keep the token formula.**
5. **Keep passing an explicit language.** Switching `en` to `English` showed no gain, and auto-detect was worse on meetings.
6. **Ask for the meeting language rather than defaulting to auto.** Vote and pin now closes the auto gap for 1.7B on single-language tracks, at the cost of a second decode. It cannot help 0.6B tracks where misfires exceed 20%, or mixed-language meetings. An explicit language in onboarding would give most users the pinned result without the extra pass.

## Limits

Meeting scores measure agreement with other vendors, not accuracy: a system that alone gets a hard word right is penalized. AMI covers only 27 minutes, so its intervals are about ±1 point. The AMI speaker-region condition uses reference turns, which are not what the app's diarizer produces. Each condition was run once with greedy decoding. Only Qwen3-ASR 1.7B was tested, on three English meetings from one owner. Diarization ran on the Mix-Headset mix, which is harder than the app's separate microphone and system tracks. cpWER is scored only on AMI, because the meetings have no speaker reference. Four speaker-region variants were built but not scored. Word attribution and the hill-climbs used English text only; the aligner's other ten languages were not measured. The hill-climb picked among seven candidates on the same data, so its gains are slightly optimistic. The meeting gain's interval is far from zero; the AMI gains are not.

## Reproduction and privacy

`../../README.md` describes the harness and commands. `summary.json` (span sweep), `regions-summary.json` (speaker regions), `align-summary.json` (word attribution), `hill-summary.json` (1.7B hill-climb), `compact-summary.json` (0.6B), `language-summary.json` (language handling) and `vad-summary.json` (VAD gate) hold aggregates only. Transcripts stay in the private `SPAN_BENCH_OUT` folder. This run sent no audio or text over the network. The meeting consensus reuses the CloudSTT outputs saved on 30 September. Meeting transcripts were read through `lokalbot-cli path`, which is read-only. The source baseline is `13e01c0`.
