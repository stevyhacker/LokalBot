**Autocomplete experiment record — 10–11 October 2026**

Current decision: **retain Gemma 4 E2B Q6_K as the default model.** The opt-in experimental switch enables selective one-word fallback plus bounded prefix search; switching it off restores the previous decoder. This is still a draft, experimental PR. [Trial and rollback guide](../../../Docs/experimental-autocomplete-hybrid.md).

Every study below retains its original conclusions and validation boundaries. Historical statements about installation, default candidates or queued work describe that stage, not the current adoption decision. In particular, the calibration-stage Luchador fallback recommendation was superseded by the user’s explicit choice of E2B after the midword experiment. Do not combine quality samples or average latency across different studies.

| Experiment | Result and current treatment | Evidence |
|---|---|---|
| Installed Cotypist investigation using rea | Identified prefix constraints, bounded candidate exploration and cache mechanisms; no claim about its live quality or measured speed | [Investigation](../../../Docs/cotypist-autocomplete-comparison-2026-10-10.md) |
| Two/four free-continuation candidates | Only +2 reference-word matches per 600, higher latency; rejected | [Initial](2026-10-10-candidates/REPORT.md), [after master PR228/229](2026-10-10-candidates-master/REPORT.md) |
| Ranking audit and exact-prefix logit cache | Output parity held; held-out dynamic p95 worsened 116.9→139.1 ms; rejected | [Report](2026-10-10-cache/REPORT.md) |
| Nine decoder variants and refinements | Boundary-mass/guarded stop improved first-word reference score but missed the combined character/false-show objective; no wholesale adoption | [Loop report](2026-10-10-decoder-loop/REPORT.md) |
| Blind Claude comparison of policy combinations | Favored retaining the ordinary gate and adding only one fallback word | [Judge report](2026-10-10-claude-judge/REPORT.md) |
| Native selective hybrid | On 738 checkpoints preserved all 306 current outputs and added 77; Claude rated 71 helpful/6 neutral; modest extra latency | [Report](2026-10-10-native-hybrid/REPORT.md) |
| Five additional models and papers | LFM2.5 1.2B/2.6B Base, Qwen3.5 2B Base, Gemma E4B Base, Luchador; Luchador became the English-quality finalist | [Model report](2026-10-10-models/REPORT.md), [Claude additions](2026-10-10-models/CLAUDE-TEST-LIST.md) |
| Confidence calibration and Claude-selected models | Added stock Gemma E4B IT, Qwen3 4B Base, Salamandra 2B, YugoGPT 7B; at equal EN/Serbian-Latin frequency no clear overall winner over E2B/Luchador; fitted gates remain replay-only | [Report](2026-10-10-calibration/REPORT.md), [examples](2026-10-10-calibration/EXAMPLES.md) |
| Midword conditioning probes and atomic last-token healing | Forced spelling verdicts, canonical conditioning and last-token variants did not generalize; atomic lost English quality and was rejected | [Rejected study](2026-10-10-midword/REPORT.md) |
| Bounded prefix-only search | Independent fresh confirmation improves Serbian Latin for both E2B and Luchador; integrated behind the experimental switch | [Latest report](2026-10-10-prefix-search/REPORT.md), [examples](2026-10-10-prefix-search/EXAMPLES.md) |
| E2B latency reuse, thread counts, prewarm and cancellation | Eleven new replay-only variants; best confirmed mean/p95 67.0/142.4→51.6/98.9 ms with identical outputs. Thread/cancellation tradeoffs remain; no installed-app change | [Report](2026-10-11-latency/REPORT.md), [examples](2026-10-11-latency/EXAMPLES.md), [raw archive](2026-10-11-latency.tar.gz) |
| Earlier consolidated interpretation | Preserved to show the proposals that led to calibration and the later tests; superseded where those tests now have outcomes | [Historical aggregate](2026-10-10-aggregate/REPORT.md) |

The 10 October prefix-search study held models, raw prompt bytes, sampler and six-token/four-word budgets fixed. All four arms showed 250/288 suggestions, 125/144 per language. E2B Serbian useful/poor counts improved 61/33→74/17 out of 96 midword cases; English useful improved 71→81. E2B mean/p95 native latency increased 55.3/88.4→71.0/145.4 ms. Luchador improved Serbian 55/39→68/25; English useful stayed 90; mean/p95 increased 85.5/140.0→100.4/224.2 ms. The gain costs latency and retains individual regressions.

All 10 October frozen corpora, raw JSONL runs, rejected attempts, judge packets/responses/receipts, source snapshots, build logs and analysis files are in the [complete archive](2026-10-10-experiments.tar.gz). Its [SHA-256 manifest](2026-10-10-experiments-manifest.json) lists every member. This includes the archived research runtime for reproducing discarded modes without adding them to the shipped app. GGUF weights and app binaries are identified by hashes rather than redistributed. The prior native-hybrid archive retains its attribution and Cotabby license. The new model and midword corpora are synthetic.

Some links in browsable historical reports download the archive; [the link map](2026-10-10-archived-links.json) gives their original member paths. Browsable copies normalize trailing whitespace and repair broken source links; the archive retains the original text. For an exact historical report, extract the archive into a separate directory:

```sh
mkdir -p /tmp/lokalbot-autocomplete-evidence
tar -xzf Benchmarks/Cotyping/results/2026-10-10-experiments.tar.gz \
  -C /tmp/lokalbot-autocomplete-evidence
```

Top-level benchmark Python scripts and fixtures are also checked in. Historical runner defaults point at dated local binaries and model paths; use the recorded pins, a new output directory, and the appropriate archived source to reproduce a study. A rerun must not overwrite frozen evidence. Only synthetic text should be sent to an external judge under explicit authorization.

[PR integration validation](2026-10-10-pr-integration/VALIDATION.md) separates the installed app and final branch checks from the original benchmark binaries. No new blind quality sample is implied by a byte-for-byte integration parity check.
