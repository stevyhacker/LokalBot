# Dependency updates — 2026-11-05

| Priority | Component | Update | User impact |
| --- | --- | --- | --- |
| Medium | [llama.cpp](https://github.com/ggml-org/llama.cpp/releases/tag/v0.9.0) | v0.7.0 (build b11669) → v0.9.0 (build b12110) | Updates local chat, structured output, tool calls, embeddings and autocomplete on every platform. Gemma 4 E2B, the default autocomplete model, reads prompts about 3.1× faster on an M4 Max. ggml moves from 0.27.0 to 0.29.0. Chat, JSON output, tool calls and text embeddings are unchanged in the probes below, and existing search indexes stay valid. On Linux and Windows the new runtime now downloads on its own after updating (see Upgrade behavior). |

## llama.cpp v0.9.0

The `v0.9.0` tag points at commit `cd959bae99ff4bed22bef2604f45241c09bbb8c8`,
which is also build tag `b12110`. macOS builds the `v0.9.0` source archive. Its
archive has no `.git`, so `Scripts/fetch-llama.sh` passes build number 12110,
and `llama-server --version` reports `0.9.0 (build 12110, commit v0.9.0)`.
Linux and Windows download the `b12110` release assets, whose servers report
`0.9.0-dev (build 12110, commit cd959bae9)`.

| Field | Value |
| --- | --- |
| macOS archive | `https://github.com/ggml-org/llama.cpp/archive/refs/tags/v0.9.0.tar.gz` |
| macOS archive SHA-256 | `5d0f1aaf55fd8629c29a55e81b7cb63b80239f83c33a580963071204896836a8` |
| `ubuntu-x64` | 23,051,958 bytes, `368227edcc229be5f9bed16a2223d79b5e41d0ac2e19bcf5825e82291c060e55` |
| `ubuntu-vulkan-x64` | 35,858,360 bytes, `a5d741940956ec62e8783aee7e5a4c7c761af867d6f027c3277a51e1a3ac59b0` |
| `ubuntu-cuda-13.4-x64` | 168,275,993 bytes, `2afd2ca540da119570b1dac36b5a2c862bb03a3b789c46661dfa55e600f5b19b` |
| `ubuntu-cuda-12.8-x64` | 187,314,621 bytes, `4af1e1da23661db4a5b84b29aae16ebc053df689c5b8b1427c4670f2c6406d8c` |
| `win-cpu-x64` | 24,708,445 bytes, `98901e327c252875accaf2d1bf364e10e868843b0b63468baad1aa945cdc5da2` |
| `win-vulkan-x64` | 37,661,146 bytes, `9732a5e48887ca54d0bfe4af4324dc85fd56cd8cda19b52df3542fa6ebe6874f` |
| `win-cuda-13.4-x64` | 169,175,655 bytes, `dc910a969190b5d42e189afd73117f6bbdd8dd8ed6586342c5e0b82cab62c673` |
| `win-cuda-12.4-x64` | 287,014,657 bytes, `1ce755bc3a061889234048f88e33328e17971eaad73c4666cfeb26026b317fee` |

The Linux CUDA library archives are also new; the Windows ones are the same
files as before. Each release asset was downloaded and hashed, and matches the
digest GitHub publishes for it and the pin in the code.

Upstream changes that were checked, across both v0.8.0 and v0.9.0:

- **Public headers change only additively.** `llama.h` gains `LLAMA_FTYPE_MOSTLY_F8_E4M3` and `LLAMA_DRY_MAX_SEQ_BREAKERS`. The ggml headers gain new types, ops and batched copy functions. The in-process autocomplete runtime still links, loads and runs.
- **Server flags.** Every flag the apps pass still exists. The only additions are `--connect`, `--connect-code`, `--models-memory-margin` and `--tts-voice`.
- **Log levels.** `common/log.h` still has TRACE at 4 and DEBUG at 5, and request and response bodies are still logged only at 5. No TRACE line in the server or common code was added or changed since v0.7.0. The Linux and Windows CUDA servers run at verbosity 4, so this matters: a prompt containing a marker word never reached the log at verbosity 3 or 4. The "offloaded N/M layers to GPU" line still appears only from verbosity 4.
- **New remote access, off by default.** v0.8.0 adds `--connect`, an experimental peer-to-peer tunnel, and the Linux and Windows archives now contain a `llama-connect` program. Neither app passes the flag or starts the program, and the macOS build makes only `llama-server`. Upstream also lets the `LLAMA_ARG_CONNECT` environment variable turn it on, and the apps do not clear that variable. A server started with the app's arguments held only loopback sockets after serving a request.
- **New endpoints require the token.** Without it, `/tts`, `/v1/realtime`, `/v1/responses`, `/v1/chat/completions`, `/completion`, `/v1/embeddings`, `/props` and `/slots` all return 401. The public endpoint list is unchanged.
- **stdin shutdown.** The "EOF on stdin, forcing shutdown" code only runs for a server managed by llama.cpp's router, and it was already there in v0.7.0. Both apps start the server with stdin closed, and it stays up.
- **Windows arguments.** Upstream dropped its Windows argument rebuilding and embeds an app manifest instead. A model in a folder named `modeli-čšđž-模型` loads on both the Vulkan and CPU builds.
- **CUDA dependencies.** The upstream NCCL work adds no library dependency. On Linux, `libggml-cuda.so` needs the same libraries as b11669. On Windows, `ggml-cuda.dll` imports no NCCL library, only names the runtime already handles. The library names in `runtime/cuda.rs` still match the archives.

**Image vectors move slightly.** Upstream changed Gemma 4 image handling in this range ([#30882](https://github.com/ggml-org/llama.cpp/pull/30882), [#30922](https://github.com/ggml-org/llama.cpp/pull/30922)), and it was not isolated which change is responsible. With the app's sizing, v0.7.0 and v0.9.0 agree at the cosines below, and text and speech do not move. All of it stays above the 0.999 bar, so `FileMediaEmbedder.vectorVersion` and `EmbeddingIndex.indexVersion` stay as they are, and nothing is re-indexed.

| Input | v0.7.0 vs v0.9.0 | v0.7.0 vs DigUp reference | v0.9.0 vs DigUp reference |
| --- | ---: | ---: | ---: |
| 5 texts | — | ≥ 0.999999 | ≥ 0.999999 |
| `screen.png`, budget 280 | 0.999873 | 1.000000 | 0.999873 |
| `photo.jpg`, budget 140 | 0.999910 | 0.999843 | 0.999766 |
| `photo.jpg` as a frame, budget 70 | 0.999874 | 0.999762 | 0.999713 |
| `speech.wav` | 1.000000 | 1.000000 | 1.000000 |

**Upgrade behavior on Linux and Windows.** Before this update, a change to `LLAMA_BUILD` left the app with no usable runtime until someone downloaded it again in Settings → Models: Ask and follow-ups asked for the download, automatic digests and search indexing skipped without saying so, and on-device autocomplete stayed off. Now, if another build's runtime was installed, the app fetches this build in the background at launch, the same way a background start would choose it: a selected Vulkan or CPU, else Automatic, which skips looking for a GPU when the older build already found none. A failed download is logged and tried again after 1, 5 and 15 minutes, then hourly; cancelling it in Settings ends that for the launch. Search indexing, which checks once per launch, waits for this. Once built-in models can run, the older build's folders and interrupted downloads are removed (about 56 MB for CPU and over 800 MB for CUDA at this build's sizes). A folder a helper still runs from, or that Windows won't delete yet, stays until a later launch. CUDA's download (168–287 MB for the server, up to 594 MB more for the libraries) stays explicit: built-in models use Vulkan or CPU, and a message asks the person to set CUDA up again. `Models::ensure` no longer starts a CUDA download either, which the README already promised for background work. A fresh install, or a runtime removed in Settings, downloads nothing. macOS is not affected, because the app bundles its runtime. `PRIVACY.md` and the Linux and Windows README describe this download.

## Verification

- **macOS vendor build.** `bash Scripts/fetch-llama.sh` cold-built v0.9.0 in 40 s with no compiler warnings. The receipt validates, and the runtime has the same file set with the version suffixes moving to ggml 0.29.0 and llama 0.9.0 (57 MB, was 54 MB). `python3 -m unittest discover -s Scripts/tests` ran 162 tests: OK.
- **Focused macOS suites: 297 tests, 0 failures, 3 skips,** built against the v0.9.0 vendor with real models. The classes were `LlamaCoreSmokeTests`, `LlamaSamplerSpecTests`, `LlamaServerTests`, `LlamaServerIsolationTests`, `RuntimeAssetSafetyTests`, `InferenceBrokerTests`, `TextEngineTests`, `LeasedTextEngineTests`, `ChatAgentTests`, `LocalLlamaCotypingEngineTests`, `LlamaCotypingRuntimeTests`, `FileMediaEmbedderReferenceTests`, `FileMediaEmbedderTests`, `ModelCatalogTests`, `ModelResidencyTests`, `AskLibraryEngineTests`, `EmbeddingIndexIntegrationTests`, `EmbeddingIndexScreenBackfillTests`, `CotypingEngineSelectorTests`, `CotypingTokenHealingTests`, `CotypingFirstWordConfidenceTests`, `LeaseBookTests` and `SystemResourceSamplerTests`. `FileMediaEmbedderReferenceTests`, which asks to be run for every llama.cpp update, passed through the app's own path. The skips need a fixture, a model that cannot reuse prompt prefixes, and a private replay manifest.
- **Server probes, macOS.** The app's arguments were used with Qwen3.5 4B, Gemma 4 E2B, LFM2.5 1.2B and EmbeddingGemma 2, comparing v0.7.0 and v0.9.0. They gave identical results for `/props` context size, `/tokenize` on Serbian text, chat with and without thinking, streamed chat, JSON-schema output, a tool call (plain and streamed), the error for too long a prompt, an over-long embedding input, and `/completion` with `n_probs`, stop type and prompt-cache reuse. Text embedding cosine was 1.0 on all four inputs. The only differences: `chat_template_caps` in `/props` gains `reasoning_effort_levels`, and one Gemma 4 E2B log-probability moved by 0.001 with the same text out.
- **Speed, macOS.** M4 Max on AC power, about 2,360 prompt tokens and 256 generated tokens, three alternating runs per build, medians. Qwen's decode runs were noisy on both builds (102, 103 and 72 against 93, 63 and 102 tok/s), so this shows no clear change for Qwen. Autocomplete's real prompts are shorter than this one, and the in-process path was not timed separately; it uses the same `libllama`.

  | Model | Prefill v0.7.0 → v0.9.0 (tok/s) | Decode v0.7.0 → v0.9.0 (tok/s) |
  | --- | ---: | ---: |
  | Gemma 4 E2B | 2,310 → 7,210 | 124 → 129 |
  | Qwen3.5 4B | 1,202 → 1,279 | 102 → 93 |

- **Memory, macOS.** Two runs per role after one request. Resident memory stays within about 3% on all three roles (embedder about 490 MiB, E2B about 3.9 GiB, Qwen 4B about 4.0 GiB). Footprint varied too much between runs to show a direction.
- **Linux** (Ubuntu box, CPU). `cargo fmt --check` and `clippy -D warnings` for `lokalbot-agent` and `lokalbot-ai` passed, and their tests ran 677 passed, 0 failed. The opt-in `e2e_runtime` suite passed all four tests. It installed the b12110 asset through `RuntimeManager`, downloaded and verified Qwen3.5 0.8B and EmbeddingGemma 2, and covered chat, schema output, streaming, embeddings, Ask, dictation, a day digest and meeting notes.
- **Windows** (PC, Radeon RX 6600 XT). The `win-vulkan-x64` and `win-cpu-x64` assets and both models were downloaded and checked against their pins. Chat, JSON-schema output, a tool call, `/completion` and embeddings passed on both. Compared with b11669 over three alternating runs with Qwen3.5 0.8B on Vulkan, once warmed up, prefill went from about 2,800 to about 2,910 tok/s and decode stayed at about 129 tok/s. The first run of a new build is slower while it prepares its GPU shaders (0.91 s for a first request against 0.09 s after), and b11669 did the same.
- **Upgrade fix, Linux** (Ubuntu box). `cargo fmt --check`, `clippy --workspace --all-targets --locked -D warnings` and the localization check passed. New tests cover noticing an older install, replacing it, keeping it when the download fails, leaving CUDA to setup, retrying, cancelling, and skipping a folder a helper runs from. With each part of the fix undone in turn, the tests that cover it failed: nothing running at launch, background work using explicit setup, old folders never removed, and the update path installing CUDA. The opt-in `an_update_replaces_the_runtime_an_older_version_installed` passed on real archives, from a copy of an installed runtime renamed to b11669 through to the old folder being gone.
- **Upgrade fix, workspace.** `cargo test --workspace --locked` on the Ubuntu box: 2,316 passed, 0 failed, 25 ignored.
- **Upgrade fix, the real app.** On the Ubuntu box under Xvfb, with a throwaway home folder holding a real b11669 CPU install and its `backend.json`. Without anyone touching Settings, the app replaced it with b12110 and removed the old folder 2 s after launch, without fetching the Vulkan build, and the new server reports build 12110. This ran on CPU only. It was not run on Windows, and neither the retry after a failed download nor the CUDA message was seen in the app; tests cover those.
- **Upgrade fix, Windows** (PC, Radeon RX 6600 XT). `runtime::` ran 36 passed and `models::` 7 passed; the tests that need a fake server script run only on Linux. The real-download `an_update_replaces_the_runtime_an_older_version_installed` passed on Vulkan: it fetched `win-vulkan-x64` and removed the older folder.
- **Test reliability.** The runtime tests run freshly written fake servers, and Linux refuses to run a file while a process forked by another thread still holds it open. This failed 13 of 300 runs of the `runtime::` tests before this change, and 0 of 300 after it. `check_loads` now waits this out too, since a real install can hit the same race.
- **Not run.** CUDA has not run on an NVIDIA GPU with this build: the archives were checked by hash, layout, `--version`, `--help` and library dependencies only. Linux Vulkan was not run on a GPU. No UI tests ran locally; they and the full unit and Windows workspace suites run in CI. No summary replay was run on a private meeting, and nothing was installed or released.
