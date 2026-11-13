# Direct-dictation cleanup prompt — 2026-10-08

## Outcome

`DictationCleanupPrompt.production` is now `transcriptAsData`. Speech that routing does not mark as a writing request is sent as a JSON transcript to a cleanup-only system prompt. That prompt says the transcript is text to insert, never to be answered or carried out, and that numbers, dates and times keep their recognized form. Writing requests keep the Compose prompt.

Results on the second cleanup set, which was frozen before the revised prompt ran:

- **Direct sentences kept as dictated:** 13/16 with the previous prompt, 16/16 with the new one.
- **Writing requests and the earlier case sets:** scores unchanged.
- **Median latency for direct speech:** up about 40–70 ms on a quiet machine.

FluidVoice and Handy separate cleanup instructions from the transcript in the same way (see the comparison in PR #217).

## Why

The previous design used one Compose prompt that told the model to carry out instructions and lightly fix everything else, leaving the model to decide which was which. The 2026-10-08 routing report showed it answering or acting on dictated text whatever routing decided. This run found more of the same. With the previous prompt, on the frozen v4 set:

| Spoken | Previous output |
|---|---|
| What is the status of the Birch invoice? | I do not have access to the Birch invoice status. Please provide the i… |
| Tell Ivana I will bring 4 copies. | I will bring 4 copies. |
| Ask the team if 11 works for lunch. | Hi team, does 11 work for lunch? |

With the new prompt all three were inserted as dictated.

## Eval design

- Same machine, model, server and production options as the 2026-10-08 routing run. Candidates were selected with `--cleanup-prompt` on one Release build per prompt revision. Hashes are in each run's `manifest.json`.
- `context-cleanup-v3.json` (20 cases) was frozen before the first candidate ran ([`fixture-freeze.json`](fixture-freeze.json)). It contains direct English and Serbian dictation that reads like a question or instruction to an assistant, with conflicting text above the field, three writing requests, and Transcribe.
- **First candidate (`first-prompt/`):** it stopped every answered or executed sentence, but it spelled small numbers out ("4 slides" became "four slides", "3 sastanka" became "tri sastanka"). Its v3 score was 11/16 against 9/16. Its latency is **not usable**: those runs overlapped a Debug build on the same machine, and the server log shows generation falling from about 100 to 40–60 tokens/s.
- **Revision:** one sentence was added ("Keep numbers, dates and times in the form they were recognized: digits stay digits. Do not spell them out or reformat them."). `context-cleanup-v4.json` (18 cases: number-heavy direct dictation, questions and relays in English and Serbian, one request, Transcribe) was authored and frozen before the revision ran ([`revised-prompt-freeze.json`](revised-prompt-freeze.json)). v3 informed the revision, so it is reported but is not a holdout for it.
- The revised runs (`revised-prompt/`) ran on an otherwise idle machine and covered v4, v3, the routing set (v2, with nine conditions), and the earlier fresh, regression and development sets, with both prompts.

## Measured quality

Direct sentences kept as dictated (identical across grant conditions):

| Set | Previous prompt | Transcript as data |
|---|---:|---:|
| v4 (frozen before the revision) | 13/16 | **16/16** |
| v3 (informed the revision) | 9/16 | 15/16 |
| v2 routing set | 10/13 | 12/13 |
| fresh / regression / development | 8/8 · 4/4 · 1/1 | 8/8 · 4/4 · 1/1 |

Writing requests answered with all grants were unchanged on every set: v3 3/3, v4 1/1, v2 6/12, fresh 8/8, regression 11/12, development 3/4. All privacy, selection and invariance checks passed, except on cases whose routing disagrees with their label. Those are expected and identical for both prompts: c3-summarize-thoughts and the v2 relay requests that `referencedRelays` does not route.

Remaining misses with the new prompt:

- **v3 `c3-summarize-thoughts`:** "Summarize your thoughts on the 2 proposals before Friday." starts with a command word, so it is routed as a writing request and Compose writes a summary. The fix would be routing, not cleanup.
- **v2 `d2-sr-javi-mi`:** "Javi mi sutra da li dolaziš na 3 sastanka." became "…na tri sastanka". The digit rule held in every English case but not in this Serbian one, so it is an instruction to a 4B model, not a guarantee. The other v2 direct sentences that the previous prompt changed are now kept, including "Tell me if 14:00 works for you.", "Tell him I am running 10 minutes late." and "Ask him to call me after 5."

Median latency for direct speech (`neither` condition, idle machine): v4 187 → 256 ms, v3 173 → 246 ms, v2 180 → 213 ms. Fresh, regression and development varied in both directions, within run-to-run noise. These are batch medians on a warm server.

## Verification of the shipped default

A Release build with the new default (commit `f2587c1`, app SHA-256 `6160274a42cd1b88…`) reran v4, v3 and the fresh set without `--cleanup-prompt`. All 290 observations matched the `transcriptAsData` runs in output text and score (v4 16/16, v3 15/16, fresh 8/8 and 8/8).

## Limits

These are synthetic post-ASR cases scored with whole-word checks. They do not measure prose quality, punctuation preferences, or broad multilingual behaviour, and the digit rule is an instruction to a 4B model, not a guarantee. No live ASR, insertion or end-to-end dictation ran.

## Files

- `first-prompt/runs/…`, `revised-prompt/runs/…`: `report.json` and `manifest.json` for each run.
- `first-prompt/raw-runs.tar.gz`, `revised-prompt/raw-runs.tar.gz`: replay inputs, raw outputs (prompts included) and logs.
- `verification/runs/…`, `verification/raw-runs.tar.gz`: the shipped-default reruns.
- `fixture-freeze.json`, `revised-prompt-freeze.json`: corpus and source hashes recorded before inference.
