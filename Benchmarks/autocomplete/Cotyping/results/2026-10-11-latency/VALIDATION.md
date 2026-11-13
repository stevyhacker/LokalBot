**Validation — 11 October 2026 latency study**

- Release benchmark builds succeeded for both pinned source snapshots. The final binary adds independent batch threads and actual cancellation-issuance timestamps; the app default remains `baseline`.
- Final focused non-UI XCTest: **195 passed, zero failed, zero skipped**. Covers the original 14 cotyping test classes plus new prefix-index, replay-control and cold/warm Unicode parity checks. Native parity includes default threads, two/two and two/fourteen. The separate pinned Qwen 0.8B fixture was supplied, so all six formerly skipped native checks ran.
- **61 benchmark Python tests passed**. Full strict SwiftLint and `git diff --check` passed. App project configuration and dependency pins are unchanged; no XcodeGen update was needed.
- 75 complete replay receipts, 11,064 measured rows plus 600 warmups. Every receipt's input and raw-output SHA-256 was checked. No replay errors. Primary A/A and copied-installed controls each match all 288 prior saved outputs; follow-up binary parity matches all 144 fresh outputs per selected arm.
- The main fastest candidate matches 1,496/1,496 non-cancelled paired observations in phase one and another 728/728 in phase two. Repeats are included and are not independent quality examples. Split threads also match all 728 follow-up observations.
- All 216 cancellation/recovery checks and all 288 cold/prewarm pairs across both phases match their cold reference exactly. This establishes state recovery, not instantaneous abort or cancellation latency improvement.
- Claude quality: verified `claude-opus-5-5`, tools/MCP disabled, all 107 primary and 24 repeat cases validated. No future references, private writing or product source sent. 39/42 repeat utility ratings agree; no inconsistent preferred/utility responses.
- Installed executable and E2B model hashes remain unchanged from the frozen plan. The existing hybrid setting is still enabled and there is no stale selector-test storage override. This study **did not reinstall or release an app**.
- No local UI tests. No CI workflow was changed, manually dispatched or retried. PR remains experimental/draft.

The final XCTest invocation used Debug, `-parallel-testing-enabled NO`, the 14 cotyping `-only-testing` selectors, an isolated `TEST_RUNNER_LOKALBOT_STORAGE_ROOT`, and the pinned E2B path through `TEST_RUNNER_LOKALBOT_CANDIDATE_TEST_MODEL`. Release uses `CODE_SIGNING_ALLOWED=NO` for headless benchmark copies; this is not a signing or installation receipt.

**Reproduction**

Extract the raw archive into a separate directory. It contains frozen inputs and metadata, original raw JSONL/stderr/receipts, phase-specific source patches, binary/model hashes, run order, Claude packets/responses and analysis snapshots. Model weights and app bundles are not redistributed. Read the recorded phase source/pins before comparing timings.

The runner supports `--output`, `--scratch` and `--model`; choose new directories and copy the frozen `inputs/` and `plan.json` there. `pin --binary <Release app executable>` verifies the E2B hash and refuses to replace existing binary metadata. Run `current` and `certified_threads2` against `fresh`, using new round numbers; never overwrite a frozen or failed attempt. `split_batch14` sets two generation/fourteen batch threads. The source defaults still point at this dated study, so supply new paths for a rerun.

The output-identical optimizations are available only through replay fields: `searchExperiment` (`baseline`, `reuseRoot`, `memoized`, `certified`, `widthTwo`, `budgetEight`, `exactOnly`), `nativeThreads` and `nativeBatchThreads`. Scope, delays, cancellation and prewarm controls are native-only and validated. Normal app construction leaves all of these at their existing defaults. Quality judgments require separate explicit authorization to send synthetic fixtures externally.

No existing expected output was relaxed. Three focused tests were added, and the new Unicode parity test also exercises thread settings. Earlier PR-wide changed expectations remain documented in the PR description.
