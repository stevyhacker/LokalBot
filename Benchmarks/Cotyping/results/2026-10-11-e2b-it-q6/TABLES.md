**Native measurements; Claude quality ratings pending**

All matched arms show 112/144 English and 109/144 Serbian Latin suggestions. These timings measure native completion, excluding load, debounce, accessibility and rendering.

| Variant | Warm mean / p95, ms | Matched mean / p95, ms | Matched mean delta [95% interval], ms | Matched shown-only mean / p95, ms |
|---|---:|---:|---:|---:|
| Current E2B base i1 Q6 | 52.5 / 105.7 | 52.0 / 105.0 | +0.00 [+0.00, +0.00] | 61.1 / 107.0 |
| Unsloth E2B IT Q6_K | 51.2 / 99.5 | 45.9 / 101.6 | -6.08 [-8.60, -3.63] | 54.3 / 105.9 |
| Bartowski E2B IT Q6_K | 50.8 / 101.3 | 45.3 / 99.9 | -6.69 [-9.07, -4.36] | 53.5 / 103.3 |

**By language at matched frequency**

| Variant | English mean / p95, ms | Serbian Latin mean / p95, ms | Exact authored first-word matches /288 (not Claude utility) |
|---|---:|---:|---:|
| Current E2B base i1 Q6 | 44.4 / 86.2 | 59.6 / 109.1 | 164 |
| Unsloth E2B IT Q6_K | 36.6 / 69.0 | 55.2 / 110.3 | 141 |
| Bartowski E2B IT Q6_K | 36.4 / 66.4 | 54.2 / 107.3 | 142 |

**Production gates: long fields, typing and cancellation**

| Variant | Long mean / p95, ms | Typing mean / p95, ms | Cancellation return, paired current → candidate, ms | Cancellation through replacement, paired current → candidate, ms | Median peak RSS, GB |
|---|---:|---:|---:|---:|---:|
| Current E2B base i1 Q6 | 156.3 / 241.3 | 52.1 / 107.7 | 32.8 → 32.8 | 238.9 → 238.9 | 4.15 |
| Unsloth E2B IT Q6_K | 162.5 / 254.5 | 53.3 / 103.8 | 33.6 → 40.5 | 241.6 → 249.6 | 4.81 |
| Bartowski E2B IT Q6_K | 156.2 / 251.8 | 51.3 / 103.9 | 33.9 → 39.1 | 243.7 → 239.7 | 4.21 |

Cancellation comparisons include only pairs where both models actually received cancellation and returned cancelled. Each candidate therefore has a different paired baseline; only four source scenarios were used.

**Native confidence gates, fitted without quality labels**

| Variant | EN primary / fallback | SR Latin primary / fallback |
|---|---:|---:|---:|
| Current E2B base i1 Q6 | 0.10005 / 0.31016 | 0.09625 / 0.29838 |
| Unsloth E2B IT Q6_K | 0.49802 / 1.00000 | 0.35126 / 1.00000 |
| Bartowski E2B IT Q6_K | 0.47946 / 1.00000 | 0.34292 / 1.00000 |

The frozen implementation uses fallback = min(1, 3.1 × primary), so both IT fallback thresholds saturate at 1. These cutoffs are evaluation-only; current-Q6 text and all midword outputs remain unchanged.
