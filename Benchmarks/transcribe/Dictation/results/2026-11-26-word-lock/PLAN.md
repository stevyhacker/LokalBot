# Plan, frozen before the first inference — 2026-11-26

Re-measure the 2026-11-21 word-lock replay ([`../2026-11-21-word-lock/REPORT.md`](../2026-11-21-word-lock/REPORT.md)) on the
project's current default Think model and the current bundled llama-server.

## What changes against 2026-11-21

- Model: `Qwen3.5-4B-LokalBot-v4-Q4_K_M.gguf` (SHA-256 `678f3d49c92ece8cd9425bad9e30cd626d35149b00f5dc2b661cb78ad9346ab0`),
  verified before the first run. 2026-11-21 used the stock `Qwen3.5-4B-Q4_K_M.gguf`. Reasoning off, as the runner's production
  Compose options set it.
- Server: the llama-server bundled by a Debug build of this branch at `e53aa887` (rebased on upstream/master `22f03d80`),
  llama.cpp v1.1.0 (build b12774). 2026-11-21 used v1.0.0 (build 12359).
- Word-lock rules: unchanged, the branch as it stands (`digitsNamesNegation`, with digit restoring).

## What stays the same

- `context_replay.py` of this branch, `--split heldout` for every set, `--word-lock off` and `--word-lock digitsNamesNegation`,
  production routing and cleanup prompt, production Compose options, fixed server seed. One server per run, as in
  2026-11-21 (this branch's runner has no `--fresh-server-per-condition`; the five grant conditions run one after another on
  the same server, and the report says so).
- Corpora byte-identical to 2026-11-21 (SHA-256 prefixes checked against the old manifests: `73742d72`, `bdced6d4`,
  `3e0936c0`, `57b002a1`, `0f59157c`, `7063219e`, `fccaae5f`).
- Built app run only from a disposable copy under `/private/tmp/lokalbot-bench`, with the runner's isolated home, storage and
  defaults. The owner's trial copy of LokalBot Dev is open and idle; it is not touched.

## Runs (14), in this order, one after another, lock off then lock on for each set

1. `context-wordlock-v1` (31 cases) 2. `context-cleanup-v4` 3. `context-cleanup-v3` 4. `context-routing-v2`
5. `context-routing-heldout` 6. `context-cases` 7. `context-speed-v1` (long, 8 cases).

Run names follow 2026-11-21: `wordlock-v1`, `v4`, `v3`, `v2`, `heldout`, `cases`, `speed`, each `-off` and
`-digitsNamesNegation`.

## What counts

- Correct and total over cleaned direct-speech (`fidelity`) outputs across the five grant conditions, as in 2026-11-21;
  scores come from `report.json` as they come, not promoted into a pass/fail.
- How often the lock fired and which check: from the lock-on runs' output and logs.
- Digits restored: outputs where the lock-on text differs from lock-off only by restored digits.
- Any output that was correct with the lock off and differs with it on is named.
- Latency: median, p90 and p95 per run over cleaned outputs (Transcribe-kind cases left out: no model call), compared off
  with on within this build.
- One pass. A run that fails twice stops the sweep and is reported. Free disk under 8 GB stops it too.
- The 2026-11-21 numbers are quoted from its report, not re-derived, in one table. This report states plainly if the lock is
  worse on the v4 model or makes no difference.

## Conditions of the machine

Apple M4 Pro, 48 GB. Kept awake with `caffeinate -i` only. Nothing else heavy started. The owner's trial copy of LokalBot Dev
(a separate build) was running and idle when the sweep started; the report says whether it stayed that way.
