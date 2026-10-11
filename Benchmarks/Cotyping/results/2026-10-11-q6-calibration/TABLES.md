## Warm native generation and equal-frequency quality

| Q6 variant | Warm mean / p95, ms | Matched mean / p95, ms | EN utility | SR Latin utility | Helpful / poor | Overall utility delta [95% interval] |
|---|---:|---:|---:|---:|---:|---:|
| Current mradermacher i1 Q6 | 51.7 / 103.9 | 52.1 / 106.0 | 1.056 | 0.688 | 184 / 21 | +0.000 [+0.000, +0.000] |
| mradermacher static Q6 | 52.4 / 105.6 | 52.1 / 103.3 | 1.035 | 0.646 | 177 / 23 | -0.031 [-0.087, +0.024] |
| Local static Q6 | 52.4 / 104.7 | 52.1 / 102.9 | 1.035 | 0.646 | 177 / 23 | -0.031 [-0.087, +0.024] |
| Local English-calibrated Q6 | 52.2 / 105.2 | 51.9 / 104.2 | 1.035 | 0.674 | 181 / 21 | -0.017 [-0.059, +0.021] |
| Local EN/SR Latin Q6 | 52.6 / 106.1 | 51.7 / 104.6 | 1.035 | 0.639 | 179 / 23 | -0.035 [-0.080, +0.007] |
| Animateus Q6 | 52.1 / 105.1 | 51.8 / 104.2 | 1.028 | 0.632 | 178 / 25 | -0.042 [-0.090, +0.003] |
| Sporky Q6 | 52.3 / 104.7 | 52.0 / 104.0 | 1.035 | 0.646 | 177 / 23 | -0.031 [-0.087, +0.024] |

## Per-language quality at equal frequency

| Variant | EN helpful / poor | EN delta [95% interval] | SR Latin helpful / poor | SR Latin delta [95% interval] |
|---|---:|---:|---:|---:|
| Current mradermacher i1 Q6 | 101 / 3 | +0.000 [+0.000, +0.000] | 83 / 18 | +0.000 [+0.000, +0.000] |
| mradermacher static Q6 | 100 / 5 | -0.021 [-0.069, +0.021] | 77 / 18 | -0.042 [-0.146, +0.062] |
| Local static Q6 | 100 / 5 | -0.021 [-0.069, +0.021] | 77 / 18 | -0.042 [-0.146, +0.062] |
| Local English-calibrated Q6 | 98 / 3 | -0.021 [-0.056, +0.014] | 83 / 18 | -0.014 [-0.090, +0.062] |
| Local EN/SR Latin Q6 | 99 / 4 | -0.021 [-0.069, +0.021] | 80 / 19 | -0.049 [-0.125, +0.021] |
| Animateus Q6 | 98 / 4 | -0.028 [-0.076, +0.014] | 80 / 21 | -0.056 [-0.139, +0.021] |
| Sporky Q6 | 100 / 5 | -0.021 [-0.069, +0.021] | 77 / 18 | -0.042 [-0.146, +0.062] |

## Controlled calibration comparisons

| Candidate minus control, matched frequency | Overall delta [95% interval] | EN delta [95% interval] | SR Latin delta [95% interval] |
|---|---:|---:|---:|
| english-vs-local_static | +0.014 [-0.028, +0.059] | +0.000 [-0.035, +0.042] | +0.028 [-0.062, +0.125] |
| bilingual-vs-local_static | -0.003 [-0.049, +0.042] | +0.000 [-0.035, +0.042] | -0.007 [-0.104, +0.090] |
| bilingual-vs-english | -0.017 [-0.045, +0.007] | +0.000 [-0.021, +0.021] | -0.035 [-0.090, +0.007] |
| sporky-vs-static | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] | +0.000 [+0.000, +0.000] |

## Longer fields, typing and cancellation

| Variant | Long-field mean / p95, ms | Typing mean / p95, ms | Cancellation through replacement, paired mean Q6 → variant, ms | Peak RSS GB |
|---|---:|---:|---:|---:|
| Current mradermacher i1 Q6 | 162.0 / 261.1 | 53.9 / 110.7 | 269.4 → 269.4 | 4.16 |
| mradermacher static Q6 | 171.4 / 278.5 | 52.4 / 105.1 | 272.0 → 279.5 | 4.15 |
| Local static Q6 | 181.7 / 293.2 | 51.9 / 104.3 | 272.0 → 255.5 | 4.16 |
| Local English-calibrated Q6 | 167.9 / 265.0 | 52.5 / 102.7 | 272.0 → 253.9 | 4.16 |
| Local EN/SR Latin Q6 | 161.6 / 257.0 | 52.1 / 104.7 | 272.0 → 258.0 | 4.15 |
| Animateus Q6 | 168.0 / 265.1 | 52.2 / 106.4 | 272.0 → 256.7 | 4.15 |
| Sporky Q6 | 178.8 / 294.8 | 52.9 / 104.9 | 272.0 → 266.3 | 4.16 |

## Matched confidence gates

| Variant | English primary / fallback | Serbian Latin primary / fallback |
|---|---:|---:|
| Current mradermacher i1 Q6 | 0.10005 / 0.31016 | 0.09625 / 0.29838 |
| mradermacher static Q6 | 0.09900 / 0.30689 | 0.09468 / 0.29352 |
| Local static Q6 | 0.09900 / 0.30689 | 0.09480 / 0.29389 |
| Local English-calibrated Q6 | 0.10265 / 0.31823 | 0.09615 / 0.29808 |
| Local EN/SR Latin Q6 | 0.09951 / 0.30850 | 0.09822 / 0.30447 |
| Animateus Q6 | 0.09883 / 0.30637 | 0.09440 / 0.29263 |
| Sporky Q6 | 0.09900 / 0.30689 | 0.09468 / 0.29352 |
