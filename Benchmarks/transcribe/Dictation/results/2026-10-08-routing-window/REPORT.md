# Writing-request routing and focused-window context — 2026-10-08

## Outcome

Two production changes, each chosen from measured candidates:

- **Routing:** `DictationRequestRouting.production` is now `referencedRelays`. Leading filler ("hey", "okay so", "dobro") is skipped, and relay verbs aimed at someone else ("tell him", "let her know", "remind them", "text her", "reci mu", "pitaj ga") count as writing requests when the request also points at context ("…from the message above", "…iz poruke iznad"). On the new cases, requests answered with all grants rose from **0/12 to 6/12**. No direct sentence acquired screen context, and the earlier sets scored exactly as before.
- **Focused window:** the OCR text keeps the **last 2,000 characters** instead of the first 12,000. The old cut dropped the newest message of a long window, and Compose answered from a stale message. Window cases: **4/5 → 5/5**.

The broader `relays` candidate answered **9/12** requests. However, it routed the self-contained relay "Tell him I am running 10 minutes late." as a request and wrote "The bus is 20 minutes late. I am running 10 minutes late.", copying a screen fact into a direct message. That is the failure the 2026-10-02 routing rule exists to prevent, so it was not adopted.

## Eval design

- Machine: Apple M4 Max, 48 GiB, Mac16,5. Model `Qwen3.5-4B-Q4_K_M.gguf` on the bundled llama-server (loopback, 32,768 context, one slot, seed 12648430). Production Compose options: temperature 0.2, 4,096 output tokens, no thinking.
- One Release build (commit `8ec10cd`) carried all candidates; the replay selected them through `--routing` and `--variant-set full`, so every candidate ran the same binary, server and model. Hashes are in each run's `manifest.json`.
- `context-routing-v2.json` (31 cases) was authored and frozen before any inference ([`fixture-freeze.json`](fixture-freeze.json); its corpus hash matches every manifest). It contains:
  - 12 writing requests outside the original command list;
  - 12 direct sentences that begin with the same words, including two self-contained relays ("Tell him I am running 10 minutes late.", "Ask him to call me after 5.") labelled as text to insert;
  - 7 focused-window cases: a 14,288-character Slack window whose newest message is past the old 12,000-character cut, a short email, a stale-versus-latest conflict, Serbian, an injected instruction, direct speech and Transcribe.
- The `contextEligible` label records the intended reading. The `referencedRelays` cue list was written after the corpus was frozen and with the corpus in view, so its v2 score is not an untouched holdout result.
- Conditions: the five grant conditions from 2026-10-02, plus the focused window alone and with every grant, each with the first 12,000 characters (`head`) and the last 2,000 (`tail`). Twelve runs: the three routing rules × (v2 with nine conditions, and the earlier fresh, regression and development sets with five).

## Measured quality

Routing on the v2 cases, with every grant on (`all`):

| Rule | Requests answered (12) | Direct sentences kept (13) | Cases routed against their label | Screen context leaked into direct text |
|---|---:|---:|---:|---:|
| `commands` (previous production) | 0 | 10 | 12 | 0 |
| `relays` | 9 | 11 | 2 | 2 cases (forbidden reads; one wrong fact inserted) |
| `referencedRelays` (new production) | 6 | 10 | 4 | 0 |

All three rules gave identical results on the earlier sets: fresh 8/8 facts and 8/8 fidelity, regression 11/12 and 4/4, development 3/4 and 1/1. Every privacy, selection and invariance check passed.

Focused window on the v2 window cases (identical under every routing rule):

| Condition | Window cases (5) | Median ms |
|---|---:|---:|
| No window | 1 | 176–188 |
| Window, first 12,000 characters | 4 | 184 |
| Window, last 2,000 characters | 5 | 192 |
| Every grant + window, first 12,000 | 4 | 248 |
| Every grant + window, last 2,000 | 5 | 281 |

With the first 12,000 characters, the long window lost its last message and the reply was "Last week the Heron release went out at 17:10.", the stale fact. With the last 2,000 it was correct. The window was never read for direct speech or Transcribe (every screen-read check passed under the matching label), and no control changed. Median latencies are batch medians on a warm server, not user-perceived dictation latency.

## Verification of the shipped defaults

After the two defaults were changed, a second Release build (commit `6cbe1f7`, app SHA-256 `fd3fc06bcb119996…`) ran the same four sets with no `--routing` override:

- **Routing (v2 set):** every one of the 279 observations was routed as in the `referencedRelays` run, and every output text was identical. With all grants: requests 6/12, direct sentences 10/13, controls unchanged 14/14.
- **Earlier sets:** unchanged. Fresh 8/8 facts and 8/8 fidelity; regression 11/12 and 4/4; development 3/4 and 1/1. Every privacy, selection and invariance check passed.

The window variants pass their policy explicitly. The production policy default is covered by `DictationGroundingTests/testWindowTextKeepsTheNewestLinesNextToTheField`.

## What remains wrong

Compose's cleanup step acts on some direct sentences itself, whatever the routing decides:

| Spoken | Output with no context at all |
|---|---|
| Tell me if 14:00 works for you. | Does 14:00 work for you? |
| Can you tell me when the 9 boxes arrive? | I don't know when the 9 boxes will arrive. |
| Tell him I am running 10 minutes late. | I am running 10 minutes late. |
| Ask him to call me after 5. | Please call me after 5. |

The "9 boxes" case passes the frozen word check (it keeps "9" and does not say "90"), but the model answered the question instead of inserting it. That is a fidelity failure the scorer does not catch, and the case is reported here rather than rescored.

Requests that no rule routes are not passed through unchanged either. Without context the model tries to carry them out and can invent an answer: "Tell him the start time from the message above." became "The start time is 9:00 AM." under the previous rule.

Both behaviours come from the system prompt, which leaves the model to decide whether speech is an instruction. A prompt that states the routing decision ("insert this as dictated") is the next candidate, and it needs its own frozen cases before inference.

Other limits:

- Two Serbian requests ("Javi joj broj sobe…", "Pitaj ga da potvrdi datum…") were routed but returned unchanged by the 4B model.
- "Ask them to confirm the room number mentioned above." produced a request without the number.
- These are synthetic post-ASR cases. They do not measure live OCR quality, Accessibility compatibility, ASR, insertion, end-to-end latency or general multilingual quality.

## Files

- `runs/<set>-<routing>/report.json` and `manifest.json`: scored rows and hashes for each of the twelve runs.
- `raw-runs.tar.gz`, `raw-verification-runs.tar.gz`: replay inputs, raw JSONL outputs (prompts included), server and stderr logs.
- `fixture-freeze.json`: corpus, scorer and source hashes recorded before inference.
