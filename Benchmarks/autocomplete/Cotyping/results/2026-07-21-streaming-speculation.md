# Cotyping streaming and post-accept speculation (2026-07-21)

## Decision

- Retain partial streaming. On the new fresh-install default,
  `LFM2.5-1.2B-Instruct-Q4_K_M.gguf`, raw HTTP SSE first-visible p95 was 32 ms
  versus 56 ms for the final normalized completion: 24 ms, or 43%, sooner.
- Remove speculative post-accept generation. The governing production
  in-process benchmark measured 494 ms generation p95. With the 40 ms
  host-publication trace input and the 55 ms in-process debounce tier, the
  timing estimate is 494 ms speculative versus 549 ms non-speculative: only
  55 ms, or 10%, below the predeclared 15% materiality threshold.

These are two different measurements. The streaming numbers come from a raw
llama-server HTTP/SSE microbenchmark. The speculation decision uses the real
production in-process engine's 28-scenario quality run. Using the 56 ms HTTP
result as if it represented the default in-process route would overstate the
benefit of speculation.

## Environment

- MacBook Pro `Mac16,5`, Apple M4 Max, 48 GB
- llama.cpp server build `9844 (b9844)`
- New default model `LFM2.5-1.2B-Instruct-Q4_K_M.gguf`
- Prior configured model `gemma-4-E4B-it-UD-Q5_K_XL.gguf`
- Context 2,048; Metal layers 99; one parallel slot; 512 MB prompt cache

The HTTP/SSE streaming benchmark used this temporary-server shape for each
model:

```sh
/Applications/LokalBot.app/Contents/Resources/llama-cpp/llama-server \
  -m "$HOME/Library/Application Support/me.dotenv.LokalBot/models/<model>.gguf" \
  --host 127.0.0.1 --port 17876 -c 2048 -ngl 99 --jinja --no-webui \
  --parallel 1 --cache-ram 512
```

Measured streaming command:

```sh
python3 Benchmarks/autocomplete/Cotyping/run_llama_server_benchmark.py \
  --base-url http://127.0.0.1:17876/v1 \
  --model <model>.gguf \
  --surface-context --repetitions 8
```

Each HTTP run produced 32 samples: eight repetitions of the four standard
microbenchmark scenarios. Percentiles use the nearest-rank value over those
32 rows.

## Measured HTTP/SSE streaming results

### New default: LFM 2.5 1.2B

Raw runner summary:

```json
{"summary":{"count":32,"avg_first_ms":16,"avg_final_ms":39,"max_first_ms":92,"max_final_ms":121}}
```

| Signal | p50 | p95 |
|---|---:|---:|
| First visible streamed text | 13 ms | 32 ms |
| Final normalized completion | 35 ms | 56 ms |

Partial streaming reduced raw first-visible p95 by 24 ms, or 43%, versus
waiting for the final completion. The result clears the 15% threshold.

### Prior configured model: Gemma 4 E4B

Raw runner summary:

```json
{"summary":{"count":32,"avg_first_ms":67,"avg_final_ms":156,"max_first_ms":266,"max_final_ms":393}}
```

| Signal | p50 | p95 |
|---|---:|---:|
| First visible streamed text | 55 ms | 101 ms |
| Final normalized completion | 174 ms | 211 ms |

Partial streaming reduced raw first-visible p95 by 110 ms, or 52%. Acceptance
now freezes the reviewed partial and invalidates its in-flight stream, so a
later final callback cannot reset or reoffer accepted text.

## Post-accept timing estimate

The production `LokalBot --cotyping-bench` run exercised all 28 checked-in
scenarios through the real in-process engine. Its final-source warmed LFM run
measured 494 ms generation p95. Full commands, quality gates, and raw-result
locations are recorded in `2026-07-21-model-debounce-benchmark.md`.

For a 40 ms host-publication trace input, the adaptive in-process policy's
55 ms tier has 15 ms remaining after publication:

| Route | Estimated p95 |
|---|---:|
| Speculative generation starts at acceptance | `max(494, 40) = 494 ms` |
| Generation starts after publication and remaining debounce | `40 + 15 + 494 = 549 ms` |

The estimated gain is 55 ms, or 10% of 549 ms. That misses the 15% threshold,
so the speculative coordinator state, optimistic field snapshots, parked
results, and route timing helper were removed. Normal regeneration now begins
only after the host publishes the accepted text, preserving a single validated
generation path.

## Limitations

- HTTP/SSE time-to-first-token omits Accessibility validation, normalization,
  main-actor scheduling, overlay layout, and host rendering. Retaining partial
  streaming is supported by a material transport-level delta, but a future
  end-to-end host trace should confirm the visible UI gain.
- The post-accept comparison is arithmetic over measured production inference
  p95 plus a 40 ms host-publication trace input; it is not a direct UI trace.
- The model runs are warmed. Cold Metal compilation and fresh-install first-use
  latency remain separate release-QA work.
