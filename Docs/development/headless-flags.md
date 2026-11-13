# Headless flags

Part of the [development guide](../../DEVELOPMENT.md).

The app binary doubles as a test harness; flows that need ungranted permissions are skipped.

| Flag | Effect |
| --- | --- |
| `--process <meeting-folder> [--no-summary]` | Run the transcribe/summarize pipeline, then exit |
| `--search "<query>"` | Print FTS5 hits (and semantic hits, if enabled) |
| `--record <seconds>` | Record for N seconds (needs the Mic grant) |
| `--digest` | Generate today's day digest |
| `--shot-test` | Capture one screenshot (needs Screen Recording) |
| `--chat "<question>"` | Ask the meeting chat assistant once and print the answer |
| `--agent "<prompt>"` | Run one Agent Mode turn headlessly (tool calls auto-approved) and exit by result |
| `--cotyping-bench [--model-path <model.gguf> [--passes N]]` | Run the 28 synthetic autocomplete scenarios and print a JSON report; exit 1 when a result is unsafe or errors. Without `--model-path` it starts the app and uses the selected engine and settings; this starts the full app, which can take focus. With `--model-path` it runs before app startup on the production autocomplete runtime with fresh-install settings, repeats the scenarios N times (default 5), and reports model loading, first-pass and warm latency separately. `Benchmarks/autocomplete/Cotyping/engine_benchmark.py` runs it together with next-word accuracy and typing latency. |
| `--cotyping-measurements` | Print the saved autocomplete counters and typing measurements as JSON, then exit before any window opens. Read-only |
| `--event-taps` | Print the keyboard and mouse hooks (event taps) installed on this Mac, grouped by app, as JSON, then exit before any window opens. Flags LokalBot holding more than 3 and any app holding 5 or more, the pattern of an app leaking taps. Read-only |
| `--cotyping-replay <fixture.json> --model-path <model.gguf>` | Replay synthetic prefix requests through the native production engine; print JSONL. Runs before app startup, migration, capture or learning. See [quality replay](../../Benchmarks/autocomplete/Cotyping/README.md) for the corpus, scoring and held-out procedure. |
| `--dictation-replay <fixture.json> --server-url http://127.0.0.1:<port>/v1` | Replay synthetic recognized speech, nearby text and saved facts through production Compose preparation; print JSONL with selected source IDs and reads. Runs before app startup; accepts only a loopback HTTP endpoint. See [dictation replay](../../Benchmarks/transcribe/Dictation/README.md). |
| `--health [--day yyyy-MM-dd] [--json]` | Evaluate one day's library health (default: yesterday), write the report to `diagnostics/health/`, and print it; exit 0 pass/warn, 1 fail, 2 invalid day |
| `--export-diagnostics <zip>` | Write the Export Diagnostics archive, as Settings does |
| `--radar-replay <fixture.json> [--model <id>] [--interval <s>] [--delay <s>] [--base-url <url> [--reasoning-line <level>]] [--audio <folder>] [--screens <folder>] [--answers [--folders <a,b>] [--answer-model <id>]]` | Replay a timed synthetic or public transcript through Live Radar's request and grounding code against the Meta Model API (or another OpenAI-compatible server with `--base-url`) and print JSONL per pass plus a summary. `--audio` streams the folder's `me.wav` and `them.wav` through fast live text in real time instead of using the fixture's text, `--screens` answers each caught question from the folder's synthetic captures, and `--answers` runs live answers with the fixture's `memory` and earlier passages standing in for the library and `--folders` read for real. Runs before app startup; reads `META_API_KEY` from the environment, never the Keychain or a library. See [Benchmarks/think/MuseRadar](../../Benchmarks/think/MuseRadar/README.md). |
| `--follow-through-replay <fixture.json> [--model <id>]` | Run Follow-through's tool loop against a fixture meeting: read tools answer from the fixture and every proposal is recorded and approved without being carried out. Same key and isolation as `--radar-replay`. |
| `--agent-sessions [yyyy-MM-dd]` | Print the day's Claude Code and Codex session evidence as the digest would read it (default: today), then exit before any window opens. Read-only: nothing is stored or sent |

Debug builds add test-only flags (`LOKALBOT_TEST_HOOKS`; Release never compiles them):

| Flag | Effect |
| --- | --- |
| `--record-capture <seconds> [--scenario <name>]` | Run tracking, capture, and meeting detection on the live Mac, then write a scrubbed capture trace to `diagnostics/capture-traces/` |
| `--set-boundaries <meeting-folder> <start> <end>` | Apply a meeting boundary the way the review sheet does, then wait for re-transcription and notes |
| `--search-screen "<query>"` | Print screen-text hits from the Recall search; exit 1 when there are none |
