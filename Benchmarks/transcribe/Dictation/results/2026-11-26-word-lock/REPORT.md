# Word lock re-measured on the new default model — 2026-11-26

This repeats the replay of the [2026-11-21 word-lock report](../2026-11-21-word-lock/REPORT.md) on the project's current default
Think model and the current bundled llama-server, with the lock rules unchanged. The plan was frozen and committed before the
first inference ([`PLAN.md`](PLAN.md)) and followed as written.

## Outcome

On the v4 model the lock does what it did on the stock model where it matters for the long set, and has less to do on the
short ones:

- **It never fell back to the transcript.** Across all 14 runs the lock kept the transcript 0 times, so no check (digits,
  negation or names) failed on any output, and no correct output was replaced.
- **It restored spoken digits 20 times, in four cases**, and every one of those outputs went from wrong to right:
  `w1-digits-filler` ("We need three more days." → "We need 3 more days.") in all five grant conditions on the
  wordlock set, and the long-set cases `s1-plan-45`, `s5-stutter-120` and `s7-brainstorm-250` in all five conditions
  (15 outputs). On the stock model the same restoring fixed the same three long cases; the wordlock set's
  `w1-digits-filler` was right with the stock model and is wrong with v4 when the lock is off.
- **The Serbian case the lock was written for is no longer needed on v4.** `d2-sr-javi-mi` ("na 3 sastanka") came back with
  the digit kept with the lock off, so context-routing-v2 is 65/65 off and on; with the stock model the lock turned 60/65
  into 65/65.
- **Lock off versus on:** 420/435 → 425/435 on the six replay sets (the five restored outputs on the wordlock set), and
  25/40 on the long set where lock off is 10/40. No output that was correct with the lock off changed with it on.
- **Latency:** the lock's medians are within 2 ms of lock-off on every set.
- **Model change:** the v4 model with the lock off scores lower than the stock model on two sets: context-cleanup-v3
  70/80 (stock 75/80) and the long set 10/40 (stock 20/40). That is the model, not the lock; on those the lock does not move
  the count, except for the long set's digits. The v3 misses are `c3-summarize-thoughts` (routed as a writing request, as
  before) and `c3-filler`, where v4 dropped "I think" from "um so the the release is moved to Thursday I think"; both are
  outside a digits, names and negation lock.

## Numbers, 2026-11-21 (stock model) beside 2026-11-26 (v4)

Cleaned direct-speech (`fidelity`) outputs across the five grant conditions. "Lock acted" counts outputs where the lock kept the
transcript (11-21 only: the 5 on v2) or restored spoken digits (11-26: all of them).

| Set | 11-21 off → on | 11-21 lock acted | 11-26 off → on | 11-26 lock acted | 11-26 median ms off → on |
|---|---:|---:|---:|---:|---:|
| `context-wordlock-v1` | 150/150 → 150/150 | 0 | 145/150 → 150/150 | 5 (restored) | 226 → 228 |
| `context-cleanup-v4` | 80/80 → 80/80 | 0 | 80/80 → 80/80 | 0 | 262 → 260 |
| `context-cleanup-v3` | 75/80 → 75/80 | 0 | 70/80 → 70/80 | 0 | 251 → 251 |
| `context-routing-v2` | 60/65 → 65/65 | 5 (kept transcript) | 65/65 → 65/65 | 0 | 244 → 244 |
| `context-routing-heldout` | 40/40 → 40/40 | 0 | 40/40 → 40/40 | 0 | 297 → 299 |
| `context-cases` (heldout) | 20/20 → 20/20 | 0 | 20/20 → 20/20 | 0 | 264 → 263 |
| **Six sets** | **425/435 → 430/435** | **5** | **420/435 → 425/435** | **5** | |
| `context-speed-v1` (long) | 20/40 → 25/40 | 15 (restored) | 10/40 → 25/40 | 15 (restored) | 2004 → 2005 |

- **Which check:** none failed, so there is no fallback to name. Every action was digit restoring (log line
  "dictation word lock restored spoken digits": 5 on the wordlock set, 15 on the long set, none elsewhere).
- **Correct output changed by the lock:** none. The lock-on texts differ from the lock-off texts in exactly those 20 outputs,
  and all 20 were wrong before and right after.
- **What the long set still gets wrong:** 15 outputs, three cases in every condition, where cleanup kept an "uh"
  (`s2-numbers-70`, `s6-feedback-200`, `s8-handoff-90`), as in 11-21. Outside the lock.
- 11-21 columns are quoted from that report (its `runs.csv` was regenerated for it, and matches its tables).
- Per-run rows, including the p90 and p95 latencies, are in [`runs.csv`](runs.csv).

## What was measured

- Model `Qwen3.5-4B-LokalBot-v4-Q4_K_M.gguf`, SHA-256 `678f3d49c92ece8cd9425bad9e30cd626d35149b00f5dc2b661cb78ad9346ab0`
  (verified before the first run), reasoning off.
- Server: the llama-server bundled by a Debug build of this branch at `e53aa887`, rebased on upstream/master `22f03d80`,
  ad-hoc signed and run from a disposable copy under `/private/tmp/lokalbot-bench`: llama.cpp v1.1.0, build 12774
  (`libllama.1.dylib` SHA-256 `0e3c7ce9…`). 11-21 used v1.0.0 (build 12359). The manifests' `appSHA256` is that of the copied app
  executable.
- Machine: Apple M4 Pro, 48 GB, macOS 26.7.3, 2026-11-26 10:37 to 10:47 local, kept awake with `caffeinate -i`; 14 runs, one
  after another, about 10 minutes.
- `context_replay.py` of this branch, `--split heldout`, `--word-lock off` and `--word-lock digitsNamesNegation`, production
  routing, cleanup prompt and Compose options (temperature 0.2, reasoning off), fixed server seed, the runner's isolated home,
  storage and defaults. Corpora unchanged from 11-21 (SHA-256 prefixes in each manifest match the 11-21 manifests).
- One server per run, as in 11-21: the five grant conditions run one after another on the same server, so every condition
  after the first reuses a warm prompt cache. Latency compares off with on within this build only.
- Running at the time: the owner's trial copy of LokalBot Dev (a separate build) was open and idle before, during and after
  (its CPU time moved by about 9 seconds over the hour around the run); it was not touched. Nothing else heavy was started.
- Raw outputs, server and app logs and every `report.json` are in one archive outside git:
  [raw runs](https://github.com/user-attachments/files/35472427/word-lock-2026-11-26-raw-runs.tar.gz), SHA-256 `daf6322c9d148f09a788d1bdb85ca9df0f1b277e787dc617ceceb32bbad429cb`. This folder keeps `PLAN.md`, this report, `runs.csv` and each run's
  `manifest.json`.

## Limits

- **It is the same synthetic corpora.** Nothing here measures real dictation on the v4 model: the real-dictation samples in
  the 11-21 report were cleaned by the stock model and were not repeated. Whether v4 makes the lock fire more or less on
  real speech is not known from this run.
- **Seven sets, one seed, one pass each.** No repeat of any run, so run-to-run spread on v4 is unmeasured; the lock-off and
  lock-on texts being identical outside the 20 restored outputs shows the replay is deterministic here, but a different
  seed or build could differ.
- **The sets are small, and the rules were shaped on some of them.** The rules changed after the wordlock set and the long set
  were first run, as the 11-21 report says, so on those two this run is not a blind test of the rules.
- **The lock did not fire a single fallback**, so this run says nothing new about the digit, negation and name checks as
  checks; it shows only that they did not harm any output, and that digit restoring still helps on v4.
- Everything in the 11-21 "Not covered" section still applies.
- Because the stock model got `w1-digits-filler` right and v4 gets it wrong, restoring now helps on a set where it did not in 11-21.
  That is a property of the new model, not of changed rules.
