# Cotyping model and debounce benchmark — 2026-07-21

## Decision

- Use the already-cataloged `LFM2.5-1.2B-Instruct-Q4_K_M.gguf` as the recommended
  cotyping model for fresh settings. It is 730,895,584 bytes (0.731 decimal GB),
  clears the existing quality gate on three warmed runs, and cuts
  warmed inference latency materially versus the 6.66 GB Gemma default.
- Keep Gemma 4 E4B Instruct available as the higher-capacity choice. Persisted
  user selections are not migrated.
- Do not add or recommend the Cotabby Gemma E2B base checkpoint. Neither tested
  Gemma base checkpoint clears LokalBot's safety or word-completion gate with
  LokalBot's current instruction-oriented prompt and normalizer.
- Use short 20/25/55 ms tiers only while the selector is actually serving an
  in-process engine. Preserve the existing latency/2 backoff (160 ms configured
  floor, 600 ms cap) for the model-server route. The settings control is labeled
  as the initial/server pause because it is intentionally replaced by adaptive
  tiers after the first in-process latency sample.

## Harness and run rule

Source baseline: `5fb3b6da50f82fbb27afff654e52cf2b6a83bdd6` plus the in-progress
cotyping audit changes. Hardware: Apple M4 Max, 48 GB, arm64. The production
`LokalBot --cotyping-bench` command ran all 28
`CotypingBenchmarkScenario.defaults` cases through the real in-process
llama.cpp engine. Settings used 3 output words, local learning off, clipboard
context off, app context on, and streaming off.

```sh
CFFIXED_USER_HOME=<temp>/home \
LOKALBOT_STORAGE_ROOT=<temp>/storage \
LOKALBOT_DEFAULTS_SUITE=<candidate-suite> \
<Debug/LokalBot.app/Contents/MacOS/LokalBot> --cotyping-bench
```

Each candidate suite selected one catalog entry (or a benchmark-only custom
entry for the two base Gemma files). The local GGUF was symlinked into isolated
`<temp>/storage/models`; no model was downloaded and user preferences/storage
were not touched. Raw JSON from this run is in
`/private/tmp/lokalbot-cotyping-model-bench.COZBaH/results/`.

The first invocation that compiled a new Metal kernel family was excluded from
the latency comparison. The table uses the following invocation after that
one-time compilation. Safety/word-completion results remained part of every run.
LFM was run twice more warmed, including once after rebuilding the final source
changes, to check stability. The quality gate
is the checked-in parity gate: 28/28 safety, at least 12/13 word completions, and
p95 inference latency at or below 2,000 ms.

## Model matrix

| Model / exact file | Type | Bytes | Safety | Word completion | Avg ms | p95 ms | Gate |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| LFM2.5 1.2B `LFM2.5-1.2B-Instruct-Q4_K_M.gguf` | Instruct | 730,895,584 | 28/28 | 12/13 | 143 / 143 / 151 | 484 / 487 / 494 | Pass three times |
| Qwen3.5 2B `Qwen3.5-2B-Q4_K_M.gguf` | Catalog model | 1,280,835,840 | 27/28 | 11/13 | 437 | 1,629 | Fail quality |
| Qwen3.5 4B `Qwen3.5-4B-Q4_K_M.gguf` | Catalog model | 2,740,937,888 | 27/28 | 11/13 | 434 | 1,652 | Fail quality |
| Gemma 4 E2B `gemma-4-E2B.i1-Q6_K.gguf` | Cotabby base | 3,845,328,608 | 26/28 | 10/13 | 883 | 2,560 | Fail quality + latency |
| Gemma 4 E4B `gemma-4-E4B-it-UD-Q5_K_XL.gguf` | Current instruct baseline | 6,656,152,736 | 28/28 | 12/13 | 399 | 1,830 | Pass |
| Gemma 4 E4B `gemma-4-E4B-UD-Q5_K_XL.gguf` | Base | 6,700,259,616 | 26/28 | 10/13 | 697 | 3,022 | Fail quality + latency |

LFM also produced 15/64 keyword hits on both warmed runs versus 13/64 for the
Gemma instruct baseline. That is a weak relevance signal, not a separate gate.
The one missing word-completion result is the allowed strictly-inside-word
safety suppression, so 12/13 is the suite's expected ceiling in these runs.

Cold Metal compilation is still a first-use UX concern, not steady-state
inference: LFM's first compiled run took 19,349 ms on its first scenario; the
Gemma instruct first compiled run took 127,466 ms. Focus prewarm should hide most
of this, but release QA should separately time a genuinely fresh install.

## Debounce replay

The debounce comparison replays each warmed run's measured scenario latencies
in order. The first scenario uses the configured 160 ms fallback; later
scenarios use the preceding generation latency. No host-publish wait is
subtracted, so these figures isolate debounce from inference.

| LFM warmed run | Inference avg / p95 | Existing debounce avg / p95 | In-process debounce avg / p95 | Existing inferred E2E avg / p95 | In-process inferred E2E avg / p95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 143 / 484 ms | 173 / 242 ms | 35 / 55 ms | 316 / 644 ms | 178 / 509 ms |
| 2 | 143 / 487 ms | 173 / 243 ms | 35 / 55 ms | 316 / 647 ms | 178 / 512 ms |
| Final-source verification | 151 / 494 ms | 176 / 247 ms | 35 / 55 ms | 327 / 680 ms | 186 / 519 ms |

This is arithmetic replay, not an end-user typing trace. It supports the smaller
stateless policy change but does not replace burst-cancellation or post-accept
UI timing tests.

## Identity, prompt, and license caveats

The promoted file is the existing immutable catalog artifact from
`unsloth/LFM2.5-1.2B-Instruct-GGUF` at revision
`bf1ebe055f24ddd24f3622d933a63b42606773f3`, SHA-256
`856aeee6d85ac684b1db8dee48795b44fc06731ecda03aee36ece682413a9b9a`.
The underlying official model is
[LiquidAI/LFM2.5-1.2B-Instruct](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct),
an instruction-tuned, eight-language model. This matters: the base-model failures
measure compatibility with LokalBot's current instruction/chat prompt, not an
intrinsic verdict on base continuation models. LFM remains described as
English-first in the picker; the suite has only two German cases and is not a
broad multilingual evaluation.

LFM is **not Apache-2.0 or MIT**. It is governed by the
[LFM Open License v1.0](https://docs.liquid.ai/lfm/help/model-license): Liquid AI
states that free commercial use is limited to legal entities under USD 10M in
annual revenue, while distribution requires the license, copyright/attribution
notices, and modification notices. Before release, verify the legal entity is
eligible and that any model redistribution/download packaging satisfies those
notice requirements; otherwise retain Gemma as the default or obtain a
commercial license.
