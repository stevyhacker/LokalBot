# Dependency updates — 2026-11-26

| Priority | Component | Update | User impact |
| --- | --- | --- | --- |
| Medium | [llama.cpp](https://github.com/ggml-org/llama.cpp/releases/tag/v1.1.0) | build b12613 → v1.1.0 (build b12774) | Moves back to a tagged release, 161 commits past b12613. For LokalBot it mainly brings upstream's Inkling 2 fixes (tokenizer `ignore_merges`, chat parser and grammar, a leaner graph, the indexed-bias attention path), token-aware chat parsing, faster BPE tokenization and Metal/Vulkan work. No flag the apps pass changed; v1.1.0 adds only `--ui-agent`. The macOS libraries keep major version 1 (`lib*.1.dylib`), and Linux and Windows fetch the new runtime on their own after updating. Chat, streaming, JSON output, tool calls, completions, tokenization and text embeddings came out identical to b12613 with the app's arguments. |

## llama.cpp v1.1.0

The `v1.1.0` tag points at commit `171527522610996f5f0acf12334e185156ca8f44`,
which is also build tag `b12774`. macOS builds the `v1.1.0` source archive and
passes build number 12774, so `llama-server --version` reports
`1.1.0 (build 12774, commit v1.1.0)`. Linux and Windows download the `b12774`
release assets.

| Field | Value |
| --- | --- |
| macOS archive | `https://github.com/ggml-org/llama.cpp/archive/refs/tags/v1.1.0.tar.gz` |
| macOS archive SHA-256 | `370603b8d973f4c02cd68ff2b815859c0f71878a57075cf2758015ceb7fc7990` |
| `ubuntu-x64` | 23,454,685 bytes, `ab5837cca2317cfb7ecb5f85b550934e7355cd9df74cdde6e106581457034dbb` |
| `ubuntu-vulkan-x64` | 37,166,104 bytes, `75b7044df1232bd5bc78ffc753f14a5a44d9f3b5c67228b6103705c57084d02d` |
| `ubuntu-cuda-13.5-x64` | 225,744,161 bytes, `15ffe2e6ab20d9383d22ce96e1376a05966b343c3b23e8b4294a602318b5274f` |
| `ubuntu-cuda-13.5-x64` libraries | 444,078,957 bytes, `bf83f2f5c3a0885fd99b3910cf69997d62976fd6b81b9a8e1230d6f698306bf5` |
| `ubuntu-cuda-12.8-x64` | 220,356,732 bytes, `0b21de91989e04e7cca05a320b1c075046ce427b59256ba51038df61e52bd5fe` |
| `ubuntu-cuda-12.8-x64` libraries | 594,377,009 bytes, `b8fd3ce0bf1a3f437bcd2b2df81e635828d58f3c9f0606faddbe813d56589590` |
| `win-cpu-x64` | 25,288,075 bytes, `44b70b20f3374eec3d16a002beceefef33cc3565678caeb3eea5f6cacba61836` |
| `win-vulkan-x64` | 39,160,850 bytes, `d29a16265d26ef7598209caaf1a544cbfa6abe2858c24b0ce4ae6bff87a76f22` |
| `win-cuda-13.5-x64` | 226,955,179 bytes, `28ebbb62c43039b54e3e0b6da9c2cf869c5747ddb5731070684a2c5ec106638f` |
| `win-cuda-13.5-x64` libraries | unchanged, `c2bf4cc202bfbaaa7a0b75f5082457c3811326947bb216059b72839d844e9cba` |
| `win-cuda-12.4-x64` | 357,985,904 bytes, `7c2f8e99f7ffe244e5cba92e6c2b65f1d04fbabe8d4eb304d3fa200778ccf8f3` |
| `win-cuda-12.4-x64` libraries | unchanged, `8c79a9b226de4b3cacfd1f83d24f962d0773be79f1e7b75c6af4ded7e32ae1d6` |

All 12 pinned sizes and digests match the ones GitHub publishes for `b12774`.
Asset names and CUDA toolkits (13.5 and 12.8 on Linux, 13.5 and 12.4 on
Windows) are unchanged, and the release workflow's CUDA architecture lists did
not change in this range. The Windows CUDA library archives are the same files
as before.

Upstream changes that were checked, by diffing the b12613 and v1.1.0 source
archives:

- **API.** `llama.h` only adds quantization fields (`target_bpw`, `target_size`, `state_file`, an abort callback) to `llama_model_quantize_params`, which the apps don't use. `llama_batch_init`, `llama_batch_free` and `llama_decode`, which the in-process autocomplete runtime calls, were already deprecated at b12613 and still work, so the macOS build shows the same three warnings as before. The seven headers the in-process module imports are all still there.
- **Server flags.** Every flag the apps pass still exists; `--ui-agent` is the only addition. `/props` gains `ui_agent`.
- **Authentication.** The public endpoints are still `/health` and `/v1/health`. The new `/models/sse` progress stream is let through while a model loads but still needs the API key (401 without it, checked on b12774).
- **Reasoning.** `reasoning_effort: "none"` sent at the top level now reaches templates that list `none` ([#32763](https://github.com/ggml-org/llama.cpp/pull/32763)). The apps send Inkling's effort inside `chat_template_kwargs`, which the server already passed through, so their requests are unaffected.
- **Embedding batches.** Non-causal batches now must fit in one ubatch ([#32713](https://github.com/ggml-org/llama.cpp/pull/32713)). The embedder servers run with `-b 2048 -ub 2048`, so nothing changes for them.
- **Log levels.** `common/log.h` is unchanged. A server started with the app's arguments at verbosity 4 kept a marker word from the prompts out of its log on both builds.

## Checks

- **macOS (M4 Max):** `Scripts/build/fetch-llama.sh` built v1.1.0 in 41 s with no compiler warnings. Its layout check passed: every required `lib*.1.dylib`, minimum macOS 15.0, `@loader_path` rpaths. The app and unit tests built against it in 81 s with no new warnings. `python3 -m unittest discover -s Scripts/tests` (313 tests) and the model-free runtime classes `LlamaCoreSmokeTests`, `LlamaServerTests`, `LlamaServerIsolationTests`, `RuntimeAssetSafetyTests` and `CotypingEngineSelectorTests` (46 tests, 1 skipped) passed. No model was loaded on the Mac, so `FileMediaEmbedderReferenceTests` and the real-model cotyping classes were not run.
- **Linux runtime e2e** (Ubuntu 24.04, CPU build): `lokalbot-ai` `runtime::` (45 tests) passed, and all five `e2e_runtime` tests passed in 71 s when run one at a time. Automatic tried Vulkan, then took the CPU build and reported build 12774 (commit 171527522). `an_update_replaces_the_runtime_an_older_version_installed` moved an older runtime to b12774. Notes, digest, ask, dictation and drafting passed with the real Qwen3.5 0.8B model.
- **b12613 and b12774 side by side** (Linux CPU, the app's main and embedder arguments, Qwen3.5 0.8B and EmbeddingGemma 2): chat, streaming, JSON schema output, a tool call, thinking on, `reasoning_effort: none`, `/completion` with `n_probs`, and tokenizing Serbian Latin, Serbian Cyrillic, accented and CJK text all came out identical. Text embedding cosine between the builds was 1.0 for all four inputs. Missing or foreign-origin requests got the same answers (401 without the key).
- **Inkling 2 Mini on Windows** (Radeon RX 6600 XT, `win-vulkan-x64`, the app's arguments with `-ngl 99`), compared with b12602: the app's Off (zero budget, `reasoning_effort: none`), Automatic (budget only) and Low request shapes all finished with `stop`, kept reasoning out of the answer and leaked no template markers. Generation rose from about 4.5 to 5.5 tokens/s, and the model loaded in 42 s instead of 67 s, one run each. Wording changed slightly, as expected from upstream's Inkling tokenizer fix. `/props` now lists `none` among Inkling's effort levels.
