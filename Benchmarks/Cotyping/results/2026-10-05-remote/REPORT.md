# Hosted vs local autocomplete — 2026-10-05

Two hosted models, reached through OpenRouter, beat local Gemma 4 E2B Base by
about **3 points of next-word accuracy** on the held-out corpus sample, at
**4–6.5× the latency**. On the 32-scenario challenge set (email, formatting,
earlier facts, multilingual) neither gains. That is not the considerable
improvement the question asked for.

Same production prompt, normalizer and scorer for every engine; only the
generation backend differs (`remote_comparison.py --via-openrouter`). Hosted
requests use boundary healing (see the Cotyping README). Paired 95% intervals
resample whole phrases, stratified by category.

## Held-out corpus sample (30 phrases per category, 1,168 checkpoints)

| Engine | Next word | Δ vs local (95% CI) | 2 words | 3 words | Shown | p50 | p90 | p95 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Gemma 4 E2B Base, local | 32.02% | – | 11.90% | 4.95% | 99.91% | 61 ms | 78 ms | 86 ms |
| Qwen3.8 27B, CoreWeave | 35.10% | **+3.08** (+1.29 to +4.96) | 14.51% | 6.55% | 94.78% | 397 ms | 447 ms | 469 ms |
| Nemotron 3.5 Lightning, CoreWeave | 34.76% | **+2.74** (+0.77 to +4.79) | 14.51% | 6.42% | 95.89% | 270 ms | 315 ms | 397 ms |

| Category | Local | Nemotron | Qwen |
| --- | ---: | ---: | ---: |
| conversation | 32.6% | 29.2% | 31.2% |
| entertainment | 28.7% | 32.5% | 28.7% |
| everyday | 31.5% | 32.7% | 35.2% |
| science | 47.9% | 50.9% | 52.8% |
| technology | 23.1% | 23.1% | 24.7% |
| travel | 34.8% | 38.8% | 38.2% |
| work | 26.7% | 36.4% | 35.2% |

## Challenge set (32 scenarios, 178 checkpoints)

| Engine | Next word | Δ vs local (95% CI) | 2 words | 3 words | Shown | p50 | p95 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Gemma 4 E2B Base, local | 46.63% | – | 15.75% | 5.26% | 99.44% | 55 ms | 96 ms |
| Qwen3.8 27B, CoreWeave | 42.70% | −3.93 (−10.23 to +1.83) | 12.33% | 4.39% | 91.01% | 423 ms | 479 ms |
| Nemotron 3.5 Lightning, CoreWeave | 46.07% | −0.56 (−5.95 to +4.76) | 19.86% | 8.77% | 94.38% | 278 ms | 352 ms |

| Category | Local | Nemotron | Qwen |
| --- | ---: | ---: | ---: |
| email | 53.8% | 59.6% | 51.9% |
| formatting | 48.7% | 48.7% | 41.0% |
| long-context | 27.7% | 25.5% | 34.0% |
| multilingual | 57.5% | 50.0% | 42.5% |

## Notes

- Hosted suggestions are withheld when the output does not re-type the healed
  boundary (4–5% of checkpoints, counted as misses). Even if every one of those
  had been right at the hosted model's usual rate, the corpus gain would stay
  under 5 points.
- Latency is the full request from this Mac through OpenRouter, so it includes
  OpenRouter's hop. Local latency is warm in-process generation. Neither
  includes debounce, Accessibility reads or drawing.
- Qwen3.8 27B ran on CoreWeave (fp8), not Cerebras: OpenRouter adds a
  `reasoning_effort` field that Cerebras's raw completions reject. Quality
  should match; Cerebras's lower latency was not measured. Gemma 4 31B had no
  usable raw-completion route and was not run.
- The first Qwen corpus run stopped with no error after 897 of 1,168 cases (the
  process was ended from outside); it was rerun in full on the same
  checkpoints and paired with the same local run.
- Cost at these short synthetic prompts was about $0.01 per 1,000 suggestions;
  real prompts with screen or memory context are longer.
- Scoring is exact lexical match on synthetic English text. It penalizes valid
  alternative wording and does not measure acceptance.
