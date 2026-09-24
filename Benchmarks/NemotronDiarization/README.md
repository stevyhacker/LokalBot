# Nemotron 3 diarization evaluation

This harness compares the final Nemotron 3 CoreML checkpoint with LokalBot's pre-integration FluidAudio 0.15.8 diarization pipeline on an Apple Silicon Mac. It creates independent Swift executables and does not change the application or its dependency pins. The app integration pins FluidAudio 0.17.1, whose commit matches the evaluated Nemotron runtime.

Read the [completed evaluation](results/2026-09-23/REPORT.md).

## Reproduce

Requires macOS, Xcode/Swift 6.2+, Git, and uv. Models, audio, builds, and the Python environment live under `/private/tmp/lokalbot-nemotron-bench` (roughly a few GB). The first two commands download public source, model weights, and AMI audio.

From the repository root:

```sh
export UV_CACHE_DIR=/private/tmp/nemotron-uv
uv run --no-project python Benchmarks/NemotronDiarization/setup.py
uv run --no-project python Benchmarks/NemotronDiarization/prepare.py
uv venv /private/tmp/lokalbot-nemotron-bench/scoring-env
uv pip install --python /private/tmp/lokalbot-nemotron-bench/scoring-env/bin/python -r Benchmarks/NemotronDiarization/requirements-scoring.txt
uv run --no-project python Benchmarks/NemotronDiarization/run.py
uv run --no-project python Benchmarks/NemotronDiarization/run.py --repeats baseline offline fast128 c128-split-w8a8
MPLCONFIGDIR=/private/tmp/lokalbot-nemotron-bench/mpl /private/tmp/lokalbot-nemotron-bench/scoring-env/bin/python Benchmarks/NemotronDiarization/score.py
uv run --no-project python Benchmarks/NemotronDiarization/collect.py
```

The binary path in `run.py` matches Swift 6.4's Swift Build output on this machine. Older SwiftPM backends may require changing it to their release binary location. Run inference jobs sequentially; score after inference when collecting timings. Run zero in the repeats manifest is warm-up; runs one through three provide the warm median. No UI tests are involved.

## Fixed protocol

- Four independent AMI test meetings, chosen before inference: EN2002a, ES2004a, IS1009a, TS3003a. Evaluate both Mix-Headset (MHM) and Array1-01 (SDM). These are eight recording conditions, not eight independent conversations.
- Full recordings, mono 16 kHz. No truncation, VAD gating, known speaker-count hint, threshold search, or manual correction.
- Forced-alignment RTTMs from pinned `nttcslab-sp/diar-forced-alignment`. Score the whole audio duration, including silence. Match anonymous speaker labels with pyannote.metrics' optimal global mapping.
- Report pooled DER with overlap included at zero collar and 250 ms collar. The pooled score sums error seconds and reference speaker seconds; it is not an arithmetic mean of file percentages.
- Baseline reproduces `NeuralDiarizationEngine.configuration`: clustering 0.70, Fa 0.07, embedding minimum 0.3 s, segment gap 0.05 s, segmentation step ratio 0.15; other library defaults remain, including exclusive output. Voice-sample export is off.
- `baseline-overlap` changes only exclusive output to false. `community-overlap` uses the pinned library's community defaults (threshold 0.6, embedding minimum 1 s, gap 0.1 s, step ratio 0.2) with exclusive output false. These controls are evaluated separately, without changing LokalBot.
- Nemotron uses shipped `offline`, `fast128`, `c128-split-w8a8`, and `low` presets; activity threshold 0.5 and default minimum output duration 0.2 s. The split model allows CPU/Neural Engine; other presets use CoreML `.all`.
- `low` receives 100 ms pieces through the actual streaming API, followed by a final flush. This is accelerated file replay through the streaming frontend, not real-time microphone capture. Calls producing a model chunk are timed individually.
- Processing time includes file decoding, features, inference, and segment postprocessing, but excludes model loading and JSON serialization. The baseline reads audio through its normal file API; Nemotron decodes the complete file before replay/inference. RSS is process peak RSS, including harness buffers; it does not measure all out-of-process GPU/ANE memory or power consumption.

`prepare.py` pins model revisions and writes SHA-256 download provenance. `setup.py` pins source and annotation revisions. The final report and saved evidence are under `results/2026-09-23/`.

Aggregate results and provenance are checked in. `collect.py` additionally saves raw predictions, timing repeats, and reference RTTMs when reproducing locally; these larger generated files are omitted from the integration PR.

## App adapter and voice compatibility

After the preparation above, export the old runtime's vectors for one public recording:

```sh
uv run --no-project python - <<'PY'
import json, pathlib
root = pathlib.Path('/private/tmp/lokalbot-nemotron-bench')
rows = [r for r in json.loads((root/'manifest.json').read_text()) if r['id'] == 'ES2004a_mhm']
(root/'voices-manifest.json').write_text(json.dumps(rows))
PY
/private/tmp/lokalbot-nemotron-bench/build-baseline/out/Products/Release/DiarBench \
  /private/tmp/lokalbot-nemotron-bench/voices-manifest.json \
  /private/tmp/lokalbot-nemotron-bench/models/baseline baseline \
  /private/tmp/lokalbot-nemotron-bench/voices-baseline voices
TEST_RUNNER_NEMOTRON_BENCH_ROOT=/private/tmp/lokalbot-nemotron-bench \
  Scripts/unit-tests.sh NemotronRuntimeTests
```

This optional non-UI test checks app-adapter output against the original Nemotron predictions, resets between repeated tracks, and compares all exported Pyannote vector components to the 0.15.8 baseline. Without the explicit fixture path it skips without downloading models or reading private recordings. It is separate from the original timing runs.
