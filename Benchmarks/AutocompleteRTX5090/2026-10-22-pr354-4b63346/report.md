# RTX 5090 autocomplete: master, Vulkan and CUDA — 2026-10-22

On one RTX 5090, the PR's CUDA backend reduced median last-key-to-suggestion latency by **17.4%** and p95 by **39.3%** versus the PR's Vulkan backend in this evaluator. All times include the **160 ms debounce**.

| Build / backend | Suggestions | Pooled p50 | Pooled p95 | Maximum |
| --- | --- | --- | --- | --- |
| Master · Vulkan | 57/60 | 211 ms | 338 ms | 671 ms |
| PR · Vulkan | 57/60 | 218 ms | 346 ms | 385 ms |
| PR · CUDA | 57/60 | 180 ms | 210 ms | 217 ms |

These are headless engine measurements over synthetic fields. They do not measure insertion into other desktop apps, transcription, suggestion quality or a general speedup for every model. Percentiles cover successful suggestions only; non-suggestions are counted in the coverage column.

## Per-run observations

| Build / backend | Run | Suggestions | p50 | p95 / max | Model warm-up |
| --- | --- | --- | --- | --- | --- |
| Master · Vulkan | 1 | 19/20 | 213 ms | 671 / 671 ms | 4.3 s |
| Master · Vulkan | 2 | 19/20 | 203 ms | 310 / 310 ms | 1.9 s |
| Master · Vulkan | 3 | 19/20 | 211 ms | 306 / 306 ms | 1.9 s |
| PR · Vulkan | 1 | 19/20 | 216 ms | 385 / 385 ms | 1.9 s |
| PR · Vulkan | 2 | 19/20 | 243 ms | 346 / 346 ms | 1.9 s |
| PR · Vulkan | 3 | 19/20 | 210 ms | 354 / 354 ms | 1.9 s |
| PR · CUDA | 1 | 19/20 | 177 ms | 212 / 212 ms | 1.9 s |
| PR · CUDA | 2 | 19/20 | 181 ms | 217 / 217 ms | 1.9 s |
| PR · CUDA | 3 | 19/20 | 181 ms | 210 / 210 ms | 1.9 s |

Cases without a suggestion: `email, after a full stop`.

## Matched environment and method

- PR source: `4b63346556f15776d441cf3e8c42a8ce2a7c15f6`; master snapshot: `a70373f0f20f5daaee0c08fa1216beb3a9e76bb7`. Both source trees were clean before and after the runs. Later PR changes only add storage-label translations and this evidence.
- RTX 5090, 32,607 MiB; GPU UUID `GPU-903d71c2-dae0-8afc-1174-de27f968a942`. Driver 595.58.03, CUDA driver API 13.2; Ubuntu 24.04, Ryzen 9 7940HX, Rust 1.99.1.
- Release-mode `lokalbot-engine` evaluator; pinned llama.cpp b11669. LFM2.5 1.2B Instruct Q4_K_M, 4096-token context, debounce 160 ms, simulated key interval 140 ms. Model checksums are identical in all three roots.
- Three runs per build/backend, rotated in order: master/Vulkan → PR/Vulkan → PR/CUDA; PR/CUDA → PR/Vulkan → master/Vulkan; PR/Vulkan → master/Vulkan → PR/CUDA. Runs are sequential, with no builds or other validation jobs overlapping them.
- Each invocation performs its own warm-up prompt before timing the 20 cases. Startup is reported separately. Filesystem and driver shader caches were not cleared between runs; first-run shader compilation can affect tails. Pooled percentiles use nearest rank over the rounded millisecond case logs.
- Live process maps establish Vulkan or CUDA plus NVIDIA driver libraries; CUDA markers require `gpuOffloaded: true`. Process arguments are sanitized to remove the local server bearer token. GPU use was sampled once per second.
- The host already reported 15,790 MiB used before our model processes started, with no other process visible and 0% idle GPU utilization. That allocation persisted between runs. Both backends fit in the remaining memory; exclusive control of all host activity cannot be established from inside the container.
- The container initially lacked the NVIDIA EGL vendor manifest. Adding the manifest for the already-mounted `libEGL_nvidia.so.0` made Vulkan detect this exact GPU. The host driver was unchanged; the repair script is included.

## Driver relaxation and repair validation

The early gate now accepts a driver reporting CUDA 13.0 or newer instead of requiring 13.4. [NVIDIA documents minor-version compatibility for CUDA 13.x on R580+ drivers](https://docs.nvidia.com/deploy/cuda-compatibility/minor-version-compatibility.html), with limitations for PTX and newer driver features. The pinned libraries stay at CUDA 13.4; real GPU detection and offload remain mandatory.

On this API-13.2 driver, all three full integration runs passed: bundled companion libraries, compatible system libraries, and repair after removing those system libraries. Each checked text generation, token counting, schema-constrained JSON, streaming, 768-dimensional embeddings and confirmed GPU offload for Main and Embedder. The repair kept the server inode and SHA-256 unchanged, installed only companion libraries, and left no completed archives in `.downloads`.

The GPU host passed 293 release-mode AI unit tests. [Platform CI](https://github.com/stevyhacker/LokalBot/actions/runs/39740789946) passed 985 Linux tests and 955 Windows tests, release builds/packages, localization and hosted desktop checks. [macOS CI](https://github.com/stevyhacker/LokalBot/actions/runs/39740789941) passed build, unit tests and the synthetic workday. No local UI tests were run.

## Scope and retained baseline

The original master-only run used a different RTX 5090 (`GPU-198ccaca-5ff4-e59e-fa07-cf53de1ac795`, driver 595.71.05): pooled p50 217 ms, p95 319 ms, 57/60 suggestions. That rental had already been destroyed. The master row above is a fresh rerun on the same card as both PR backends; original-card results are not pooled into this comparison.

Native Windows NVIDIA execution remains untested. The minimum R580/API-13.0 driver is accepted by unit tests and the documented compatibility contract; actual hardware validation here establishes R595/API-13.2, not every R580 driver, GPU or PTX path. Automatic still selects Vulkan/CPU and CUDA remains opt-in.

## Reproduction and evidence

Use the scripts in [scripts](scripts): setup, EGL-manifest fix if needed, build-resume, validation (builds both revisions and invokes the matched benchmark), and system-library repair after timing completes. The proof collector checks live GPU libraries for each run; the summarizer requires all nine results, clean source records and successful benchmark exit.

- [Structured per-case results and pooled statistics](evidence/summary.json)
- [Matching model hashes](evidence/model-checksums.txt)
- [Driver API](evidence/driver-version.txt), [card identity](evidence/card-details.csv), [GPU samples](evidence/gpu-usage.csv)
- [Bundled inference](evidence/e2e-bundled.log), [system-library inference](evidence/e2e-system.log), [repair inference](evidence/e2e-repair.log)
- [Server identity before repair](evidence/repair-before.json), [after repair](evidence/repair-after.json)

All prompts and library fixtures are synthetic. No personal meeting library or credentials were uploaded. The temporary GPU instance was destroyed after collecting the evidence.
