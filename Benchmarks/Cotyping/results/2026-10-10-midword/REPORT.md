Historical experiment snapshot. Current adoption: **E2B remains the default; the experimental switch enables hybrid plus prefix search.** See [the trial guide](../../../../Docs/experimental-autocomplete-hybrid.md). Complete raw evidence and the original, unedited report are in [the experiment archive](../2026-10-10-experiments.tar.gz). Archive member paths are listed in [the manifest](../2026-10-10-experiments-manifest.json).

# Rejected atomic last-token experiment

Fresh blind evaluation rejected atomic last-token healing. It is retained only as an explicit replay control. After this rejection the source default was temporarily returned to the original decoder. A subsequent independent [prefix-search confirmation](../2026-10-10-prefix-search/REPORT.md) passed and is the current source default.

All arms showed exactly 250/288 suggestions, 125/144 per language. Models, raw prompts, six free tokens, sampler and four-word display budget were fixed.

| Arm | Useful / poor | Mean / p95 ms |
|---|---:|---:|
| baseline-control | 170 / 52 | 56.6 / 88.3 |
| baseline-fixed | 154 / 71 | 53.4 / 79.4 |
| luchador-control | 180 / 54 | 82.2 / 132.9 |
| luchador-fixed | 168 / 71 | 78.2 / 122.1 |

Here `fixed` labels the rejected atomic experiment, not a promoted implementation. English midword utility fell from 1.010 to 0.406 for E2B and 1.302 to 0.625 for Luchador. Serbian Latin midword utility stayed 0.500 for E2B and changed only 0.323 to 0.354 for Luchador.

The diagnostic examples improved, but those improvements did not generalize. Neither model supports adopting this change.

Method: [plan](plan.json), [frequency adjustment](frequency-amendment.json), [analysis](analysis.json), [judge receipts (archive)](../2026-10-10-experiments.tar.gz), and [implementation decision before inference](decision.json). The one naturally suppressed Luchador English midword suggestion was offset by one additional word-boundary suggestion, using unlabeled confidence only. No quality label set a gate.

115 focused Swift tests, including real-model regression and disabled-fix checks, passed; 61 Python tests and strict changed-file Swift lint passed. Twelve timing runs matched traced outputs and had no output drift. The control matched the immutable previous binary on all 296 warmup/evaluation requests. These checks establish implementation consistency, not suggestion quality.

No app installation, PR update or CI action occurred. This result remains a rejected experiment.
