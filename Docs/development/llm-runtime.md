# Built-in LLM runtime — llama.cpp & model catalog

Part of the [development guide](../../DEVELOPMENT.md).

- `LlamaServer` copies the vendored `llama-server` out of Resources into Application Support on first run (never executes from inside the bundle), spawns it (`-ngl 99 --jinja`, port 17872), health-checks `/health`, restarts on model switch, and terminates on quit. Each bundled version gets its own `llama-cpp/<sha256>/` folder (sherpa-onnx likewise). A running app holds a shared lock (`.claim-<sha256>.lock`) on every version it uses until it quits, and each install removes the versions that no app claims and no process runs from, along with the flat layout older releases installed.
- **Ports:** the release app's servers listen on main 17872, embeddings 17873, cotyping fallback 17874, Granite ASR 17875 and the Files media embedder 17876; the CLI and MCP `ask_library` connect to 17872. Release-identity builds run from Xcode share them. Every other copy gets its own block (`LocalRuntimeOwner`, `LlamaServerRole`): LokalBot Dev 17882–17886, the UI Test Host 17892–17896, and the unit-test host 17902–17906. Binaries, PID markers and bearer tokens live in the identity's Application Support folder; the unit-test host carries the release bundle id, so it uses `me.dotenv.LokalBot.unit-tests` instead. Residency ids and Resource Monitor labels name the role (`llama-server:main`, `:embedder`, `:cotyping`, `:granite-asr`, `:media-embedder`), not the port.
- **Orphaned helpers:** when a server's port is held by a LokalBot llama-server whose app has exited (its parent is launchd, it runs from a `me.dotenv.LokalBot*/llama-cpp/` runtime, and no PID marker there names a live owner), `LlamaServer.start` stops it and logs one line instead of failing with "port … is already in use". A helper still owned by a running app is never touched. To check by hand: `lsof -nP -iTCP:17873 -sTCP:LISTEN`, then the listener's parent (`ps -o ppid= -p <pid>`) and executable path.
- **Inference broker:** the three shared llama-servers — main (17872), embeddings (17873), cotyping fallback (17874) — are lease-managed by `InferenceBroker`: consumers take per-request leases, a server with no active leases unloads after a short linger, and loaded models sit under a RAM residency budget with LRU eviction. Settings → Diagnostics shows a live **resource monitor** of what's loaded and which lease is pinning it. The MLX speech engines (Qwen3-ASR, its forced aligner, Granite Turbo) idle-unload after two minutes, call the package's own `unload()` where it has one, and return MLX's GPU buffer pool (`MLXMemoryRelease`), which otherwise stayed allocated (4.3 GB after one meeting).
- **Model catalog** (Settings → Models) — download / cancel / delete with progress, radio-select the active model. Qwen "thinking" is disabled for summaries via `chat_template_kwargs`. The Models tab also manages the dedicated cotyping model, the embedding model, and the **Kokoro** TTS voice (sherpa-onnx; downloads once, then reads summaries and chat answers aloud offline).

| Model | Size | Best for |
| --- | --- | --- |
| Qwen 3.5 · 0.8B | ~0.5 GB | tiny downloadable fallback |
| LFM2.5 · 1.2B Instruct | ~0.7 GB | lightweight autocomplete alternative |
| Gemma 4 · E2B Base (Q6) | ~3.85 GB | default autocomplete; 16 GB+ Macs |
| Qwen 3.5 · 2B | 1.3 GB | lightweight cotyping |
| Qwen 3.5 · 4B | ~2.8 GB | balanced summaries |
| Gemma 4 · E4B | ~6.7 GB | higher-capacity cotyping |
| LFM2.5 · 8B MoE | 5.2 GB | fast summaries |
| Qwen 3.6 · 35B-A3B | 17.7 GB | recommended summaries on 32 GB+ Macs |
| Qwen 3.6 · 27B | ~16.8 GB | maximum-quality dense summaries |
| Gemma 4 · 12B | ~7.5 GB | multimodal-family summaries |

- **Browse Hugging Face** in-app: search GGUF repos, list `.gguf` files, download — resilient (synchronous temp-file rescue, outcome classification, GGUF magic-byte validation). `HardwareCapabilityProbe` surfaces a per-model fit advisory under Settings → Models.
