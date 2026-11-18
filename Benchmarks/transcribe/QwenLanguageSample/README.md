# Qwen3-ASR language sampling

With the transcription language on auto, the default, `QwenASREngine` used to decode every window of a track twice. It decoded them all on auto, voted the track's language over their text, and when one language held at least 80% of it (the Serbian/Croatian/Bosnian/Montenegrin aliases vote as Croatian), decoded them all again pinned to that language. [QwenLlamaCpp](../QwenLlamaCpp/README.md) measured that vote-and-pin at 20.5× real time against 40.0× with the language given.

The engine now decodes a sample of windows on auto first, spread across the track, and votes on those (`QwenASREngine.decodeOnAuto`). When the sample's vote holds, the whole track decodes once, pinned, and the sampled windows decode again with the rest. When it does not, the rest decodes on auto and the whole track votes, exactly as before. This benchmark measures what that costs in accuracy and saves in time against the old path, and picks the sample's size and share. [results/2026-11-18/REPORT.md](results/2026-11-18/REPORT.md) has the findings.

## How it runs

The benchmark runs the app's own code. `LokalBotTests/Engines/QwenLanguageSampleReplayTests.swift` is an opt-in unit test: it starts Qwen3-ASR 1.7B's llama-server the way the app does (`QwenLlamaASR.accuracy.makeServer`, the pinned Q8_0 GGUF pair, the app's flags), cuts each track into windows with the app's VAD (`SpeechActivity`, then `QwenASREngine.merged` for the word-attribution layout), and decodes them with `QwenASREngine.transcribeWindow`. Two modes run on the same windows and server:

- **before** replays the old auto path line for line: every window on auto, `QwenASREngine.pinnedLanguage`, then every window again in the voted language, unless the forced aligner cannot time it.
- **after** calls `QwenASREngine.decodeOnAuto`, the new path.

Two layouts cover the engine's two entry points: `word`, the merged windows of up to 30 s that meeting tracks with speaker separation use (`transcribeForWordAttribution`), and `plain`, the VAD spans of up to 15 s of `transcribe`. When a word-layout track settles on a language the aligner cannot time (Croatian), both modes stop and the app attributes the track by speaker regions decoded in that language. That region pass is the same in both modes, so it is not run here; such rows compare decode time and the decision only.

Each track, layout and mode appends a JSON line to `runs.jsonl` with every window decode (text, language, seconds, and the window's own language vote) and the result. Decoding is greedy, so a window decoded in the same language gives the same text in both modes, and accuracy does not depend on when a run happened. `simulate.py` uses that to replay any sample size and share from the `before` runs alone. Wall time does depend on it: with other work on the machine, identical decodes ran 35% slower a few minutes apart. `score.py` therefore compares time only within paired runs (`--alternate`), where both paths decode each track back to back and take turns going first.

## Data

`fetch_tracks.py` builds, under `QLS_OUT` (default `/private/tmp/lokalbot-qwen-sample`):

- **FLEURS (CC-BY-4.0):** one-language tracks of 40 dev utterances (6–9 minutes each) in English, German, French, Spanish, Japanese, Chinese, Russian, Serbian, Croatian and Bosnian, with their human references.
- **Code-switched FLEURS tracks**, 40 utterances each: English then German for the last 30% or 15% of utterances, English then Serbian for the last 20%, Serbian then English for the last 30% or 15%, English and German alternating every five utterances, and four Serbian utterances to one English throughout.
- **AMI (CC-BY-4.0):** the whole ES2004a and TS3003a Mix-Headset recordings (17.5 and 25.1 minutes) with every speaker's IHM test transcript as the reference.

`make_manifest.py --meetings <id> …` adds the owner's own meeting tracks, read in place from the LokalBot library through `lokalbot-cli path` (read only). They have no reference, so they are compared on decisions, identical output and time. Nothing leaves the Mac: the only requests go to the local llama-server. Audio, transcripts and runs stay in `QLS_OUT`; `results/` holds aggregates only, and meetings appear there by letter.

## Running

```sh
export QLS_OUT=/private/tmp/lokalbot-qwen-sample
uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python numpy requests duckdb rapidfuzz "transformers<5"
.venv/bin/python fetch_tracks.py
mkdir -p $QLS_OUT/llama-models
for f in Qwen3-ASR-1.7B-Q8_0.gguf mmproj-Qwen3-ASR-1.7B-Q8_0.gguf; do
  curl -fL -o $QLS_OUT/llama-models/$f \
    https://huggingface.co/ggml-org/Qwen3-ASR-1.7B-GGUF/resolve/36a678687ba7d07a74ca70ccb0e36902e005fb80/$f
done
shasum -a 256 $QLS_OUT/llama-models/*.gguf   # compare with QwenLlamaASR.accuracy

# The old path first, in short batches with a minute's pause between them; runs resume.
.venv/bin/python make_manifest.py --modes before --layouts word plain --sets fleurs && ./run_replay.sh
.venv/bin/python make_manifest.py --modes before --layouts word plain --sets switch ami && ./run_replay.sh
.venv/bin/python simulate.py --detail 8          # pick the sample size and share
# Set QwenASREngine.languageSampleSize and sampleShare, then the new path:
.venv/bin/python make_manifest.py --modes after --layouts word plain --sets fleurs switch ami && ./run_replay.sh
# Wall time, paired: both paths back to back on each long track, alternating which goes first.
.venv/bin/python make_manifest.py --modes after before --alternate --layouts word plain --sets ami \
  --output $QLS_OUT/runs-paired.jsonl && ./run_replay.sh
.venv/bin/python score.py --results results/<date> --timing $QLS_OUT/runs-paired.jsonl
.venv/bin/python simulate.py --shares 0.8 0.85 0.9 --sizes 4 8 12 16 --resample 2000 --results results/<date>
```

`run_replay.sh` runs `Scripts/test/unit-tests.sh QwenLanguageSampleReplayTests/testReplayBenchmarkTracks` with the manifest and the model folder passed to the test host (`TEST_RUNNER_` variables). It needs `Vendor/llama-cpp` (`Scripts/build/fetch-llama.sh`) and the Silero VAD model the app already keeps under `~/Library/Application Support/FluidAudio/Models`.
