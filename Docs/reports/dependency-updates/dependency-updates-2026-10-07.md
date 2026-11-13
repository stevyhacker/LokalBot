# Dependency updates — 2026-10-07

| Priority | Component | Update | User impact |
| --- | --- | --- | --- |
| High | [llama.cpp](https://github.com/ggml-org/llama.cpp/releases/tag/b11474) | v0.6.0 → b11474 | Adds EmbeddingGemma 2 support ([ggml-org/llama.cpp#30054](https://github.com/ggml-org/llama.cpp/pull/30054)), which the next search-model switch needs. Chat, structured output, tool calls, embeddings and autocomplete keep their models and settings. Still built from checksum-pinned source for macOS 15, with generic arm64 CPU code and bundle-relative libraries. |

## Why a build tag

No `v*` tag after v0.6.0 contains #30054 yet; the GitHub compare API shows
v0.6.0 23 commits behind its merge and b11474 22 commits ahead of it. b11454 is
the first published build with the change. The source archive has no `.git`, so
upstream build-info would report build 0; `Scripts/build/fetch-llama.sh` passes
`LLAMA_BUILD_NUMBER` and `llama-server --version` reports
`0.6.0 (build 11474, commit b11474)`.

| Field | Value |
| --- | --- |
| Tag | `b11474` |
| Commit | `b9acf138a1e28ce1fc23b5a4fc4b12444b50f7ea` |
| Archive | `https://github.com/ggml-org/llama.cpp/archive/refs/tags/b11474.tar.gz` |
| Computed SHA-256 | `ccbd56a50f965442b4cefdab5262b6d9b8e45a8041fb0cc6faa5d564d9b18b72` |

From v0.6.0 the public headers change only additively (`LLAMA_VOCAB_TYPE_PLAMO3`
and a scheduler copy callback); the in-process autocomplete runtime needed no
Swift changes. Two upstream behaviour changes were checked: greedy selection for
temperature-zero sampler chains (autocomplete samples at 0.1) and cpp-httplib
0.60 in the server.

## Verification

- **Vendor build.** A cold source build produced all required files. All 26 Mach-O files declare minimum macOS 15.0 and `@loader_path` rpaths. The receipt and manifest validate, a second run is a cache hit, and a relocated copy still loads.
- **Build and tests.** XcodeGen, `build-for-testing` for the app and unit tests, and the 105 script tests passed. The focused llama suites passed: 125 tests, 1 opt-in skip (the Granite replay). They cover `LlamaCoreSmokeTests`, `LlamaSamplerSpecTests`, `LlamaServerTests`, `RuntimeAssetSafetyTests`, `InferenceBrokerTests`, `TextEngineTests` and `ChatAgentTests`. They also cover the real-model autocomplete classes, `LocalLlamaCotypingEngineTests` and `LlamaCotypingRuntimeTests`.
- **Embeddings.** The vendored source build reproduces the vectors of the b11469 upstream release exactly (cosine 1.000000) for Harrier, EmbeddingGemma 2 text and EmbeddingGemma 2 image inputs. Retrieval scores on the synthetic fixtures are unchanged.
- **Summaries.** `Benchmarks/think/SummaryEfficiency` replayed one private 26-minute meeting with Qwen3.5-4B, three alternating runs per runtime. All 12 cold and warm runs completed with complete envelopes. Model sampling varies the number of requests from run to run, so decode speed is the comparable figure:

  | Run | v0.6.0 median decode | b11474 median decode |
  | --- | ---: | ---: |
  | Cold | 87.4 tok/s | 84.0 tok/s |
  | Warm | 77.5 tok/s | 89.2 tok/s |

  The first cold run of the new binary decoded at 54 tok/s; the later two ran at 84 tok/s. That fits a one-time Metal shader compile for a new binary.
