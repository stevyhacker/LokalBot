# Dependency updates — 2026-10-21

| Priority | Component | Update | User impact |
| --- | --- | --- | --- |
| Medium | [Pi](https://github.com/earendil-works/pi/releases/tag/v1.3.0) | 1.0.3 → 1.3.0 | Updates Agent Mode's runtime on every platform. Tool calls whose final arguments are malformed JSON now fail validation instead of running with the fields parsed before the error; more transient provider errors are retried. Setup downloads about 5 MB less and installs 11–12 MB less, because pi no longer depends on `chord` and `esbuild`. Approvals, private-library access and approved-origin restrictions are unchanged. |
| Medium | [llama.cpp](https://github.com/ggml-org/llama.cpp/releases/tag/v0.7.0) | b11474 → v0.7.0 (build b11669) | Updates local chat, structured output, tool calls, embeddings and autocomplete on every platform. Embedding servers skip the LM head, prompt-cache restores are more reliable, and ggml moves to 0.27.0. Models, settings and outputs are unchanged in the probes below. macOS still builds checksum-pinned source for macOS 15 with generic arm64 CPU code and bundle-relative libraries. |

## Pi 1.3.0

The bundled `package.json` pins 1.3.0 and the matching `pi-agent-core`,
`pi-ai` and `pi-tui` overrides. `bun.lock` was regenerated from the previous
lockfile with Bun 1.4.2, the version in `AgentRuntimeManifest`. Only pi's own
packages changed version; `@earendil-works/chord`, `esbuild` and its 26
platform packages left the tree (126 → 123 packages), and no third-party
version moved. The macOS and Linux/Windows templates are identical.

LokalBot's extension uses only `registerProvider` and the `tool_call` event.
`ToolCallEvent` and `ToolCallEventResult` are unchanged, and
`openAICompletionsApi` is still exported from `pi-ai/compat`. The 1.2.0
breaking changes (`before_agent_start` as a union, busy-session semantics)
concern events the extension does not use. The pi helpers that the extension
copies to check paths before approval (`normalizePath`, `resolveToCwd`,
`resolveReadPath`, `normalizeWindowsShellPath`) and pi's Windows shell lookup
are byte-for-byte unchanged, so their comments now name 1.3.0. The `read` tool
only gained structured output.

| Pin | Value |
| --- | --- |
| `package.json` | `bdc29089f9460b2fda49be93cc4a804fb852bdcc88ff6915fb9bea85ce01a40b` |
| `bun.lock` | `7acf67d8ff01a8118e447d5494fcd17a23d8d8ec90f2836385e99bb7f7e474ff` |
| `cli.js` | unchanged; it is a 160-byte loader |
| Tree, macOS and Linux | `c9ee7086e5c6b38f6362f095704519b9a91d27200415382d0d733342f2b974be` |
| Tree, Windows | `b08b18bf247139aeba1abac52baaea03ba7733a9877140440fce536ead545e27` |

Without esbuild's per-platform binary, the macOS and Linux trees are now
identical. Windows still differs because Bun writes `.bin` shims there. Each
tree digest comes from two clean
`bun install --production --frozen-lockfile --ignore-scripts` runs on that OS.
The same procedure first reproduced every 1.0.3 pin.

**Upgrade behavior.** An existing Agent Mode runtime no longer matches its
receipt, so the normal explicit setup installs the new frozen lockfile and
verifies it. Conversation files are stored apart from the runtime cache.

## llama.cpp v0.7.0

The `v0.7.0` tag points at commit `620d2225cc436ab0b001e3200e590e3b286ef9ab`,
which is also build tag `b11669`. macOS builds the `v0.7.0` source archive.
Its archive has no `.git`, so `Scripts/fetch-llama.sh` passes build number
11669, and `llama-server --version` reports
`0.7.0 (build 11669, commit v0.7.0)`. Linux and Windows download the `b11669`
release assets, whose servers report `0.7.0-dev (build 11669, commit 620d2225c)`.

| Field | Value |
| --- | --- |
| macOS archive | `https://github.com/ggml-org/llama.cpp/archive/refs/tags/v0.7.0.tar.gz` |
| macOS archive SHA-256 | `55d67acf3ad2ad747a9bbeb75f9f0e173dbcc0d1753a471038a90c819421c5e1` |
| `ubuntu-x64` | 17,851,611 bytes, `cf07c1c112d709bd67e522017471de57ed0ec8bea031d732c5422351c07f65ac` |
| `ubuntu-vulkan-x64` | 30,497,889 bytes, `e8709e5ba6c1b093dea7f3de57f4aba842f9a188fba6b465782d65d6fcfa4d9f` |
| `win-cpu-x64` | 19,537,886 bytes, `37b3efcf962847ca869745fd4ccf7f5e7e8dacfeff9fa3523b4ca8cdc66d632b` |
| `win-vulkan-x64` | 32,182,350 bytes, `2c07574e7bde71321cb785282b20cc821e951132149eeceeea32ddebdbf0598e` |

Each release asset was downloaded and hashed, and matches the digest GitHub
publishes for it.

Upstream changes that were checked:

- **Default port 9931.** Both apps always pass `--port`.
- **Server chat refactor** (session-based parsing, part-based formatted output). Chat, streaming, JSON-schema output and tool calls returned identical results in the probes below.
- **Embeddings skip the LM head** when pooling is set. Vectors match b11474.
- **ggml 0.27.0 hides symbols by default.** The in-process autocomplete runtime still links, loads and runs.
- **Public headers change only additively:** `moe_cache_size` in `llama_context_params` and two graph-reallocation counters in `llama_perf_context_data`.
- **Server flags.** Every flag the apps pass still exists, including `--no-webui` and `--no-ui`.

## Verification

- **macOS vendor build.** `bash Scripts/fetch-llama.sh` cold-built v0.7.0 in 41 s. The receipt validates and the runtime has the same file set as before, with the version suffixes moving to ggml 0.27.0 and llama 0.7.0.
- **Build.** XcodeGen and `build-for-testing` for the app and `LokalBotTests` succeeded. `python3 -m unittest discover -s Scripts/tests` ran 138 tests: OK.
- **Focused macOS suites: 224 tests, 0 failures, 3 opt-in skips.** The classes were `LlamaCoreSmokeTests`, `LlamaSamplerSpecTests`, `LlamaServerTests`, `LlamaServerIsolationTests`, `RuntimeAssetSafetyTests`, `InferenceBrokerTests`, `TextEngineTests`, `LeasedTextEngineTests` and `ChatAgentTests`. They also included the real-model autocomplete classes `LocalLlamaCotypingEngineTests` and `LlamaCotypingRuntimeTests`, and the Agent Mode classes `AgentRuntimeTests`, `AgentRuntimeInstallerTests`, `AgentSetupTests`, `PiLaunchPlannerTests`, `PiIntegrationTests`, `PiProcessTests`, `PiRPCClientTests` and `AgentWorkspaceTests`. Two of the skips are opt-in checks that were then run against a fresh 1.3.0 install, and both passed: `AgentRuntimeTests/testCurrentManifestMatchesProvidedPinnedRuntimeTree` (the app's own verifier) and `PiIntegrationTests/testPromptRoundTripsThroughRealPi`. The third skip is the Granite region replay, which needs a private replay manifest.
- **Pi extension suites.** These ran against the fresh 1.3.0 install with the pinned Bun on each OS. macOS: 38 passed. Linux: 33 passed, plus 1 Windows-only skip. Windows: 34 passed, including the Git Bash drive-path check.
- **Server probes, macOS.** The app's arguments were used with Qwen3.5 4B and EmbeddingGemma 2, comparing b11474 and v0.7.0. They gave identical results for `/props` context size, `/tokenize`, chat, streamed chat, JSON-schema output, a tool call (plain and streamed) and `/completion` with `n_probs`, stop type and timings. Embedding cosine against b11474 was 0.9999998, 1.0 and 1.0.
- **Speed, macOS.** Qwen3.5 4B, 1,612 prompt tokens and 256 generated tokens, three alternating runs per build after a warm-up request. Median prefill was 1,376 (b11474) and 1,246 (v0.7.0) tok/s; median decode was 97.2 and 93.9 tok/s. The laptop was on battery and both builds slowed run over run, and the paired decode differences were +0.5%, +5.3% and −10%. This shows no clear regression, but it is not a precise comparison.
- **Linux** (Ubuntu box, CPU). `cargo fmt --check` and `clippy -D warnings` for `lokalbot-agent` and `lokalbot-ai` passed, and their tests ran 414 passed, 0 failed. The opt-in `e2e_runtime` suite passed all four tests. It installed the b11669 asset through `RuntimeManager`, downloaded and verified Qwen3.5 0.8B and EmbeddingGemma 2, and covered chat, schema output, streaming, embeddings, Ask, dictation, a day digest and meeting notes.
- **Windows** (PC, Radeon RX 6600 XT). The `win-vulkan-x64` asset and both models were downloaded and checked against their pins. The probe script passed on Vulkan with the same checks as on macOS.
- **Not run.** No UI tests ran locally; they run on hosted CI. `cargo test` for the whole Windows workspace runs in CI. No summary replay was run on a private meeting, and nothing was installed or released.
