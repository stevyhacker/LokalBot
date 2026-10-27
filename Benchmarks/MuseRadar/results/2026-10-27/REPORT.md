# Live Radar on 12 AMI meetings — 27 October 2026

**Result:** run live on Muse Spark 1.3, Live Radar caught **22 of the 62 decisions** and **8 of the 20 actions** in AMI's human summaries of 12 meetings, 6.4 hours in all. On the same transcripts, LokalBot's existing post-meeting notes, written afterwards by the local Qwen3.5 4B, caught 2 decisions and 3 actions.

**Speed and cost:** each item appeared a median **23 s** after it was said. A request took a median **1.05 s**, and the run cost **$0.49 per meeting hour**.

**Muse Wonder:** on half the meetings it caught more decisions than Spark, 23 of 42 against 13 of 42, at 2.5 times the cost.

## Systems

All three read the same text: AMI's manual transcripts of the meetings that [Benchmarks/SummaryQuality](../../../SummaryQuality/README.md) uses (ES2004, IS1009, TS3003; meetings a–d).

- **Live Radar.** `LokalBot Dev --radar-replay` ran the app's request, grounding, and client code ([harness](../../README.md)).
  - **Lines.** The transcript arrived as the live preview delivers it, one line per ~12 s chunk of each track. A line became visible 12 s after it started, and a pass ran every 20 s of meeting time.
  - **Speakers.** The Project Manager was the microphone ("Me"). The other three shared the call track ("Others"), with no voices told apart.
  - **Earlier meetings.** Each meeting after the first was given up to six decision and action sentences from AMI's summaries of the team's earlier meetings, standing in for the outcomes LokalBot's search would find.
  - **Request settings.** `reasoning_effort` minimal, a strict JSON schema, and the app's quote and evidence checks.
- **Post-meeting notes.** `LokalBot Dev --process --summary-only`: the app's existing notes pipeline on the built-in Qwen3.5 4B `Q4_K_M` (llama.cpp v0.7.0, b11669), after the meeting. Actions are `actionItems` and decisions are `decisionRecords` from `outcomes.json` ([saved](notes/)).

## Matching

- **Similarity.** Every system item and AMI sentence was embedded with EmbeddingGemma 2 `Q8_0` (LokalBot's search model) using its sentence-similarity prompt.
- **Coverage.** An AMI sentence counts as covered when its best match among the system's items reaches τ. Actions are scored against commitments, decisions against decisions.
- **Support.** An item counts as supported when it matches any sentence of that meeting's AMI summary (abstract, actions, decisions, problems). This is a rough precision proxy: AMI summaries are short, so most true items have nothing to match.
- **Threshold.** τ = **0.877**, the 95th percentile of 507 best matches between each system's items and a *different* team's AMI summary: what an unrelated design meeting would score. One τ covers all systems and both tables, as in SummaryQuality, which used Harrier embeddings and therefore a different τ.

## All 12 meetings

| System | AMI actions covered | AMI decisions covered | Items supported | Commitments / decisions / questions / contradictions |
|---|---:|---:|---:|---:|
| Live Radar · Muse Spark 1.3 | **8/20 (40%)** | **22/62 (35%)** | 26% of 238 | 26 / 86 / 104 / 22 |
| Post-meeting notes · Qwen3.5 4B (local) | 3/20 (15%) | 2/62 (3%) | 21% of 91 | 87 / 4 / 0 / 0 |

**Decisions.**
- **Notes.** The notes record almost none: 4 decision records across 12 meetings. SummaryQuality found the same: the 4B model treats very few design choices as "explicitly settled".
- **Radar.** It records 86. That raises recall, but it also proposes more than AMI lists, so some radar decisions are proposals the group later revised.

**Actions.**
- **Small sample.** With 20 action sentences, the gap is small in absolute terms. Of the 8 actions Spark caught, 6 were in two meetings (IS1009a, IS1009c).
- **Notes.** They list many more actions (87) than AMI's annotators did. Most match nothing in AMI's short summaries, which also lowers the notes' support rate.

## Six meetings with both models

ES2004b, ES2004d, IS1009b, IS1009d, TS3003b, and TS3003d: meetings b and d of each team, 220 minutes.

| System | AMI actions covered | AMI decisions covered | Items supported | Pass median (p95) | Cost per meeting hour |
|---|---:|---:|---:|---:|---:|
| Live Radar · Muse Spark 1.3 | 2/8 | 13/42 (31%) | 23% of 145 | 1.07 s (2.70 s) | $0.50 |
| Live Radar · Muse Wonder 1.0 | 2/8 | **23/42 (55%)** | 28% of 178 | 2.05 s (3.97 s) | $1.27 |
| Post-meeting notes · Qwen3.5 4B | 3/8 | 2/42 (5%) | 16% of 62 | after the meeting | local |

- **Decisions.** Wonder caught 10 more decisions on these meetings. On the same meetings it wrote fewer reasoning tokens than Spark (57k against 141k), but its per-token prices are 3–5 times higher.
- **Timing.** Items appeared a median 24 s after they were said with either model. That delay is mostly the preview's 12 s chunk and the wait for the next pass.
- **Defaults.** Spark stays the default for cost. Wonder is offered in Settings.

## Live behaviour

| | Muse Spark 1.3 (12 meetings) | Muse Wonder 1.0 (6 meetings) |
|---|---:|---:|
| Passes | 1,007 | 582 |
| Failed requests | 0 | 0 |
| Items rejected by the quote and evidence checks | 5 | 5 |
| Pass time, median (p95) | 1.05 s (2.62 s) | 2.05 s (3.97 s) |
| Item shown after it was said, median | 23 s | 24 s |
| Input / output / reasoning tokens | 2.03M / 265k / 233k | 1.17M / 77k / 57k |
| Cost | $3.09, $0.49 per meeting hour | $4.67, $1.27 per meeting hour |

## Contradictions

Spark flagged 22 contradictions: 10 against an earlier meeting and 12 within the same meeting. Each was read beside its quote and the passages it could cite. This review was done by the assistant, unblinded, so treat it as a sanity check rather than a measured precision.

- **Against earlier meetings (10).** All 10 name a real change of plan, one of them borderline. Examples:
  - "No docking station now, contradicting earlier plan to have one" (TS3003d), against "The remote will have a docking station."
  - "Remote now TV-only, contradicting earlier multi-device requirement" (TS3003b), against "The remote will be able to control multiple devices."
  - "Case material is now plastic only, not wood or plastic" (TS3003d).
  - The borderline one (ES2004d) pairs a fair conflict with a weak quote.
- **Within the meeting (12).** 9 describe a real reversal or conflict, such as the docking station changing from upright to flat (TS3003c). 3 do not: an ambivalent remark, a general claim that multi-device remotes are hard, and a market-share comment.

## Limits

- **Clean text.** The transcripts are manual, so these numbers describe the radar on clean text. Live preview recognition errors will lower them.
- **Sample size.** AMI annotates few actions: 20 for 12 meetings, 8 for the six. It writes one sentence for several decisions, which makes decision coverage understate recall for all systems.
- **Stand-in history.** The earlier-meeting passages are human summary sentences, not LokalBot's own extracted outcomes.
- **One run each.** There was no seed, and the Muse models are versionless from the client's side. Wonder ran only on the six-meeting subset, chosen in advance by meeting letter.
- **Different purposes.** Post-meeting notes favour precision by design ("explicitly settled" decisions, cited owners), while the radar is built to surface candidates as they come up. The comparison shows what each catches, not which is better overall.

## Run record

- **Software.**
  - Radar: built from `e7fc494` on branch `meta-hackathon`. A later commit added a prompt rule that commitments be written as plain tasks ("Book the venue", not "Me will book the venue"). These results predate it and were not re-run; on the synthetic meeting, six replays with the rule caught the free-tier contradiction 6 times and the launch-date one 5 times.
  - Notes: the same build.
  - Scoring: Python 3.13.18 and numpy 2.3.1, with EmbeddingGemma 2 `Q8_0` on the app's llama-server.
  - Machine: macOS 27.0.1 on an Apple M4 Max.
- **Spend.** The AMI replays cost $7.76 in hackathon credits. Under those credits Meta may use the content to improve its products; only public AMI text was sent.
- **Files.**
  - [scores.json](scores.json) (all meetings) and [scores-six-meetings.json](scores-six-meetings.json) (the subset);
  - [references.json](references.json) (AMI summary sentences);
  - [replays/](replays/): every pass, with the items kept, their quotes, and timing;
  - [notes/](notes/): the post-meeting outcomes.

AMI transcripts and summaries are © the AMI Consortium and are used under CC BY 4.0.
