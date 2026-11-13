# Laya Ask/Search evaluation — 2026-09-24

**Decision: do not integrate the shipped Laya checkpoints into LokalBot's Ask/Search routing.** They are fast on this Mac, but their accuracy, false Ask activations, and option-order instability fail the proposed product gates. This does not establish that fine-tuning would fail, or evaluate meeting-outcome extraction or retrieval reranking.

## What was tested

- Apple M4 Max, 16 CPU cores, 48 GiB unified memory, macOS 27.0.
- LokalBot revision `73afd4a8069cf370bf3972ce0ec310153f076554`; the actual `AskIntent` enum was extracted from the source and compiled with `swiftc -O` using Foundation only.
- Laya 0.3.20 at `23a17522aa4942da6cce53a995a275760320b691`; laya-apple 1.0.2 at `e45e40b92a067ffec6ab6e594339e0609adaac85`.
- PyTorch 2.14.0 MPS FP32 and MLX 0.32.2 FP32/FP16. All three checkpoints were tested in all three configurations: nine independent processes, 504 measured calls each (252 primary + 252 reversed-option calls), or 4,536 direct model calls. Additional live router calls confirm the routing comparison.
- All weights were pinned and SHA-256 verified. The pinned weights and encoder/agent JSON configurations match the current standalone Hugging Face repositories at evaluation time. See [manifest.json](manifest.json).
- 240 synthetic, author-labeled query rows: 40 Ask and 40 Search examples in each of English, Serbian Latin, and Serbian Cyrillic. These are 80 translated semantic families, not 240 statistically independent user examples. Twelve cases from the existing AskIntent unit tests are scored separately; some overlap the main fixture.
- One fixed task schema, frozen labels before inference, no prompt tuning, no training, no calibration fitting, no private recordings or screen data. Downloads/metadata checks used Hugging Face; inference used offline flags and local snapshots.

The intended interaction is answer/synthesize versus retrieve a matching item. Difficult search inputs include quoted question-like titles, filenames, code, identifiers, and lone keywords ending in `?`. This is a deliberately challenging diagnostic, not an estimate of production query frequency or general multilingual accuracy.

## Accuracy

Primary option order. All three runtime configurations produce identical primary classifications.

| Strategy | Correct / 240 | Overall | English | Serbian Latin | Serbian Cyrillic | Search incorrectly becomes Ask / 120 | Existing-case failures / 12 |
|---|---:|---:|---:|---:|---:|---:|---:|
| Current Swift heuristic | 144 | 60.0% | 75.0% | 52.5% | 52.5% | 11 (9.2%) | 0 |
| Expanded rules, benchmark only | 194 | 80.8% | 75.0% | 83.8% | 83.8% | 24 (20.0%) | 0 |
| English Laya only | 149 | 62.1% | 83.8% | 50.0% | 52.5% | 6 (5.0%) | 4 |
| Multilingual Laya only | 151 | 62.9% | 61.3% | 61.3% | 66.2% | 37 (30.8%) | 2 |
| Typed-decisions Laya only | 162 | 67.5% | 76.2% | 55.0% | 71.3% | 21 (17.5%) | 3 |
| Default language router | 172 | 71.7% | 83.8% | 63.8% | 67.5% | 22 (18.3%) | 4 |
| Router with fixture language supplied | 169 | 70.4% | 83.8% | 61.3% | 66.2% | 28 (23.3%) | 4 |

The expanded comparator only adds Serbian leading words and two-word imperative handling; it is not an app implementation or an acceptable replacement. It improves recall but doubles false Ask activations versus the existing heuristic. **None of the evaluated strategies meets the predeclared quality gates**: 95% overall, 90% per language, at most 2% false Ask activations, and no existing-case regressions.

Default language detection sends 35/80 Serbian Latin rows to the English checkpoint; some rows contain only shared technical identifiers. Supplying the intended language does not fix the classification problem. Routing scores were first reconstructed from the selected per-checkpoint predictions, then verified through the real PyTorch Router. MLX routing rows in the JSON remain reconstructed; they are not a live multi-model MLX service measurement.

## Concrete failures

- English Laya treats `Who owns the failover benchmark` and `summarize the design review` as Search, regressing existing behavior.
- Multilingual Laya treats `When is the migration due` as Search (71.9% selected-option probability), and also misses its Serbian equivalents.
- Multilingual Laya treats `Sažmi pregled dizajna` and its Cyrillic equivalent as Search.
- Typed-decisions Laya also misses `Who owns the failover benchmark`, and turns `whatever happened` into Ask despite the existing test expecting Search.

These are classification mistakes with valid output structure. The full predictions and error lists are retained in the JSON artifacts.

## Robustness and runtime parity

Reversing the same two option definitions changes **14/240** primary decisions for English Laya, **36/240** for multilingual Laya, and **38/240** for typed-decisions on FP32 (37/240 on MLX FP16). No labels or instructions were otherwise changed. This is a material input-presentation dependency for a user-facing Enter-key decision.

MLX FP32 matches MPS FP32 on all 504 calls for each checkpoint, with maximum probability differences of approximately 0.0001. MLX FP16 matches every primary prediction. Across reversed cases, typed-decisions has one near-tie flip: `Да ли је Ана пристала да пошаље извештај` (`ask-08-sr-Cyrl`); upstream Ask probability is 0.5002 versus MLX FP16 0.4999. This numerical difference is much smaller than the model's task errors. Other FP16 runs have zero decision mismatches; maximum per-option probability differences range from 0.0025 to 0.0066.

Using a 0.9 selected-option-probability threshold and falling back to the existing heuristic does not rescue the result. Multilingual Laya covers only 5.8% of main cases at that threshold and the combined accuracy is 63.8%; English/typed variants stay at 60.0%. These probabilities were not calibrated for this task. The benchmark uses actual selected-option probability, not the differently defined entropy-based `confidence` field. All predeclared thresholds are retained in [summary.json](summary.json).

## Performance

Measured full synchronous single-request calls after five warm-ups; main-set timings only. This is a short-query workload on a working Mac, without isolating other applications or measuring energy. The option-reversal pass is a robustness check, not an additional timing sample in this table.

| MLX FP16 checkpoint | Warm p50 | Warm p95 | Fresh harness to first answer | Process peak RSS | MLX peak allocation |
|---|---:|---:|---:|---:|---:|
| English | 12.1 ms | 12.9 ms | 0.38 s | 0.92 GiB | 0.95 GiB |
| Multilingual | 6.7 ms | 7.3 ms | 1.47 s | 1.08 GiB | 0.67 GiB |
| Typed-decisions | 11.9 ms | 12.6 ms | 0.27 s | 0.92 GiB | 0.95 GiB |

PyTorch MPS FP32 p95 ranges from 15.6 to 24.6 ms; fresh-harness time to first answer ranges from 3.27 to 9.04 s. Its single-model process peak RSS is 2.42–2.76 GiB. MLX FP32 p95 is 7.8–14.9 ms.

The real PyTorch Router confirms all reconstructed classifications (zero mismatches over 504 calls). Default routing measures 18.4 ms p50 / 21.4 ms p95; explicit language hints measure 12.1 / 19.7 ms. Preloading the two resident models takes 3.39 s after imports. Process peak RSS is 2.77 GiB and the final MPS driver allocation is 2.82 GiB; do not add these overlapping measures. These timings are directly measured, unlike the reconstructed MLX routing times in the aggregate JSON.

"Fresh harness" starts at the first timestamp inside the Python script, includes module imports/model initialization/first prediction, and excludes OS process creation and initial standard-library imports. Weights are already downloaded and the filesystem cache was not flushed. These are single cold-process samples, not cold-download or app-launch distributions. RSS and GPU allocation measure different, potentially overlapping parts of unified memory and must not be summed. The Swift rule microbenchmark is below 0.02 ms p95 and has no model footprint.

No ANE conversion or inference was run. The native Swift app was not linked to these Python runtimes, built, installed, or released. Model runtime parity is not end-to-end app integration proof.

## Validation

All nine direct runs contain the expected 504 unique id/order pairs with valid probabilities; the two live router modes add 504 calls, for **5,040 measured inference calls**. Main cases remain balanced by language and label, and the fixture hash is unchanged. The largest reported input is 108 tokens (94 for the multilingual checkpoint), below the default context limits. The extracted production Swift heuristic passes all 12 existing cases. Script compilation, relative artifact links, and whitespace checks passed. See [validation.json](validation.json). No local UI tests were run.

## Recommendation

Keep Laya out of the default stack for this use case. Address the current heuristic's multilingual and title/filename handling with a scoped product change and independently reviewed interaction fixtures. The simple expanded comparator is evidence that inexpensive rules deserve investigation, not code to ship as-is.

Reconsider a specialized classifier only with a representative, independently labeled query set, a separate training/validation/test split, and a meaningful improvement over those inexpensive baselines. The observed speed is sufficient; the remaining problem is reliable decisions. A separate meeting-outcome or reranking evaluation would be needed before drawing conclusions about those uses.

## Artifacts

- [Protocol and reproduction](../../README.md)
- [Frozen fixture](../../cases.jsonl)
- [Harness](../../run.py), [sequential runner](../../run_all.py), [scoring](../../score.py)
- [Exact Python dependencies](../../requirements-lock.txt)
- [Machine, source and weight provenance](manifest.json)
- [Aggregate results, error lists, confidence fallbacks and parity](summary.json)
- `mps-*.jsonl` and `mlx-*.jsonl`: complete direct-model predictions, probabilities and full-call timings.
- `router-mps-*.jsonl`: real upstream Router predictions and routing metadata.
- `*-metrics.json`: initialization, memory, checkpoint and runtime details.
- [Extracted production Swift enum and comparator](baseline-provenance.json)
