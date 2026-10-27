# Whisper candidates on existing LokalBot recordings — 8 October 2026

Keep the current Whisper turbo. This quick screen does not justify adding full
large-v3 to the picker yet. TheStage turbo is faster and worth further integration
work, but the tested free Apple path has text-stitching and timestamp problems
that need resolving before adoption.

## Measured result

Eight excerpts from two existing LokalBot meetings: four BCMS and four English,
split equally between microphone and system audio. They total **112.08 seconds**
of decoded audio. Models ran serially on an **Apple M4 Max, 48 GB, macOS 27.0.1**.
Times below use automatic language detection and exclude loading and warm-up.

| Model and runtime | Decode time | Speed relative to realtime | Process peak RSS |
|---|---:|---:|---:|
| Current Whisper large-v3 turbo, WhisperKit 1.1.0 | **11.45 s** | **9.79×** | 1.33 GB |
| Full Whisper large-v3, WhisperKit 1.1.0 | 45.55 s | 2.46× | 1.89 GB |
| TheStage turbo S/10-second, Core ML + MLX, word timestamps | **6.48 s** | **17.30×** | 1.65 GB |

Full large-v3 took **3.98× as long** as the current turbo. TheStage took **43% less
decode time** (1.77× the throughput), but missing text in two excerpts means this
is not yet a clean speed/quality win. RSS is process memory, not total ANE/GPU or
system memory. Loading was observed at 12.7 s, 20.5 s and 54.4 s respectively;
different cache histories mean these are not controlled cold-start comparisons.

The full Argmax model download is 3.09 GB, versus the current turbo's roughly
1.62 GB. TheStage's selected compressed Apple assets total 0.712 GB before
unpacking; this is not its installed footprint.

## What the quality check establishes

The old benchmark's temporary reference transcripts were no longer present.
The real-meeting comparisons therefore use the saved **Qwen3-ASR-generated**
transcripts. These numbers measure word disagreement, **not true word error or
accuracy**. They cannot prove that the saved transcript is correct.

| Condition | Current turbo | Full large-v3 | TheStage turbo |
|---|---:|---:|---:|
| English, auto — disagreement, 137 reference words | 11.7% | 9.5% | 39.4% |
| BCMS, auto — disagreement, 155 reference words | 61.9% | 52.3% | 56.8% |
| BCMS, explicit Bosnian hint — disagreement, same words | 48.4% | 50.3% | 54.2% |
| Existing synthetic control — actual script WER, 59 words | **0%** | **0%** | **0%** |

The 17.71-second synthetic control was additional to the eight meeting excerpts.
All final configurations reproduced its normalized script exactly. This is a
small English sanity check, not evidence of broad quality parity.

Full large-v3 avoided a language-selection/translation failure seen in turbo on
one mixed-language clip. However, the Bosnian-hint condition removed its aggregate
agreement advantage, and the four English clips gained only three word edits
against the saved ASR text. That is insufficient evidence for the fourfold
decode cost and larger download.

## TheStage integration findings

The final comparison uses the documented `return_timestamps="word"` call. On two
English excerpts, switching from segment mode to word mode shortened normalized
outputs from **23 to 14 words** and **40 to 15 words**. Internal phrases present in
its own segment-mode output, the saved transcript, and both WhisperKit outputs
disappeared. This is a concrete consistency problem even without human references.
See [the mode comparison](timestamp-mode-check.json).

Word mode returned word timings, but every final clip had a last word with no end
timestamp. Consumers need explicit handling; range checks alone do not establish
word-alignment accuracy. WhisperKit also produced a small number of overlong
segment endpoints, recorded in the aggregates.

An initial boolean segment-timestamp run returned missing endpoints and corrupted
the synthetic control with repeated characters. A focused word-mode probe fixed
that control failure, so the full sample was rerun in word mode. The results above
come from that final rerun, not the failed initial call pattern.

The publisher's Python loader requires a serialized pickle model skeleton.
Automatic approval review rejected executing it. The successful evaluation
instead constructed the skeleton from JSON on PyTorch's meta device and installed
the publisher's unchanged Core ML encoder and safetensors MLX decoder. No pickle
was deserialized. This adaptation is a limitation: these findings apply to the
tested free implementation, not a verdict on the raw weights or commercial SDK.

TheStage's **non-turbo** repository at
`b585e07e1299f7f6017e529b75726a0c8599323b` had no Apple/Core ML assets in its file
listing. Its supplied Apple loader expects `free/macos_15_ios_18/...`. It was not
run; the full-model result above is **OpenAI/Argmax large-v3**, not TheStage large-v3.

## Validation and limits

- The release harness used the app's exact WhisperKit 1.1.0 source revision.
  All 20 current turbo model files matched the app catalog's pinned digests.
- All three final runs completed 13 conditions: nine auto clips, including the
  control, and four additional BCMS clips with `bs`. Shared clips are counted
  once in the throughput table.
- Selection happened before candidate inference. All models read identical PCM
  files. Private audio, references, decoded text, and logs stayed outside the
  repository; inference had outbound networking blocked by a macOS sandbox.
- No cloud reference request, app-setting change, library write, UI test,
  installation, or release was performed.
- This is one small pass with short speech-rich excerpts, no human meeting
  references, no thermal controls or repetitions, and no long-meeting coverage.
  It does not establish a general accuracy ranking or power-efficiency gain.

The next useful check is a small human-verified meeting set and investigation of
TheStage's word-timestamp stitching. A larger model picker or production runtime
switch should wait for that evidence.

[Aggregates](summary.json) · [Revisions and environment](provenance.json) ·
[Python dependency snapshot](requirements.freeze.txt) · [Reproduction](../../README.md)
