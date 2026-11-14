# Dependency updates — 2026-11-14

| Priority | Component | Update | User impact |
| --- | --- | --- | --- |
| Medium | [llama.cpp](https://github.com/ggml-org/llama.cpp/releases/tag/v1.0.0) | v0.9.0 (build b12110) → v1.0.0 (build b12359) | Updates local chat, structured output, tool calls, embeddings and autocomplete on every platform. ggml moves from 0.29.0 to 1.0.0 and the library names gain major version 1. Linux and Windows fetch the new runtime on their own after updating, and their newer CUDA build moves from CUDA 13.4 to 13.5. Chat, JSON output, tool calls, completions and text and image embeddings came out identical in the probes below on the Mac and with Vulkan on Windows, and Mac speed is unchanged. On a Radeon RX 6600 XT with Vulkan, Qwen3.5 0.8B generates about 1.8× faster and reads prompts about 2.3× faster through the server. The CPU build moves slightly, because upstream now accumulates in F32 on the CPU ([#29810](https://github.com/ggml-org/llama.cpp/pull/29810), [#31854](https://github.com/ggml-org/llama.cpp/pull/31854)): a few greedy words changed on Linux and Windows, and embeddings stay above 0.9998 cosine, so search indexes stay valid. |
| Medium | [FluidAudio](https://github.com/FluidInference/FluidAudio/releases/tag/v0.18.3) | 0.17.7 → 0.18.3 | Parakeet transcription recovers dropped opening speech and repairs seam gaps in long recordings; the CTC mel spectrogram runs on the CPU (fixes all-blank output on M1/M4 with macOS 27.0.1); interrupted model downloads resume. The offline speaker separation keeps one speaker per segment: 0.18.2 changed the default to keep overlapping speech, so LokalBot now sets `exclusiveSegments` itself. |
| Medium | [Pi](https://github.com/earendil-works/pi/releases/tag/v1.5.2) and [Bun](https://github.com/oven-sh/bun/releases/tag/bun-v1.4.4) | pi 1.3.0 → 1.5.2, Bun 1.4.2 → 1.4.4 | Updates Agent Mode's runtime on every platform. Tool arguments are validated by pi's own schema checker, and large streamed tool calls and file reads use less CPU and memory. Setup downloads about 15 MB more, because Bun's archives grew: about 65 MB on macOS, 75 MB on Linux and 80 MB on Windows. Approvals, private-library access and approved-origin restrictions are unchanged. |
| Low | Other Swift packages | 23 packages, within their declared ranges | Listed under Swift packages. Only swift-log (1.16.1 → 1.17.0) is a direct dependency; the rest come in through other packages, mostly speech-swift and MLX-LM. LokalBot's code needed no changes; swift-transformers 1.4.0 now resolves swift-jinja 3.1.0 and swift-huggingface 1.0.0, which its manifest allows. |
| Low | Rust crates (`LinuxWindows/Cargo.lock`) | 112 semver-compatible updates | tokio 1.54, ureq 3.5, zip 9.5, uuid 1.29 and others. notify-rust stays at 4.18.2, because 4.19 adds a third copy of zbus (version 6). |
| Low | Android companion | Gradle 9.8.2 → 9.9.1, Android Gradle plugin 9.5.0 → 9.5.1, kotlinx.serialization 1.12.0 → 1.13.0, Robolectric 4.17 → 4.18, Roborazzi 1.77.0 → 1.79.0 | Gradle 9.9.1 fixes three security issues in the build tool. The app's own libraries were already at their latest stable releases apart from kotlinx.serialization, whose update reverts 1.12.0's exception wrapping and changes nothing the app relies on. The shrunk release build passed the phone trip, and all 38 screenshots matched. |

Not updated, and why:

- **MLX Swift 0.33.0.** mlx-swift-lm 3.32.3, the newest release, accepts only `0.32.x`. Stays at 0.32.3.
- **speech-swift 0.0.29.** Upstream pins mlx-swift-lm 3.31.4 again ([#501](https://github.com/soniqo/speech-swift/pull/501) is still open), so it would move MLX back to 0.31. Taking it means rebasing the fork on 0.0.29 with the 3.32.3 pin. 0.0.29 fixes repeated-request cache growth in Qwen3-ASR, which matters for meeting transcription.
- **Sparkle 2.10.1.** The DigUp fork (pinned by commit) requires Sparkle 2.10.0 exactly.
- **Android targetSdk 37.** Targeting API 37 makes local network access a runtime permission (`ACCESS_LOCAL_NETWORK`), which pairing and sync need, so it is its own change. CameraX 1.7.0, biometric 1.4.0 and Kotlin 2.5.0 are not stable yet.
- **Major versions that need code changes:** sherpa-onnx 2.0 (Mac vendor build and the Rust crate), gpui-kit 0.9 / gpui-pre 0.3.12, rusqlite 0.42, keyring 4, ocrs 0.14 / rten 0.28, lopdf 0.47, ashpd 0.14, global-hotkey 0.10, zbus 6, windows-core 0.100.

## llama.cpp v1.0.0

The `v1.0.0` tag points at commit `b1b770d90d94cad9e9ea5b993bdbc383a522fb28`,
which is also build tag `b12359`. macOS builds the `v1.0.0` source archive and
passes build number 12359, so `llama-server --version` reports
`1.0.0 (build 12359, commit v1.0.0)`. Linux and Windows download the `b12359`
release assets.

| Field | Value |
| --- | --- |
| macOS archive | `https://github.com/ggml-org/llama.cpp/archive/refs/tags/v1.0.0.tar.gz` |
| macOS archive SHA-256 | `3f5f750e36326aea4d65c7623e7d597a33e395d65f4d76e5e0532171f252532b` |
| `ubuntu-x64` | 23,311,084 bytes, `0bc1f091e8916102b6d8f2cf944233a620e90a0f856c72d0ce41150c65c2e72e` |
| `ubuntu-vulkan-x64` | 36,153,377 bytes, `19b60f00395a3f4954e46a5037695bc1d843404fc9d3124f82a612ecd8fbe9f0` |
| `ubuntu-cuda-13.5-x64` | 178,419,847 bytes, `9440f417615bed0e191acef03bff0249117d2be74335358265a6d28475a9baf0` |
| `ubuntu-cuda-13.5-x64` libraries | 444,078,822 bytes, `976a9146bb8a487a6ea701224d7fb14b05e494ab3c8f5c1799ffc4e5805d640c` |
| `ubuntu-cuda-12.8-x64` | 199,223,370 bytes, `50c937bec5bbd9f74c99138034f7403283ee21f1943f2429d7b1e4c079eafc11` |
| `ubuntu-cuda-12.8-x64` libraries | 594,371,571 bytes, `75a12d227f44a391608992329241765343bd143ee9445b90dc62e154ee726e5d` |
| `win-cpu-x64` | 25,097,509 bytes, `837c1655e87df3b66989f4be33a792a1399c785bf259038dc75c900096683e69` |
| `win-vulkan-x64` | 38,090,643 bytes, `e8d18c6e4210cca87e7307c2ea78363ac8d158e4e1397358ec96ab70b53a0d5e` |
| `win-cuda-13.5-x64` | 179,546,112 bytes, `1de9ca1ff408d6e348ea0007c6880ad2393311a02e7799bcde26dc16daef03dd` |
| `win-cuda-13.5-x64` libraries | 426,314,199 bytes, `c2bf4cc202bfbaaa7a0b75f5082457c3811326947bb216059b72839d844e9cba` |
| `win-cuda-12.4-x64` | 318,976,332 bytes, `e9c0abf442e8339c06728366c1ad2c711332f9939c0c00603fb75d85fd44c914` |
| `win-cuda-12.4-x64` libraries | unchanged, `8c79a9b226de4b3cacfd1f83d24f962d0773be79f1e7b75c6af4ded7e32ae1d6` |

Each Linux and Windows asset was downloaded on the Ubuntu box and matches its
pinned size and SHA-256, which are the digests GitHub publishes. The Windows
CUDA 12.4 library archive is the same file as before; every other archive is
new, and the Windows CUDA 13 library archive is now named for 13.5. The CUDA
archives hold the `llama-server`, `libggml-cuda.so`/`ggml-cuda.dll` and the
three runtime libraries `runtime/cuda.rs` places, and `readelf` shows that
`libggml-cuda.so` needs exactly those three plus the driver's `libcuda.so.1`.
The Windows archives still contain `llama-connect.exe`, which neither app
starts.

Upstream changes that were checked:

- **Removed API.** v1.0.0 removes 35 deprecated `llama.h` functions (`llama_token_*`, `llama_n_vocab`, `llama_load_model_from_file`, `llama_new_context_with_model`, `llama_set_warmup` and others), the `defrag_thold` context field and `--defrag-thold`, and `clip.h`. None of the llama, ggml and mtmd functions the Swift sources call is among them, and no app passes the removed flag. `llama_context_params` gains `moe_cache_size` and `moe_cache_cpu_share`; the in-process runtime starts from `llama_context_default_params()`, where the MoE cache is off. The seven headers the in-process module imports are all still there.
- **Library names.** Every library's SOVERSION follows the major version, so the macOS runtime now has `libllama.1.dylib`, `libggml.1.dylib` and so on. `fetch-llama.sh`, its test and the `project.yml` comment name the new files. The app bundles the whole `Vendor/llama-cpp` folder and links through the `libllama.dylib` symlink, so nothing else names them.
- **Server flags.** Every flag the apps pass still exists. The additions are `--allow-unauthenticated-tools`, `--media-allow-private-urls`, `--moe-cache-cpu-share`, `--ple` and `--shard`.
- **Host and Origin checks** ([#32098](https://github.com/ggml-org/llama.cpp/pull/32098), [#32113](https://github.com/ggml-org/llama.cpp/pull/32113), [#32115](https://github.com/ggml-org/llama.cpp/pull/32115)). The new DNS-rebinding and cross-origin guards apply only with `--cors-origins` or when server tools or MCP are enabled. The apps use neither, so the default `*` skips them, and a request with a foreign `Host` or `Origin` still gets the same answer as on v0.9.0 (the API key still gates every endpoint). Remote media URLs to private addresses need a new opt-in; the apps send images and audio inline as base64.
- **Log levels.** `common/log.h` still has TRACE at 4 and DEBUG at 5, and request and response bodies are still logged only at 5. The only new TRACE lines report router proxying, which the apps do not use. The "offloaded N/M layers to GPU" line is unchanged, so the Linux and Windows CUDA servers keep verbosity 4. A server started with the app's arguments at verbosity 4 kept a marker word from the prompt out of its log on both builds.
- **CUDA.** Upstream's CUDA 13 builds moved from 13.4 to 13.5 with the same architecture list (8.6, 8.9 and 12.x prebuilt, PTX from 7.5), so the newer build now needs a CUDA 13.5 driver for PTX on Turing, A100 and H100; prebuilt kernels still run on any CUDA 13 driver. `ggml-cuda` now links cuBLASLt directly, which the companion libraries already include.
- **MoE expert cache, FP8 KV caches, external PLE shards and the `/v1/audio/speech` endpoint** are new and off unless asked for. The apps use none of them.

## Swift packages

FluidAudio is pinned in `project.yml`; the rest moved in `Package.resolved`
after a full re-resolve (cached workspace state removed), each within the
range its parent declares.

| Package | Before → after |
| --- | --- |
| FluidAudio | 0.17.7 → 0.18.3 |
| async-http-client | 1.36.2 → 1.37.0 |
| compress-nio | 1.4.2 → 1.5.0 |
| EventSource | 1.5.1 → 1.6.0 |
| swift-asn1 | 1.7.3 → 1.7.4 |
| swift-async-algorithms | 1.1.5 → 1.1.7 |
| swift-certificates | 1.19.4 → 1.21.1 |
| swift-collections | 1.6.0 → 1.7.6 |
| swift-configuration | 1.2.1 → 1.5.0 |
| swift-distributed-tracing | 1.4.1 → 1.7.4 |
| swift-http-types | 1.6.0 → 1.8.0 |
| swift-huggingface | 0.12.0 → 1.0.0 |
| swift-jinja | 2.5.1 → 3.1.0 |
| swift-log | 1.16.1 → 1.17.0 |
| swift-metrics | 2.11.0 → 2.13.0 |
| swift-nio | 2.103.0 → 2.105.0 |
| swift-nio-extras | 1.34.3 → 1.35.2 |
| swift-nio-http2 | 1.45.0 → 1.46.0 |
| swift-nio-ssl | 2.37.2 → 2.37.6 |
| swift-service-context | 1.3.0 → 1.5.1 |
| swift-service-lifecycle | 2.12.0 → 2.13.0 |
| swift-system | 1.8.1 → 1.9.0 |
| swift-transformers | 1.3.3 → 1.4.0 |
| yyjson | 0.12.0 → 0.13.0 |

swift-collections 1.7.6 declares Swift tools 6.4 but ships a
`Package@swift-6.2.swift` manifest, so Xcode 26.3 and 26.4.1 on CI still
resolve it. FluidAudio 0.18.3 declares tools 6.0.

FluidAudio changes that reach LokalBot:

- **Offline speaker separation.** [#1081](https://github.com/FluidInference/FluidAudio/pull/1081) makes `PostProcessing.community` keep overlapping speech. LokalBot starts from that preset and gives each transcript word one speaker, so `NeuralDiarizationEngine` now sets `exclusiveSegments = true`. Upstream measured that setting to give the same segments as the old default on all 16 AMI meetings; it was not re-run on LokalBot recordings. The CAM++ speaker-embedding fixes ([#1094](https://github.com/FluidInference/FluidAudio/pull/1094), [#1099](https://github.com/FluidInference/FluidAudio/pull/1099)) are for the `_v2` model, which LokalBot does not load.
- **Parakeet long-form decoding** recovers dropped opening speech ([#1056](https://github.com/FluidInference/FluidAudio/pull/1056)) and repairs short seam gaps ([#1061](https://github.com/FluidInference/FluidAudio/pull/1061)). **CTC** runs its mel spectrogram on the CPU ([#1079](https://github.com/FluidInference/FluidAudio/pull/1079)). **Downloads** resume after an interruption instead of deleting the folder ([#1090](https://github.com/FluidInference/FluidAudio/pull/1090)).
- TTS and the diarizer became package traits that are on by default ([#1001](https://github.com/FluidInference/FluidAudio/pull/1001)); the app's products are unchanged.

## Rust crates

`cargo update` in `LinuxWindows/` changed 112 crates, all within the
versions `Cargo.toml` allows. `notify-rust` 4.19.0 moved to zbus 6, while
`keyring` still uses zbus 4 and `ashpd`, AccessKit, `ksni` and
`lokalbot-platform` use zbus 5, so it is held at 4.18.2 with
`cargo update -p notify-rust --precise 4.18.2`.

## Pi 1.5.2 and Bun 1.4.4

The bundled `package.json` pins pi 1.5.2 and the matching `pi-agent-core`,
`pi-ai` and `pi-tui` overrides. `bun.lock` was regenerated from the previous
lockfile with Bun 1.4.4, the new `AgentRuntimeManifest` version. pi's seven
packages moved to 1.5.2, and pi added `@earendil-works/pi-schema`. A few
third-party packages also changed, all because pi now pins them:

- `undici` 8.10.2 → 8.12.3, which pi took for security advisories.
- `minimatch` 10.2.6 → 11.0.3, for the glob denial-of-service fix. It brings `@isaacs/nonrecursive-glob-match` 1.1.0 from the same author and drops the nested `brace-expansion` 5.0.9.
- The terminal Mermaid renderer `grok-mermaid` 0.2.3 is replaced by `lovely-mermaid` 0.3.3.
- `pi-tui` adds `marked-cjk-friendly` 0.1.2.

The install grows from 123 to 125 packages. No other third-party version
moved. The macOS and Linux/Windows templates are identical.

LokalBot's extension uses `registerProvider`, the `tool_call` event,
`before_agent_start` with `systemPromptOptions.sections` and `ctx.ui.confirm`,
and these are unchanged. Between 1.3.0 and 1.5.2 the extension types gained
only additions (keybinding hints, a `blocked` option for custom dialogs, more
Markdown transformer surfaces). `tool_call` still fires after argument
preparation and validation and carries the validated arguments that then run.
`openAICompletionsApi` and `openAIResponsesApi` are still exported from
`pi-ai/compat`. The extension loader now maps that import to a superset: the
compat entry plus TypeBox's `Type`. The `fetch` and `onPayload` stream options
and `compat.supportsMaxOutputTokens` are unchanged.

Every CLI flag the apps pass still exists, and the argument parser changed only
in its help text. The default tools are still `read`, `bash`, `edit` and
`write`, and the RPC message and event types are unchanged.

**Helper copies.** The pi helpers the extension copies to check paths before
approval are byte-for-byte unchanged, both in `dist/` and in the shipped
bundle:

- `normalizePath`, `normalizeWindowsShellPath` and `resolvePath` (`utils/paths.js`);
- `resolveToCwd` and `resolveReadPath` (`core/tools/path-utils.js`).

The tools call the same resolvers as before, so the comments now name 1.5.2.
`paths.js` only gained path-comparison helpers.

**Windows shell lookup.** pi's Bash lookup order on Windows is unchanged:
`shellPath`, then Git Bash under `%ProgramFiles%` and `%ProgramFiles(x86)%`,
then `bash.exe` on `PATH`. pi now accepts Microsoft Store app aliases. That
doesn't matter here, because LokalBot pins `shellPath`, or uses PowerShell, and
never picks a `WindowsApps` Bash. The PowerShell tool also finds
`%ProgramFiles%\PowerShell\7` and Windows PowerShell under `%SystemRoot%` when
they are not on `PATH`.

**Breaking changes.** 1.5.0 validates tool arguments with `pi-schema`. Only the
error text the model sees changes. No LokalBot test matches the old TypeBox
messages, and the extension registers no tools of its own. The 1.5.1 breaking
changes, grep context lines and dropping `"tools": []` when no tools are active,
don't apply to LokalBot.

**Shutdown.** Since 1.5.1, a single SIGTERM no longer cuts short a shutdown
already under way, for example one started by closing stdin. pi still kills the
tool processes it started on every signal, and a second signal exits at once.
Both apps close stdin, send SIGTERM, wait 2 s and then SIGKILL, so stopping
still takes at most about 2 s.

**Privacy-relevant changes, checked in the source:**

- **Telemetry.** No new telemetry, update checks or startup network calls. Install telemetry still runs only in interactive mode, and `PI_TELEMETRY=0` turns it off. `pi-telemetry` is an in-process tracing API with no network code. The provider attribution headers (OpenRouter `HTTP-Referer` and `X-OpenRouter-Title`, NVIDIA, OpenCode) moved into pi-ai's client identity, but they are still sent only with install telemetry on. With `PI_TELEMETRY=0`, none are sent, as before.
- **Startup network.** `--offline` (`PI_OFFLINE`) still turns off the version check (with `PI_SKIP_VERSION_CHECK`), the model-catalog refresh and the automatic `fd`/`rg` downloads. Every package references the same `pi.dev` endpoints as in 1.3.0.
- **User-Agent.** Requests to the Think endpoint send `pi/1.5.2 (darwin; bun/1.4.4; arm64)` instead of `pi (darwin <kernel release>; arm64)`. The OS release is gone, and the pi and Bun versions are added.
- **Idle prompt-cache warming.** 1.5.1 made it the default: one-token refresh requests for up to 30 minutes after a run. It applies only to models with a prompt-cache lifetime and a token price. LokalBot's registered model has neither (`promptCache` unset, cost 0), so pi stops with "cache lifetime unavailable" and sends nothing, as in 1.3.0.
- **Anthropic.** Message threads apply only to pi's `anthropic` provider on the Messages API. Agent Mode reaches Anthropic through its OpenAI-compatible endpoint, so it is unaffected.
- **ChatGPT plan relay.** pi renamed the OpenAI affinity header from `session_id` to `session-id`. The relay forwards only the request body, with its own headers, and the body fields didn't change.
- **Features LokalBot doesn't reach.** The custom `pi update` command, `pi auth login`, extension changelogs and the MCP OAuth changes are out of reach: LokalBot runs pi in RPC mode with a private `PI_CODING_AGENT_DIR` that has no MCP configuration, and loads its extension from a local path.

**Bun 1.4.3–1.4.4.** The lockfile format stays at `lockfileVersion: 2`.
`--frozen-lockfile` is stricter, and the bundled lockfile passes it. Unknown
package-manager flags are now errors. The apps' flags are accepted: both
installs ran with exactly those flags. TLS certificates are now checked during
the handshake, HTTP parsing is stricter, and NSS 3.128 drops a few root CAs.
`ALL_PROXY` is now used when `HTTP_PROXY` and `HTTPS_PROXY` are unset. Bun's
archives grew by about 15 MB each, and the binaries by 27–29 MB.

| Pin | Value |
| --- | --- |
| `package.json` | `493e0f739297dd7e1906cfdc394aeb3e89ec4aa3a1910fe48a4e615952490665` |
| `bun.lock` | `82710b2df114f1a091d5f04b8f7a2d6e711d79ca8c4085e7c89cc9e8776ce230` |
| `cli.js` | unchanged; it is a 160-byte loader |
| Tree, macOS and Linux | `1b3ef0bd494367a8465762f22a6dd90bd5e02196cac51acf1ce279a421e690c5` |
| Tree, Windows | `a4630c4e76e6adeaa9eb8fbce0df7f4b46ea7a87701e447199c793613723221f` |

| Bun 1.4.4 asset | Archive | Binary |
| --- | --- | --- |
| `bun-darwin-aarch64.zip` | 40,323,673 bytes, `c240d7f0ccb90c263a849fcdb09b7ee62630d921348ed6aafda86b9d577bc510` | `0a2237cdcfa0d16ef501d9acca9f0026309ef348bea7393a64e8d1e3609565cc` |
| `bun-linux-x64.zip` | 51,794,595 bytes, `bf8ccbfb2b0b80159e0f9a6d15c55317add8077534dbc6130a3edb52fccb395c` | `10702245766b225e70bbf6235fd6b47214fd94b4760d00ffaed8ab0df57ac235` |
| `bun-windows-x64.zip` | 54,731,706 bytes, `cd2c0fccc78f3ede1f50ca827a15f063eda13d4d150a3d0674f4f6e323d864a5` | `cb1d8e6564e655e49d30cead359750a1cbbd12f42651caa4b62244d7bd93c244` |

Each archive was downloaded, hashed and matched against the digest GitHub
publishes. The `x64-baseline` archives hold the same Linux and Windows
binaries, so one pin per OS still serves every x86-64 CPU. Each tree digest
comes from two clean `bun install --production --frozen-lockfile
--ignore-scripts` runs on that OS. The same procedure first reproduced the
1.3.0 pins on macOS and Windows.

On macOS and Linux the tree doesn't depend on the Bun version: Bun 1.4.4
installs the 1.3.0 lockfile with the old digest. On Windows it does. Bun 1.4.4
ships new `.bin\*.exe` launchers, and these eight files are the only
difference.

**Setup sizes.** The npm packages grow from 24.4 to 25.3 MB, and the pi tree
from 112.6 to 116.0 MB on Linux. Setup copy now reads:

| | Download | Installed |
| --- | --- | --- |
| macOS | about 65 MB (was 50) | about 215 MB |
| Linux | 75 MB (was 60) | 225 MB (was 190) |
| Windows | 80 MB (was 65) | 230 MB (was 200) |

The macOS installed figure is Bun's 88.7 MB plus the 125.4 MB tree. The old
225 MB figure was already out of date. The Linux and Windows figures come from
the manifest. The README now says about 75 MB on Linux and 80 MB on Windows.

**Upgrade behavior.** An existing Agent Mode runtime no longer matches its
receipt, so the normal explicit setup installs Bun 1.4.4 and the new frozen
lockfile, then verifies them. Conversation files are stored apart from the
runtime cache.

## iPhone and iPad companion

The iOS app and `LokalBotCompanionKit` use no third-party Swift packages. Their
one dependency is the shared Rust crate `lokalbot-sync`, which picks up the
Cargo.lock updates above through `Scripts/build/build-sync-xcframework.sh`.

## Android companion

Five build and test pins move to their latest stable releases. Every library the
app ships was already at its latest stable release except kotlinx.serialization,
so CameraX, ML Kit, WorkManager, DataStore, biometric and JNA are unchanged. The
shrunk release build passed the phone trip on an emulator, and all 38 screenshot
goldens matched without re-recording.

| Pin | Before | After | Notes |
| --- | --- | --- | --- |
| Gradle wrapper | 9.8.2 | [9.9.1](https://docs.gradle.org/9.9.1/release-notes.html) | `distributionSha256Sum` is Gradle's published `d8a18a7a841dd5df825d35a685fad6f2d7f12ac0c280e57b67c27b4a520ba228`. The wrapper task regenerated `gradle-wrapper.jar`, which now matches Gradle's published 9.9.1 wrapper checksum `621008afc4f5d59357fcf06ffa644dd5aade5e091bdc363742710445f73cdaf8`. `gradlew` and `gradlew.bat` are unchanged. |
| Android Gradle plugin | 9.5.0 | [9.5.1](https://developer.android.com/build/releases/agp-9-5-0-release-notes) | Bundles R8 9.5.29 instead of 9.5.28. |
| kotlinx.serialization | 1.12.0 | [1.13.0](https://github.com/Kotlin/kotlinx.serialization/releases/tag/v1.13.0) | Built on Kotlin 2.4.10, so it works with the 2.4.21 plugin. |
| Robolectric | 4.17 | [4.18](https://github.com/robolectric/robolectric/releases/tag/robolectric-4.18) | Tests only. |
| Roborazzi | 1.77.0 | [1.79.0](https://github.com/takahirom/roborazzi/releases/tag/1.79.0) | Tests only. |

Already at the latest stable release: Kotlin 2.4.21 (2.5.0 is at RC), coroutines
1.11.0, Compose BOM 2026.09.00, Material 3 Adaptive 1.3.0, activity 1.13.0,
core-ktx 1.19.1, lifecycle 2.11.0, DataStore 1.3.0, window 1.5.1, WorkManager
2.12.0, CameraX 1.6.2 (1.7.0 is at rc02), ML Kit barcode scanning 17.3.0,
biometric 1.1.0 (1.4.0 is at beta01), fragment 1.9.1, JNA 5.19.1, JUnit 4.13.2,
Truth 1.4.5, AndroidX Test core 1.7.0 and ext-junit 1.3.0. UniFFI stays at 0.32.2
in `Cargo.lock`, so JNA and the generated Kotlin bindings are unchanged.

Not changed, and why:

- **targetSdk 36.** API 37 is available, but targeting it makes local network access the runtime permission `ACCESS_LOCAL_NETWORK`, so it needs its own change (see `Companion/android/README.md`). minSdk stays 29.
- **compileSdk 37.** Platforms 37.1 and 37.2 (minor SDK releases) are stable, but no dependency needs them, and CI and the box install `android-37.0`.
- **NDK r30** (30.0.16248370) is stable. The NDK isn't pinned in Gradle: `build-sync-android.sh` takes the newest one installed, and the box and README use r29.
- **cargo-ndk 4.1.2**, pinned in the workflow, is already the latest release.

Upstream changes that were checked:

- **Gradle 9.9.1** fixes three security issues: version-catalog values run as code in generated accessors (rated critical, 9.3), the client trusting the daemon registry (8.6), and port squatting through stale registry entries (7.0). It also brings faster Kotlin DSL recompilation. The build reported no Gradle deprecations. The only problems it reported are Compose test-rule deprecations in the test sources, which predate this update.
- **AGP 9.5.1** lists no public fixes. AGP 9.5 needs Gradle 9.6.0 or later and supports API levels up to 37. The R8 update from 9.5.28 to 9.5.29 was checked by running the shrunk release build on the emulator, not by reading the keep rules. The trip opened the QR scanner, and logcat had no `Could not instantiate` from `ComponentDiscovery` and no `ClassNotFound`, `NoSuchMethod` or fatal exception. ML Kit's barcode module loaded, and pairing, sync and recording through the JNA and UniFFI core all worked.
- **kotlinx.serialization 1.13.0** reverts 1.12.0's breaking change, which wrapped every exception a serializer threw in a `JsonException`, and makes `JsonElement.toString` faster. The app's records have no custom serializers and no `init` checks. Its decoding call sites either catch everything (`PairingLink`) or turn an `IllegalStateException` into a cancellation only after the library has closed (`RustRepository.alive`), so behavior is the same as on 1.12.0.
- **Robolectric 4.18** drops SDK 23 and removes `@TextLayoutMode`, `shadows-httpclient` and `ShadowRemoteCallbackList`. The tests use none of these, and they run on the default SDK 36 and on SDK 32. Robolectric now extracts its native-runtime fonts and ICU once into `/tmp/robolectric-nativeruntime-assets` (about 190 MB), shared between runs.
- **Roborazzi 1.78.0** writes opaque screenshots as RGB PNGs. `verify` still passes against the goldens, but the next `recordRoborazziDebug` rewrites every golden's bytes once with the same pixels, so review that commit by pixels. Version 1.79.0 adds an experimental accessibility-legend capture and recycles bitmaps sooner. Roborazzi builds against Robolectric 4.14.1 and runs on 4.18.

## Verification

- **macOS vendor build.** `bash Scripts/build/fetch-llama.sh` cold-built v1.0.0 in 35 s. CMake printed only its usual configuration notes (no OpenMP, no `.git`, no web UI). The receipt validates, and the runtime has the same file set with the version suffixes moving to 1 (57 MB, as before). `python3 -m unittest discover -s Scripts/tests` ran 222 tests: OK. `swiftlint lint --strict --quiet` passed.
- **macOS app.** `build-for-testing` succeeded with every update, with no new warnings from LokalBot's sources; the Xcode build phase rebuilt `lokalbot-sync` from the new Cargo.lock. The whole unit bundle ran 4,991 tests with real models (`TEST_RUNNER_LOKALBOT_COTYPING_TEST_MODEL` and `…_CANDIDATE_TEST_MODEL` set to Gemma 4 E2B, `…_MEDIA_EMBEDDER_MODELS` to the app's models folder): 48 skipped and 2 failures, both in `TranscriptionModelStoreTests` and both caused by FluidAudio's stricter cache check (see Changed test expectations below). With the fixtures fixed, `TranscriptionModelStoreTests`, `PinnedSpeechCatalogTests` and `PinnedModelSnapshotTests` ran 19 tests with 0 failures. The llama.cpp classes passed against v1.0.0: `FileMediaEmbedderReferenceTests` 2/2 (it asks to be run for every llama.cpp update), `LlamaCoreSmokeTests` 2/2, `LlamaCotypingRuntimeTests` 10/11 and `LlamaServerTests` 9/10 with one fixture skip each, `LocalLlamaCotypingEngineTests` 3/3, `CotypingFirstWordConfidenceTests` 18/18 and `CotypingTokenHealingTests` 8/8. With every update in this report applied, the whole bundle ran again: 4,992 tests, 0 failures, 47 skipped. That run also set `TEST_RUNNER_LOKALBOT_PINNED_RUNTIME_TREE` and `…_PINNED_RUNTIME_ROOT` to a fresh pi 1.5.2 install, so `AgentRuntimeTests/testCurrentManifestMatchesProvidedPinnedRuntimeTree` checked the new macOS tree pin and `PiIntegrationTests/testPromptRoundTripsThroughRealPi` ran a prompt through the real runtime; both passed. The remaining skips need a live ChatGPT plan, private fixtures or models not on this Mac.
- **Server probes.** The same script ran each build with the app's arguments and compared `/props`, `/tokenize` on Serbian text, chat with and without thinking, streamed chat, JSON-schema output, a tool call (plain and streamed), the too-long-prompt error, `/completion` with `n_probs` and prompt-cache reuse, embeddings (text, an over-long input, and on the Mac a PNG screen and a JPEG photo through the projector), 401 without the token, and requests with a foreign `Host` or a browser `Origin`.

  | Platform | Backend | Models | Result |
  | --- | --- | --- | --- |
  | macOS, M4 Max | Metal | Qwen3.5 4B, Gemma 4 E2B, LFM2.5 1.2B, EmbeddingGemma 2 + projector | Identical, apart from random tool-call ids; vectors at cosine 1.000000 |
  | Windows, Radeon RX 6600 XT | Vulkan | Qwen3.5 0.8B, EmbeddingGemma 2 | Identical; vectors at cosine 1.000000 |
  | Windows, i5-13400F | CPU | Qwen3.5 0.8B, EmbeddingGemma 2 | One chat reply lost a word and one completion picked another; log-probabilities within 0.27; vectors at 0.99983–0.99994 |
  | Linux, Ryzen 7 9700X | CPU | Qwen3.5 0.8B, EmbeddingGemma 2 | One chat reply ended a clause earlier; log-probabilities within 0.17; vectors at 0.99988–0.99993 |

  JSON output, tool-call names and arguments, error types and every auth and `Host`/`Origin` status were the same on both builds everywhere. At verbosity 4, a marker word from the prompt stayed out of the server log on both builds, and the GPU offload line is still printed.
- **Speed.** About 2,480 prompt tokens and 256 generated tokens, three alternating runs per build, medians, through `llama-server` with the app's sizing. Only Windows Vulkan moved beyond run-to-run noise, and it got faster: `llama-bench` on the same card agrees for generation (tg128 91.6 → about 181 tok/s, with ±16 tok/s spread on the new build) but shows only 6% more raw prompt speed (pp2048 2,898 → 3,078 tok/s), so most of the server's prompt gain comes from the server itself. One candidate is [#30137](https://github.com/ggml-org/llama.cpp/pull/30137), which stops deep-copying context checkpoints, which hybrid models like Qwen3.5 save while reading a prompt; it was not isolated.

  | Platform | Model | Prefill v0.9.0 → v1.0.0 (tok/s) | Decode v0.9.0 → v1.0.0 (tok/s) |
  | --- | --- | ---: | ---: |
  | macOS, Metal | Gemma 4 E2B | 7,567 → 7,612 | 132.9 → 132.6 |
  | macOS, Metal | Qwen3.5 4B | 1,492 → 1,457 | 104.5 → 104.7 |
  | Windows, Vulkan (RX 6600 XT) | Qwen3.5 0.8B | 1,129 → 2,620 | 85.3 → 155.2 |
  | Windows, CPU (i5-13400F) | Qwen3.5 0.8B | 546 → 533 | 49.5 → 48.0 |
  | Linux, CPU | Qwen3.5 0.8B | 1,235 → 1,259 | 71.1 → 71.6 |
- **Linux** (Ubuntu box). `cargo fmt --all --check`, `cargo clippy --workspace --all-targets --locked -- -D warnings` and `cargo test --workspace --locked` passed: 2,715 tests, 0 failed, 28 ignored. The opt-in `e2e_runtime` suite passed all five tests on the CPU build: it installed b12359 through `RuntimeManager`, downloaded and verified Qwen3.5 0.8B and EmbeddingGemma 2, covered chat, schema output, streaming, embeddings, Ask, dictation, a day digest and meeting notes, and `an_update_replaces_the_runtime_an_older_version_installed` replaced an older build's folders with b12359. The same `fmt`, `clippy` and workspace test commands passed again with every update in this report applied, Agent Mode included: 2,715 passed, 0 failed.
- **Windows** (PC, Radeon RX 6600 XT). `cargo test -p lokalbot-ai --lib runtime::` ran 37 passed. The opt-in install test fetched `win-vulkan-x64` and started it (2.6 s), and `an_update_replaces_the_runtime_an_older_version_installed` replaced an older build's folder with b12359 on Vulkan.
- **Agent Mode runtime (pi and Bun).**
  - **Python.** `python3 -m unittest discover -s Scripts/tests` ran 222 tests: OK, including `test_fetch_bun`.
  - **Rust, Ubuntu box.** `cargo fmt --check`, `cargo clippy -p lokalbot-agent --all-targets --locked -- -D warnings` and `cargo test -p lokalbot-agent --locked` passed: 182 passed, 0 failed.
  - **End to end, Ubuntu box.** The opt-in `agent_turn` example ran with `--install --download-model --approve`. The real installer downloaded Bun 1.4.4, checked the archive and binary, installed pi 1.5.2 from the frozen lockfile and verified the tree; the receipt matches every pin. Qwen3.5 4B on CPU then made one `write` call. The approval card showed it, it was approved, the file was written and the session saved, in 22.3 s.
  - **Pi extension suites**, against the new runtime with the pinned Bun:
    - macOS: 45 passed.
    - Linux: 43 passed, plus 1 Windows-only skip.
    - Windows: 43 passed, 1 failed. The failing test, `a file URL pi can't open asks instead of failing the check`, also fails with the old runtime (Bun 1.4.2 + pi 1.3.0), so this update didn't cause it. On Windows `file://evil.example/etc/hosts` resolves to a UNC path, so the approval card names a path. The approval is still requested.
  - **Model stub.** `stub-openai.ts` serves `/v1/models` and streamed chat completions under Bun 1.4.4.
  - **Windows** (PC, Radeon RX 6600 XT). `cargo test -p lokalbot-agent --locked` ran 177 passed, 0 failed. `agent_turn --install --download-model --approve` installed Bun 1.4.4 and pi 1.5.2 into an empty library, and the runtime passed the integrity check against the new Windows tree pin. Qwen3.5 4B on the b12359 Vulkan runtime then made one `write`, the approval card was answered, the file was written and the session saved, in 28.2 s.
- **iPhone and iPad.** `swift test --package-path Companion/ios/LokalBotCompanionKit` ran 74 tests: passed. The app built for the iOS Simulator and for devices, as in CI, against `lokalbot-sync` built from the new Cargo.lock. The Simulator end-to-end trip was left to CI.
- **Android** (Ubuntu box, JDK 21, Android SDK 37.0, NDK r29). The checks ran on a copy of the worktree, with the same commands as CI:

  - `build-sync-android.sh` built the sync core in 72 s.
  - `./gradlew :app:assembleDebug :app:testDebugUnitTest :app:verifyRoborazziDebug :app:lintDebug` passed in 86 s. It ran 139 unit tests with no failures or skips, Roborazzi reported 38 of 38 screenshots unchanged, and lint passed.
  - `python3 -m unittest discover -s Companion/e2e` ran 23 tests: OK.
  - `./gradlew :app:assembleRelease` passed in 63 s without any signing key, and R8 ran rather than coming from the cache. The unsigned APK is 27.3 MB. The `companion_host` example built.
  - The release-build phone trip, `Companion/e2e/own_emulator.py` running `android_trip.py` on the unsigned APK (the trip signs it with the debug key), passed twice, in 221 s and 215 s including emulator boot. In the timed second run, boot took 21 s and the trip 3 min 12 s. The main steps were opening every screen (52 s), the recording while the computer was away (46 s), the first recording (23 s) and the force-stopped recording (21 s).
- **Not run.** CUDA with b12359 on any GPU: the CUDA archives were checked by hash, layout and linked libraries only, and the CUDA 13.5 build needs an NVIDIA GPU (a rented one, as for the last update). No UI tests ran locally; they run in CI. No summary replay was run on a private meeting, and nothing was installed or released.

## Changed test expectations

- `TranscriptionModelStoreTests/testDownloadedChoicesReadDiskCaches` and `testUltraRequiresItsOwnCompleteCacheAndDeletionPreservesV3`: expectations unchanged, fixtures changed. They wrote empty files named `*.mlmodelc`; FluidAudio 0.18 counts a compiled model only when it is a folder with `coremldata.bin` and no `*.partial` file inside (issue [#1067](https://github.com/FluidInference/FluidAudio/issues/1067), fixed in [#1090](https://github.com/FluidInference/FluidAudio/pull/1090)), so the fixtures now write that minimal folder. Real installs from the pinned snapshots already have it; every Parakeet, VAD and diarization model on this Mac passes the new check.
- `AgentRuntimeTests/testManifestPinsExpectedVersions` (Swift) and `manifest::tests::manifest_pins_expected_versions` (Rust): Bun 1.4.2 → 1.4.4, pi 1.3.0 → 1.5.2 and the `bun-v1.4.4` URL. They assert the pinned versions, which this update changes on purpose.
- `runtime::tests` on Linux and Windows: the build in the expected download URL and the parsed folder name move from b12110 to b12359, the stored CUDA build name from "CUDA 13.4" to "CUDA 13.5", and `runtime/cuda.rs`'s selection tests use a CUDA 13.5 driver (13050) where they used 13.4. A 13.4 driver now gets the CUDA 12 build for Turing, A100 and H100, because it cannot compile 13.5 PTX.
- New: `testInterruptedParakeetDownloadIsNotDownloaded` checks that a Parakeet folder with a `*.partial` file inside a compiled model, or with a plain file where the model folder should be, no longer counts as downloaded.

Known gap: on Windows, an interrupted download of the CUDA 13.4 library archive (`cudart-llama-bin-win-cuda-13.4-x64.zip`, no build number in its name) is not removed by the old-build cleanup, which goes by build number. It only exists where a CUDA setup was interrupted.
