# Standard native hybrid decoder — 11 October 2026

The user adopted the faster hybrid after trying it in real typing and requested removal of the experimental switch. Native autocomplete now always selects selective one-word fallback, prefix-search healing, certified search and two generation/two prefill threads. Gemma 4 E2B Q6_K remains the default model. The normal **Enable autocomplete** control remains; this change does not enable autocomplete for users who disabled it.

`cotypingSelectiveOneWordHybrid` is removed from the app settings model, Codable keys, setting descriptors, UI, engine identity, model-check identity and suggestion-cache fingerprint. Old true/false JSON values are ignored and omitted on the next settings save. The no-longer-callable decoder-switch cleanup hook is removed. Native/HTTP routing and other settings retain their existing behavior. The HTTP fallback is unchanged.

The production factory has no decoder-mode argument. Explicit replay-only controls and baseline replay defaults remain available for historical experiments. Earlier documents describing an app rollback toggle refer to older builds; there is no such switch now.

## Validation of this change

- **280 non-UI XCTest cases passed, zero failures/skips.** Coverage includes legacy settings decoding/re-encoding, fixed production policy, model selection/routing, Unicode prefix healing and cold/warm native parity, request preparation, confidence, normalization, cache identities and coordinator lifecycle. The real E2B and pinned Qwen fixtures were present.
- The dedicated **LokalBot UI Test Host** and updated `CotypingSettingsUITests` compiled successfully with `build-for-testing`. No UI tests were executed locally or manually dispatched. The test checks that the main autocomplete toggle remains and the experimental toggle is absent after navigation.
- **176/176 measured installed outputs matched** the preceding signed fast-hybrid app: 144 fresh English/Serbian Latin checkpoints and 32 Unicode/edge checkpoints. The 16 warmup outputs also matched. Prompts, text, suppression, error/cancellation state and replay policy fields were compared exactly. Fresh coverage stayed 111/144 and edge coverage stayed 32/32.
- **Signed Release 0.10.3 (47) was reinstalled in place and relaunched** with `Scripts/reinstall-preserve-permissions.sh`. Bundle/team, designated requirement and entitlements matched the preceding app; strict signature verification passed, and the installed executable matched the signed export. E2B, native runtime and the main autocomplete setting remained selected. No test storage override was present.
- Strict SwiftLint, local Markdown-link checks and `git diff --check` passed. XcodeGen left tracked project configuration and dependency pins unchanged. No release, notarization submission, merge, CI configuration change or manual workflow action was performed. The PR remains draft.

An initial attempted replacement for the deleted decoder-switch lifecycle test asserted that the main enable/disable path also cleared a decoder-specific fingerprint. That is not the main control's existing contract. The inappropriate replacement was removed together with the obsolete switch test and deleted hook; existing enable/disable coverage was retained. The final 280-case run passed.

This is integration and installation verification, not a new quality or speed benchmark. The replay explicitly selects the same fixed policy asserted for the production factory by XCTest; it does not automate UI typing. No new Claude judgment was needed because all compared suggestions were identical. Identity continuity is verified; this is not a fresh audit of macOS permission grants.

## Receipts and reproduction

- [Test receipt](test-receipt.json) and [test summary](test-summary.txt).
- [Installation receipt](install-receipt.json), including executable/model hashes and signing continuity.
- [Output parity receipt](parity.json) and [runner](verify_parity.py).
- [Source manifest](source-sha256.json): hashes of app, unit/UI test sources and build configuration, based on parent `5c4b26c2b4b7c25a01de3b9efa680f067ec6420c`. These hashes match the files used for the test and installed builds.
- [Synthetic replay evidence](evidence.tar.gz) and its [manifest](evidence-manifest.json): fixed inputs, prior/current raw outputs, per-run receipts and process logs. No model weights, app binaries, screenshots or private typing are included.

Installed executable SHA-256: `322e74f16ffe42bc77cd60f3a56aeae2e0a1ca05ad0ba78d579f465bf6160379`.
E2B SHA-256: `20f49b221691c71d955e1d5a840b6e26329db4a5e1626f702fa4226e80a9c629`.

Run the standalone parity checker with `uv run --no-project python verify_parity.py --app /Applications/LokalBot.app --model /path/to/gemma-4-E2B.i1-Q6_K.gguf --reference /path/to/preceding-install/parity --output /path/to/new-output`. The reference directory is the preceding [fast-default evidence archive](../2026-10-11-fast-default/VALIDATION.md), with its original `fresh/` and `edges/` inputs, raw outputs and receipts. The runner rejects mismatched reference/model hashes and compares immutable observations.

## Changed test expectations

- `CotypingSettingsTests`: saved hybrid true/false no longer round-trip; both are ignored, omitted on save, and preserve other preferences and E2B selection.
- `LocalLlamaHealedGenerationTests`: the app factory always selects hybrid prefix search, certified search and two threads. Historical replay modes retain explicit comparison coverage.
- `CotypingEngineSelectorTests`: the retired flag no longer rebuilds an engine; changing model identity still invalidates suspended resolution.
- `CotypingSuggestionCacheFingerprintTests`: obsolete values no longer alter cache or model-check identity.
- `CotypingCoordinatorTests`: the decoder-switch-specific fixture is removed with its deleted hook; main autocomplete lifecycle tests remain.
- `CotypingSettingsUITests`: verifies absence of the experimental toggle and presence of the main control, replacing the obsolete opt-in/rollback UI expectation. Compiled, not locally executed.

## Earlier quality and latency evidence

The [11 October latency study](../2026-10-11-latency/REPORT.md) measured a 23.0% lower fresh native mean and 30.5% lower p95 for this policy on the M4 Max, with 1,496 paired non-cancelled outputs unchanged. The [10 October prefix-search study](../2026-10-10-prefix-search/REPORT.md) records the equal-frequency English/Serbian Latin model comparison and anonymous Claude judgments. Neither study is rerun or pooled with this installation check. First-visible UI latency and other hardware remain unmeasured; the previously documented long-prefill cancellation tradeoff remains.
