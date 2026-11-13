# Hosted vs local autocomplete, full held-out set — 2026-10-06

Asked through chat, Qwen3.8 27B on Cerebras is the only hosted option that
beats local Gemma 4 E2B Base on every set without collapsing mid-word: **+2.8
points** of next-word accuracy on the whole held-out corpus (34.5% → 37.3%),
**+4.5** on the 32-scenario set (not significant at that size), and level on
mid-word completion, at a **235 ms** median through OpenRouter (local: 61 ms).
The raw-continuation candidates gain at most 1.6 points and fall apart
mid-word.

Same production prompt, normalizer and scorer for every engine; only the
generation backend differs (`remote_comparison.py --via-openrouter
--per-category 0 --midword-per-category 5`). Raw-continuation requests use
boundary healing. The chat route sends the app's autocomplete instruction as
the system message and the rendered prompt as the user message, with thinking
off. Paired 95% intervals resample whole phrases, stratified by category. The
local result reproduces the 2026-10-02 held-out figure exactly (2,300 / 6,667).

## Next word, whole held-out set (6,667 checkpoints)

| Engine | Next word | Δ vs local (95% CI) | 2 words | 3 words | Shown | p50 | p95 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Gemma 4 E2B Base, local | 34.50% | – | 12.05% | 4.26% | 99.8% | 61 ms | 79 ms |
| **Qwen3.8 27B, Cerebras, chat** | **37.30%** | **+2.80** (+1.76 to +3.85) | 14.88% | 5.43% | 87.6% | 235 ms | 486 ms |
| Qwen3.8 27B, CoreWeave, raw | 36.06% | +1.56 (+0.79 to +2.34) | 14.06% | 5.64% | 94.6% | 424 ms | 557 ms |
| Nemotron 3.5 Lightning, CoreWeave, raw | 35.91% | +1.41 (+0.55 to +2.25) | 14.10% | 5.71% | 95.4% | 264 ms | 303 ms |
| GLM 5.3 Flash, Together, raw | 35.61% | +1.11 (+0.26 to +2.01) | 13.51% | 5.29% | 95.3% | 313 ms | 1,041 ms |
| DeepSeek V4.1 Flash, Together, raw | 34.83% | +0.33 (−0.53 to +1.22) | 12.45% | 4.56% | 94.2% | 243 ms | 326 ms |

The chat route returned an empty reply on 12% of checkpoints, counted as
misses. When it did suggest, the first word was right 42.6% of the time,
against 34.6% for local.

| Category | Local | Qwen chat | Qwen raw | Nemotron | DeepSeek | GLM |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| conversation | 38.6% | 34.1% | 38.4% | 35.7% | 37.2% | 38.2% |
| entertainment | 31.9% | 35.5% | 32.5% | 33.0% | 31.7% | 32.1% |
| everyday | 34.4% | 36.7% | 35.3% | 36.6% | 33.0% | 35.7% |
| science | 43.5% | 48.1% | 45.1% | 44.3% | 42.6% | 44.6% |
| technology | 29.9% | 32.3% | 31.8% | 30.1% | 31.7% | 30.9% |
| travel | 32.9% | 36.5% | 34.3% | 35.9% | 35.0% | 34.9% |
| work | 31.4% | 37.8% | 35.6% | 36.1% | 33.2% | 33.7% |

## Challenge set (32 scenarios, 178 checkpoints)

| Engine | Next word | Δ vs local (95% CI) | 2 words | 3 words | p50 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Gemma 4 E2B Base, local | 46.63% | – | 15.75% | 5.26% | 54 ms |
| **Qwen3.8 27B, Cerebras, chat** | **51.12%** | +4.49 (−1.15 to +10.33) | 17.12% | 7.02% | 236 ms |
| Nemotron 3.5 Lightning | 46.63% | +0.00 (−5.06 to +5.06) | 19.86% | 8.77% | 259 ms |
| DeepSeek V4.1 Flash | 44.94% | −1.69 (−6.74 to +3.45) | 17.12% | 7.89% | 240 ms |
| GLM 5.3 Flash | 42.13% | −4.49 (−9.77 to +1.12) | 17.12% | 7.02% | 360 ms |
| Qwen3.8 27B, CoreWeave, raw | 41.57% | −5.06 (−11.17 to +1.12) | 12.33% | 3.51% | 457 ms |

| Category | Local | Qwen chat | Qwen raw | Nemotron | DeepSeek | GLM |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| email | 53.8% | 53.8% | 51.9% | 59.6% | 53.8% | 51.9% |
| formatting | 48.7% | 51.3% | 38.5% | 48.7% | 46.2% | 46.2% |
| long-context | 27.7% | 38.3% | 29.8% | 27.7% | 27.7% | 21.3% |
| multilingual | 57.5% | 62.5% | 45.0% | 50.0% | 52.5% | 50.0% |

## Mid-word completion (767 checkpoints, 35 phrases)

| Engine | Correct | Δ vs local (95% CI) | Shown |
| --- | ---: | ---: | ---: |
| Gemma 4 E2B Base, local | 72.10% | – | 100% |
| **Qwen3.8 27B, Cerebras, chat** | **70.66%** | −1.43 (−6.60 to +3.93) | 97.1% |
| Nemotron 3.5 Lightning, raw | 27.12% | −44.98 | 30.8% |
| Qwen3.8 27B, CoreWeave, raw | 25.81% | −46.28 | 30.0% |
| GLM 5.3 Flash, raw | 22.82% | −49.28 | 27.6% |
| DeepSeek V4.1 Flash, raw | 19.69% | −52.41 | 24.9% |

Raw continuation cannot be forced to re-type a half-typed word the way the
local runtime does, so healed raw requests miss most fragments, and unhealed
ones get mangled ("I di" → "I diived"). In chat, the fragment is just part of
the user's text, and the model completes it.

## Direct Cerebras API (same checkpoints, same local baseline)

| Engine | Next word (Δ, 95% CI) | Challenge (Δ) | Mid-word (Δ) | Shown | p50 | p90 | p95 |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: |
| Qwen3.8 27B, chat | 37.21% (**+2.71**, +1.68 to +3.78) | 50.56% (+3.93, n.s.) | 70.66% (−1.43, n.s.) | 87.7% | 212 ms | 321 ms | 417 ms |
| Qwen3.8 27B, raw | 35.83% (+1.33, +0.53 to +2.12) | 45.51% (−1.12) | 25.81% (−46.28) | 94.6% | 210 ms | 314 ms | 426 ms |
| gpt-oss-120b, chat, low reasoning | 28.81% (−5.68, −6.77 to −4.57) | 33.15% (−13.48) | 47.20% (−24.90) | 99.8% | 238 ms | 364 ms | 480 ms |

- The chat result reproduces the OpenRouter run (+2.71 vs +2.80), and going
  direct saves about 23 ms at the median.
- Raw continuation on Cerebras scores like raw on CoreWeave (+1.33 vs +1.56),
  so chat's lead comes from asking through chat, not from the host.
- gpt-oss-120b is worse than local on every set.
- Gemma 4 31B answered 404 `model_archived` on Cerebras.
- Two rate-limit retries per Qwen run at about 7.5 requests per second across
  both runs.

## Why chat beats raw for the same weights

Same model, same host: Qwen3.8 27B on Cerebras scored +2.71 through chat and
+1.33 through raw continuation. Hosted models are instruction-tuned and
continue a message better than a bare text stream; in chat, a half-typed word
is part of the user's text rather than a token boundary. The other hosted
models were only tested raw and might do better through chat.

## Which allowed models could be tried

| Model | Outcome |
| --- | --- |
| Qwen3.8 27B | Cerebras through chat (raw is rejected: OpenRouter adds `reasoning_effort`); CoreWeave through raw |
| Nemotron 3.5 Lightning, DeepSeek V4.1 Flash, GLM 5.3 Flash | Run above, raw only |
| Gemma 4 31B (and free) | ModelRun rejects raw completions; Friendli, CoreWeave fp4 and Parasail fp8 continue raw text as gibberish; Crusoe and the free endpoint were rate-limited |
| Nemotron 3.5 Lightning (free) | Its only endpoint trains on prompts, excluded by the no-retention rule |
| GPT Luna Latest | Every OpenAI endpoint excluded by the no-retention rule; p50 time to first token 1.6 s |
| Qwen3.8 Flash | Alibaba rejects raw completions; p50 3.7 s |
| Gemini 3.8 Flash, GLM 5.3 FlashX, Muse Spark 1.3 Contributor | Chat only with mandatory reasoning, 1.5–5.5 s to first token |

## Notes

- Raw-continuation suggestions are withheld when the output does not re-type
  the healed boundary (4.5–5.5% of word checkpoints); chat replies were empty on
  12%. Both count as misses.
- Thinking has to be off for the chat route: left at its default, Qwen spent
  the whole reply budget thinking and returned nothing.
- GLM 5.3 Flash hit 163 rate-limit retries and one unrecovered error; its p95
  is above one second.
- Latency is the full request from this Mac through OpenRouter. Local latency
  is warm in-process generation. Neither includes debounce, Accessibility reads
  or drawing.
- Cost: about $0.10 per 1,000 suggestions for the Cerebras chat route at these
  prompts (about 90 input tokens each), under $0.05 for the others. Prompts with
  screen or meeting context run longer.
- Scoring is exact lexical match on synthetic text; it penalizes valid
  alternative wording and does not measure acceptance.
