# n-gram speculation for dictation cleanup, re-measured on the new default model and server — 2026-11-25

This repeats the [2026-11-21 speed report](../2026-11-21-speed/REPORT.md) on the project's current default Think model and the
current bundled llama-server. The plan was frozen before the first inference ([`PLAN.md`](PLAN.md)); it was followed as
written, nothing was trimmed.

## Outcome

`--spec-type ngram-cache` is again about 20% faster for cleanup, on both sets, on the new model and server:

- **Long dictation** (`context-speed-v1`, 43 to 220 words): median 2,172 → 1,800 ms; paired ratio 0.80 (round 2: 0.82).
- **Short dictation** (`context-cleanup-v4`): median 268 → 216 ms; paired ratio 0.81 (round 2: 0.79).
- `ngram-mod` alone again did nothing (ratio 0.98 to 1.01); adding it to `ngram-cache` changed nothing. `ngram-simple` with a
  3-token lookup helped less (0.86 long, 0.87 short); the other settings were no faster or slower (1.14 at worst).
- **The output text is no longer identical to the baseline everywhere.** On the new model, `ngram-cache` and `ngram-simple` n 3 changed the text of one
  dictation in each set, in all five conditions (on the long set `ngram-simple` n 6, `ngram-map-k` and `ngram-mod` match 8 did too). The change is a digit against a spelled-out number
  (details below). On the old stock model with the same new server, `ngram-cache` changed no output. The 11-21 report found no
  difference on the stock model either.
- Model change and server change each moved the no-speculation numbers by under 3% (run-to-run spread of the baselines is about 1.5%): stock model on the old server (11-21) 2,229 ms,
  stock model on the new server 2,227 ms, new model on the new server 2,172 ms (long, no speculation).

No production setting is changed here. The main server is shared with Ask and meeting notes; Ask was not measured, and meeting
notes were not re-measured on the new model (the first look in the 11-21 report stands as it was).

## What was measured

- Model `Qwen3.5-4B-LokalBot-v4-Q4_K_M.gguf`, SHA-256 `678f3d49c92ece8cd9425bad9e30cd626d35149b00f5dc2b661cb78ad9346ab0`
  (the current default, reasoning off). The stock-model pair used `Qwen3.5-4B-Q4_K_M.gguf`, SHA-256
  `00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4`, as in 11-21.
- Server: llama.cpp b12613 (`llama-server --version`: 1.0.0, build 12613, commit b12613), from a Debug build of this branch,
  ad-hoc signed, run from a disposable copy. 11-21 used v1.0.0 (build 12359). The manifests' `serverSHA256` is the same for both,
  because `llama-server` is a small launcher; the engine is in the dylibs. `libllama.1.dylib` SHA-256: new
  `7d4acb4d…`, old `78f094d0…`; `libllama-server-impl.dylib`: new `d29b3f9d…`, old `5144f8ab…`.
- Machine: Apple M4 Pro, 48 GB, macOS 26.7.3, 2026-11-25 07:55 to 08:29 local, kept awake with `caffeinate -i`.
- Production Compose options (temperature 0.2, reasoning off), fixed server seed, the `context_replay.py` of this branch
  (`--split heldout --fresh-server-per-condition`), corpora unchanged: `context-speed-v1.json` (8 cases, SHA-256
  `fccaae5f…`) and `context-cleanup-v4.json` (17 cases, `bdced6d4…`).
- **Every run used a fresh server for each of the five grant conditions**, so every cleaned output is a first-time dictation
  and all five conditions count: 40 outputs per long run, 85 per short run. 11-21 counted only the first condition (8 and 17).
  Medians are over all of them; the paired ratio is the median over (case, condition) of the configuration's latency divided
  by the baseline's for the same case and condition. Baseline: round 1 `none (first)`; round 2 `none`.
- Order: round 1 on the long set, then the short set (baseline first and last); then the stock-model pair on each set; then
  round 2 on each set. 30 runs, about 34 minutes in all, one after another.
- Whether another app was running: the owner's trial copy of LokalBot Dev was open and idle throughout (before, during and
  after); it was not touched. Nothing else heavy was started; the rest of the work during the runs was reading files and
  writing this report.

## Long dictation (8 cases, 40 outputs per row)

Round 1:

| Speculation | Median ms | p90 ms | Paired ratio | Draft tokens accepted | Same text as baseline | Correct (scored) |
|---|---:|---:|---:|---:|---:|---:|
| none (first) | 2172 | 4273 | 1.00 | — | 40/40 | 10/40 |
| none (last) | 2141 | 4237 | 0.99 | — | 40/40 | 10/40 |
| `ngram-simple`, n 3, m 16 | 1944 | 3463 | 0.86 | 3,200 of 8,955 (36%) | 35/40 | 15/40 |
| `ngram-simple`, n 6, m 32 | 2473 | 4459 | 1.14 | 1,875 of 13,600 (14%) | 35/40 | 15/40 |
| `ngram-simple` (defaults) | 2237 | 4165 | 1.01 | 400 of 4,560 (9%) | 40/40 | 10/40 |
| `ngram-mod` | 2123 | 4288 | 0.98 | 5 of 320 (2%) | 40/40 | 10/40 |
| `ngram-mod`, match 8, 4-32 | 2585 | 4597 | 1.14 | 1,130 of 11,160 (10%) | 35/40 | 15/40 |
| `ngram-map-k`, n 4, m 32 | 2116 | 4119 | 1.00 | 330 of 1,920 (17%) | 35/40 | 15/40 |
| `ngram-cache` | 1800 | 3400 | 0.80 | 3,065 of 7,575 (40%) | 35/40 | 15/40 |

Round 2:

| Speculation | Median ms | p90 ms | Paired ratio | Draft tokens accepted | Same text as baseline | Correct (scored) |
|---|---:|---:|---:|---:|---:|---:|
| none | 2113 | 4181 | 1.00 | — | 40/40 | 10/40 |
| `ngram-mod` | 2119 | 4312 | 1.01 | 5 of 320 (2%) | 40/40 | 10/40 |
| `ngram-cache` | 1813 | 3408 | 0.82 | 3,065 of 7,575 (40%) | 35/40 | 15/40 |
| `ngram-mod,ngram-cache` | 1807 | 3393 | 0.81 | 3,065 of 7,575 (40%) | 35/40 | 15/40 |

Stock model, same new server:

| Speculation | Median ms | p90 ms | Paired ratio | Draft tokens accepted | Same text as baseline | Correct (scored) |
|---|---:|---:|---:|---:|---:|---:|
| none (stock model) | 2227 | 4365 | 1.00 | — | 40/40 | 20/40 |
| `ngram-cache` (stock model) | 1934 | 3781 | 0.83 | 2,935 of 7,655 (38%) | 40/40 | 20/40 |

## Short dictation (`context-cleanup-v4`, 17 cases, 85 outputs per row)

Round 1:

| Speculation | Median ms | p90 ms | Paired ratio | Draft tokens accepted | Same text as baseline | Correct (scored) |
|---|---:|---:|---:|---:|---:|---:|
| none (first) | 268 | 558 | 1.00 | — | 85/85 | 83/85 |
| none (last) | 267 | 561 | 1.00 | — | 85/85 | 83/85 |
| `ngram-simple`, n 3, m 16 | 222 | 530 | 0.87 | 545 of 1,408 (39%) | 80/85 | 78/85 |
| `ngram-simple`, n 6, m 32 | 256 | 564 | 1.00 | 325 of 1,525 (21%) | 85/85 | 83/85 |
| `ngram-simple` (defaults) | 275 | 564 | 1.02 | 15 of 455 (3%) | 85/85 | 83/85 |
| `ngram-mod` | 271 | 560 | 1.00 | — | 85/85 | 83/85 |
| `ngram-mod`, match 8, 4-32 | 256 | 568 | 1.00 | 175 of 1,000 (18%) | 85/85 | 83/85 |
| `ngram-map-k`, n 4, m 32 | 266 | 554 | 0.99 | — | 85/85 | 83/85 |
| `ngram-cache` | 216 | 511 | 0.81 | 520 of 1,032 (50%) | 80/85 | 78/85 |

Round 2:

| Speculation | Median ms | p90 ms | Paired ratio | Draft tokens accepted | Same text as baseline | Correct (scored) |
|---|---:|---:|---:|---:|---:|---:|
| none | 274 | 566 | 1.00 | — | 85/85 | 83/85 |
| `ngram-mod` | 267 | 557 | 0.98 | — | 85/85 | 83/85 |
| `ngram-cache` | 212 | 503 | 0.79 | 520 of 1,032 (50%) | 80/85 | 78/85 |
| `ngram-mod,ngram-cache` | 214 | 501 | 0.80 | 520 of 1,032 (50%) | 80/85 | 78/85 |

Stock model, same new server:

| Speculation | Median ms | p90 ms | Paired ratio | Draft tokens accepted | Same text as baseline | Correct (scored) |
|---|---:|---:|---:|---:|---:|---:|
| none (stock model) | 277 | 569 | 1.00 | — | 85/85 | 83/85 |
| `ngram-cache` (stock model) | 224 | 521 | 0.79 | 549 of 1,040 (53%) | 85/85 | 83/85 |

"Draft tokens accepted" is summed over the server log's per-request lines; "—" means the server drafted nothing.
"Correct (scored)" is the scorer's count of correct outputs and is not a speculation metric: it is shown because it moved with
the text (below).

## Output text against the no-speculation baseline

- The two no-speculation baselines of round 1 agree with each other in every output (40/40, 85/85): the runs are repeatable
  with the fixed seed.
- **Same text in every output:** `ngram-simple` with defaults, `ngram-mod` and (short set) `ngram-simple` n 6, `ngram-mod` match 8,
  `ngram-map-k`; and, on the stock model, `ngram-cache`.
- **Changed text:** exactly one dictation per set, in all five conditions (5 of 40, 5 of 85 outputs), for the configurations marked
  below 40/40 or 85/85 above. Long set, `s1-plan-45` ("…test the checkout flow on 3 devices"): the baseline wrote "Then, Petra
  walks … on three devices" in separate sentences; with speculation, "…, then Petra walks …, and after lunch we split … on 3
  devices". Short set, `f4-tell-relay`: baseline "Tell Ivana I will bring 4 copies.", with speculation "…four copies."
- The scorer counted the changed outputs differently: on the long set 15 of 40 against 10 of 40 (more correct with
  speculation), on the short set 78 of 85 against 83 of 85 (fewer correct: the spelled-out number fails its check). Those
  differences come from one dictation per set; they are not a quality result for speculation in either direction.
- The long set's own failures (kept "uh", numbers written as words) exist at baseline, with both models, and are unrelated to
  speculation.
- Why it is not byte-for-byte: speculative decoding verifies drafted tokens in a batch, whose arithmetic differs slightly from
  one-token steps, and at temperature 0.2 a near-tie between two spellings can flip. Whether it flips depends on the model, so
  the claim of identical text from 11-21 held for the stock model and does not hold for the new one.

## Compared with 2026-11-21

| | 11-21 (stock model, old server, condition 1 only) | 11-25 (new model, new server, all conditions) |
|---|---:|---:|
| Long, none → `ngram-cache` | 2,229 → 1,919 ms (0.82) | 2,113 → 1,813 ms (0.82); round 1 2,172 → 1,800 (0.80) |
| Short, none → `ngram-cache` | 275 → 218 ms (0.79) | 274 → 212 ms (0.79); round 1 268 → 216 (0.81) |
| `ngram-mod`, long / short | 0.98 / 1.00 | 1.01 / 0.98 (round 2); 0.98 / 1.00 (round 1) |
| `ngram-simple` n 3 m 16, long / short | 0.92 / 0.86 | 0.86 / 0.87 |
| Same text in every output | yes, every configuration | no for the new model (one dictation per set), yes for the stock model on the new server |

The speed-up is the same size. The 11-21 long-set figure for `ngram-cache` uses round 2; round 1 there was 0.84.

## Limits

- Cleanup only; meeting notes were **not re-measured** on the new model (see the first look in the 2026-11-21 report), and
  Ask was not measured. Transcribe uses no model.
- Eight long and 17 short dictations, so the one changed dictation per set is 12% and 6% of the cases. Five conditions per case
  are not independent samples: the text is the same in all five.
- One machine, one seed; temperature 0.2 means other seeds can differ.
- Raw outputs and server logs are in [`raw-runs.tar.gz`](raw-runs.tar.gz) (no local paths); `runs/` holds each run's
  `manifest.json` and `report.json` (round 2 prefixed `round2-`, stock-model runs `*-stock-*`).
- The wordlock set from 11-21 was not re-run.
