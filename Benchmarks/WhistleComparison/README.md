# Whistle versus LokalBot's speech engines

Headless, local comparison of Cactus Whistle, Parakeet Ultra 0.6B (FluidAudio),
and Qwen3-ASR 1.7B (speech-swift/MLX). See the [measured report](results/2026-10-09/REPORT.md).
This benchmark does not launch LokalBot, modify its settings, use its meeting
library, or run UI tests. Model inference is blocked from all network access.

## Scope and sample

The sample is selected before candidate inference, using public or synthetic audio:

- 24 existing AMI IHM test utterances, with human transcripts, selected in the
  earlier ModelAlternatives benchmark. These are headset utterances from meetings,
  not a full mixed-channel meeting or a diarization test.
- The first eligible FLEURS **test** archive entries at the pinned revision:
  20 English and eight each of German, French, Polish, and Serbian. Eligibility
  is duration from 3 to 25 seconds; archive order is fixed. Serbian is an explicit
  unsupported-language probe for Whistle, excluded from supported-language aggregates.
- Six English FLEURS clips with deterministic white noise at 10 dB whole-clip SNR.
  These measure that artificial degradation, not general real-world noise robustness.
- The existing continuous-speech regression fixture; three synthetic name/terminology
  sentences with and without vocabulary hints; six silence/tone/noise controls;
  and two attenuated versions of one English clip.
- A separate 55.28-second stream concatenates six English clips with 0.5-second
  gaps. Audio is supplied one second at a time, as fast as computation permits.
  Commit delay is measured in supplied audio time, not wall-clock microphone latency.

There are 97 batch conditions (some reuse the same audio), 839.06 seconds total.
Repeated inference does not create additional independent accuracy samples.

## What the timings measure

All engines receive the same mono 16 kHz float PCM. File reading is outside the
timer. The timer covers the complete speech-engine call, rather than first-token
latency. A five-second speech warm-up precedes three measured passes; the middle
pass reverses clip order. Tables use the median time for each clip and then
aggregate those medians. Model loading and warm-up are recorded separately.

These are **engine-only** measurements, not the complete LokalBot pipeline.
Production VAD, track language voting/re-decoding, speaker attribution, Qwen's
extra forced aligner, paste delivery, and other app work are excluded. Qwen uses
the app's token-cap formula and the current decoder defaults on each whole clip;
production can split or merge clips differently. Language is automatic throughout.
Only the three explicitly hinted name conditions supply vocabulary. Parakeet
does not accept that vocabulary, so its hinted condition is an unchanged repeat.

Whistle uses the publisher's native C API with word timestamps on and default
decoding. Parakeet returns native token timings. Qwen returns text without a
separate aligner. Timestamp checks verify valid ranges/order, not acoustic accuracy.
The native Whistle state is process-global and not thread-safe; each engine runs
in its own serial process.

English WER uses the same Whisper English normalizer and spelling map as the
earlier CloudSTT benchmark. Written clock times are joined before normalization
so `3:30` matches spoken `three thirty`. Other languages use Whisper's basic
normalizer without removing diacritics. Serbian Cyrillic is transliterated to
Latin before scoring. The first pass supplies accuracy; all passes supply timing.
Paired 2,000-sample bootstrap intervals resample clips and are exploratory: clips
sharing speakers/references are correlated. Silence is scored by invented words.

`time -l` maximum RSS is process memory; it does not capture every allocation
owned by Core ML/ANE services or the GPU. Qwen also reports MLX peak allocation.
The models' download sizes must not be read as runtime RAM requirements. The Mac
was in normal use, with other builds/model processes; repeated timings are not
idle-machine or battery measurements.

## Reproduce

Keep downloaded models, audio, transcripts, and logs in a separate output directory.
The 9 October run used `/private/tmp/lokalbot-whistle-eval-20261009` (temporary).
From this directory, with `OUT` set to an absolute output directory:

```sh
uv venv --python 3.12 "$OUT/venv"
uv pip install --python "$OUT/venv/bin/python" -r results/2026-10-09/requirements.freeze.txt
"$OUT/venv/bin/python" download.py "$OUT"
"$OUT/venv/bin/python" prepare.py "$OUT"
"$OUT/venv/bin/python" baselines.py "$OUT"
```

`baselines.py` copies the locally cached baseline weights with APFS cloning and
verifies the 18 Parakeet files against the app catalog and the six Qwen files
against their cached revision/ETag metadata. It accepts explicit source-directory
arguments. It does not download missing baseline models or write into app caches.

```sh
clang++ -O3 -std=c++17 -I "$OUT/models/needle3/macos-arm64" whistle_runner.cpp \
  "$OUT/models/needle3/macos-arm64/libneedle.a" -o "$OUT/whistle-runner"
(cd harness && xcodebuild -scheme WhistleBaselines -destination 'platform=macOS,arch=arm64' \
  -configuration Release -derivedDataPath "$OUT/dd" -clonedSourcePackagesDirPath "$OUT/spm" \
  -skipPackagePluginValidation -skipMacroValidation build)
"$OUT/venv/bin/python" run.py "$OUT"
"$OUT/venv/bin/python" score.py "$OUT" "$OUT/summary.json"
```

Run outside a parent sandbox that forbids applying a child sandbox. `run.py`
applies `(version 1) (allow default) (deny network*)`, sets telemetry/offline
environment variables, records competing process load, and refuses to overwrite
existing results unless `--replace` is explicit. Downloads and builds happen
before inference. The recorded run additionally verified outbound socket denial
with an `EPERM` assertion before executing any candidate.

Source pins and file hashes are in [provenance.json](results/2026-10-09/provenance.json).
The Swift package resolution and Python freeze are included for reproducibility.
Only aggregate results and fixture identifiers/hashes belong in this checkout.
