# PR #230 integration and installed-app validation

Verified on 2026-10-10. App implementation commit: `5bba13184c51039204660d1e38b0de8ec52885eb`. Later commits add reports/evidence only. The generated Xcode project and dependency pins have no tracked changes.

## Result

Gemma 4 E2B Q6_K (`gemma4-e2b-base-q6`) remains the catalog default and the installed selection. The installed app has autocomplete, the in-process runtime and **Experimental hybrid suggestions** enabled. Turning the existing switch off restores both the ordinary confidence gate and the previous midword decoder. The setting stays off by default for users who have not opted in.

The signed Release app was installed **in place** at `/Applications/LokalBot.app` with `Scripts/reinstall-preserve-permissions.sh --no-relaunch`, validated, then relaunched from that path. Bundle identifier `me.dotenv.LokalBot`, team `3N8B4562P4`, designated requirement and entitlements match the pre-install app. Strict deep signature verification passed. Its executable hash matches the exported build:

`ef6783c6e24a1d42f10ff76a353670c9e418132ddc33b73c2cd20d76baeb7b37`

Version 0.10.3, build 47. This is a local trial, not a release or a notarization submission. Identity was preserved without resetting TCC; individual capture permissions were not re-exercised. [Installation receipt](installation.json) · [Source manifest](source-manifest.json).

The manual Settings inspection showed **Model ready**, **Accessibility granted**, **Input Monitoring granted**, E2B selected and the experimental switch on. It initially exposed a stale `lokalbot.uiTest.storageRoot` pointing to a temporary selector-test folder. That single key was backed up and removed, restoring the existing library and downloaded model; no library content or other preferences were changed. The corrected selector fixture uses explicit storage injection and no longer writes this key. [Repair receipt](storage-override-repair.json).

## Tests

- Focused non-UI XCTest: **186 passed, 0 failed, 6 skipped** (192 total). The six skipped cases require a separate Qwen 0.8B fixture. Native E2B prefix selection, long-context rewind/cold-score parity, prewarming, streaming, settings and engine routing tests ran.
- Python benchmark tooling: **61 passed**.
- Full strict SwiftLint: passed. `git diff --check`: passed.
- The initial routing fixture failure was repaired by direct temporary storage-root injection. The native composition test now fixes the healing policy independently for both gate comparisons; no exact output or streaming assertion was removed.
- The archived source study includes the failing native Serbian regression with prefix search disabled; the integrated check passes.
- No local UI tests. No CI configuration changes, workflow dispatches or retries. Old-head PR checks are not evidence for this update.

## Installed binary versus the frozen study

The installed executable replayed all four frozen arms: E2B control/fixed and Luchador control/fixed. Each arm includes **288 measured requests plus eight warmups**, with exactly **250 shown suggestions**. Compared fields are case ID, prompt bytes, final text, suppression and error. All **1,152 measured requests** and 32 warmups match the original study exactly. Model hashes and input/output hashes are in the raw receipts.

This is integration parity, not another quality sample, latency benchmark or fresh judge call. It establishes that the installed build produces the same evaluated outputs under those explicit study controls. The [existing anonymous Claude judgments and latency rounds](../2026-10-10-prefix-search/REPORT.md) therefore remain applicable to those outputs. The app still uses its ordinary production cutoffs (0.1/0.31); study frequency-matching cutoffs were not installed.

## Rollback parity

With `selectiveOneWordHybrid=false`, no explicit healing override and ordinary confidence defaults, the installed build and a saved copy of the previous installed app produced **zero differences** across **288 measured requests plus eight warmups**. This comparison includes prompts, text and suppression. [Parity summary](parity-summary.json).

## Evidence

[Integration evidence archive](integration-evidence.tar.gz) includes replay inputs/outputs, receipts, comparison results, the parity runner, test logs and signing/build logs. [SHA-256 manifest](integration-manifest.json). The separate [complete historical experiment record](../2026-10-10-experiments.md) includes unsuccessful variants and original Claude responses.
