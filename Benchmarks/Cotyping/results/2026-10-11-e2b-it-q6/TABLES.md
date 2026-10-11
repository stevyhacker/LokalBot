**Warm timing and matched-frequency quality**

All matched arms show 112/144 English and 109/144 Serbian Latin suggestions. Utility is Claude Opus 5.5 opinion on a −2..2 scale with silence at zero, averaged across every checkpoint. Helpful is utility >0; poor is utility <0. Timing is native completion, excluding model load, debounce, accessibility and rendering. Intervals use 5,000 paired bootstrap draws over 48 bilingual scenarios.

| Variant | Warm mean / p95, ms | Matched mean / p95, ms | EN utility | SR Latin utility | Helpful / poor | Utility delta vs current [95% interval] |
|---|---:|---:|---:|---:|---:|---:|
| Current E2B base i1 Q6 | 52.5 / 105.7 | 52.0 / 105.0 | 1.125 | 0.819 | 191 / 18 | +0.000 [+0.000, +0.000] |
| Unsloth E2B IT Q6_K | 51.2 / 99.5 | 45.9 / 101.6 | 1.215 | 0.271 | 170 / 41 | -0.229 [-0.399, -0.062] |
| Bartowski E2B IT Q6_K | 50.8 / 101.3 | 45.3 / 99.9 | 1.201 | 0.278 | 169 / 42 | -0.233 [-0.396, -0.073] |

**Language-specific quality**

| Variant | EN helpful / poor | EN delta [95% interval] | SR Latin helpful / poor | SR Latin delta [95% interval] |
|---|---:|---:|---:|---:|
| Current E2B base i1 Q6 | 104 / 4 | +0.000 [+0.000, +0.000] | 87 / 14 | +0.000 [+0.000, +0.000] |
| Unsloth E2B IT Q6_K | 107 / 1 | +0.090 [-0.035, +0.222] | 63 / 40 | -0.549 [-0.833, -0.285] |
| Bartowski E2B IT Q6_K | 106 / 1 | +0.076 [-0.042, +0.188] | 63 / 41 | -0.542 [-0.819, -0.285] |

**Matched timing detail**

| Variant | Mean delta [95% interval], ms | Shown-only mean / p95, ms | EN mean / p95, ms | SR Latin mean / p95, ms |
|---|---:|---:|---:|---:|
| Current E2B base i1 Q6 | +0.000 [+0.000, +0.000] | 61.1 / 107.0 | 44.4 / 86.2 | 59.6 / 109.1 |
| Unsloth E2B IT Q6_K | -6.084 [-8.599, -3.632] | 54.3 / 105.9 | 36.6 / 69.0 | 55.2 / 110.3 |
| Bartowski E2B IT Q6_K | -6.686 [-9.069, -4.359] | 53.5 / 103.3 | 36.4 / 66.4 | 54.2 / 107.3 |

**Long fields, typing and cancellation**

| Variant | Long mean / p95, ms | Typing mean / p95, ms | Cancellation return, paired mean current → candidate, ms | Cancellation through replacement, paired mean current → candidate, ms | Median peak RSS GB |
|---|---:|---:|---:|---:|---:|
| Current E2B base i1 Q6 | 156.3 / 241.3 | 52.1 / 107.7 | 32.8 → 32.8 | 238.9 → 238.9 | 4.15 |
| Unsloth E2B IT Q6_K | 162.5 / 254.5 | 53.3 / 103.8 | 33.6 → 40.5 | 241.6 → 249.6 | 4.81 |
| Bartowski E2B IT Q6_K | 156.2 / 251.8 | 51.3 / 103.9 | 33.9 → 39.1 | 243.7 → 239.7 | 4.21 |

Long, typing and cancellation measurements use production gates. Cancellation comparisons include only mutually cancelled pairs; baselines differ by candidate and use only four source scenarios.

**Quality at unchanged production gates (unequal suggestion frequency)**

| Variant | Shown /288 | Helpful / poor | Mean utility |
|---|---:|---:|---:|
| Current E2B base i1 Q6 | 221 | 191 / 18 | 0.972 |
| Unsloth E2B IT Q6_K | 267 | 196 / 54 | 0.802 |
| Bartowski E2B IT Q6_K | 265 | 192 / 54 | 0.788 |

**Native confidence gates fitted without quality labels**

| Variant | EN primary / fallback | SR Latin primary / fallback |
|---|---:|---:|
| Current E2B base i1 Q6 | 0.10005 / 0.31016 | 0.09625 / 0.29838 |
| Unsloth E2B IT Q6_K | 0.49802 / 1.00000 | 0.35126 / 1.00000 |
| Bartowski E2B IT Q6_K | 0.47946 / 1.00000 | 0.34292 / 1.00000 |

The frozen implementation uses fallback = min(1, 3.1 × primary), so both IT fallback thresholds saturate at 1. These cutoffs are evaluation-only; current-Q6 text and all midword outputs remain unchanged.

**Bartowski minus Unsloth at matched frequency**

| Language | Utility difference [95% interval] |
|---|---:|
| all | -0.003 [-0.059, +0.049] |
| en | -0.014 [-0.083, +0.035] |
| sr_latn | +0.007 [-0.076, +0.083] |
