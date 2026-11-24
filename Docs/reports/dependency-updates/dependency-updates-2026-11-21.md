# Dependency updates — 2026-11-21

| Priority | Component | Update | User impact |
| --- | --- | --- | --- |
| Medium | [llama.cpp](https://github.com/ggml-org/llama.cpp/releases/tag/b12613) | v1.0.0 (build b12359) → build b12613 | Adds Thinking Machines' Inkling 2 Mini (`inkling2_loop`, llama.cpp #32694, from b12596), which this update offers as an opt-in Think model. No server flag LokalBot passes changed; b12613 adds only `--tts-speaker-text` and `--ui-mcp-proxy-allow-private-urls`. The macOS libraries keep major version 1 (`lib*.1.dylib`). Linux and Windows fetch the new runtime on their own after updating. |

Not updated, and why:

- **A tagged release.** No `v` tag newer than v1.0.0 exists yet; Inkling support is only in build tags, so macOS builds the `b12613` source archive.

## llama.cpp b12613

Build tag `b12613` points at commit `362ac929749d56e433878585a8506f24968698b4`. macOS builds that tag's source archive with build number 12613; Linux and Windows download the `b12613` release assets.

| Field | Value |
| --- | --- |
| macOS archive | `https://github.com/ggml-org/llama.cpp/archive/refs/tags/b12613.tar.gz` |
| macOS archive SHA-256 | `539f5b7a306c9392e0308094f9c39d1c793041bf18a2c5da5e93f79050be2eb7` |
| `ubuntu-x64` | 23,184,889 bytes, `1a1af0cb6dc2af9779e10085266de44084288d58a2917e14b64400c436fb124a` |
| `ubuntu-vulkan-x64` | 36,860,521 bytes, `0f9e00b9d370ae23319ed1cede97b3edbee4ba826b593f2181a2972e99e44e4e` |
| `ubuntu-cuda-13.5-x64` | 224,354,186 bytes, `2341f734e8a4a5b9ff44e132c4b32de2e7cc3b33a63f55a7a88eefafc6d824a6` |
| `ubuntu-cuda-13.5-x64` libraries | 444,077,873 bytes, `fe676b7a36753342af68d20e11a4d3e65eb370cf58da635f0790b7d0240df466` |
| `ubuntu-cuda-12.8-x64` | 220,056,150 bytes, `a481dbef80b57d19a647b1af88cd4734af52ec0c6a76b1a298185191144b9fcf` |
| `ubuntu-cuda-12.8-x64` libraries | 594,376,095 bytes, `b7454258a93707e36673cd6fa6a426c151d38d865ac8b8cfb1cc6d6e8ec14fb5` |
| `win-cpu-x64` | 25,009,376 bytes, `4c4ca218083b090393f517b598e7c86fc61e62f4d15f8748d6fedf24f809f429` |
| `win-vulkan-x64` | 38,845,965 bytes, `56f1fca056efc933a39226fa767328a0082ebd42ec3c4d2e0193a37ac44abdee` |
| `win-cuda-13.5-x64` | 225,600,888 bytes, `87fbf5aab2747a0d18699d8f2894203b904b503926a1656c830ad68bcb5d3cee` |
| `win-cuda-13.5-x64` libraries | 426,314,199 bytes, `c2bf4cc202bfbaaa7a0b75f5082457c3811326947bb216059b72839d844e9cba` |
| `win-cuda-12.4-x64` | 357,938,946 bytes, `41179bdab19d94eccafb5fa7391722be8be6c01ebb009313c3c98bda6c93fecc` |
| `win-cuda-12.4-x64` libraries | 391,443,627 bytes, `8c79a9b226de4b3cacfd1f83d24f962d0773be79f1e7b75c6af4ded7e32ae1d6` |

## Checks

- **macOS:** `Scripts/build/fetch-llama.sh` built b12613 in 35 s (M4 Max). Its layout check passed: every required `lib*.1.dylib`, minimum macOS 15.0, `@loader_path` rpaths. The app and unit tests built against it.
- **Linux runtime e2e** (Ubuntu 24.04, CPU build): all five `e2e_runtime` tests passed in 158 s. Automatic picked Vulkan, then the CPU build, and reported build 12613 (commit 362ac9297). `an_update_replaces_the_runtime_an_older_version_installed` moved an older runtime to b12613. Notes, digest, ask, dictation and drafting passed with the real Qwen3.5 0.8B model. The 12 Windows and Linux asset names, sizes and digests were checked against GitHub's release API.
- **CUDA (Linux):** on an RTX 3090 (driver 570, CUDA 12.8 build), `llama-server` with the app's arguments served Qwen3.5 4B at about 155–160 tokens/s and Inkling 2 Mini at about 51–56 tokens/s through the notes benchmark ([report](../../../Benchmarks/think/ReasoningDefaults/2026-11-21/REPORT.md)).
- **Large MoE models on small GPUs (follow-up, not changed here):** on a Radeon RX 6600 XT (8 GB, Vulkan), Inkling 2 Mini with the app's `-ngl 99` generated 2.8 tokens/s, because llama.cpp's automatic fit gives up when `-ngl` is set ("n_gpu_layers already set by user to 99, abort") and the weights spill into shared memory. Without `-ngl`, fit brought it to 4.1 tokens/s; keeping the looped layers' experts on the GPU by hand reached 12–13. Qwen3.6 35B-A3B has the same limitation today, so Windows and Linux describe Inkling as needing a 24 GB GPU until MoE placement is handled.
