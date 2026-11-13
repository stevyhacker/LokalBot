# In-process `libllama` Cotyping Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the per-keystroke HTTP→`llama-server`→SSE cotyping path with an in-process `libllama` runtime that holds a persistent KV cache, re-prefills only the typed suffix, streams tokens natively, and cancels instantly — for the built-in GGUF backend only, with the HTTP engine retained as fallback.

**Architecture:** Additive seam swap. The coordinator already depends only on `CotypingCompleting`. We add a `LlamaCore` C-interop module over the already-vendored `libllama.dylib` (`b9844`), an `LlamaCotypingRuntime` actor that owns the model/context/KV, a `LocalLlamaCotypingEngine: CotypingCompleting` that reuses the existing normalizer + stop policy, and a `CotypingEngineSelector` that routes built-in-GGUF-on-Apple-Silicon to the local engine and everything else to the existing HTTP `CotypingEngine`. Nothing in the orchestration, prompting, normalization, overlay, accept, learning, or debounce layers changes.

**Tech Stack:** Swift 5.10 (actors, structured concurrency), C-interop via Clang module map, llama.cpp `libllama` C API pinned to release `b9844` (vendored `libllama.0.0.9844.dylib` + `libggml*.dylib`), Metal offload, XcodeGen (`project.yml` → `LokalBot.xcodeproj`), XCTest, `xcodebuild`.

## Global Constraints

Every task's requirements implicitly include this section. Values are copied verbatim from the design spec (`Docs/archive/superpowers/specs/2026-06-29-inprocess-cotyping-runtime-design.md`) and standing project constraints.

- **100% on-device.** Nothing leaves the device. No cloud calls. The in-process runtime makes zero network requests; it loads a local GGUF and decodes locally.
- **Clipboard context is sensitive.** Read fresh at generation time, never cached or persisted. This plan does not touch clipboard handling — `CotypingRequestBuilder` already reads it fresh and the prompt arrives pre-built in `CotypingRequest`.
- **Platform:** macOS 15.0+, Apple Silicon only. `MACOSX_DEPLOYMENT_TARGET = 15.0`.
- **Version lock:** llama.cpp release **`b9844`**. Code against the *vendored header*, not memory. The dylibs are already in `Vendor/llama-cpp/` (`libllama.0.0.9844.dylib`); headers are fetched at the same tag.
- **No new third-party dependency, no new binary in the bundle.** Reuse the exact dylibs and GGUF models already shipped. One model format (GGUF).
- **Contained blast radius (spec §3):** Do NOT modify `CotypingCoordinator`, `CotypingPromptRenderer`/`CotypingRequestBuilder`, `CotypingTextNormalizer`, `CotypingOverlayController`, accept logic, the learning store, the debounce policy, or `LlamaServer`. The HTTP `CotypingEngine` stays as the fallback + non-GGUF path.
- **No main-thread blocking.** `llama_decode` runs off the main actor (on the `LlamaCotypingRuntime` actor's executor). Only ghost-painting hops to `@MainActor`.
- **Cotyping seam is `@MainActor`.** `CotypingCompleting` is `@MainActor`; all conformers and the selector are `@MainActor`.

### Pinned `b9844` C API (verified via `nm -gU Vendor/llama-cpp/libllama.dylib`)

These exact symbols are exported by the vendored dylib. Use these — the older `llama_kv_cache_*` / `llama_kv_self_*` / `llama_new_context_with_model` names are deprecated/renamed and MUST NOT be used (prefer the new names below, both happen to be exported):

- Lifecycle: `llama_backend_init()`, `llama_backend_free()`, `llama_model_default_params()`, `llama_model_load_from_file(path, params)`, `llama_model_free(model)`, `llama_context_default_params()`, `llama_init_from_model(model, params)`, `llama_free(ctx)`.
- Vocab/tokenize: `llama_model_get_vocab(model)`, `llama_vocab_n_tokens(vocab)`, `llama_vocab_bos(vocab)`, `llama_vocab_eos(vocab)`, `llama_vocab_is_eog(vocab, token)`, `llama_tokenize(vocab, text, text_len, tokens, n_max, add_special, parse_special)`, `llama_token_to_piece(vocab, token, buf, length, lstrip, special)`.
- KV / memory (incremental prefill): `llama_get_memory(ctx)`, `llama_memory_seq_rm(mem, seq_id, p0, p1)`, `llama_memory_clear(mem, data)`.
- Batch/decode: `llama_batch_init(n_tokens, embd, n_seq_max)`, `llama_batch_free(batch)`, `llama_decode(ctx, batch)`, `llama_n_ctx(ctx)`, `llama_n_batch(ctx)`.
- Sampler: `llama_sampler_chain_default_params()`, `llama_sampler_chain_init(params)`, `llama_sampler_chain_add(chain, smpl)`, `llama_sampler_init_penalties(last_n, repeat, freq, present)`, `llama_sampler_init_top_k(k)`, `llama_sampler_init_top_p(p, min_keep)`, `llama_sampler_init_min_p(p, min_keep)`, `llama_sampler_init_temp(t)`, `llama_sampler_init_dist(seed)`, `llama_sampler_sample(smpl, ctx, idx)`, `llama_sampler_accept(smpl, token)`, `llama_sampler_free(smpl)`.

Swift bridging notes: opaque `struct *` arrive as `OpaquePointer?`; `llama_token`/`llama_pos`/`llama_seq_id` are `Int32`; `llama_memory_t` is `OpaquePointer?`; `llama_batch` is a value struct with `token`, `pos`, `n_seq_id`, `seq_id`, `logits`, `n_tokens` fields; `min_keep` params are `size_t` (pass Swift `Int`); seed is `UInt32`.

---

## File Structure

**Create:**
- `LokalBot/Cotyping/Llama/IncrementalPrefill.swift` — pure common-prefix helper (the latency heart).
- `LokalBot/Cotyping/Llama/LlamaSamplerSpec.swift` — pure config→sampler-chain descriptor mapping.
- `LokalBot/Cotyping/Llama/LlamaCotypingRuntime.swift` — the inference actor (model/context/KV/decode).
- `LokalBot/Cotyping/Llama/LocalLlamaCotypingEngine.swift` — `CotypingCompleting` conformer (the seam).
- `LokalBot/Cotyping/Llama/CotypingEngineSelector.swift` — per-completion local-vs-HTTP router + prewarm.
- `LokalBotTests/IncrementalPrefillTests.swift`
- `LokalBotTests/LlamaSamplerSpecTests.swift`
- `LokalBotTests/CotypingEngineSelectorTests.swift`
- `LokalBotTests/LlamaCotypingRuntimeTests.swift` — integration, gated on bundled model presence.
- `LokalBotTests/CotypingABBenchmarkTests.swift`

**Modify:**
- `Scripts/build/fetch-llama.sh` — also fetch `b9844` headers into `Vendor/llama-cpp/include/` and generate the `module.modulemap` there (both gitignored, script-reproduced — `Vendor/` stays fully generated).
- `project.yml` — header search path + `SWIFT_INCLUDE_PATHS` (module map) + link `-lllama` + `LD_RUNPATH_SEARCH_PATHS`.
- `LokalBot/Models/AppSettings.swift` — add `cotypingInProcessRuntime: Bool` (default `true`), tolerant decode.
- `LokalBot/LokalBotApp.swift` — `cotypingEngine` becomes a `CotypingEngineSelector`; prewarm on cotyping-enable.
- `LokalBot/Cotyping/CotypingBenchmark.swift` — A/B (local vs HTTP) summary + TTFT/prefill probes.
- `LokalBot/Views/SettingsView.swift` — a toggle for the in-process runtime flag.
- `Docs/guides/CotypingParityQA.md` — mark the runtime parity item complete; document the A/B benchmark.

---

## Task 1: Build spike — `LlamaCore` C module links, loads, and runs

The riskiest piece (spec risk: "Link / `@rpath` issues"; open question #2: exact header set). Prove the module imports, the dylib links, `@rpath` resolves at runtime, and a real C call executes — before any runtime code is written. Fold header fetch + module map + project wiring into this one task; its deliverable is a passing test that calls into `libllama`.

**Files:**
- Modify: `Scripts/build/fetch-llama.sh` (fetch headers **and** generate `Vendor/llama-cpp/include/module.modulemap` — both gitignored, script-reproduced)
- Modify: `project.yml`
- Test: `LokalBotTests/LlamaCoreSmokeTests.swift` (create)

**Interfaces:**
- Consumes: vendored `Vendor/llama-cpp/libllama.dylib` (+ `libggml*.dylib`), `b9844`.
- Produces: a Swift-importable module `LlamaCore` exposing the `b9844` C API; build settings other targets inherit (`HEADER_SEARCH_PATHS`, `SWIFT_INCLUDE_PATHS`, link flags, rpath). Later tasks `import LlamaCore`.

- [ ] **Step 1: Add header fetch to `Scripts/build/fetch-llama.sh`**

Open `Scripts/build/fetch-llama.sh`. It already sets `TAG=b9844`, `SERVER_DIR=Vendor/llama-cpp`, and downloads/extracts `llama-$TAG-bin-macos-arm64.tar.gz`. After the block that copies `llama-server` + `*.dylib` into `$SERVER_DIR`, add a header-fetch block. The macOS bin tarball does not reliably ship headers, so fetch them from the pinned source tag. Insert:

```bash
# --- Public C headers for in-process libllama (LlamaCore module) ---
# Fetched from the pinned source tag so the Swift module compiles against the
# exact b9844 API the vendored dylib exports. Idempotent: skip if present.
INCLUDE_DIR="$SERVER_DIR/include"
RAW_BASE="https://raw.githubusercontent.com/ggml-org/llama.cpp/$TAG"
HEADERS=(
  "include/llama.h"
  "ggml/include/ggml.h"
  "ggml/include/ggml-backend.h"
  "ggml/include/ggml-alloc.h"
  "ggml/include/ggml-cpu.h"
  "ggml/include/ggml-metal.h"
)
mkdir -p "$INCLUDE_DIR"
for h in "${HEADERS[@]}"; do
  dest="$INCLUDE_DIR/$(basename "$h")"
  if [ ! -f "$dest" ]; then
    echo "fetch-llama: downloading header $(basename "$h")"
    curl -fsSL "$RAW_BASE/$h" -o "$dest"
  fi
done

# Declare the LlamaCore Clang module over the fetched headers. Generated here
# (not committed) so the whole Vendor/ tree stays reproducible and gitignored,
# matching the dylibs/model. Rewritten every run so it tracks any HEADERS edit.
cat > "$INCLUDE_DIR/module.modulemap" <<'EOF'
module LlamaCore {
    header "llama.h"
    header "ggml.h"
    header "ggml-backend.h"
    header "ggml-alloc.h"
    header "ggml-cpu.h"
    export *
}
EOF
```

- [ ] **Step 2: Run the script and confirm headers + module map land**

Run: `cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot && bash Scripts/build/fetch-llama.sh && ls Vendor/llama-cpp/include`
Expected: lists `llama.h ggml.h ggml-backend.h ggml-alloc.h ggml-cpu.h ggml-metal.h module.modulemap` (and no error). If `curl` 404s on a header, that header moved at this tag — open the tag tree at `https://github.com/ggml-org/llama.cpp/tree/b9844/ggml/include` to find its path and fix the `HEADERS` entry. This is the open-question-#2 resolution: confirm the transitive set compiles in Step 6 and trim/extend here. (`llama.h` was already verified present at this tag — `raw.githubusercontent.com/ggml-org/llama.cpp/b9844/include/llama.h` returns HTTP 200.)

- [ ] **Step 3: Confirm the dylib install name + that the needed symbols exist**

Run: `cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot && otool -D Vendor/llama-cpp/libllama.dylib && nm -gU Vendor/llama-cpp/libllama.dylib | grep -E '_llama_(backend_init|model_default_params|model_load_from_file|init_from_model|get_memory|memory_seq_rm|tokenize|decode|sampler_sample)$' | sort`
Expected: `otool -D` prints an install name (e.g. `@rpath/libllama.0.0.9844.dylib` or `@rpath/libllama.dylib`); the `nm` grep lists all nine symbols. Note the `@rpath` value — Step 5 must make that rpath resolve.

- [ ] **Step 4: Confirm the generated `LlamaCore` module map**

Step 1's heredoc wrote `Vendor/llama-cpp/include/module.modulemap` when the script ran in Step 2 — it is NOT a hand-committed file (the whole `Vendor/` tree is gitignored and script-generated). Confirm its content:

Run: `cat /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot/Vendor/llama-cpp/include/module.modulemap`
Expected:

```
module LlamaCore {
    header "llama.h"
    header "ggml.h"
    header "ggml-backend.h"
    header "ggml-alloc.h"
    header "ggml-cpu.h"
    export *
}
```

(If Step 6 reports a missing header that `llama.h` transitively includes, add a `header "..."` line to the **heredoc in `Scripts/build/fetch-llama.sh`** AND a corresponding entry in that script's `HEADERS` array, then re-run Step 2. Do not hand-edit the generated file — the script overwrites it.)

- [ ] **Step 5: Wire `project.yml` — header path, module, link, rpath**

Open `project.yml`. It has **no top-level `settings:` block** today — shared app settings live in the `LokalBotApp` *template* (which `LokalBot`, `LokalBot Dev`, and `LokalBot UI Test Host` all inherit), and each target has its own `settings.base`. Make two additions:

**(a)** Add a **new top-level `settings:` block** (place it right after the `options:` block, before `packages:`) so every target — the app targets *and* `LokalBotTests`, which `import LlamaCore` directly — sees the module:

```yaml
settings:
  base:
    HEADER_SEARCH_PATHS:
      - $(inherited)
      - $(SRCROOT)/Vendor/llama-cpp/include
    SWIFT_INCLUDE_PATHS:
      - $(inherited)
      - $(SRCROOT)/Vendor/llama-cpp/include
```

**(b)** Add the link flags to the **`LokalBotApp` template's** existing `settings.base` (around line 124, alongside `SWIFT_VERSION`/`DEVELOPMENT_TEAM`), so all three app targets link the dylib and get the runtime search path:

> **Build-spike correction (Task 1, applied):** the `LokalBotTests` target ALSO needs these link flags. `-bundle_loader`/`TEST_HOST` only resolves symbols *defined in* the host executable, and the `llama_*` symbols live in `libllama.dylib` (which the host merely *loads*), so the test bundle must link `-lllama` itself with its own rpath (`@executable_path/../Resources/llama-cpp` and `@loader_path/../../../../Resources/llama-cpp`, both reaching the host app's `Contents/Resources/llama-cpp`). Task 1 wired this on the `LokalBotTests` target. **Consequence for later tasks:** every subsequent `import LlamaCore` test file (`LlamaCotypingRuntimeTests`, `LocalLlamaCotypingEngineTests`, `CotypingABBenchmarkTests`) inherits this target-level wiring automatically — do NOT re-edit `project.yml` to link them.

```yaml
        LIBRARY_SEARCH_PATHS:
          - $(inherited)
          - $(SRCROOT)/Vendor/llama-cpp
        OTHER_LDFLAGS:
          - $(inherited)
          - -lllama
        LD_RUNPATH_SEARCH_PATHS:
          - $(inherited)
          - "@executable_path/../Resources/llama-cpp"
```

Notes: `-lllama` resolves the `libllama.dylib` symlink in `Vendor/llama-cpp`. The dylibs continue to be copied into `Contents/Resources/llama-cpp/` by the existing `Vendor/llama-cpp` folder **resource** build phase in the template (DO NOT remove it — `llama-server` and the in-process link both rely on those Resources copies). The rpath `@executable_path/../Resources/llama-cpp` makes the linked `@rpath/libllama*.dylib` (and transitively `libggml*.dylib`) resolve at runtime. The `Vendor/llama-cpp/include/` headers also get copied into the bundle as part of that folder resource — harmless (a few KB).

- [ ] **Step 6: Regenerate the project and write the smoke test**

Run: `cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot && xcodegen generate`
Expected: `Loaded project ... Created project at LokalBot.xcodeproj` with no error.

Create `LokalBotTests/LlamaCoreSmokeTests.swift`:

```swift
import XCTest
import LlamaCore

/// Proves the LlamaCore module imports, the vendored libllama.dylib links, and
/// the @rpath resolves at runtime by executing real b9844 C calls.
final class LlamaCoreSmokeTests: XCTestCase {
    func testBackendInitAndDefaultParamsLink() {
        llama_backend_init()
        let model = llama_model_default_params()
        // Full Metal offload is what the runtime will request; the field must exist.
        XCTAssertGreaterThanOrEqual(model.n_gpu_layers, 0)
        let ctx = llama_context_default_params()
        XCTAssertGreaterThan(ctx.n_ctx, 0)
        llama_backend_free()
    }
}
```

- [ ] **Step 7: Run the smoke test (it must build, link, and pass)**

Run: `cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot && xcodebuild test -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' -only-testing:LokalBotTests/LlamaCoreSmokeTests 2>&1 | tail -25`
Expected: `Test Suite 'LlamaCoreSmokeTests' passed`, `** TEST SUCCEEDED **`. If it fails to *link* (`Undefined symbols` / `library not found for -lllama`), fix `LIBRARY_SEARCH_PATHS`/`OTHER_LDFLAGS` (Step 5) and regenerate. If it builds but *crashes at runtime* (`dyld: Library not loaded: @rpath/libllama...`), the rpath is wrong — re-check the install name from Step 3 against `LD_RUNPATH_SEARCH_PATHS`. If a *header* is missing during compile, add it (Step 4 note).

- [ ] **Step 8: Commit**

```bash
cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot
git add Scripts/build/fetch-llama.sh project.yml LokalBot.xcodeproj LokalBotTests/LlamaCoreSmokeTests.swift
git commit -m "build: link in-process libllama via LlamaCore module (b9844)"
```

Note: nothing under `Vendor/` is committed — `.gitignore` ignores the whole tree (confirmed: `git check-ignore Vendor/llama-cpp/include/module.modulemap` matches `Vendor/`). The module map and headers are regenerated/fetched by `Scripts/build/fetch-llama.sh` on every build (it is a pre-build phase), so a fresh clone and CI reconstruct them. Do NOT `git add -f` the module map or headers.

---

## Task 2: `IncrementalPrefill.commonPrefixLength` — the latency heart (pure)

Pure, no libllama, fully unit-testable. Returns how many leading tokens two sequences share, so the runtime drops only the diverged KV tail.

**Files:**
- Create: `LokalBot/Cotyping/Llama/IncrementalPrefill.swift`
- Test: `LokalBotTests/IncrementalPrefillTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum IncrementalPrefill { static func commonPrefixLength(_ a: [Int32], _ b: [Int32]) -> Int }`. Used by `LlamaCotypingRuntime` (Task 4).

- [ ] **Step 1: Write the failing test**

Create `LokalBotTests/IncrementalPrefillTests.swift`:

```swift
import XCTest
@testable import LokalBot

final class IncrementalPrefillTests: XCTestCase {
    func testEmptyInputs() {
        XCTAssertEqual(IncrementalPrefill.commonPrefixLength([], []), 0)
        XCTAssertEqual(IncrementalPrefill.commonPrefixLength([1, 2], []), 0)
        XCTAssertEqual(IncrementalPrefill.commonPrefixLength([], [1, 2]), 0)
    }

    func testIdenticalSequences() {
        XCTAssertEqual(IncrementalPrefill.commonPrefixLength([1, 2, 3], [1, 2, 3]), 3)
    }

    func testDivergeAtZero() {
        XCTAssertEqual(IncrementalPrefill.commonPrefixLength([9, 2, 3], [1, 2, 3]), 0)
    }

    func testOneIsPrefixOfOther() {
        // Typing forward: old cache [1,2,3], new prompt [1,2,3,4,5] → reuse 3.
        XCTAssertEqual(IncrementalPrefill.commonPrefixLength([1, 2, 3], [1, 2, 3, 4, 5]), 3)
        XCTAssertEqual(IncrementalPrefill.commonPrefixLength([1, 2, 3, 4, 5], [1, 2, 3]), 3)
    }

    func testDivergeInMiddle() {
        XCTAssertEqual(IncrementalPrefill.commonPrefixLength([1, 2, 3, 4], [1, 2, 9, 4]), 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot && xcodebuild test -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' -only-testing:LokalBotTests/IncrementalPrefillTests 2>&1 | tail -15`
Expected: FAIL — `cannot find 'IncrementalPrefill' in scope` (compile error).

- [ ] **Step 3: Write the minimal implementation**

Create `LokalBot/Cotyping/Llama/IncrementalPrefill.swift`:

```swift
import Foundation

/// Pure helper for KV-cache reuse. Given the token sequence currently resident
/// in the llama context (`cached`) and the freshly tokenized prompt (`next`),
/// returns the number of leading tokens they share. The runtime keeps that
/// prefix in the KV cache and re-prefills only `next[p...]`, which is what makes
/// per-keystroke decode cheap as the user types forward.
enum IncrementalPrefill {
    static func commonPrefixLength(_ a: [Int32], _ b: [Int32]) -> Int {
        let limit = min(a.count, b.count)
        var p = 0
        while p < limit && a[p] == b[p] { p += 1 }
        return p
    }
}
```

- [ ] **Step 4: Add the file to the project and run the test**

Run: `cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot && xcodegen generate && xcodebuild test -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' -only-testing:LokalBotTests/IncrementalPrefillTests 2>&1 | tail -15`
Expected: `Test Suite 'IncrementalPrefillTests' passed`, 5 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot
git add LokalBot/Cotyping/Llama/IncrementalPrefill.swift LokalBotTests/IncrementalPrefillTests.swift LokalBot.xcodeproj
git commit -m "feat: add IncrementalPrefill.commonPrefixLength for KV reuse"
```

---

## Task 3: `LlamaSamplerSpec` — config→sampler-chain descriptor (pure)

Map `CotypingConfiguration`'s sampler knobs to an ordered, value-typed descriptor of the llama sampler chain. Keeping the *mapping* pure makes it unit-testable without libllama (spec §14 "Sampler-config mapping"); the runtime (Task 4) turns the descriptor into the real C chain.

**Files:**
- Create: `LokalBot/Cotyping/Llama/LlamaSamplerSpec.swift`
- Test: `LokalBotTests/LlamaSamplerSpecTests.swift`

**Interfaces:**
- Consumes: `CotypingConfiguration` (fields `temperature`, `topP`, `topK`, `minP`, `repeatPenalty`, `seed`).
- Produces:
  - `enum LlamaSamplerSpec: Equatable { case penalties(lastN: Int32, repeat: Float, freq: Float, present: Float); case topK(Int32); case topP(Float, minKeep: Int); case minP(Float, minKeep: Int); case temp(Float); case dist(seed: UInt32) }`
  - `static func LlamaSamplerSpec.specs(temperature: Float, topK: Int32, topP: Float, minP: Float, repeatPenalty: Float, repeatLastN: Int32, seed: UInt32) -> [LlamaSamplerSpec]`
  - `static func LlamaSamplerSpec.specs(from config: CotypingConfiguration) -> [LlamaSamplerSpec]`
  - Used by `LlamaCotypingRuntime.makeSampler` (Task 4) and `LocalLlamaCotypingEngine` (Task 5, maps the per-request params).

- [ ] **Step 1: Write the failing test**

Create `LokalBotTests/LlamaSamplerSpecTests.swift`:

```swift
import XCTest
@testable import LokalBot

final class LlamaSamplerSpecTests: XCTestCase {
    func testStandardConfigMapsToOrderedChain() {
        let specs = LlamaSamplerSpec.specs(from: .standard)
        XCTAssertEqual(specs, [
            .penalties(lastN: 64, repeat: 1.05, freq: 0, present: 0),
            .topK(20),
            .topP(0.7, minKeep: 1),
            .minP(0.08, minKeep: 1),
            .temp(0.1),
            .dist(seed: 0x00C0_FFEE),
        ])
    }

    func testExplicitParamsPreserveSamplerOrder() {
        let specs = LlamaSamplerSpec.specs(
            temperature: 0.2, topK: 40, topP: 0.9, minP: 0.05,
            repeatPenalty: 1.1, repeatLastN: 64, seed: 42)
        XCTAssertEqual(specs.map(\.order), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(specs.last, .dist(seed: 42))
    }
}

private extension LlamaSamplerSpec {
    var order: Int {
        switch self {
        case .penalties: 0
        case .topK: 1
        case .topP: 2
        case .minP: 3
        case .temp: 4
        case .dist: 5
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot && xcodebuild test -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' -only-testing:LokalBotTests/LlamaSamplerSpecTests 2>&1 | tail -15`
Expected: FAIL — `cannot find 'LlamaSamplerSpec' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `LokalBot/Cotyping/Llama/LlamaSamplerSpec.swift`:

```swift
import Foundation

/// Value-typed description of the llama.cpp sampler chain, in apply order.
/// Pure so the config→chain mapping is unit-testable without libllama; the
/// runtime turns each case into the matching `llama_sampler_init_*` call.
///
/// Order mirrors llama.cpp's `common` default for this subset:
/// penalties → top_k → top_p → min_p → temp → dist (final distribution sampler).
enum LlamaSamplerSpec: Equatable {
    case penalties(lastN: Int32, repeat: Float, freq: Float, present: Float)
    case topK(Int32)
    case topP(Float, minKeep: Int)
    case minP(Float, minKeep: Int)
    case temp(Float)
    case dist(seed: UInt32)

    static func specs(
        temperature: Float,
        topK: Int32,
        topP: Float,
        minP: Float,
        repeatPenalty: Float,
        repeatLastN: Int32,
        seed: UInt32
    ) -> [LlamaSamplerSpec] {
        [
            .penalties(lastN: repeatLastN, repeat: repeatPenalty, freq: 0, present: 0),
            .topK(topK),
            .topP(topP, minKeep: 1),
            .minP(minP, minKeep: 1),
            .temp(temperature),
            .dist(seed: seed),
        ]
    }

    static func specs(from config: CotypingConfiguration) -> [LlamaSamplerSpec] {
        specs(
            temperature: Float(config.temperature),
            topK: Int32(config.topK),
            topP: Float(config.topP),
            minP: Float(config.minP),
            repeatPenalty: Float(config.repeatPenalty),
            repeatLastN: 64,
            seed: UInt32(truncatingIfNeeded: config.seed))
    }
}
```

(Verified against `LokalBot/Cotyping/CotypingModels.swift`: `CotypingConfiguration` stores `temperature`/`topP`/`minP`/`repeatPenalty` as `Double` and `topK`/`seed` as `Int`, so the `Float(...)`, `Int32(...)`, and `UInt32(truncatingIfNeeded:)` conversions above are exactly the required casts. `CotypingConfiguration.standard` is the source of the expected values in the test.)

- [ ] **Step 4: Add to project and run the test**

Run: `cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot && xcodegen generate && xcodebuild test -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' -only-testing:LokalBotTests/LlamaSamplerSpecTests 2>&1 | tail -15`
Expected: `Test Suite 'LlamaSamplerSpecTests' passed`, 2 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot
git add LokalBot/Cotyping/Llama/LlamaSamplerSpec.swift LokalBotTests/LlamaSamplerSpecTests.swift LokalBot.xcodeproj
git commit -m "feat: add LlamaSamplerSpec config→sampler-chain mapping"
```

---

## Task 4: `LlamaCotypingRuntime` — the inference actor

Owns the model + context + KV. Loads once, warms up, tokenizes, runs incremental prefill + the decode loop, all off the main actor. This is the largest task; its integration test is gated on the bundled `Qwen3.5-0.8B-Q4_K_M` model being present and proves both deterministic output and KV reuse.

**Files:**
- Create: `LokalBot/Cotyping/Llama/LlamaCotypingRuntime.swift`
- Test: `LokalBotTests/LlamaCotypingRuntimeTests.swift`

**Interfaces:**
- Consumes: `LlamaCore` (Task 1), `IncrementalPrefill.commonPrefixLength` (Task 2), `LlamaSamplerSpec` (Task 3).
- Produces (the actor's surface, used by `LocalLlamaCotypingEngine` in Task 5):
  - `actor LlamaCotypingRuntime`
  - `enum LlamaRuntimeError: Error { case modelLoadFailed(String); case contextInitFailed; case decodeFailed }`
  - `func loadIfNeeded(modelPath: String) throws`
  - `func unload()`
  - `var isLoaded: Bool { get }`
  - `func tokenize(_ text: String, addBOS: Bool) -> [Int32]`
  - `func generate(promptTokens: [Int32], maxTokens: Int, samplerSpecs: [LlamaSamplerSpec], onToken: @Sendable (String) -> Bool) -> String`
  - `private(set) var lastPrefillTokenCount: Int` — number of tokens decoded during the most recent prefill (the KV-reuse probe).
  - `func prewarm(modelPath: String) throws` — `loadIfNeeded` already runs a priming decode, so this is `loadIfNeeded`.

- [ ] **Step 1: Write the failing integration test (gated on the bundled model)**

Create `LokalBotTests/LlamaCotypingRuntimeTests.swift`:

```swift
import XCTest
@testable import LokalBot

final class LlamaCotypingRuntimeTests: XCTestCase {

    /// Resolves the bundled tiny model from the app bundle's Resources, or skips.
    private func bundledModelPath() throws -> String {
        let entry = ModelCatalog.entry(id: ModelCatalog.bundledID)!
        let storage = StorageManager()
        guard let url = ModelCatalog.localURL(for: entry, storage: storage) else {
            throw XCTSkip("Bundled model \(entry.fileName) not present; skipping libllama integration test.")
        }
        return url.path
    }

    private let standardSpecs = LlamaSamplerSpec.specs(from: .standard)

    func testLoadsAndGeneratesDeterministically() async throws {
        let path = try bundledModelPath()
        let runtime = LlamaCotypingRuntime()
        try await runtime.loadIfNeeded(modelPath: path)
        let loaded = await runtime.isLoaded
        XCTAssertTrue(loaded)

        let prompt = await runtime.tokenize("The capital of France is", addBOS: true)
        XCTAssertFalse(prompt.isEmpty)

        let first = await runtime.generate(
            promptTokens: prompt, maxTokens: 8, samplerSpecs: standardSpecs) { _ in true }
        XCTAssertFalse(first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        // Same prompt + fixed seed (0x00C0FFEE in standardSpecs) → identical output.
        try await runtime.loadIfNeeded(modelPath: path) // no-op reload
        let second = await runtime.generate(
            promptTokens: prompt, maxTokens: 8, samplerSpecs: standardSpecs) { _ in true }
        XCTAssertEqual(first, second, "fixed seed must produce deterministic output")
    }

    func testKVReuseDecodesOnlySuffix() async throws {
        let path = try bundledModelPath()
        let runtime = LlamaCotypingRuntime()
        try await runtime.loadIfNeeded(modelPath: path)

        let base = await runtime.tokenize("Hi Sarah, thanks for sending this over. I wanted to follow", addBOS: true)
        _ = await runtime.generate(promptTokens: base, maxTokens: 2, samplerSpecs: standardSpecs) { _ in true }
        let firstPrefill = await runtime.lastPrefillTokenCount
        XCTAssertEqual(firstPrefill, base.count, "cold prompt prefills every token")

        // Extend the prompt: the shared prefix must be reused, only the suffix decoded.
        let extended = base + (await runtime.tokenize(" up tomorrow", addBOS: false))
        _ = await runtime.generate(promptTokens: extended, maxTokens: 2, samplerSpecs: standardSpecs) { _ in true }
        let secondPrefill = await runtime.lastPrefillTokenCount
        XCTAssertLessThan(secondPrefill, extended.count, "KV reuse must skip the shared prefix")
        XCTAssertEqual(secondPrefill, extended.count - base.count,
                       "only the appended suffix should be prefilled")
    }

    func testOnTokenReturningFalseStopsDecode() async throws {
        let path = try bundledModelPath()
        let runtime = LlamaCotypingRuntime()
        try await runtime.loadIfNeeded(modelPath: path)
        let prompt = await runtime.tokenize("Once upon a time", addBOS: true)
        var count = 0
        let out = await runtime.generate(
            promptTokens: prompt, maxTokens: 20, samplerSpecs: standardSpecs
        ) { _ in count += 1; return count < 3 }   // stop after 3 tokens
        XCTAssertLessThanOrEqual(count, 3)
        XCTAssertFalse(out.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot && xcodebuild test -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' -only-testing:LokalBotTests/LlamaCotypingRuntimeTests 2>&1 | tail -15`
Expected: FAIL — `cannot find 'LlamaCotypingRuntime' in scope`.

- [ ] **Step 3: Write the implementation**

Create `LokalBot/Cotyping/Llama/LlamaCotypingRuntime.swift`:

```swift
import Foundation
import LlamaCore

enum LlamaRuntimeError: Error, Equatable {
    case modelLoadFailed(String)
    case contextInitFailed
    case decodeFailed
}

/// In-process llama.cpp runtime for cotyping. Owns the model, a persistent
/// context + KV cache, and serializes all inference on the actor's executor
/// (off the main actor). Re-prefills only the diverged suffix per call
/// (`IncrementalPrefill`), which is what makes per-keystroke decode cheap.
///
/// Pinned to llama.cpp `b9844`; symbols verified against the vendored dylib.
actor LlamaCotypingRuntime {
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var loadedModelPath: String?
    /// Tokens currently resident in the KV cache (basis for incremental prefill).
    private var cachedTokens: [Int32] = []
    private(set) var lastPrefillTokenCount: Int = 0

    private static var backendReady = false

    var isLoaded: Bool { model != nil && ctx != nil }

    // MARK: - Lifecycle

    func loadIfNeeded(modelPath: String) throws {
        if isLoaded, loadedModelPath == modelPath { return }
        unload()

        if !Self.backendReady {
            llama_backend_init()
            Self.backendReady = true
        }

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 99   // full Metal offload (matches LlamaServer's -ngl 99)
        guard let m = llama_model_load_from_file(modelPath, mparams) else {
            throw LlamaRuntimeError.modelLoadFailed(modelPath)
        }

        var cparams = llama_context_default_params()
        cparams.n_ctx = 2048        // matches LlamaServer.cotyping.contextTokens
        cparams.n_batch = 2048
        let threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
        cparams.n_threads = threads
        cparams.n_threads_batch = threads
        guard let c = llama_init_from_model(m, cparams) else {
            llama_model_free(m)
            throw LlamaRuntimeError.contextInitFailed
        }

        model = m
        ctx = c
        vocab = llama_model_get_vocab(m)
        loadedModelPath = modelPath
        cachedTokens = []
        lastPrefillTokenCount = 0
        warmup()
    }

    /// Prewarm == load + the priming decode `loadIfNeeded` already performs.
    func prewarm(modelPath: String) throws { try loadIfNeeded(modelPath: modelPath) }

    func unload() {
        if let c = ctx { llama_free(c) }
        if let m = model { llama_model_free(m) }
        ctx = nil
        model = nil
        vocab = nil
        loadedModelPath = nil
        cachedTokens = []
    }

    /// Runs one priming decode so Metal pipelines are hot before the first real
    /// keystroke, then clears the KV so generation starts from a clean cache.
    private func warmup() {
        guard let vocab, let ctx else { return }
        let bos = llama_vocab_bos(vocab)
        _ = decode([bos], startPos: 0, logitsLastOnly: true)
        llama_memory_clear(llama_get_memory(ctx), true)
        cachedTokens = []
    }

    // MARK: - Tokenize / detokenize

    func tokenize(_ text: String, addBOS: Bool) -> [Int32] {
        guard let vocab else { return [] }
        return text.withCString { cstr -> [Int32] in
            let textLen = Int32(strlen(cstr))
            var capacity = textLen + (addBOS ? 1 : 0) + 8
            var tokens = [Int32](repeating: 0, count: Int(capacity))
            var n = llama_tokenize(vocab, cstr, textLen, &tokens, capacity, addBOS, true)
            if n < 0 {                      // buffer too small: -n is required size
                capacity = -n
                tokens = [Int32](repeating: 0, count: Int(capacity))
                n = llama_tokenize(vocab, cstr, textLen, &tokens, capacity, addBOS, true)
            }
            return Array(tokens.prefix(Int(max(0, n))))
        }
    }

    private func piece(for token: Int32) -> String {
        guard let vocab else { return "" }
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        }
        guard n > 0 else { return "" }
        let bytes = buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Decode

    /// Decodes `tokens` starting at `startPos` in sequence 0. When
    /// `logitsLastOnly` is true only the final token requests logits (prefill).
    @discardableResult
    private func decode(_ tokens: [Int32], startPos: Int32, logitsLastOnly: Bool) -> Bool {
        guard let ctx, !tokens.isEmpty else { return true }
        var batch = llama_batch_init(Int32(tokens.count), 0, 1)
        defer { llama_batch_free(batch) }
        for i in 0..<tokens.count {
            batch.token[i] = tokens[i]
            batch.pos[i] = startPos + Int32(i)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = 0
            batch.logits[i] = (logitsLastOnly ? (i == tokens.count - 1) : true) ? 1 : 0
        }
        batch.n_tokens = Int32(tokens.count)
        return llama_decode(ctx, batch) == 0
    }

    // MARK: - Generate

    func generate(
        promptTokens: [Int32],
        maxTokens: Int,
        samplerSpecs: [LlamaSamplerSpec],
        onToken: @Sendable (String) -> Bool
    ) -> String {
        guard let ctx, let vocab, !promptTokens.isEmpty else { return "" }
        guard let sampler = makeSampler(samplerSpecs) else { return "" }
        defer { llama_sampler_free(sampler) }

        let mem = llama_get_memory(ctx)
        let reuse = IncrementalPrefill.commonPrefixLength(cachedTokens, promptTokens)
        // Drop the diverged tail from the KV cache (keep [0, reuse)).
        llama_memory_seq_rm(mem, 0, Int32(reuse), -1)

        var newTokens = Array(promptTokens[reuse...])
        var prefillStart = Int32(reuse)
        if newTokens.isEmpty {
            // Prompt identical to cache: re-decode the final token to refresh logits.
            llama_memory_seq_rm(mem, 0, Int32(promptTokens.count - 1), -1)
            newTokens = [promptTokens[promptTokens.count - 1]]
            prefillStart = Int32(promptTokens.count - 1)
        }
        lastPrefillTokenCount = newTokens.count
        guard decode(newTokens, startPos: prefillStart, logitsLastOnly: true) else { return "" }
        cachedTokens = promptTokens

        var output = ""
        var pos = Int32(promptTokens.count)
        for _ in 0..<maxTokens {
            let tok = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, tok) { break }
            llama_sampler_accept(sampler, tok)
            let text = piece(for: tok)
            output += text
            if !onToken(text) { break }
            cachedTokens.append(tok)
            guard decode([tok], startPos: pos, logitsLastOnly: true) else { break }
            pos += 1
        }
        return output
    }

    private func makeSampler(_ specs: [LlamaSamplerSpec]) -> OpaquePointer? {
        let params = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(params) else { return nil }
        for spec in specs {
            let s: OpaquePointer?
            switch spec {
            case let .penalties(lastN, rep, freq, present):
                s = llama_sampler_init_penalties(lastN, rep, freq, present)
            case let .topK(k):            s = llama_sampler_init_top_k(k)
            case let .topP(p, minKeep):   s = llama_sampler_init_top_p(p, minKeep)
            case let .minP(p, minKeep):   s = llama_sampler_init_min_p(p, minKeep)
            case let .temp(t):            s = llama_sampler_init_temp(t)
            case let .dist(seed):         s = llama_sampler_init_dist(seed)
            }
            if let s { llama_sampler_chain_add(chain, s) }
        }
        return chain
    }
}
```

- [ ] **Step 4: Add to project and run the integration test**

Run: `cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot && xcodegen generate && xcodebuild test -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' -only-testing:LokalBotTests/LlamaCotypingRuntimeTests 2>&1 | tail -30`
Expected: `Test Suite 'LlamaCotypingRuntimeTests' passed`, 3 tests, 0 failures — OR each test reports `Skipped` if the bundled GGUF isn't resolvable in the test host (acceptable on CI; the code still had to compile + link). If a test *fails* on `seq_id[i]!` being nil, the batch's `n_seq_max` was too small — confirm `llama_batch_init(..., 1)`. If `testKVReuseDecodesOnlySuffix` fails because `secondPrefill == extended.count`, the tokenizer re-added a BOS to the suffix; confirm the test tokenizes the suffix with `addBOS: false` (it does) and that `commonPrefixLength` sees the shared prefix.

- [ ] **Step 5: Commit**

```bash
cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot
git add LokalBot/Cotyping/Llama/LlamaCotypingRuntime.swift LokalBotTests/LlamaCotypingRuntimeTests.swift LokalBot.xcodeproj
git commit -m "feat: add LlamaCotypingRuntime in-process inference actor (KV reuse, warmup)"
```

---

## Task 5: `LocalLlamaCotypingEngine` — the `CotypingCompleting` seam

Adapt the runtime to the protocol the coordinator already calls. Reuse the existing `CotypingTextNormalizer.normalizeDetailed` + `CotypingDecodeStopPolicy.verdict` unchanged. Honor `Task.isCancelled` so a superseding keystroke stops decode within one token (the coordinator already cancels the in-flight task — see plan note below).

**Files:**
- Create: `LokalBot/Cotyping/Llama/LocalLlamaCotypingEngine.swift`
- Test: `LokalBotTests/LlamaCotypingRuntimeTests.swift` (add cases) — or a new `LocalLlamaCotypingEngineTests.swift`.

**Interfaces:**
- Consumes: `LlamaCotypingRuntime` (Task 4), `LlamaSamplerSpec` (Task 3), `CotypingRequest`/`CotypingNormalizationResult`/`CotypingTextNormalizer`/`CotypingDecodeStopPolicy`/`CotypingCompleting` (existing).
- Produces: `@MainActor final class LocalLlamaCotypingEngine: CotypingCompleting`, `init(runtime: LlamaCotypingRuntime, modelPath: String)`, plus `func prewarm() async throws`. Used by the selector (Task 7).

> **Cancellation note (no coordinator change):** `CotypingCoordinator.scheduleGeneration()` cancels `debounceTask` and `generate(work:)` runs *inside* that task, so a superseding keystroke cancels the task while it is suspended in `engine.generateStreaming`. Therefore checking `Task.isCancelled` inside the per-token closure halts decode immediately. This is the same mechanism the HTTP engine relies on (it observes `URLError.cancelled`).

- [ ] **Step 1: Write the failing test**

Append to `LokalBotTests/LlamaCotypingRuntimeTests.swift` a new `@MainActor` test class (the engine is `@MainActor`):

```swift
@MainActor
final class LocalLlamaCotypingEngineTests: XCTestCase {
    private func bundledModelPath() throws -> String {
        let entry = ModelCatalog.entry(id: ModelCatalog.bundledID)!
        guard let url = ModelCatalog.localURL(for: entry, storage: StorageManager()) else {
            throw XCTSkip("Bundled model not present; skipping engine integration test.")
        }
        return url.path
    }

    private func makeRequest() -> CotypingRequest {
        let field = CotypingField(
            appName: "Mail", bundleID: "com.apple.mail", processID: 0, role: "AXTextArea",
            precedingText: "Hi Sarah,\nThanks for sending this over. I wanted to follow",
            trailingText: "", selectionLength: 0, caretRect: .zero, isSecure: false,
            caretIsExact: true, windowTitle: "Re: Q3", fieldPlaceholder: nil)
        return CotypingRequestBuilder.build(
            field: field, config: .standard,
            personalization: .none, generation: 1, learnedExamples: [])!
    }

    func testGenerateReturnsNormalizedResult() async throws {
        let path = try bundledModelPath()
        let engine = LocalLlamaCotypingEngine(runtime: LlamaCotypingRuntime(), modelPath: path)
        let result = try await engine.generate(makeRequest())
        XCTAssertFalse(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testStreamingFiresPartials() async throws {
        let path = try bundledModelPath()
        let engine = LocalLlamaCotypingEngine(runtime: LlamaCotypingRuntime(), modelPath: path)
        var partials = 0
        _ = try await engine.generateStreaming(makeRequest()) { _ in partials += 1 }
        XCTAssertGreaterThan(partials, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot && xcodebuild test -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' -only-testing:LokalBotTests/LocalLlamaCotypingEngineTests 2>&1 | tail -15`
Expected: FAIL — `cannot find 'LocalLlamaCotypingEngine' in scope`.

- [ ] **Step 3: Write the implementation**

Create `LokalBot/Cotyping/Llama/LocalLlamaCotypingEngine.swift`:

```swift
import Foundation

/// In-process `CotypingCompleting` conformer. Tokenizes the already-built
/// prompt, drives `LlamaCotypingRuntime`, and reuses the EXACT same
/// normalization + decode-stop policy as the HTTP engine so suggestions are
/// shaped identically. Stops on the stop policy, the token budget, or task
/// cancellation (superseded keystroke).
@MainActor
final class LocalLlamaCotypingEngine: CotypingCompleting {
    private let runtime: LlamaCotypingRuntime
    private let modelPath: String

    init(runtime: LlamaCotypingRuntime, modelPath: String) {
        self.runtime = runtime
        self.modelPath = modelPath
    }

    /// Loads + primes the model so the first keystroke isn't cold.
    func prewarm() async throws {
        try await runtime.prewarm(modelPath: modelPath)
    }

    func generate(_ request: CotypingRequest) async throws -> CotypingNormalizationResult {
        try await run(request) { _ in }
    }

    func generateStreaming(
        _ request: CotypingRequest,
        onPartial: @escaping @Sendable (CotypingNormalizationResult) -> Void
    ) async throws -> CotypingNormalizationResult {
        try await run(request, onPartial: onPartial)
    }

    private func run(
        _ request: CotypingRequest,
        onPartial: @escaping @Sendable (CotypingNormalizationResult) -> Void
    ) async throws -> CotypingNormalizationResult {
        try await runtime.loadIfNeeded(modelPath: modelPath)
        let promptTokens = await runtime.tokenize(request.prompt, addBOS: true)
        guard !promptTokens.isEmpty else {
            return CotypingNormalizationResult(text: "", suppression: .emptyGeneration)
        }

        let specs = LlamaSamplerSpec.specs(
            temperature: Float(request.temperature),
            topK: Int32(request.topK),
            topP: Float(request.topP),
            minP: Float(request.minP),
            repeatPenalty: Float(request.repeatPenalty),
            repeatLastN: 64,
            seed: UInt32(truncatingIfNeeded: request.seed))

        let accumulator = TokenAccumulator()
        let raw = await runtime.generate(
            promptTokens: promptTokens,
            maxTokens: request.maxTokens,
            samplerSpecs: specs
        ) { piece in
            if Task.isCancelled { return false }
            accumulator.append(piece)
            let result = CotypingTextNormalizer.normalizeDetailed(accumulator.raw, for: request)
            onPartial(result)
            // Native decode-stop at the SAME boundary the HTTP path stops at.
            if CotypingDecodeStopPolicy.verdict(
                accumulated: accumulator.raw,
                tokensGenerated: accumulator.count) != nil {
                return false
            }
            return true
        }

        if Task.isCancelled { throw CancellationError() }
        return CotypingTextNormalizer.normalizeDetailed(raw, for: request)
    }
}

/// Reference-typed accumulator the decode closure mutates across token calls.
/// The runtime invokes `onToken` serially on one thread, so no synchronization
/// is required; marked `@unchecked Sendable` only to cross the actor boundary.
private final class TokenAccumulator: @unchecked Sendable {
    private(set) var raw = ""
    private(set) var count = 0
    func append(_ piece: String) { raw += piece; count += 1 }
}
```

- [ ] **Step 4: Add to project and run the test**

Run: `cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot && xcodegen generate && xcodebuild test -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' -only-testing:LokalBotTests/LocalLlamaCotypingEngineTests 2>&1 | tail -25`
Expected: `Test Suite 'LocalLlamaCotypingEngineTests' passed` (or `Skipped` if model absent). If the closure won't compile (`@Sendable` capture of `request`), confirm `CotypingRequest` is `Sendable` (it is) and that `onPartial` is the `@Sendable` parameter.

- [ ] **Step 5: Commit**

```bash
cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot
git add LokalBot/Cotyping/Llama/LocalLlamaCotypingEngine.swift LokalBotTests/LlamaCotypingRuntimeTests.swift LokalBot.xcodeproj
git commit -m "feat: add LocalLlamaCotypingEngine seam reusing normalizer + stop policy"
```

---

## Task 6: `AppSettings.cotypingInProcessRuntime` flag (resolves open question #1)

Spec open question #1's recommendation: flag-gated default-on, HTTP fallback one toggle away. Add a persisted bool defaulting `true`, with tolerant decoding so existing saved settings don't break.

**Files:**
- Modify: `LokalBot/Models/AppSettings.swift`
- Test: `LokalBotTests/CotypingTests.swift` (the `CotypingSettingsTests` group)

**Interfaces:**
- Consumes: nothing.
- Produces: `AppSettings.cotypingInProcessRuntime: Bool` (default `true`). Used by `CotypingEngineSelector.shouldUseLocal` (Task 7).

- [ ] **Step 1: Write the failing test**

In `LokalBotTests/CotypingTests.swift`, add to the `CotypingSettingsTests` class:

```swift
    func testInProcessRuntimeDefaultsOn() {
        XCTAssertTrue(AppSettings().cotypingInProcessRuntime)
    }

    func testInProcessRuntimeRoundTrips() throws {
        var settings = AppSettings()
        settings.cotypingInProcessRuntime = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertFalse(decoded.cotypingInProcessRuntime)
    }

    func testTolerantDecodeDefaultsInProcessRuntimeOn() throws {
        // A saved blob predating the flag must decode with the default (true).
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertTrue(decoded.cotypingInProcessRuntime)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot && xcodebuild test -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' -only-testing:LokalBotTests/CotypingSettingsTests/testInProcessRuntimeDefaultsOn 2>&1 | tail -15`
Expected: FAIL — `value of type 'AppSettings' has no member 'cotypingInProcessRuntime'`.

- [ ] **Step 3: Add the property with a default**

In `LokalBot/Models/AppSettings.swift`, add the stored property next to the other `cotyping*` fields (e.g. just after `cotypingBuiltInModelID`):

```swift
    /// When true (default), cotyping uses the in-process `libllama` runtime for
    /// the built-in GGUF backend on Apple Silicon; false forces the HTTP
    /// `llama-server` path. The HTTP fallback also covers non-GGUF backends and
    /// any in-process load failure regardless of this flag.
    var cotypingInProcessRuntime: Bool = true
```

`AppSettings` does `Codable` by hand — explicit `CodingKeys`, explicit `encode(to:)`, and a tolerant `init(from:)` (the container is named `c`, defaults come from a local `let defaults = AppSettings()`). Wire the new key into **all three**, mirroring the existing `cotypingBuiltInModelID` lines exactly. Missing the encode line is silent: `encode(to:)` would drop the key and `testInProcessRuntimeRoundTrips` would fail (decode falls back to the `true` default).

1. Add the coding key to the `CodingKeys` enum (next to `case cotypingBuiltInModelID`, ~line 281):

```swift
        case cotypingInProcessRuntime
```

2. Add an encode line in `encode(to:)` (after `try c.encode(cotypingBuiltInModelID, forKey: .cotypingBuiltInModelID)`, ~line 354):

```swift
        try c.encode(cotypingInProcessRuntime, forKey: .cotypingInProcessRuntime)
```

3. Add a tolerant decode line in `init(from:)` (after the `cotypingBuiltInModelID` decode, ~line 416):

```swift
        cotypingInProcessRuntime = (try? c.decode(Bool.self, forKey: .cotypingInProcessRuntime)) ?? defaults.cotypingInProcessRuntime
```

- [ ] **Step 4: Run the tests**

Run: `cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot && xcodebuild test -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' -only-testing:LokalBotTests/CotypingSettingsTests 2>&1 | tail -20`
Expected: all `CotypingSettingsTests` pass, including the three new cases and the existing `testTolerantDecodeKeepsOtherDefaults`.

- [ ] **Step 5: Commit**

```bash
cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot
git add LokalBot/Models/AppSettings.swift LokalBotTests/CotypingTests.swift
git commit -m "feat: add cotypingInProcessRuntime flag (default on, tolerant decode)"
```

---

## Task 7: `CotypingEngineSelector` + AppState wiring + prewarm

Route each completion to the local engine when (flag on) ∧ (Apple Silicon) ∧ (built-in model resolves to a GGUF on disk); otherwise the existing HTTP `CotypingEngine`. Fall back to HTTP if the local engine throws a load error (spec §11). Wire it into `AppState` and prewarm on cotyping-enable.

**Files:**
- Create: `LokalBot/Cotyping/Llama/CotypingEngineSelector.swift`
- Modify: `LokalBot/LokalBotApp.swift` (the `cotypingEngine` lazy var ~line 430, and the cotyping-enable path)
- Test: `LokalBotTests/CotypingEngineSelectorTests.swift`

**Interfaces:**
- Consumes: `CotypingCompleting` (existing HTTP `CotypingEngine`), `LocalLlamaCotypingEngine` (Task 5), `AppSettings` (`cotypingInProcessRuntime`, `cotypingBuiltInModelID`, `customBuiltInModels`), `ModelCatalog`, `StorageManager`, `LlamaRuntimeError` (Task 4).
- Produces:
  - `@MainActor final class CotypingEngineSelector: CotypingCompleting`
  - `init(http: CotypingCompleting, makeLocal: @escaping (String) -> LocalLlamaCotypingEngine, settings: @escaping () -> AppSettings, storage: StorageManager)`
  - `static func shouldUseLocal(settings: AppSettings, modelURL: URL?, isAppleSilicon: Bool) -> Bool`
  - `func prewarm() async`

- [ ] **Step 1: Write the failing test (pure decision function)**

Create `LokalBotTests/CotypingEngineSelectorTests.swift`:

```swift
import XCTest
@testable import LokalBot

final class CotypingEngineSelectorTests: XCTestCase {
    private let modelURL = URL(fileURLWithPath: "/models/gemma.gguf")

    func testUsesLocalWhenFlagOnAppleSiliconAndModelResolves() {
        var s = AppSettings(); s.cotypingInProcessRuntime = true
        XCTAssertTrue(CotypingEngineSelector.shouldUseLocal(
            settings: s, modelURL: modelURL, isAppleSilicon: true))
    }

    func testFallsBackWhenFlagOff() {
        var s = AppSettings(); s.cotypingInProcessRuntime = false
        XCTAssertFalse(CotypingEngineSelector.shouldUseLocal(
            settings: s, modelURL: modelURL, isAppleSilicon: true))
    }

    func testFallsBackOnIntel() {
        var s = AppSettings(); s.cotypingInProcessRuntime = true
        XCTAssertFalse(CotypingEngineSelector.shouldUseLocal(
            settings: s, modelURL: modelURL, isAppleSilicon: false))
    }

    func testFallsBackWhenModelMissing() {
        var s = AppSettings(); s.cotypingInProcessRuntime = true
        XCTAssertFalse(CotypingEngineSelector.shouldUseLocal(
            settings: s, modelURL: nil, isAppleSilicon: true))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot && xcodebuild test -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' -only-testing:LokalBotTests/CotypingEngineSelectorTests 2>&1 | tail -15`
Expected: FAIL — `cannot find 'CotypingEngineSelector' in scope`.

- [ ] **Step 3: Write the implementation**

Create `LokalBot/Cotyping/Llama/CotypingEngineSelector.swift`:

```swift
import Foundation

/// Per-completion router between the in-process `LocalLlamaCotypingEngine`
/// (built-in GGUF on Apple Silicon, flag on) and the existing HTTP
/// `CotypingEngine` (non-GGUF backends, flag off, or in-process load failure).
/// Conforms to `CotypingCompleting`, so `CotypingCoordinator` is unchanged.
@MainActor
final class CotypingEngineSelector: CotypingCompleting {
    private let http: CotypingCompleting
    private let makeLocal: (String) -> LocalLlamaCotypingEngine
    private let settings: () -> AppSettings
    private let storage: StorageManager
    private var local: LocalLlamaCotypingEngine?
    private var localModelPath: String?
    /// Set after the first in-process failure so the HTTP fallback is logged
    /// once per failure episode (spec §13), not on every keystroke. Reset on a
    /// successful local generation or a model-path change.
    private var didLogLocalFailure = false

    init(
        http: CotypingCompleting,
        makeLocal: @escaping (String) -> LocalLlamaCotypingEngine,
        settings: @escaping () -> AppSettings,
        storage: StorageManager
    ) {
        self.http = http
        self.makeLocal = makeLocal
        self.settings = settings
        self.storage = storage
    }

    static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    static func shouldUseLocal(settings: AppSettings, modelURL: URL?, isAppleSilicon: Bool) -> Bool {
        settings.cotypingInProcessRuntime && isAppleSilicon && modelURL != nil
    }

    /// Resolves the built-in cotyping model path the same way `makeTextEngine` does.
    private func resolvedModelURL(_ s: AppSettings) -> URL? {
        guard let entry = ModelCatalog.entry(id: s.cotypingBuiltInModelID, custom: s.customBuiltInModels)
                ?? ModelCatalog.entry(id: ModelCatalog.bundledID) else { return nil }
        return ModelCatalog.localURL(for: entry, storage: storage)
    }

    /// Returns the local engine if eligible, lazily (re)building it when the
    /// resolved model path changes; nil → use HTTP.
    private func localIfEligible() -> LocalLlamaCotypingEngine? {
        let s = settings()
        guard let url = resolvedModelURL(s),
              Self.shouldUseLocal(settings: s, modelURL: url, isAppleSilicon: Self.isAppleSilicon)
        else { return nil }
        if local == nil || localModelPath != url.path {
            local = makeLocal(url.path)
            localModelPath = url.path
            didLogLocalFailure = false
        }
        return local
    }

    func prewarm() async {
        guard let engine = localIfEligible() else { return }
        try? await engine.prewarm()
    }

    func generate(_ request: CotypingRequest) async throws -> CotypingNormalizationResult {
        guard let engine = localIfEligible() else { return try await http.generate(request) }
        do {
            let result = try await engine.generate(request)
            didLogLocalFailure = false
            return result
        } catch let error as LlamaRuntimeError {
            logLocalFallback(error)
            return try await http.generate(request)
        }
    }

    func generateStreaming(
        _ request: CotypingRequest,
        onPartial: @escaping @Sendable (CotypingNormalizationResult) -> Void
    ) async throws -> CotypingNormalizationResult {
        guard let engine = localIfEligible() else {
            return try await http.generateStreaming(request, onPartial: onPartial)
        }
        do {
            let result = try await engine.generateStreaming(request, onPartial: onPartial)
            didLogLocalFailure = false
            return result
        } catch let error as LlamaRuntimeError {
            logLocalFallback(error)
            return try await http.generateStreaming(request, onPartial: onPartial)
        }
    }

    /// Logs the in-process→HTTP fallback once per failure episode (spec §13).
    /// The local engine is kept (not torn down) so a transient failure — e.g. a
    /// memory-pressure unload (Task 8) — recovers on a later completion, and the
    /// log does not repeat on every keystroke.
    private func logLocalFallback(_ error: LlamaRuntimeError) {
        guard !didLogLocalFailure else { return }
        didLogLocalFailure = true
        NSLog("Cotyping: in-process runtime unavailable (\(error)); using HTTP fallback (will keep retrying).")
    }
}
```

- [ ] **Step 4: Run the selector unit test**

Run: `cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot && xcodegen generate && xcodebuild test -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' -only-testing:LokalBotTests/CotypingEngineSelectorTests 2>&1 | tail -15`
Expected: `Test Suite 'CotypingEngineSelectorTests' passed`, 4 tests, 0 failures.

- [ ] **Step 5: Wire the selector into `AppState`**

In `LokalBot/LokalBotApp.swift`, replace the existing `cotypingEngine` lazy var (currently around line 430):

```swift
    private(set) lazy var cotypingEngine = CotypingEngine(makeEngine: { [weak self] in
        guard let self else { throw TextEngineError.unavailable("LokalBot is shutting down.") }
        return try await self.pipeline.makeTextEngine(
            self.settings.cotypingTextEngineSettings,
            server: .cotyping)
    })
```

with the selector wrapping that exact HTTP engine as its fallback:

```swift
    private(set) lazy var cotypingEngine = CotypingEngineSelector(
        http: CotypingEngine(makeEngine: { [weak self] in
            guard let self else { throw TextEngineError.unavailable("LokalBot is shutting down.") }
            return try await self.pipeline.makeTextEngine(
                self.settings.cotypingTextEngineSettings,
                server: .cotyping)
        }),
        makeLocal: { modelPath in
            LocalLlamaCotypingEngine(runtime: LlamaCotypingRuntime(), modelPath: modelPath)
        },
        settings: { [weak self] in self?.settings ?? AppSettings() },
        storage: storage)
```

`CotypingCoordinator(engine: cotypingEngine, ...)` is unchanged — `CotypingEngineSelector` is a `CotypingCompleting`. The property type changes from `CotypingEngine` to `CotypingEngineSelector`; both satisfy the coordinator's `CotypingCompleting` parameter.

- [ ] **Step 6: Prewarm on cotyping-enable**

`cotyping.applySettings()` is the single propagation point, called from two places in `LokalBotApp.swift`: the `settings.didSet` (~line 388, `if interactive { cotyping.applySettings() }`) and app startup (~line 620). Add an idempotent prewarm kick after each, guarded by `settings.cotypingEnabled` — `prewarm()` early-returns when not eligible or already loaded.

At ~line 388, change:

```swift
            if interactive { cotyping.applySettings() }
```

to:

```swift
            if interactive {
                cotyping.applySettings()
                if settings.cotypingEnabled { Task { await cotypingEngine.prewarm() } }
            }
```

At ~line 620, after the startup `cotyping.applySettings()`:

```swift
        cotyping.applySettings()
        if settings.cotypingEnabled { Task { await cotypingEngine.prewarm() } }
```

`cotypingEngine` is now the `CotypingEngineSelector` (Step 5), whose `prewarm()` is `@MainActor async`; each `Task {}` inherits the main actor.

- [ ] **Step 7: Build the app and run the full cotyping + new suites**

Run: `cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot && xcodegen generate && xcodebuild test -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' -only-testing:LokalBotTests/CotypingEngineSelectorTests -only-testing:LokalBotTests/CotypingSettingsTests -only-testing:LokalBotTests/CotypingTests 2>&1 | tail -25`
Expected: the app target compiles (selector wired in) and all listed suites pass. A compile error here usually means the `cotypingEngine` property type change broke a reference — grep `LokalBotApp.swift` for other uses of `cotypingEngine` and confirm they only rely on `CotypingCompleting`/`prewarm`.

- [ ] **Step 8: Commit**

```bash
cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot
git add LokalBot/Cotyping/Llama/CotypingEngineSelector.swift LokalBot/LokalBotApp.swift LokalBotTests/CotypingEngineSelectorTests.swift LokalBot.xcodeproj
git commit -m "feat: route cotyping to in-process engine with HTTP fallback + prewarm"
```

---

## Task 8: Memory-pressure unload (spec §11, load-bearing per risk table)

The default cotyping model is now Gemma 4 E4B Q5 XL (~5 GB resident), so the memory-pressure unload is load-bearing, not optional. Add a `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` source that unloads the in-process model on warning; the next completion lazily reloads (or, if reload fails, the selector's `LlamaRuntimeError` path routes to HTTP).

**Files:**
- Modify: `LokalBot/Cotyping/Llama/LlamaCotypingRuntime.swift` (add `handleMemoryPressure()` + `isLoaded` already exists)
- Modify: `LokalBot/Cotyping/Llama/LocalLlamaCotypingEngine.swift` (own the dispatch source; call runtime on warning)
- Test: `LokalBotTests/LlamaCotypingRuntimeTests.swift` (add an unload test that does not need the model)

**Interfaces:**
- Consumes: `LlamaCotypingRuntime.unload()` / `isLoaded` (Task 4).
- Produces: `LlamaCotypingRuntime.handleMemoryPressure()` (calls `unload()`); `LocalLlamaCotypingEngine` installs a memory-pressure dispatch source at init.

- [ ] **Step 1: Write the failing test**

Add to `LlamaCotypingRuntimeTests` (does not require the model — exercises the unload path directly):

```swift
    func testMemoryPressureUnloadsWhenNotLoaded() async {
        let runtime = LlamaCotypingRuntime()
        let before = await runtime.isLoaded
        XCTAssertFalse(before)
        await runtime.handleMemoryPressure()   // safe no-op when nothing is loaded
        let after = await runtime.isLoaded
        XCTAssertFalse(after)
    }
```

(A loaded→unloaded assertion would require the GGUF; the deterministic part we can always run is that `handleMemoryPressure` is callable and leaves an unloaded runtime unloaded. The load→unload transition is covered when the gated model is present via `testLoadsAndGeneratesDeterministically` + a follow-up `handleMemoryPressure` call below.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot && xcodebuild test -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' -only-testing:LokalBotTests/LlamaCotypingRuntimeTests/testMemoryPressureUnloadsWhenNotLoaded 2>&1 | tail -15`
Expected: FAIL — `value of type 'LlamaCotypingRuntime' has no member 'handleMemoryPressure'`.

- [ ] **Step 3: Add `handleMemoryPressure` to the runtime**

In `LokalBot/Cotyping/Llama/LlamaCotypingRuntime.swift`, add:

```swift
    /// Frees the model + context under memory pressure. The next `generate`
    /// call lazily reloads via `loadIfNeeded` (or the engine routes to HTTP if
    /// reload fails). Keeps cotyping from OOMing the app under a large model.
    func handleMemoryPressure() {
        unload()
    }
```

- [ ] **Step 4: Install the dispatch source in the engine**

In `LokalBot/Cotyping/Llama/LocalLlamaCotypingEngine.swift`, add a stored `memoryPressureSource` and install it in `init`:

```swift
    private var memoryPressureSource: DispatchSourceMemoryPressure?
```

At the end of `init(runtime:modelPath:)`:

```swift
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [runtime] in
            Task { await runtime.handleMemoryPressure() }
        }
        source.resume()
        self.memoryPressureSource = source
```

And cancel it on deinit:

```swift
    deinit { memoryPressureSource?.cancel() }
```

(`runtime` is captured directly — it's an actor, safely `Sendable`. The handler hops onto the actor via `Task`.)

- [ ] **Step 5: Run the test + confirm the engine still builds**

Run: `cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot && xcodegen generate && xcodebuild test -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' -only-testing:LokalBotTests/LlamaCotypingRuntimeTests/testMemoryPressureUnloadsWhenNotLoaded 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot
git add LokalBot/Cotyping/Llama/LlamaCotypingRuntime.swift LokalBot/Cotyping/Llama/LocalLlamaCotypingEngine.swift LokalBotTests/LlamaCotypingRuntimeTests.swift
git commit -m "feat: unload in-process cotyping model under memory pressure"
```

---

## Task 9: A/B benchmark (local vs HTTP) + parity-doc update (spec §14, §16)

Extend the benchmark to record TTFT and run both engines on the existing default scenarios, producing a comparison that substantiates the latency claim in `CotypingParityQA.md`. The summary math is unit-tested with synthetic results (no model needed); the live A/B is exposed for manual runs.

**Files:**
- Modify: `LokalBot/Cotyping/CotypingBenchmark.swift`
- Modify: `Docs/guides/CotypingParityQA.md`
- Test: `LokalBotTests/CotypingABBenchmarkTests.swift`

**Interfaces:**
- Consumes: `CotypingBenchmarkRunner.run(...)`, `CotypingBenchmarkSummary` (existing), `CotypingCompleting`.
- Produces:
  - `struct CotypingABComparison: Equatable, Sendable { let local: CotypingBenchmarkSummary; let http: CotypingBenchmarkSummary; var ttftDeltaMs: Int?; var p95DeltaMs: Int? }`
  - `static func CotypingBenchmarkRunner.runAB(local:http:config:personalization:learnedExamples:) async -> CotypingABComparison`

- [ ] **Step 1: Write the failing test (pure comparison math)**

Create `LokalBotTests/CotypingABBenchmarkTests.swift`:

```swift
import XCTest
@testable import LokalBot

final class CotypingABBenchmarkTests: XCTestCase {
    private func summary(latency: Int, ttft: Int) -> CotypingBenchmarkSummary {
        CotypingBenchmarkSummary(results: [
            CotypingBenchmarkCaseResult(
                scenarioID: "s", name: "s", text: "hello", latencyMs: latency,
                firstVisibleLatencyMs: ttft, expectedTermHits: 0, expectedTermCount: 0,
                suppression: nil, error: nil, expectedVisibleSuggestion: true,
                allowedSuppression: false, latencyTargetMs: 2000),
        ])
    }

    func testComparisonComputesDeltas() {
        let comparison = CotypingABComparison(
            local: summary(latency: 300, ttft: 120),
            http: summary(latency: 1100, ttft: 600))
        XCTAssertEqual(comparison.p95DeltaMs, 800)    // http p95 - local p95
        XCTAssertEqual(comparison.ttftDeltaMs, 480)   // http ttft - local ttft (local is faster)
    }

    func testComparisonHandlesMissingTTFT() {
        let comparison = CotypingABComparison(
            local: summary(latency: 300, ttft: 120),
            http: CotypingBenchmarkSummary(results: []))
        XCTAssertNil(comparison.p95DeltaMs)
        XCTAssertNil(comparison.ttftDeltaMs)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot && xcodebuild test -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' -only-testing:LokalBotTests/CotypingABBenchmarkTests 2>&1 | tail -15`
Expected: FAIL — `cannot find 'CotypingABComparison' in scope`.

- [ ] **Step 3: Add the comparison type + AB runner**

Append to `LokalBot/Cotyping/CotypingBenchmark.swift`:

```swift
/// Result of running both cotyping engines over the same scenarios. Deltas are
/// `http − local`, so a positive value means the in-process engine is faster.
struct CotypingABComparison: Equatable, Sendable {
    let local: CotypingBenchmarkSummary
    let http: CotypingBenchmarkSummary

    /// p95 end-to-end latency improvement (ms), or nil if either side has no data.
    var p95DeltaMs: Int? {
        guard let l = local.p95LatencyMs, let h = http.p95LatencyMs else { return nil }
        return h - l
    }

    /// Time-to-first-visible-token improvement (ms), or nil if either side lacks it.
    var ttftDeltaMs: Int? {
        guard let l = local.averageFirstVisibleLatencyMs,
              let h = http.averageFirstVisibleLatencyMs else { return nil }
        return h - l
    }
}

extension CotypingBenchmarkRunner {
    /// Runs the default scenarios through both engines (streaming on, so TTFT is
    /// captured) and returns the comparison. For manual latency validation.
    static func runAB(
        local: CotypingCompleting,
        http: CotypingCompleting,
        config: CotypingConfiguration,
        personalization: CotypingPersonalization,
        learnedExamples: @escaping (CotypingField) -> [String] = { _ in [] }
    ) async -> CotypingABComparison {
        let localSummary = await run(
            engine: local, config: config, personalization: personalization,
            streamPartials: true, learnedExamples: learnedExamples)
        let httpSummary = await run(
            engine: http, config: config, personalization: personalization,
            streamPartials: true, learnedExamples: learnedExamples)
        return CotypingABComparison(local: localSummary, http: httpSummary)
    }
}
```

- [ ] **Step 4: Run the test**

Run: `cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot && xcodebuild test -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' -only-testing:LokalBotTests/CotypingABBenchmarkTests 2>&1 | tail -15`
Expected: `Test Suite 'CotypingABBenchmarkTests' passed`, 2 tests, 0 failures.

- [ ] **Step 5: Update `Docs/guides/CotypingParityQA.md`**

Open `Docs/guides/CotypingParityQA.md`. Find the line that names the runtime as the known-incomplete parity item (it calls the HTTP runtime the one outstanding gap). Update it to reflect that the in-process runtime has landed, and add a short "how to measure" note. Replace the runtime-gap sentence with:

```markdown
- **Generation runtime — DONE.** Cotyping now decodes the built-in GGUF model
  in-process via `libllama` (`b9844`), holding a persistent KV cache and
  re-prefilling only the typed suffix (`LocalLlamaCotypingEngine` →
  `LlamaCotypingRuntime`). The HTTP `llama-server` path remains as the fallback
  for non-GGUF backends, when the in-process runtime is toggled off
  (`cotypingInProcessRuntime`), or on load failure. A/B latency is measured by
  `CotypingBenchmarkRunner.runAB(local:http:...)` over the default scenarios
  (TTFT + p95 deltas).
```

(If the doc lists the runtime under a "known gaps" / "outstanding" heading, move the item to the "done / parity achieved" section instead of leaving it under gaps.)

- [ ] **Step 6: Commit**

```bash
cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot
git add LokalBot/Cotyping/CotypingBenchmark.swift LokalBotTests/CotypingABBenchmarkTests.swift Docs/guides/CotypingParityQA.md
git commit -m "feat: A/B cotyping benchmark (in-process vs HTTP) + parity doc update"
```

---

## Task 10: Settings toggle + full regression run

Expose the runtime flag in Settings (so the fallback is "one toggle away" per open question #1) and run the complete test suite to confirm no regression.

**Files:**
- Modify: `LokalBot/Views/SettingsView.swift` (the Cotyping section)
- Test: full `LokalBotTests` run.

**Interfaces:**
- Consumes: `AppSettings.cotypingInProcessRuntime` (Task 6).
- Produces: a user-visible toggle bound to it. No new symbols.

- [ ] **Step 1: Add the toggle**

In `LokalBot/Views/SettingsView.swift`, in the Cotyping settings section (search for an existing `cotyping*` binding such as `cotypingDebounceMs` or `cotypingStreamSuggestionsWhileGenerating` to find the section and copy its `Toggle`/binding idiom), add:

```swift
                Toggle("Use the fast in-process runtime (recommended)", isOn: $settings.cotypingInProcessRuntime)
                Text("Decodes the built-in model in-process for lower latency. Turn off to use the background llama-server. Non-built-in backends always use the server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
```

(Match the surrounding binding pattern exactly — if the view binds through a view model or `@Bindable settings` rather than `$settings`, use that. Place it near the other cotyping performance toggles.)

- [ ] **Step 2: Build to confirm the view compiles**

Run: `cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot && xcodebuild build -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`. A binding-type error means the settings access pattern differs — match the neighboring toggle.

- [ ] **Step 3: Run the FULL test suite (regression gate)**

Run: `cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot && xcodebuild test -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' -only-testing:LokalBotTests 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`. All pre-existing tests (the 21 cotyping/catalog tests plus the rest of `LokalBotTests`) still pass; new suites pass or `Skipped` (model-gated). If any *pre-existing* test fails, the seam wiring regressed something — bisect against the Task 7 commit.

- [ ] **Step 4: Commit**

```bash
cd /Users/0xmithrandir/Documents/GitHub/lokalbotfable/LokalBot
git add LokalBot/Views/SettingsView.swift
git commit -m "feat: add Settings toggle for the in-process cotyping runtime"
```

---

## Manual verification (post-implementation, not a code task)

From spec §5/§14 — run these by hand once the plan is implemented:

- **TTFT / p95:** with the bundled `Qwen3.5-0.8B-Q4_K_M`, trigger `CotypingBenchmarkRunner.runAB(...)` (or the existing `Scripts/cotyping/compare-cotyping.sh`) and confirm first ghost token < ~200–300 ms post-warmup and p95 well under 2000 ms, beating the HTTP summary.
- **No main-thread hitch:** Instruments (Time Profiler) while typing into a real text field with a generation in flight — the main thread must stay responsive.
- **Instant cancellation:** type quickly; superseding keystrokes must not paint stale ghosts (the generation-id guard + `Task.isCancelled` drop them).
- **Fallback:** toggle `cotypingInProcessRuntime` off → confirm suggestions still come from `llama-server`; switch the cotyping model to a non-GGUF backend (if configured) → confirm HTTP path; simulate load failure (rename the GGUF) → confirm graceful fallback, no crash.
