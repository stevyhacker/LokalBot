# In-process `libllama` cotyping runtime — design

- **Date:** 2026-06-29
- **Status:** Draft for review
- **Author:** stevyhacker (with Claude)
- **Scope:** Cotyping (inline autocomplete) generation runtime only — "Root A"

## 1. Context

LokalBot's Cotyping subsystem is a faithful port of Cotabby's suggestion pipeline
(focus → debounce → generation → ghost overlay → accept), but it generates
completions over HTTP against a bundled `llama-server` subprocess
(`/v1/completions`, SSE) — see `CotypingEngine`, `TextEngine`, and `LlamaServer`.
Cotypist and Cotabby instead run llama.cpp **in-process**, holding a persistent
context + KV cache, decoding only the newly typed suffix per keystroke, streaming
tokens straight into the ghost, and stopping inside the decode loop.

Side-by-side, LokalBot feels a half-step behind on all four axes the user
identified: latency, suggestion quality, inline visual feel, and accept/coverage.
The latency and decode-stop-fidelity axes trace directly to the HTTP runtime; the
other two are separate roots (see §15). `Docs/CotypingParityQA.md` already names
the runtime as the one known-incomplete parity item.

The pipeline already abstracts generation behind the `CotypingCompleting`
protocol, so the runtime can be swapped without touching orchestration, prompting,
normalization, the overlay, or acceptance.

## 2. Problem

For the built-in GGUF backend, replace the per-keystroke
HTTP → `llama-server` → SSE path with an in-process `libllama` runtime that:

1. Holds a persistent `llama_context` + KV cache across keystrokes.
2. Re-prefills **only** the diverged suffix of the prompt (incremental prefill).
3. Streams tokens to the ghost and stops natively at the same boundary
   `CotypingDecodeStopPolicy` already defines.
4. Cancels in-flight generation instantly when a keystroke supersedes it.
5. Never blocks the main thread while the user types.

…without regressing the non-GGUF backends (Ollama / OpenAI-compatible / Apple
Intelligence), which must keep working over the existing HTTP path.

## 3. Goals

- True Cotypist-class runtime for the built-in model: in-process decode, KV reuse,
  native streaming + stop, instant cancellation.
- Contained blast radius: one new `CotypingCompleting` conformer + an engine
  selector. No changes to `CotypingCoordinator`, `CotypingPromptRenderer`,
  `CotypingTextNormalizer`, `CotypingOverlayController`, accept logic, the learning
  store, or the debounce policy.
- Reuse the dylibs and GGUF models already shipped — one model format, version
  locked to the bundled `llama-server` (`b9844`).
- Measurable latency improvement, proven by an A/B benchmark against the HTTP path.

## 4. Non-goals

- Migrating summarization / chat / embeddings off `llama-server` (separate, larger
  effort; the in-process runtime here is cotyping-only).
- Removing the HTTP `CotypingEngine` (it stays as the fallback and the non-GGUF
  backend path — see §11).
- Root B (model-default quality) and Root C (overlay/accept polish). These are
  sequenced fast-follows with their own specs (§15).
- Speculative decoding / draft models. The architecture allows it later; it is not
  part of this spec.

## 5. Success criteria

- **First ghost token < ~200–300 ms** after warmup on the bundled small model
  (`Qwen3.5-0.8B-Q4_K_M`), measured from generation start (post-debounce).
- **End-to-end p95 well under the current 2000 ms** target in
  `CotypingParityQA.md`, on the same model and prompts.
- **KV reuse proven**: a second generation whose prompt extends the first decodes
  only the suffix (asserted by a token-count probe in tests).
- **Instant cancellation**: superseding a generation stops decode within one token
  iteration; no orphaned work.
- **No main-thread hitch**: typing latency unaffected while a generation runs
  (manual + instruments check).
- **No regression**: non-GGUF backends and the HTTP fallback path behave exactly as
  before.

## 6. Decisions (resolved during brainstorming)

| Decision | Choice | Rationale |
| --- | --- | --- |
| Runtime path | In-process now (not incremental-only / not measure-first) | User wants real Cotypist parity; HTTP is the ceiling on the felt latency. |
| Integration mechanism | Direct C-interop with vendored `libllama.dylib` via a Clang module map | Reuses exact dylibs + GGUF models already shipped; version-locked to `b9844`; stable public C API. Rejected: Obj-C++ over `common` (unstable internal API, headers not vendored); MLX (forks the model format into a second ecosystem). |
| HTTP engine | Keep as live fallback | It is also the non-GGUF backend path; removing it would regress Ollama / OpenAI-compatible / Apple Intelligence and remove the safety net. |
| Spec scope | Root A (runtime) only | Coherent, single-plan-sized. B and C are independent and sequenced. |

## 7. Architecture overview — the seam

The coordinator depends only on `CotypingCompleting`
(`generate` / `generateStreaming`). The change is additive:

- **New:** `LocalLlamaCotypingEngine: CotypingCompleting`, backed by an
  `LlamaCotypingRuntime` actor and the `LlamaCore` C-interop module.
- **Changed:** `AppState.cotypingEngine` becomes a small selector that returns the
  local engine for the built-in GGUF backend on Apple Silicon, else the existing
  HTTP `CotypingEngine`.
- **Unchanged:** everything else in `LokalBot/Cotyping/*` and `LlamaServer`.

```
CotypingCoordinator
        │  (CotypingCompleting protocol — unchanged)
        ▼
CotypingEngineSelector
   ├── built-in GGUF + Apple Silicon → LocalLlamaCotypingEngine ──► LlamaCotypingRuntime (actor) ──► LlamaCore (libllama)
   └── Ollama / OpenAI-compat / AI    → CotypingEngine (HTTP, existing)
```

## 8. Components

Each unit below states *what it does*, *its interface*, and *what it depends on*.

### 8.1 `LlamaCore` — C-interop module
- **Does:** exposes the pinned llama.cpp C API to Swift.
- **Interface:** `import LlamaCore` → `llama.h` / `ggml.h` symbols.
- **Depends on:** vendored `b9844` headers in `Vendor/llama-cpp/include/` + a
  `module.modulemap`; links the already-vendored `libllama.dylib` (+ `libggml*.dylib`).
- **Notes:** exact symbol names (e.g. `llama_model_load_from_file`,
  `llama_init_from_model`, `llama_get_memory` / `llama_memory_seq_rm`,
  `llama_sampler_*`) are pinned by the vendored header — confirm against it rather
  than from memory, since the C API evolved (the old `llama_kv_cache_*` and
  `llama_new_context_with_model` names were renamed/deprecated before `b9844`).

### 8.2 `LlamaCotypingRuntime` — inference actor
- **Does:** owns the model + context + KV state; runs incremental prefill and the
  decode loop; serializes all inference.
- **State:**
  - `llama_model` loaded once from the configured GGUF path (reuse
    `ModelCatalog` / download manager to resolve the path).
  - `llama_context` with `n_ctx = 2048` (matches `LlamaServer.cotyping`),
    `n_gpu_layers = 99` (full Metal offload, matching the server's `-ngl 99`),
    tuned `n_threads`.
  - Reusable `llama_batch`.
  - Sampler chain from `CotypingConfiguration.standard` (temp 0.1, top_k 20,
    top_p 0.7, min_p 0.08, repeat_penalty 1.05, seed `0x00C0FFEE`).
  - `cachedTokens: [llama_token]` — the sequence currently resident in the KV
    cache (basis for incremental prefill).
- **Interface (sketch):**
  ```
  func load(modelPath: String) throws        // also primes Metal (warmup decode)
  func unload()
  func generate(promptTokens: [Int32],
                maxTokens: Int,
                onToken: (String) -> Bool,    // return false to stop (cancel/stop policy)
  ) async -> String
  ```
- **Depends on:** `LlamaCore`, `CotypingConfiguration`.

### 8.3 `IncrementalPrefill` — pure helper (the latency heart)
- **Does:** given `cachedTokens` and the new `promptTokens`, returns the common
  prefix length `p`. The runtime then drops the diverged tail
  (`llama_memory_seq_rm(mem, 0, p, -1)`), decodes tokens `p ..< promptTokens.count`
  as the prefill batch (logits only on the final token), and stores `promptTokens`
  as the new `cachedTokens`.
- **Interface:** `static func commonPrefixLength(_ a: [Int32], _ b: [Int32]) -> Int`.
- **Depends on:** nothing (pure) → fully unit-testable.
- **Why it matters:** as the user types forward, the conditioning preface +
  earlier text are a stable, growing prefix, so `p` is large and only a few new
  tokens are prefilled each keystroke. This is the mechanism the HTTP path can only
  approximate via `llama-server` slot caching (which the current request body does
  not even opt into).

### 8.4 `LocalLlamaCotypingEngine: CotypingCompleting` — the seam
- **Does:** adapts the runtime to the protocol the coordinator already calls.
- **Flow:** tokenize `request.prompt` → call the runtime → in the decode loop,
  after each token, detokenize incrementally and run the **existing**
  `CotypingTextNormalizer.normalizeDetailed` + `CotypingDecodeStopPolicy.verdict`
  on the accumulated raw text → `onPartial` → stop on policy verdict, word/token
  budget, or cancellation. Returns the same `CotypingNormalizationResult` the HTTP
  engine returns.
- **Cancellation:** honors `Task.isCancelled` (the coordinator supersedes by
  generation id); the runtime's `onToken` returns `false` → decode loop exits next
  iteration. No network teardown.
- **Depends on:** `LlamaCotypingRuntime`, `CotypingTextNormalizer`,
  `CotypingDecodeStopPolicy` (both reused unchanged).

### 8.5 Engine selector — `AppState.cotypingEngine`
- **Does:** chooses the conformer per the active cotyping backend setting.
- **Rule:** built-in GGUF model + Apple Silicon → `LocalLlamaCotypingEngine`;
  otherwise the existing HTTP `CotypingEngine`. Resolved per-completion (mirrors
  today's `makeEngine` closure) so a settings change applies live.
- **Depends on:** `AppSettings` (`cotypingTextEngineSettings`,
  `cotypingBuiltInModelID`), `ModelCatalog`.

## 9. Data flow (per keystroke)

```
focus → debounce → coordinator.generate → build CotypingRequest (unchanged)
      → LocalLlamaCotypingEngine.generateStreaming
            → runtime: tokenize prompt
                     → incremental prefill (decode ONLY tokens after common prefix)
                     → decode loop { sample → detok → normalize → onPartial
                                     → CotypingDecodeStopPolicy check → cancel check }
      → CotypingNormalizationResult → overlay.show (unchanged)
```

## 10. Concurrency, threading, cancellation

- The actor serializes inference; one generation at a time.
- `llama_decode` runs **off the main actor** (actor executor on a background
  thread). Token callbacks hop to MainActor only to paint the ghost.
- Supersession cancels the in-flight generation cooperatively (flag checked each
  decode iteration). Because there is no socket, cancellation is effectively
  instant — this removes the "doomed in-flight HTTP request" lag the current path
  pays on fast typing.

## 11. Lifecycle, memory, fallback

- **Load = warmup.** Load the model on cotyping-enable and run one priming decode
  so Metal pipelines are hot before the first real keystroke. (Today only
  transcription models are prewarmed; cotyping pays a cold first hit.)
- **Unload** on cotyping-disable.
- **Memory pressure:** a `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` source unloads the
  model on warning and lazily reloads (or temporarily routes to the HTTP path), so
  cotyping never OOMs the app. `Qwen3.5-0.8B-Q4_K_M` ≈ 0.6 GB (negligible); Gemma
  E4B Q5 ≈ 3–4 GB stays gated behind the existing "separate / high-quality" model
  flow.
- **Coexistence:** the summarizer `LlamaServer.shared` is untouched; the in-process
  cotyping model is separate and small.
- **Fallback:** model-load failure, header/link mismatch, or unsupported hardware
  routes to the existing HTTP `CotypingEngine`, surfaced via the current
  `CotypingState.failed`. No regression.

## 12. Build & packaging

- **`Scripts/build/fetch-llama.sh`:** additionally fetch the `b9844` headers
  (`llama.h`, `ggml.h`, and the ggml-backend/alloc headers the public API pulls in)
  into `Vendor/llama-cpp/include/`. Same `TAG`, idempotent, runs as the existing
  pre-build phase.
- **`project.yml`:** add the module map + header search path; move
  `libllama.dylib` (+ `libggml*.dylib`) into the target's **Link Binary With
  Libraries** phase (today they are resources only). Verify the app binary's
  `@rpath` resolves to the bundled `Vendor/llama-cpp` at runtime — `llama-server`
  already loads these signed dylibs, so code signing / hardened-runtime
  entitlements are unchanged.
- No new third-party dependency, no new binary in the bundle.

## 13. Error handling

- Tokenization / decode errors → fail the single generation, surface
  `CotypingState.failed`, leave the field untouched (consistent with the HTTP
  path's error handling in `CotypingCoordinator.generate`).
- Context overflow (prompt + budget > `n_ctx`) → the prefix window already caps at
  150 words / 2500 chars (`CotypingPrefixWindow`), comfortably under 2048 tokens;
  add a defensive clamp before decode.
- Load failure → fallback engine (§11), logged once.

## 14. Testing strategy

- **Unit:** `IncrementalPrefill.commonPrefixLength` (pure, exhaustive edge cases:
  empty, identical, divergent-at-0, one-is-prefix-of-other). Sampler-config
  mapping from `CotypingConfiguration` to the llama sampler chain.
- **Integration (gated on the bundled model being present):** load
  `Qwen3.5-0.8B-Q4_K_M`, generate from a fixed prompt + seed → assert deterministic
  output; issue a second generation with an extended prefix and assert only the
  suffix is decoded (token-count probe) → proves KV reuse.
- **Benchmark:** extend `CotypingBenchmark` to record TTFT / prefill ms / decode ms
  for the in-process engine and A/B against the HTTP engine on the existing default
  scenarios (email follow-up, chat ownership, browser prose, mid-word). This closes
  the "measure the budget" gap and substantiates the parity claim in
  `CotypingParityQA.md`.
- **Manual:** the existing `Scripts/cotyping/compare-cotyping.sh` side-by-side vs Cotypist,
  plus an Instruments pass confirming no main-thread stalls while typing.

## 15. Out of scope — sequenced fast-follows

These were identified as separate roots and are **not** in this spec:

- **Root B — suggestion quality.** *Partially landed (2026-06-29):* cotyping now
  always runs its own dedicated model, defaulting to Gemma 4 E4B Q5 XL, with the
  opt-in "separate model" toggle removed — strict, with no fallback to the bundled
  tiny model and no cross-app (Cotypist) model reuse. Still pending: turning the
  good context features (app context, learning) on by default, and validating a
  base/continuation model against the instruction-tuned default. The in-process
  runtime makes a stronger model affordable (cheap incremental prefill).
- **Root C — inline visual feel + accept/coverage.** Overlay font/baseline/color
  blend, reducing popup fallback by improving caret-rect resolution, killing
  re-anchor flicker, and auditing the inserter across the apps Cotypist supports.
  The runtime's instant cancellation + native streaming already reduces flicker,
  but the blend/coverage work is separate.

## 16. Risks & mitigations

| Risk | Mitigation |
| --- | --- |
| C API drift vs memory of it | Pin headers to `b9844`; code against the vendored header, not recollection. |
| Two model copies in RAM (cotyping + summarizer) when both active | Cotyping now defaults to Gemma 4 E4B Q5 XL (~5 GB resident), so memory-pressure unload (§11) is load-bearing, not optional. On <16 GB Macs, steer to a smaller cotyping model (Qwen3.5 2B / LFM2.5 1.2B). |
| Main-thread stalls from decode | Inference strictly off the main actor; only paint hops to MainActor. |
| Link / `@rpath` issues with in-process dylibs | The dylibs are already shipped + signed for the server; verify link phase + rpath in an early build spike. |
| Determinism / sampler parity vs HTTP | Same `CotypingConfiguration` + fixed seed; benchmark A/B asserts comparable output. |

## 17. Open questions

- Should the in-process runtime become the default for the built-in backend
  immediately, or ship behind a flag for one release while the benchmark validates
  the latency win? (Recommendation: flag-gated default-on, with the HTTP fallback
  one toggle away.)
- Confirm the exact set of public headers `llama.h` transitively requires at
  `b9844` so `fetch-llama.sh` pulls all of them (resolve during the build spike).
