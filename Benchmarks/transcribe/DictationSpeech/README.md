# The speech step of a long dictation

After the shortcut is released, dictation transcribes the whole recording again (`DictationCoordinator.transcribe`), and on a
long dictation that is most of the wait. This benchmark times that exact call, in the app, for each local model, on public
recordings of dictation length with human transcripts.

- **Runner:** `LokalBot Dev --dictation-speech-replay cases.json --model ID [--language auto|en] [--passes N]`
  (`DictationSpeechReplay`). It calls the same function the release path calls, with the chosen model and language, no
  vocabulary, after one warm-up transcription. Each pass covers every recording; the middle pass runs in reverse order. It
  prints one JSON line per recording and pass (seconds and text). It never opens the library, settings or windows.
- **Recordings:** `long-dictation-v1.json`, frozen before the first run. LibriSpeech `test-clean` and `test-other`
  (openslr.org/12, CC BY 4.0): per subset, chapters in speaker/chapter order, targets cycling 30, 60, 90 and 120 seconds,
  consecutive utterances from the chapter's start joined with 0.4 s of silence until the target is reached; 16 chapters per
  subset, 32 recordings, 43.1 minutes. One speaker reading continuously is closer to a long dictation than meeting audio, but it
  is read speech, not spontaneous.
- **Scoring:** the first pass gives accuracy (word error rate after the Whisper English normalizer and the spelling map in
  `../../think/ModelAlternatives/2026-09-07/`); latency is each recording's median over the passes, then the median over
  recordings. The interval is a paired 2,000-sample bootstrap over recordings.

## Running

```sh
export BENCH=/private/tmp/lokalbot-bench/dictation-speech
mkdir -p $BENCH/download
for s in test-clean test-other; do curl -fL -o $BENCH/download/$s.tar.gz https://www.openslr.org/resources/12/$s.tar.gz; done
brew install flac     # prepare.py decodes the FLAC files with the flac executable
uv venv --python 3.12 $BENCH/.venv && uv pip install --python $BENCH/.venv/bin/python numpy rapidfuzz "transformers<5"

$BENCH/.venv/bin/python prepare.py --downloads $BENCH/download --out $BENCH/data     # checks the archives' MD5
python3 run.py --app "path/to/LokalBot Dev.app" --cases $BENCH/data/cases.json --out $BENCH/runs --root $BENCH/root
$BENCH/.venv/bin/python score.py --cases $BENCH/data/cases.json --runs $BENCH/runs --out results/DATE/summary.json
```

`run.py` gives the app a disposable home (`--root`) and clones the speech models already downloaded on this Mac into it, so
nothing in the real library is read or written; a model that isn't there is downloaded by the app as usual. Its default order
is Qwen3-ASR on automatic language, Parakeet v3, Parakeet Ultra, Qwen3-ASR with English set, and Qwen3-ASR on automatic again
as a drift check. `qwen-v3-auto` and `qwen-v3-en` are the same two settings on the LokalBot v3 weights (`qwen3-asr-1.7b-lokalbot-v3`),
the app's current default; they are not in the default order.
Each manifest's `commit` is this checkout's HEAD; when the app was built from another checkout, pass `--app-commit` with
its commit and the manifest records it as `appCommit`. `appSHA256` is the SHA-256 of the app's executable, so a run can always be
tied to the build that made it. `score.py` stops on a run whose manifest records a failed replay (a nonzero `exit` or
`appChangedDuringReplay`).
