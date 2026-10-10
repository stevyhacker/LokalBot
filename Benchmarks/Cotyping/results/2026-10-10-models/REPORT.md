Historical experiment snapshot. Current adoption: **E2B remains the default; the experimental switch enables hybrid plus prefix search.** See [the trial guide](../../../../Docs/experimental-autocomplete-hybrid.md). Complete raw evidence and the original, unedited report are in [the experiment archive](../2026-10-10-experiments.tar.gz). Archive member paths are listed in [the manifest](../2026-10-10-experiments-manifest.json).

# Five-model autocomplete evaluation — 10 October 2026

Measured on this Mac with the exact installed Release app. The five candidate models used the same hybrid decoder, completion prompt, six-token generation budget and four-word display limit. The installed Gemma 4 E2B model is the primary control; the original decoder is an additional control.

## Outcome

**Gemma 4 E4B Luchador is the strongest quality candidate. Keep the installed E2B hybrid as the default while evaluating an optional writing-quality mode.** Luchador's gain replicated on the independent set: 109 useful suggestions versus 84, and 15 poor suggestions versus 19. That is 25 additional useful suggestions across 160 checkpoints, with a positive phrase-bootstrap utility interval. It costs about 28 ms more per warm request, a 6.33 GB model instead of 3.85 GB, and substantially slower processing of a new long prefix.

The result is strongest in English. Serbian Latin also looks promising, but **Serbian Cyrillic regresses on both splits**. The fine-tune is a useful lead for the feature, rather than evidence for replacing the default for all languages. Exact first-word matches tied at 72/160 on confirmation: Claude's preference reflects more plausible alternatives and useful visible text, not a demonstrated increase in predicting the writer's exact next word.

Completed **8,556 native requests**, including 460 excluded warmups: zero inference errors and zero changed outputs across repeats. Claude Opus 5.5 judged the suggestions anonymously and separately reviewed the aggregate results. Model choice in the installed app remains Gemma 4 E2B with the experimental hybrid enabled. The PR and its CI were left alone.

## Changes worth pursuing

1. **Calibrate confidence at matched coverage before changing models.** Compare E2B and Luchador at two or three equal suggestion rates, using a separate development corpus and thresholds per language/script. This follows the evaluation approach in [Smart Compose](https://arxiv.org/html/1906.00080v1#S3.SS4). Luchador is much more willing to show a word-boundary suggestion under the inherited gates. Some of the benefit may be achievable with E2B at lower cost; that remains a hypothesis. Partial-word suggestions need separate treatment because the current first-word confidence gate is bypassed during token healing.
2. **Run a small, blinded human trial of an English quality option.** Measure acceptance, dismissals, distraction and actual characters saved. Retain E2B for Cyrillic during that trial. The measured quality gain supports trying Luchador, but a single model judge does not establish user preference. The manual language-specific choice assessed below is evidence for a possible option, not a tested automatic router.
3. **Measure and reduce new-prefix latency for the larger model.** In the long-context test, Luchador averaged 474 ms on the first request after a language/context change, then 84 ms while reusing the shared prefix; E2B took 216 ms and 48 ms respectively. Check how effectively the app's existing focus prewarm hides that first cost, then test bounded context trimming with a quality check. These are headless timings, not measured UI delays. Simply switching to LFM or Qwen for speed is unattractive here: both lose quality and their long-prefix mean latency is worse in the current runtime.

A subsequent training experiment should use **short prefix-to-continuation examples**, including Serbian Cyrillic and explicit malformed/repeated continuation negatives, on an E2B-sized model. That offers a plausible route to Luchador-like writing behavior without its larger runtime cost. No such adapter was trained here; the existing fine-tune's results do not isolate the contribution of its writing LoRA. The [research notes](RESEARCH.md) distinguish the supporting papers, model-card claims and these untested proposals.

Claude's independent recommendation also favors keeping E2B, testing matched-coverage calibration and human acceptance, and investigating long-context latency before promotion. [Raw Claude advisory](claude-advice/ADVICE.md). Its reference to a previously observed “~200 ms speed cliff” has no supporting evidence in this study and is excluded from these conclusions; its causal claims about post-training are treated as hypotheses.

## Main comparison: 320 checkpoints, 64 phrases

Useful means Claude utility > 0; poor means utility < 0 (worse than silence). Neutral suggestions and silence have utility 0. Utility ranges from −2 to +2 and is averaged over **all checkpoints**, including silence. This is model-rated usefulness, not a human acceptance rate.

| Model | Useful / 320 | Poor / 320 | Mean utility | Warm mean / p95 | Model file |
|---|---:|---:|---:|---:|---:|
| Gemma 4 E2B + hybrid (installed) | 159 | 31 | 0.603 | 46.1 / 81.2 ms | 3.85 GB |
| LFM2.5 1.2B Base | 111 | 64 | 0.172 | 18.2 / 34.9 ms | 0.96 GB |
| Qwen3.5 2B Base | 142 | 34 | 0.472 | 32.1 / 53.8 ms | 1.56 GB |
| LFM2.5 2.6B Base | 131 | 44 | 0.353 | 38.6 / 64.1 ms | 2.22 GB |
| Gemma 4 E4B Base | 161 | 30 | 0.634 | 69.1 / 123.6 ms | 6.22 GB |
| Gemma 4 E4B Luchador | 218 | 27 | 0.947 | 76.1 / 121.2 ms | 6.33 GB |

Each model ran three serial, reordered timing rounds (960 timed requests). Outputs were identical across repeats. Quality has 320 unique checkpoints grouped into 64 phrases; the bootstrap treats phrases as the resampling units. Repeated requests are not additional independent quality judgments. Ten warmup calls per process were excluded.

| Candidate vs installed hybrid | Utility delta, 95% phrase-bootstrap interval | Wins / ties / losses | Latency delta |
|---|---:|---:|---:|
| LFM2.5 1.2B Base | -0.431 [-0.606, -0.263] | 43 / 179 / 98 | -27.9 ms |
| Qwen3.5 2B Base | -0.131 [-0.269, -0.003] | 56 / 187 / 77 | -14.1 ms |
| LFM2.5 2.6B Base | -0.250 [-0.394, -0.103] | 43 / 194 / 83 | -7.5 ms |
| Gemma 4 E4B Base | +0.031 [-0.069, +0.134] | 51 / 229 / 40 | +22.9 ms |
| Gemma 4 E4B Luchador | +0.344 [+0.166, +0.503] | 129 / 132 / 59 | +30.0 ms |

Screening intervals are exploratory, unadjusted for selecting among five candidates. The confirmation split below is the independent check.

## Independent confirmation: 160 checkpoints, 32 new phrases

| Model / decoder | Useful / 160 | Poor / 160 | Mean utility | Warm mean / p95 | First-word reference matches |
|---|---:|---:|---:|---:|---:|
| Gemma 4 E2B + original decoder | 69 | 18 | 0.550 | 43.4 / 84.0 ms | 64 |
| Gemma 4 E2B + hybrid (installed) | 84 | 19 | 0.631 | 48.1 / 84.8 ms | 72 |
| Gemma 4 E4B Luchador | 109 | 15 | 1.006 | 75.6 / 121.3 ms | 72 |

Finalist versus installed hybrid: **67 wins, 64 ties, 29 losses**. Utility delta +0.375, 95% interval [+0.150, +0.600]. Warm latency delta +27.5 ms, interval [+22.9, +32.3]. These intervals resample whole phrases (5,000 samples).

## Language matters

| Model | English useful / poor (240) | Serbian useful / poor (80) | English / Serbian mean utility |
|---|---:|---:|---:|
| Gemma 4 E2B + hybrid (installed) | 128 / 21 | 31 / 10 | 0.675 / 0.388 |
| LFM2.5 1.2B Base | 111 / 31 | 0 / 33 | 0.500 / -0.812 |
| Qwen3.5 2B Base | 120 / 22 | 22 / 12 | 0.579 / 0.150 |
| LFM2.5 2.6B Base | 121 / 19 | 10 / 25 | 0.596 / -0.375 |
| Gemma 4 E4B Base | 129 / 21 | 32 / 9 | 0.696 / 0.450 |
| Gemma 4 E4B Luchador | 184 / 7 | 34 / 20 | 1.146 / 0.350 |

Serbian is evenly split between Latin and Cyrillic scripts. Detailed script, category and partial-word breakdowns are in the analysis JSON.

The confirmation set makes the script difference concrete:

| Writing group | Installed useful / poor | Luchador useful / poor | Mean utility: installed → Luchador |
|---|---:|---:|---:|
| English, 120 checkpoints | 67 / 10 | 90 / 5 | 0.733 → 1.175 |
| Serbian Latin, 20 checkpoints | 10 / 2 | 14 / 1 | 0.600 → 1.200 |
| Serbian Cyrillic, 20 checkpoints | 7 / 7 | 5 / 9 | 0.050 → -0.200 |

On screening, Cyrillic poor suggestions were 18/40 for Luchador versus 7/40 for E2B. The same direction persisted on confirmation. Failures occur at both word boundaries and partial words; a simple ban on changing scripts would not catch malformed words that remain in Cyrillic. Each confirmation script subgroup contains only four phrases, so larger native-speaker evaluation is needed.

The conservative policy frozen after screening—Luchador for English, E2B for all Serbian—produced **107 useful and 14 poor** suggestions on confirmation, versus **84 useful and 19 poor** for E2B throughout. Its utility delta was +0.331 [95% interval +0.138, +0.531]. It gives up the observed Serbian Latin gains. A script-specific choice is a further hypothesis, not an independently confirmed routing policy. All combinations here use known fixture labels; no detector, live switching latency or dual-model memory behavior was implemented or measured. See [language-policy-analysis.json](language-policy-analysis.json).

## Longer documents change the latency ranking

The same 32 synthetic checkpoints were also run with roughly 1,930–2,317 characters of preceding text. This is a separate latency stress test, not quality-selection data. Two repeat rounds were added after the first pass showed a ranking reversal.

| Model | Long-context mean / p95 | Short-prefix mean | Peak process RSS |
|---|---:|---:|---:|
| Gemma 4 E2B + hybrid (installed) | 63.5 / 221.6 ms | 46.1 ms | 3.85 GiB |
| LFM2.5 1.2B Base | 106.1 / 170.6 ms | 18.2 ms | 1.05 GiB |
| Qwen3.5 2B Base | 158.2 / 236.9 ms | 32.1 ms | 1.70 GiB |
| LFM2.5 2.6B Base | 233.4 / 354.9 ms | 38.6 ms | 2.27 GiB |
| Gemma 4 E4B Base | 106.6 / 414.7 ms | 69.1 ms | 6.13 GiB |
| Gemma 4 E4B Luchador | 120.3 / 510.0 ms | 76.1 ms | 6.24 GiB |

LokalBot preserves shared prompt KV for attention models, but fully reprocesses prefixes for recurrent/hybrid models. The measured reversal is consistent with that implementation; this study did not isolate every source of latency. RSS is peak process resident memory from `/usr/bin/time -l`, not total system or incremental GPU memory.

This stress test includes three fresh language/context transitions per round and 29 requests with shared preceding context. The model is prewarmed, but the full document is not prefilled before a context transition. Existing production focus prewarm may move some of that cost earlier. The high p95 therefore must not be presented as an observed UI delay. Transition timings are saved in [long-context-transitions.json](long-context-transitions.json).

## Examples you can rate yourself

These are held-out examples selected by fixed hash within English/Serbian wins, losses and ties. The displayed continuation is appended directly at the caret; a short suffix can finish a partially typed word. Scores are Claude’s judgments, not reference-match scores.

| Typed text before caret | Installed Gemma + hybrid | Gemma 4 E4B Luchador | Claude utility: installed → candidate |
|---|---|---|---:|
| `The soup needs a ▏` | *(silence)* | `little more flavor.` | 0 → 2 |
| `Let me know when you arrive and I will come ▏` | *(silence)* | `to meet you.` | 0 → 2 |
| `I just got back to my desk ▏` | `after a long weekend` | `and I'm feeling a` | 1 → -1 |
| `This check prevents a delayed resp▏` | `onse to a request` | `onse from a service,` | 2 → 1 |
| `The proposed schedule gives us enough ▏` | `time to prepare for` | `time to complete the` | 1 → 1 |
| `Ostavio sam knjigu na stolu pored ▏` | *(silence)* | `kreveta.` | 0 → 2 |
| `Ostavio sam knjigu ▏` | *(silence)* | `na stolu, ali nisam` | 0 → 1 |
| `Можемо да поделимо задатке на мање целине и проверимо ▏` | `да ли је свака` | `сваки поједини.` | 1 → -1 |
| `Јави ми када стигнеш на станицу па ћу доћи ▏` | `да те чекам.` | `да те поузмем.` | -1 → -2 |
| `Možeš da promeniš jezik u podešavanjima bez pono▏` | `vnog pokretanja.` | `vnog pokretanja aplikacije` | 2 → 2 |

Every result, including failures and neutral suggestions, is in [all-comparisons.csv (archive)](../2026-10-10-experiments.tar.gz) and [all-comparisons.json (archive)](../2026-10-10-experiments.tar.gz).

## Judge reliability and limits

- Screen: exact score agreement on 85/112 repeated anonymous options; positive/neutral/negative agreement on 100/112. The numeric ratings disagreed with the supplied preference list in 0 cases; analysis uses the validated numeric ratings consistently.
- Confirmation: exact score agreement on 24/27 repeated anonymous options; positive/neutral/negative agreement on 25/27. The numeric ratings disagreed with the supplied preference list in 0 cases; analysis uses the validated numeric ratings consistently.

- Actual judge model IDs are recorded in every batch receipt; the study requested Claude Opus 5.5. The judge saw only synthetic typed prefixes and anonymous actual continuations. Identical suggestions were deduplicated within a case. No reference futures, model labels, latency, source code or personal writing entered the judge packets.
- All phrases were written by the implementing assistant, so this is a small synthetic evaluation with one model judge. Repeated ratings measure only some judge variability. It does not establish human acceptance, daily typing savings, battery life or generalization to every app.
- The inherited confidence gates (.1 primary, .31 fallback) and six-token budget are fixed across tokenizers. This is a deployable replacement test, not each model’s maximum possible quality. Reference mismatch can still be a useful suggestion. A token budget is not an equal word budget across models.
- Warm latency includes token healing, native generation, confidence filtering and normalization. It excludes model load, keyboard capture, debounce and overlay rendering. The original decoder can publish earlier streamed text; these measurements compare final normalized requests, not first-visible UI latency. Normal desktop background activity was present.
- Q6_K files use different quantizers/calibration data; the weights and exact hashes, rather than an abstract model family, are what were tested. Luchador differs from E4B base in instruction tuning, writing adaptations and quantization. A gain cannot be attributed solely to a particular LoRA technique.
- The short-suggestion sensitivity analysis zeros positive benefit for suggestions of three or fewer visible characters. It is deliberately conservative for partial-word completions; see the analysis JSON.

## Reproducibility and validation

- Runtime executable SHA-256: `29a8cec1971d86b877dfa910f01b82fddd587a42e2532712b5841551e7612eeb`. This is a copy of the installed Release binary from application source commit `cf7a6b26b90b23357d22ecf39892786a6e597208`; the later PR commit changed UI test code only.
- Hardware: Apple M4 Max, 48 GiB memory, macOS 27.0.1; AC power. Exact environment and fixed settings are in [plan.json](plan.json). Model revisions, byte sizes and SHA-256 hashes are in [models.json](models.json).
- Every production replay validates request IDs, complete output, errors, native hybrid flags, unchanged prompt bytes across models, and exact repeated outputs. All model downloads matched the published whole-file hashes. Frozen case and script hashes were checked again.
- The prototype compatibility/pilot runs are preserved under `provenance/` and excluded from all reported timings and model selection. Main results were restarted with the exact installed binary. The two complete pilot outputs matched the corresponding installed-runtime outputs.
- Five existing judge-validator tests passed. Independent harness checks covered partial-word character credit, alternative continuations, silence, phrase clustering and absence of future-reference fields in native/judge inputs. Python compilation and whitespace checks passed. No local UI tests were run.
- Primary raw data: `screen-<round>-<model>/`; independent confirmation: `confirmation-<round>-<model>/`; longer-context checks: `long-context-<round>-<model>/`. Each contains inputs, JSONL observations, diagnostic logs and receipts. Judge packets, raw responses, validated ratings and blind repeats are preserved in `judge-screen/` and `judge-confirmation/`.
- Evaluation code: [model_study.py](../../model_study.py); frozen corpus: [model-study-corpus.json](model-study-corpus.json). The harness intentionally pins a local archived executable and exact model hashes. To reproduce on another machine, supply those pinned artifacts and record any runtime substitution as a different experiment.

Research sources, candidate rationale and excluded fine-tunes: [RESEARCH.md](RESEARCH.md).

Claude-selected follow-up models and papers, independently checked and queued but not yet benchmarked: [CLAUDE-TEST-LIST.md](CLAUDE-TEST-LIST.md).
