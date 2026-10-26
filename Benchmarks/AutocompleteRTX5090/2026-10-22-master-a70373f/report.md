# RTX 5090 master autocomplete baseline — 2026-10-22

The release evaluator built from master `a70373f0f20f5daaee0c08fa1216beb3a9e76bb7`
produced 57 suggestions across 60 synthetic cases over three runs: pooled
last-key-to-suggestion **p50 217 ms, p95 319 ms, maximum 578 ms**.

| Run | Suggestions | p50 | p95 / maximum | Model warm-up |
| --- | --- | --- | --- | --- |
| 1 | 19/20 | 217 ms | 578 ms | 4.3 s |
| 2 | 19/20 | 213 ms | 312 ms | 1.9 s |
| 3 | 19/20 | 237 ms | 319 ms | 1.9 s |

All times include the 160 ms debounce. The model was LFM2.5 1.2B Instruct
Q4_K_M, context 4096, simulated key interval 140 ms, using llama.cpp b11669
with Vulkan. Each run omitted a suggestion for `email, after a full stop`.
Percentiles use nearest rank over successful suggestions, rounded to whole
milliseconds in the logs. This measures the headless autocomplete engine,
not insertion into another desktop application or suggestion quality.

Hardware: RTX 5090 (32,607 MiB), UUID
`GPU-198ccaca-5ff4-e59e-fa07-cf53de1ac795`, driver 595.71.05, Ubuntu 24.04,
Ryzen 9 7940HX. The captured process maps show `libggml-vulkan` and NVIDIA
driver libraries; GPU monitoring confirms active GPU work. Source status was
clean before and after evaluation.

The original rental was destroyed after collecting these results. Subsequent
PR CUDA/Vulkan comparisons use a different RTX 5090 and rerun this master
revision on that card; these original numbers are retained as a separate
baseline rather than mixed into that controlled comparison.

See [structured results](evidence/summary.json), the raw logs and sanitized GPU
proof in [evidence](evidence), and [reproduction scripts](scripts).
