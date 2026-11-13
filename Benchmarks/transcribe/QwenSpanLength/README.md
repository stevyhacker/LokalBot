# Qwen3-ASR span length on LokalBot's own runtime

This benchmark asks whether the length of the audio windows LokalBot hands to Qwen3-ASR changes accuracy, and where the gap between the app's saved transcripts and the [CloudSTT](../CloudSTT/README.md) benchmark comes from. It holds the model, weights and runtime fixed and varies only how audio is cut into decode windows, the language hint, speech-swift's long-input repetition blocking, and the token cap.

`harness/` is a headless Swift executable that replicates `QwenASREngine`'s span path with the app's exact package pins: speech-swift 0.0.26, FluidAudio 0.17.1 and mlx-swift 0.31.4. It loads `aufklarer/Qwen3-ASR-1.7B-MLX-8bit` and the Silero VAD v6.2.1 Core ML model the app uses, and it never launches the app. `SpeechActivity.split`, `samplesForInference`, the token formula, span sample slicing and `Transcript.normalizedText` are copied from the app.

## Data

The harness reuses the CloudSTT benchmark's prepared chunks, so every condition hears the same 16 kHz audio that the vendors and mlx-audio heard:

- **AMI:** 16 Mix-Headset windows (27.4 minutes) with the IHM human reference.
- **LokalBot meetings:** 106 mic/system chunks from three meetings (99 scored), compared with CloudSTT's leave-family-out consensus of the OpenAI, Google and NVIDIA systems. This measures agreement, not accuracy.

`make_jobs.py` attaches two explicit layouts. For meetings, `app` holds production's own decode windows, which are the saved transcript's segment bounds, assigned by track and midpoint and clipped to the chunk. For AMI, `oracle` holds the regions `AttributedTrackTranscriber.regions` would build from the reference speaker turns.

## Running

```sh
export STT_BENCH_DATA=/private/tmp/lokalbot-cloud-stt   # CloudSTT's prepared data (read only)
export SPAN_BENCH_OUT=$STT_BENCH_DATA/span-length       # private jobs, transcripts, model clone
export CLOUDSTT_DIR=../CloudSTT                         # CloudSTT scripts (score.py, common.py)

# Clone, don't reference, the app's weights (APFS clone, no extra space).
mkdir -p $SPAN_BENCH_OUT/models/aufklarer
cp -c -R ~/Library/Application\ Support/me.dotenv.LokalBot/qwen3-asr-models/models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit \
  $SPAN_BENCH_OUT/models/aufklarer/

# MLX needs Xcode's Metal build, so use xcodebuild rather than `swift build`.
(cd harness && xcodebuild -scheme QwenSpanHarness -destination 'platform=macOS,arch=arm64' -configuration Release \
  -derivedDataPath $SPAN_BENCH_OUT/dd -clonedSourcePackagesDirPath $SPAN_BENCH_OUT/spm \
  -skipPackagePluginValidation -skipMacroValidation build)

uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python numpy rapidfuzz "transformers<5" requests
.venv/bin/python make_jobs.py                 # all conditions; pass condition names to select some
$SPAN_BENCH_OUT/dd/Build/Products/Release/qwen-span-harness $SPAN_BENCH_OUT/jobs.json   # resumable
.venv/bin/python score_spans.py --results results/2026-09-30
```

### Speaker-region variants

The harness's `diarize` mode runs `NeuralDiarizationEngine`'s Nemotron 3 path (offline preset, activity threshold 0.5, minimum 0.2 s) on the full recordings. `make_region_jobs.py` builds `AttributedTrackTranscriber` regions and variants on each recording's timeline, then clips them to the chunks. `score_regions.py` adds cpWER on AMI.

```sh
export NEMOTRON_MODEL_DIR=$SPAN_BENCH_OUT/nemotron
cp -c -R ~/Library/Application\ Support/me.dotenv.LokalBot/Models/NemotronDiarization/53445f72d5735e33406ccce7b92116bce7ab1ab7 \
  $NEMOTRON_MODEL_DIR
.venv/bin/python make_region_jobs.py diarize-job
$SPAN_BENCH_OUT/dd/Build/Products/Release/qwen-span-harness diarize $SPAN_BENCH_OUT/diarize.json
.venv/bin/python make_region_jobs.py         # needs jobs.json from make_jobs.py
$SPAN_BENCH_OUT/dd/Build/Products/Release/qwen-span-harness $SPAN_BENCH_OUT/region_jobs.json
uv pip install --python .venv/bin/python scipy
.venv/bin/python score_regions.py --results results/2026-09-30
```

### Transcribe first, attribute after

The harness's `align` mode times the words of an existing condition's windows with speech-swift's Qwen3 forced aligner. speech-swift 0.0.26's own downloader refuses `merges.txt`, so fetch the pinned files first; the app does the same through `PinnedModelSnapshot.qwenAligner`. `score_align.py` compares word-level attribution with production's regions and reports speaker-memory support.

```sh
export ALIGNER_MODEL_DIR=$SPAN_BENCH_OUT/aligner/models/aufklarer/Qwen3-ForcedAligner-0.6B-4bit
mkdir -p $ALIGNER_MODEL_DIR
for f in config.json merges.txt model.safetensors quantize_config.json tokenizer_config.json vocab.json; do
  curl -fL -o $ALIGNER_MODEL_DIR/$f \
    https://huggingface.co/aufklarer/Qwen3-ForcedAligner-0.6B-4bit/resolve/f0e9f12a0ddbcb5f1e1b7f0339090628f1cede1d/$f
done
.venv/bin/python make_region_jobs.py align-job
$SPAN_BENCH_OUT/dd/Build/Products/Release/qwen-span-harness align $SPAN_BENCH_OUT/align.json
.venv/bin/python score_align.py --results results/2026-09-30
```

The hill-climb aligns more conditions, and the 8-bit aligner, the same way, then compares them with `score_hill.py`. `merge-60-off-v14` is the layout the app ships:

```sh
.venv/bin/python make_region_jobs.py align-job merge-15 merge-30-off merge-60-off merge-60-off-v14 whole-en-off
for f in $SPAN_BENCH_OUT/align-4bit-*.json; do $SPAN_BENCH_OUT/dd/Build/Products/Release/qwen-span-harness align $f; done
# 8-bit aligner: fetch revision 0457b7f546f629bacd1671d57252f1c561347bcb of aufklarer/Qwen3-ForcedAligner-0.6B-8bit as above
ALIGNER_VARIANT=8bit ALIGNER_MODEL_DIR=$SPAN_BENCH_OUT/aligner8/models/aufklarer/Qwen3-ForcedAligner-0.6B-8bit \
  .venv/bin/python make_region_jobs.py align-job engine-15
$SPAN_BENCH_OUT/dd/Build/Products/Release/qwen-span-harness align $SPAN_BENCH_OUT/align-8bit-engine-15.json
.venv/bin/python score_hill.py --results results/2026-09-30
```

The 0.6B (compact) tier repeats the region baseline and the window candidates with its own weights. Clone the app's copy of `aufklarer/Qwen3-ASR-0.6B-MLX-4bit` the same way as the 1.7B model, or use the pinned Hugging Face snapshot:

```sh
export QWEN06_MODEL_DIR=$SPAN_BENCH_OUT/qwen06/models/aufklarer/Qwen3-ASR-0.6B-MLX-4bit
.venv/bin/python make_region_jobs.py compact-job      # needs region_jobs.json
$SPAN_BENCH_OUT/dd/Build/Products/Release/qwen-span-harness $SPAN_BENCH_OUT/compact_jobs.json
RUNS_FILE=runs-06b.jsonl ALIGNED_PREFIX=aligned06 .venv/bin/python make_region_jobs.py align-job \
  engine-15 merge-15-v14 merge-30-off-v14 merge-60-off-v14 merge-60-v14
for f in $SPAN_BENCH_OUT/align-aligned06-*.json; do $SPAN_BENCH_OUT/dd/Build/Products/Release/qwen-span-harness align $f; done
.venv/bin/python score_compact.py --results results/2026-09-30
```

### Language auto-detection

`fetch_fleurs.py` streams about 30 FLEURS dev utterances per language (CC-BY-4.0) and joins them into 5–7 minute tracks. The tracks are German, Japanese, Russian and Serbian, plus a code-switched English/German track. `nlid.swift` wraps Apple's `NLLanguageRecognizer`, so the scorer identifies languages exactly as the app does.

```sh
.venv/bin/python fetch_fleurs.py
.venv/bin/python make_language_jobs.py          # needs jobs.json and compact_jobs.json
for j in language_english language_fleurs language_english_06b language_fleurs_06b; do
  $SPAN_BENCH_OUT/dd/Build/Products/Release/qwen-span-harness $SPAN_BENCH_OUT/$j.json
done
swiftc -O nlid.swift -o $SPAN_BENCH_OUT/nlid
.venv/bin/python score_language.py --results results/2026-09-30
```

### Voice-activity gate

`make_noise.py` cuts the gaps between benchmark chunks out of the owner's meeting tracks, up to 10 minutes per track, read-only through `lokalbot-cli path`. The benchmark's VAD judged that audio speech-free, so every word decoded there is a false alarm. The harness layout keys `vadThreshold` and `padding` set FluidAudio's Silero entry threshold (default 0.85) and region padding (default 0.1 s).

```sh
.venv/bin/python make_noise.py
.venv/bin/python make_vad_jobs.py
for j in vad_noise vad_noise_06b vad_english vad_english_06b; do
  $SPAN_BENCH_OUT/dd/Build/Products/Release/qwen-span-harness $SPAN_BENCH_OUT/$j.json
done
.venv/bin/python score_vad.py --results results/2026-09-30
```

`make_jobs.py` and `make_region_jobs.py` read meeting transcripts and audio through `lokalbot-cli path`, which is read-only. Nothing is sent over the network. Transcripts stay in `SPAN_BENCH_OUT`; `results/` holds only aggregates.
