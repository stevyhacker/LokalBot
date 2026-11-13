# Dictation context quality replay

This benchmark measures the production **post-ASR Compose** path: explicit spoken writing requests, selected visible text above the input, relevant saved facts, the actual Compose prompt, and the configured local instruction model. The fixtures contain synthetic recognized speech, Accessibility trees and attributed facts. The replay never opens a microphone, reads a live screen or queries the user's library.

## Product behavior

- Compose uses context for explicit writing requests such as “reply,” “draft,” “rewrite,” or “translate,” including the supported polite and multilingual forms in `DictationGrounding.requestsContext`. Since 2026-10-08 it also skips leading filler (“hey,” “okay so,” “dobro”) and accepts relay verbs aimed at someone else (“tell him,” “let her know,” “reci mu”) when the request points at context (“…from the message above”). A self-contained relay such as “Tell him I am running late” stays direct. Direct sentences and unrecognized phrasing get ordinary Compose cleanup without added screen or memory context. This conservative rule prevents nearby messages from adding claims to direct dictation; it is not a general natural-language intent classifier.
- Three independent settings, initially off, grant visible text above the field, meeting/work memory, and screen-derived work memory. These do not inherit Autocomplete's grants. Mixed-provenance memories require both saved-memory grants. These grants read saved work memory whether or not Overnight review is scheduled.
- Nearby text uses the shared bounded, geometry-first Accessibility traversal. Saved facts come from current sources and require a source-title match in the spoken request or authorized screen context. Generic words in an instruction cannot qualify another project's facts through body overlap.
- The existing focused-window OCR option remains separate. When enabled it can start capturing during recording, before speech intent is known. Since 2026-10-08 the prompt keeps the last 2,000 OCR characters (the newest messages, next to the input field) instead of the first 12,000. Direct speech cancels any unfinished capture after ASR and does not send the result to Compose. The new nearby-text and memory providers are only invoked for eligible requests.
- Transcribe returns the recognized text unchanged, with no context reads and no composition-model call. This replay does not measure ASR or its existing name-vocabulary feature.
- Source deletion, changed permissions/destination and changed visible context invalidate pending composition. Current source/permission checks also guard delivery. The spoken transcript remains available if composition is rejected.

Compose continues to use the configured instruction model. These results use **Qwen3.5 4B Q4_K_M**; the Gemma Base model selected for Autocomplete is a different role and was not substituted into Compose.

## Run

Build Release, then use a disposable copy of its app bundle and isolated test identity as described in [Testing](../../Docs/development/testing.md). Do not run this through the installed app's normal GUI.

```sh
uv run --no-project python -S Benchmarks/Dictation/context_replay.py \
  --app /path/to/staged/LokalBot.app/Contents/MacOS/LokalBot \
  --server /path/to/staged/LokalBot.app/Contents/Resources/llama-cpp/llama-server \
  --model /path/to/Qwen3.5-4B-Q4_K_M.gguf \
  --split heldout \
  --corpus Benchmarks/Dictation/context-routing-heldout.json \
  --output /private/tmp/dictation-context-fresh-run
```

`--variant-set full` adds four focused-window conditions to the five grant conditions: the window alone and with every other grant, each with the production policy (the first 12,000 OCR characters) and with only the last 2,000 characters. Cases can carry a synthetic `screen` OCR fixture; the window is never read for direct speech or Transcribe, and the scorer checks that. `context-routing-v2.json` is the routing and focused-window supplement:

```sh
uv run --no-project python -S Benchmarks/Dictation/context_replay.py \
  --app … --server … --model … --split heldout --variant-set full \
  --corpus Benchmarks/Dictation/context-routing-v2.json --output /private/tmp/dictation-routing-v2-run
```

`--cleanup-prompt` selects how direct speech is cleaned (`composeDecides`, or `transcriptAsData`, which sends the transcript as JSON under a cleanup-only prompt). `context-cleanup-v3.json` holds direct dictation that reads like a question or instruction to an assistant.

The runner owns an ephemeral loopback-only server, isolates defaults/home/storage, runs conditions serially, and shuts down only its own process. The headless app dispatches `--dictation-replay` before AppState, migration or capture startup and rejects non-loopback destinations. Use a new output directory for every run; existing results are never overwritten. The binary hashes, model hash, corpus/scorer hashes and generation options are recorded. The server seed is fixed, but the production sampling temperature is 0.2, so do not assume bitwise model reproducibility.

Five conditions share the same speech and sources: neither, visible only, meeting memory only, both visible and meeting memory, and all (also screen-derived memory). Each case's reference labels specify required/forbidden whole words or phrases, permitted reads, expected source IDs and context eligibility. Reference labels are stripped from model/runtime input, including `contextEligible`; the Swift routing decision operates only on the speech. Privacy/source-selection/model-call failures exit nonzero. Semantic quality is reported as a score, not silently promoted into a passing test.

```sh
uv run --no-project python -S -m unittest discover \
  -s Benchmarks/Dictation -p 'test_*.py' -v
```

## Evaluation history and limits

The original `context-cases.json` contains six development and 22 initially held-out cases. The first model run found direct-speech contamination with context enabled. Those 22 cases became a **regression set** when the general routing fix was introduced; they are no longer an untouched holdout. The original fixtures, scorer, source/binary freeze and results remain under `results/2026-10-02-context/first-pass/`.

`context-routing-heldout.json` contains 20 fresh cases frozen after that fix and before inference: eight factual grounding tasks, eight fidelity tasks (six direct, one explicit override, one screen instruction injection), three exclusion controls and one Transcribe control. The supplement tests polite English, Serbian and French instructions as well as source provenance. It does not establish general multilingual quality.

The replay tests production preparation and selection code against synthetic trees; it does **not** establish live Accessibility compatibility, microphone quality, ASR accuracy, clipboard/paste behavior, hosted UI success or end-to-end dictation latency. Whole-phrase scoring is deliberately conservative: a response that explains a changed deadline by mentioning both the old and new date fails a forbidden-old-date check even when the explanation is correct. Preserve those scores and inspect the raw outputs.

See the [2026-10-02 report](results/2026-10-02-context/REPORT.md) for measured outcomes, validation, remaining misses and evidence hashes. The [2026-10-08 routing report](results/2026-10-08-routing-window/REPORT.md) compares the routing rules and focused-window policies behind the current production choices. The [2026-10-08 cleanup report](results/2026-10-08-cleanup/REPORT.md) shows why direct speech is now cleaned as JSON data under a cleanup-only prompt: the previous Compose prompt answered or acted on dictated questions and relays.
