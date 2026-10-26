# CUDA hardware validation

## Build selection, native Windows and backend fallback — 2026-10-22

The review fixes add a CUDA 12 build (12.8 on Linux, 12.4 on Windows) next to
CUDA 13.4 and pick between them from the driver's CUDA version and each GPU's
compute capability. They also keep built-in models on Automatic's Vulkan/CPU
runtime until CUDA setup succeeds. Release test binaries from one source tree
ran on rented GPUs; every library was a fresh download.

| GPU (compute capability) | OS / driver (CUDA) | Selected build | Result |
| --- | --- | --- | --- |
| RTX 3060 (8.6) | Ubuntu 24.04 container / 595.71 (13.2) | CUDA 13.4 | Full runtime test passed, offload confirmed on Main and Embedder |
| Titan Xp (6.1, Pascal) | Ubuntu 24.04 container / 570.158 (12.8) | CUDA 12.8 | Full runtime test passed, offload confirmed |
| GTX 1660 (7.5, Turing) | Ubuntu 24.04 container / 580.95 (13.0) | CUDA 12.8 | Full runtime test passed, offload confirmed |
| GTX 1660, build forced to 13.4 | Ubuntu 24.04 container / 580.95 (13.0) | CUDA 13.4 | Setup's device check passed, then model start failed: "the provided PTX was compiled with an unsupported toolchain" |
| L4 (8.9) | Windows Server 2022 / 596.86 (13.2) | CUDA 13.4 | Full runtime test passed, offload confirmed |
| L4 (8.9), build forced to 12.4 | Windows Server 2022 / 596.86 (13.2) | CUDA 12.4 | Full runtime test passed, offload confirmed |

A separate scenario test ran on each GPU: Automatic first, then CUDA selected
without setup, then CUDA setup. Think and embeddings kept answering on the
automatic backend (CPU in the Linux containers, Vulkan on the Windows L4) with
no server restart, and after setup both roles moved to CUDA with confirmed
offload. Without an NVIDIA driver (the OVH Ubuntu box, and the AMD RX 6600 XT
Windows PC on Vulkan), setup failed at once with the driver message and the
models kept answering on CPU or Vulkan.

The forced row shows why selection matters: the previous CUDA 13.0 driver gate
would have installed CUDA 13.4 on that GPU and failed at model start.

On GPUs without prebuilt kernels the driver compiles PTX on the first CUDA
start after setup: the first reply took 47.9 s on the Titan Xp and 177 s on the
GTX 1660, then 2.7 s and 4.6 s on the next cold start from a 59 MB and 104 MB
compute cache. CUDA servers now get 10 minutes to start; other backends keep 2.

Prompt processing and generation with `llama-bench` (3 repetitions, all
layers on the GPU), same llama.cpp b11669, CUDA 13.4 build versus Vulkan build:

| GPU | Workload | CUDA | Vulkan | CUDA vs Vulkan |
| --- | --- | --- | --- | --- |
| RTX 3060, Linux | Qwen3.5 4B Q4_K_M, 4,096-token prompt | 3,088 t/s | 2,146 t/s | +44% |
| RTX 3060, Linux | Qwen3.5 4B Q4_K_M, generation | 88.0 t/s | 80.6 t/s | +9% |
| RTX 3060, Linux | EmbeddingGemma 2 Q8_0, 2,048-token batch | 19,944 t/s | 12,981 t/s | +54% |
| L4, Windows Server 2022 | Qwen3.5 4B Q4_K_M, 4,096-token prompt | 4,502 t/s | 3,401 t/s | +32% |
| L4, Windows Server 2022 | Qwen3.5 4B Q4_K_M, generation | 64.6 t/s | 65.2 t/s | −1% |
| L4, Windows Server 2022 | EmbeddingGemma 2 Q8_0, 2,048-token batch | 22,769 t/s | 19,130 t/s | +19% |

Prompt-heavy work (notes, digests, Ask, indexing) gains the most; generation
speed is close. The embedding rows vary by up to ±30% between repetitions.

Environment problems found along the way, outside the CUDA code: upstream
`llama-server` needs `libgomp.so.1` (OpenMP) on Linux and the Microsoft Visual
C++ 2015–2022 runtime on Windows. A minimal container and a fresh Windows
Server image had neither, so every backend, CPU included, failed to start until
they were installed. The Linux packages now depend on libgomp, the Windows
archive and installer carry the Visual C++ runtime for each `llama-server.exe`,
and a start that still fails names what to install.

## RTX 5090: review fixes, older driver and matched timings — 2026-10-22

Revision `4b63346556f15776d441cf3e8c42a8ce2a7c15f6` passed real CUDA inference
on Ubuntu 24.04 with NVIDIA driver **595.58.03 / CUDA driver API 13.2**, using
the pinned CUDA 13.4 runtime. The earlier gate would have rejected this driver;
it now accepts CUDA 13.0+ through NVIDIA's minor-version compatibility while
retaining device and model-offload checks. Exact R580 hardware remains untested.

Bundled libraries, system-library reuse and repair after removing the system
libraries all passed text, JSON, streaming and embedding tests, with both roles
confirmed on the GPU. Repair preserved the server inode and SHA-256 and removed
completed download archives. The host also passed 293 release-mode AI unit tests.

Three alternating release-mode runs per configuration on the **same physical
RTX 5090**, using LFM2.5 1.2B Q4_K_M, context 4096, debounce 160 ms and 140 ms keys:

| Build / backend | Suggestions | Pooled p50 | Pooled p95 | Maximum |
| --- | --- | --- | --- | --- |
| Master `a70373f` / Vulkan | 57/60 | 211 ms | 338 ms | 671 ms |
| PR `4b63346` / Vulkan | 57/60 | 218 ms | 346 ms | 385 ms |
| PR `4b63346` / CUDA | 57/60 | 180 ms | 210 ms | 217 ms |

CUDA reduced median latency by **17.4%** and p95 by **39.3%** versus PR Vulkan
in this workload. Times include debounce and cover successful suggestions only.
This is a headless engine benchmark, not a test of desktop insertion or quality.
The host had 15,790 MiB of pre-existing VRAM usage and no other visible process;
idle utilization was 0%. Driver/filesystem caches were not cleared between runs.

The original master-only rental had already been destroyed, so master was rerun
on this comparison card. The original card's 217/319 ms pooled p50/p95 remains a
separate baseline. All temporary rentals have been destroyed.

[Full comparison, per-run results, reproduction scripts and sanitized evidence](../../Benchmarks/AutocompleteRTX5090/2026-10-22-pr354-4b63346/report.md).
[Original master baseline](../../Benchmarks/AutocompleteRTX5090/2026-10-22-master-a70373f/report.md).

## Earlier three-card CUDA validation — 2026-10-21

The validation used synthetic prompts and the repository's fictional demo library.
The L4 run tested `f4425e736abf2f73905badebfa465aee71a6c010`; the RTX 3080 and
RTX 5060 Ti runs tested `3c732843dff1b71a942ee0149db86a286f791ae4`. These revisions
have identical runtime and test code; only documentation changed between them.

## Environment

Three separate Vast.ai hosts:

| GPU | Reported memory | Runtime and autocomplete result |
| --- | --- | --- |
| NVIDIA L4 | 23,034 MiB | Passed |
| NVIDIA GeForce RTX 3080 | 10,240 MiB | Passed |
| NVIDIA GeForce RTX 5060 Ti | 16,311 MiB | Passed |

Common software environment:

- Ubuntu 24.04 x86_64 container, glibc 2.39.
- NVIDIA driver 615.71.09; `cuDriverGetVersion` returned `13040`.
- Rust 1.99.1; llama.cpp b11669 (`620d2225c`), pinned CUDA 13.4 archives.
- Initially no loadable `libcudart.so.13`, `libcublas.so.13` or `libcublasLt.so.13`.

All three temporary instances were destroyed after collecting the results.

## Runtime tests

The ignored integration test passed twice on each card with
`LOKALBOT_E2E_BACKEND=cuda`:

```sh
LOKALBOT_E2E_ROOT=/workspace/cuda-validation/bundled \
LOKALBOT_E2E_BACKEND=cuda \
cargo test --locked -p lokalbot-ai --test e2e_runtime \
  installs_runtime_downloads_models_and_answers -- --ignored --nocapture --test-threads=1
```

| Setup | Result |
| --- | --- |
| Required CUDA libraries absent | Installer downloaded and verified the server plus companion archive, about 594 MB total. Full inference test passed with `cudaLibraries` recording the companion digest. |
| Matching libraries available in `/usr/local/cuda-13.4/lib64` | A fresh runtime installation downloaded only the 154 MB server archive. Full inference test passed with `cudaLibraries: "system"` and none of the three companion libraries in the new runtime directory. |

The system-library test placed the exact matching libraries from the first
installation in a standard toolkit location. It establishes reuse of compatible
libraries, not compatibility with every CUDA toolkit version or distribution.
On the L4, after the startup fix below, the bundled-library inference run reused
its previously downloaded files; the system-library run installed into a fresh
runtime directory. Both RTX cards started with fresh runtime directories for
both installation paths. The system-library runs set
`CUDA_HOME=/usr/local/cuda-13.4` and reused the already downloaded models.
All six runs used Qwen3.5 0.8B Q4_K_M and EmbeddingGemma 2 Q8_0 and checked:

- Nonempty text generation, token counting, constrained JSON and streaming.
- 768-dimensional embeddings and higher similarity for the related document.
- Both Main and Embedder running with CUDA and `gpuOffloaded: true` markers.
- Clean shutdown of the managed servers.

### Startup regression caught by hardware execution

Revision `392f1a85f67eda42ba8d7bceead1b5c9a7769d8e` failed the integration test:
the CUDA device was detected and the server became healthy, but the runtime
could not confirm model-layer offload. The pinned server's default verbosity
level 3 omits the offload summary. At level 4, the same GPU and model reported:

```text
0.02.021.855 I load_tensors: offloaded 25/25 layers to GPU
```

CUDA launches now explicitly use `--log-verbosity 4 --log-colors off --no-log-jsonl`
so the existing stderr parser receives that evidence. The test failed before
this change and passed afterward; it also requires both exercised roles to be
running and positively marked as offloaded.

## Autocomplete smoke run

```sh
cargo run --locked -p lokalbot-engine --example autocomplete_eval -- \
  /workspace/cuda-validation/autocomplete-cuda --backend cuda
```

The headless evaluator used LFM2.5 1.2B Instruct Q4_K_M, a 4,096-token context,
160 ms debounce and simulated keystrokes 140 ms apart. The autocomplete server's
marker confirmed CUDA model offload on every card. Word-by-word acceptance and
suggestion continuation also ran.

| GPU | Suggestions | Warm-up | Last key → suggestion p50 | p95 / max |
| --- | --- | --- | --- | --- |
| L4 | 19 / 20 | 2.3 s | 214 ms | 247 ms |
| RTX 3080 | 19 / 20 | 2.8 s | 274 ms | 360 ms |
| RTX 5060 Ti | 19 / 20 | 2.1 s | 183 ms | 205 ms |

Latency includes the 160 ms debounce and covers successful suggestions only.
One scenario on each card produced no suggestion within the evaluator's timeout.
These are observations from one debug-engine run per card on separate hosts,
not a controlled GPU performance comparison, quality score or production
performance guarantee. The evaluator simulates fields; it does not test
insertion into a real desktop application.

## Remaining coverage

- Native Windows was tested on a data-center L4 under Windows Server 2022 only;
  consumer Windows 10/11 GeForce systems and the Game Ready driver remain untested.
- No host offered a CUDA 13.4+ driver, so the CUDA 13.4 build was not run on
  Turing, A100 or H100; selection gives those GPUs CUDA 12 until such a driver.
- Maxwell and Volta, multi-GPU PCs and system-library reuse with the CUDA 12
  builds were not exercised on hardware.
- The earlier L4/RTX 3080/RTX 5060 Ti runs tested CUDA only and establish no
  cross-backend speedup. The 5090 and llama-bench comparisons above are separate.
- No performance claim is made for other GPUs, models, larger contexts or
  simultaneous workloads. Automatic remains Vulkan/CPU; CUDA is opt-in.
