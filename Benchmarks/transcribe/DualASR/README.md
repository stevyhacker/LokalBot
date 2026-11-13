# Qwen3-ASR and Whisper on Serbian, Croatian and Bosnian

This benchmark asks whether a second transcription model, and a judge that picks between the two per decode window, would improve LokalBot's transcripts of Serbian, Croatian, Bosnian and code-switched meetings. It also measures which language hint each engine should get. [results/2026-10-07/REPORT.md](results/2026-10-07/REPORT.md) has the findings.

`harness/` is a headless Swift executable with the app's package pins: speech-swift 0.0.28, FluidAudio 0.17.5, mlx-swift 0.31.4 and WhisperKit 1.1.0. It cuts each track into the app's Qwen 1.7B word-attribution windows (Silero VAD regions, merged across pauses of up to 5 s into windows of up to 60 s). Both engines decode those same windows, so their outputs pair window by window. Qwen runs `aufklarer/Qwen3-ASR-1.7B-MLX-8bit` with repetition blocking off, as the app does. Whisper runs the app's pinned `openai_whisper-large-v3-v20240930` Core ML model with `WhisperEngine`'s decoding options. The `vote` and `vote-bcms` languages replay `QwenASREngine`'s vote-and-pin; `vote-bcms` also pins Croatian, Bosnian and Serbian votes to `sr`.

## Data

- **FLEURS (CC-BY-4.0):** `fetch_fleurs.py` builds 5–7 minute tracks from 30 dev utterances each in Serbian, Croatian and Bosnian, plus two code-switched tracks. `sr+en` repeats four Serbian utterances and one English; `en+sr` is the reverse. Utterance offsets are saved, so each window gets its own human reference.
- **The owner's meetings:** `make_jobs.py` reads the mic and system tracks in place from LokalBot's library (read only). `make_refs.py` asks Gemini for a reference transcript of each meeting window. It also transcribes the FLEURS Serbian windows to measure the reference's own error. Meeting audio, clips, transcripts and references stay in the private `DUAL_ASR_OUT` folder.

## Running

```sh
export DUAL_ASR_OUT=/private/tmp/lokalbot-dual-asr        # private: audio clips, transcripts, references
mkdir -p $DUAL_ASR_OUT

# Whisper weights and tokenizer at the app's pinned revisions
# (LokalBot/Resources/ModelAssets/pinned-speech-models.json, entries "whisper" and "whisperTokenizer"),
# into $DUAL_ASR_OUT/whisper/openai_whisper-large-v3-v20240930 and $DUAL_ASR_OUT/whisper/tokenizer.

# MLX needs Xcode's Metal build, so use xcodebuild rather than `swift build`.
(cd harness && xcodebuild -scheme DualASRHarness -destination 'platform=macOS,arch=arm64' -configuration Release \
  -derivedDataPath $DUAL_ASR_OUT/dd -clonedSourcePackagesDirPath $DUAL_ASR_OUT/spm \
  -skipPackagePluginValidation -skipMacroValidation build)
H=$DUAL_ASR_OUT/dd/Build/Products/Release/dual-asr-harness

uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python numpy requests rapidfuzz "transformers<5"
.venv/bin/python fetch_fleurs.py
swiftc -O ../QwenSpanLength/nlid.swift -o $DUAL_ASR_OUT/nlid      # Apple's language recognizer, as the app uses it

# Runs append to $DUAL_ASR_OUT/runs.jsonl and are resumable. Run short batches; the laptop heats up.
.venv/bin/python make_jobs.py qwen q-en q-auto q-vote q-vote-bcms && $H $DUAL_ASR_OUT/jobs-qwen.json
.venv/bin/python make_jobs.py qwen q-sr q-Serbian q-hr && $H $DUAL_ASR_OUT/jobs-qwen.json
.venv/bin/python make_jobs.py whisper w-auto w-hr && $H $DUAL_ASR_OUT/jobs-whisper.json
.venv/bin/python make_jobs.py whisper w-sr w-bs && $H $DUAL_ASR_OUT/jobs-whisper.json

# Cloud references (sends meeting audio to Google; needs the owner's approval). Keys as in ../CloudSTT.
.venv/bin/python make_refs.py --model gemini-3.8-flash

.venv/bin/python score.py q-auto,w-auto w-bs,q-auto        # WER table, per-window oracle, windows.jsonl
# LLM judge: any llama-server with the notes model, e.g. Qwen3.5-4B-Q4_K_M.gguf on port 18777
.venv/bin/python judges.py q-auto,w-bs --llm http://127.0.0.1:18777
```

Set `DUAL_ASR_MEETINGS` to a comma-separated list of library meeting paths (`2026/10/07-google-chrome-meeting`) to choose meetings. `make_jobs.py` writes the jobs to `$DUAL_ASR_OUT/jobs-<engine>.json`. The 2026-10-07 run split the jobs into the batches shown, with a one-minute pause between them.
