# n-gram speculation for dictation cleanup — 2026-11-21

## Outcome

`--spec-type ngram-cache` on the bundled llama-server made cleanup about 20% faster, with the same output text, on dictations
the server had not seen before:

- **Long dictation** (`context-speed-v1`, 43 to 220 words): median 2,229 → 1,919 ms; paired ratio 0.82 (round 1: 0.84).
- **Short dictation** (`context-cleanup-v4`): median 275 → 218 ms; paired ratio 0.79 (round 1: 0.81).
- **`ngram-mod` did nothing for a first-time dictation** (ratio 0.98 to 1.00), and adding it to `ngram-cache` changed nothing.
  `ngram-simple` with a 3-token lookup helped a little (0.92 long, 0.86 short); the other sizes and `ngram-map-k` were no faster
  or were slower.
- **Output text** was identical to the baseline in every output of every configuration.

**The replay overstates speculation unless only the first condition is counted.** It sends each dictation five times, once per
grant condition, to the same server, and n-gram speculation drafts from the server's own earlier answer to the same text. In
conditions 2 to 5, `ngram-mod` looked three times faster (2,102 → 682 ms on long dictation) although it gives nothing the first
time. Real dictations aren't repeated, so only condition 1 (`neither`) is the result here; the repeated figures are shown only
to make the effect visible. A future speed run should start a fresh server per condition, or run only the first.

No production setting is changed here; the main server is shared with Ask and meeting notes, which were not measured.

## First-time dictations

Round 2: no speculation first, then `ngram-mod`, `ngram-cache` and both together. Paired ratio is the median over cases of the
configuration's latency divided by the baseline's for the same case. Long dictation, 8 cases:

| Speculation | Median ms, first time | Paired ratio to no speculation | Median ms, repeated (conditions 2-5) |
|---|---:|---:|---:|
| none | 2229 | 1.00 | 2102 |
| `ngram-mod` | 2186 | 0.98 | 682 |
| `ngram-cache` | 1919 | 0.82 | 1143 |
| `ngram-mod,ngram-cache` | 1895 | 0.82 | 518 |

Short dictation (`context-cleanup-v4`), 17 cases:

| Speculation | Median ms, first time | Paired ratio to no speculation | Median ms, repeated (conditions 2-5) |
|---|---:|---:|---:|
| none | 275 | 1.00 | 262 |
| `ngram-mod` | 275 | 1.00 | 260 |
| `ngram-cache` | 218 | 0.79 | 188 |
| `ngram-mod,ngram-cache` | 218 | 0.79 | 187 |

Round 1: nine configurations, the baseline first and last. Long dictation:

| Speculation | Median ms, first time | Paired ratio to no speculation | Median ms, repeated (conditions 2-5) |
|---|---:|---:|---:|
| none | 2237 | 1.00 | 2172 |
| none (last) | 2216 | 0.99 | 2090 |
| `ngram-simple`, n 3, m 16 | 2099 | 0.92 | 1972 |
| `ngram-simple`, n 6, m 32 | 2610 | 1.20 | 2597 |
| `ngram-simple` (defaults) | 2363 | 1.05 | 2251 |
| `ngram-map-k`, n 4, m 32 | 2228 | 1.01 | 2105 |
| `ngram-mod`, match 8, 4-32 | 2697 | 1.19 | 2573 |
| `ngram-mod` | 2233 | 1.00 | 693 |
| `ngram-cache` | 1944 | 0.84 | 1156 |

Short dictation:

| Speculation | Median ms, first time | Paired ratio to no speculation | Median ms, repeated (conditions 2-5) |
|---|---:|---:|---:|
| none | 276 | 1.00 | 269 |
| none (last) | 275 | 0.99 | 260 |
| `ngram-simple`, n 3, m 16 | 228 | 0.86 | 230 |
| `ngram-simple`, n 6, m 32 | 272 | 0.99 | 266 |
| `ngram-simple` (defaults) | 284 | 1.02 | 264 |
| `ngram-map-k`, n 4, m 32 | 277 | 1.00 | 260 |
| `ngram-mod`, match 8, 4-32 | 265 | 0.98 | 264 |
| `ngram-mod` | 277 | 1.00 | 263 |
| `ngram-cache` | 220 | 0.81 | 189 |

## Output text

Every configuration produced exactly the baseline's text in every output and condition, so correctness scores match the
baseline's. The long set's own failures (in four of the eight long dictations cleanup kept an "uh" or wrote a spoken digit as
a word) are unrelated to speculation.

## Eval design

- `context_replay.py --server-arg ...` passes speculation flags to the runner's own loopback server; the runner still owns the
  model, host, port, context, seed and parallelism, and records the full command in each run's `manifest.json`.
- Bundled llama-server v1.0.0 (build 12359), Qwen3.5-4B-Q4_K_M, production Compose options (temperature 0.2, reasoning off),
  fixed server seed; a Debug build of this branch run from a disposable copy with the runner's isolated home, storage and
  defaults; Apple M4 Pro, 48 GB, nothing else running.
- Configurations ran one after another within each set, with the baseline first and last for a noise floor. Each
  configuration got its own server, so its first condition starts with an empty speculation cache.
- Each run's `report.json` and `manifest.json` are in
  `runs/` (round 2 prefixed `round2-`); raw outputs and server logs in [`raw-runs.tar.gz`](raw-runs.tar.gz), local paths
  rewritten to `~`; the server logs include each request's draft acceptance.
- Qwen3.5-4B's GGUF has no multi-token-prediction head, so `draft-mtp` was not tried; draft-model speculation was not tried
  because it needs a second model in memory.

## Not covered

- Only cleanup: Transcribe inserts the recognized text without a model, and for long dictations most of the wait is
  transcription (see the comment on #545).
- Other users of the main server (Ask, meeting notes, summaries) were not measured.
- `ngram-cache` keeps what it learns for the server's lifetime, so later dictations that repeat phrases from earlier ones may
  gain a little more than a first-time one; that was not measured.
