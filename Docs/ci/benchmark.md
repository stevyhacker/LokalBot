# CI compilation-cache and parallel UI validation benchmark

The benchmark uses macOS 15 hosted ARM64 runners and Xcode 26.3. Every invocation
runs `build-for-testing` with a fresh DerivedData directory; only the compiler's
content-addressed store is reusable. Native Vendor and Swift package caches are
separate and their state must be reported with each sample.

## Reproduction

Dispatch **Build** and **UI Tests** on an isolated branch with `candidate_sha` set
to its exact HEAD. `cache_mode=warm` restores compatible compiler data;
`cache_mode=cold` starts with an empty compiler store; `cache_mode=off` disables
compilation caching entirely. Do not overlap dispatches on the same branch:
superseded-run cancellation remains enabled. Save each attempt before rerunning:

```sh
uv run --no-project python Scripts/ci/ci-timings.py RUN_ID --attempt 1 --output /tmp/run.json
```

Use `--evidence /path/to/source.json` (or a UI phase report) to record the actual
checkout SHA. A PR head SHA is distinct from GitHub's tested merge commit; without
evidence the collector leaves the PR checkout SHA unknown.

The snapshot records queue delay from dependency completion, every step's elapsed
time, wall time, macOS occupied minutes and the sum of rounded job minutes. The
latter is an estimate, not an invoice or a paid-runner multiplier. Download the
`compiler-build` artifact for compiler diagnostics, input fingerprints and
`compile.json`. Compare three warm attempts, one empty-store attempt, a disabled
baseline, and a small committed Swift edit. Preserve the same dependency pins,
configuration, toolchain and app inputs for timing comparisons. Source changes
need separate samples rather than being counted as comparable warm runs.

## Cache and correctness boundaries

Apple documents [compilation caching](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes)
and the [enable and diagnostic build settings](https://developer.apple.com/documentation/xcode/build-settings-reference).
The pinned compiler must demonstrate actual cache-hit remarks. A GitHub cache
restore alone is not compiler-hit evidence. No DerivedData or compiled-test
product is a cross-run cache.

Each cache is partitioned by Xcode/Swift/SDK build, architecture, Debug
configuration, signing setting, XcodeGen version, authoritative `project.yml`
project/scheme settings, dependency pins and CI build settings. Generated PBX
object IDs are intentionally excluded: XcodeGen can reorder equivalent copy
phases across fresh generations. Their raw hash is retained as diagnostic evidence. A source-content suffix permits compatible reuse after edits.
The cache manifest checks every stored file and rejects symlinks, incompatible
settings, tampering, empty stores, and stores larger than 2 GiB. Failed cached
compilation retries once from clean products with caching disabled. A failed
fallback cannot produce a UI reuse stamp or product artifact. Cache restore/save steps have a three-minute bound. Transfer failures
leave source compilation available; cache saves occur only after a successful
cached build. Cache scope follows [GitHub's branch and PR restrictions](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching);
no elevated cache token, `pull_request_target`, or cross-run product restore is used.

All seven UI phases consume the same commit/run/attempt/toolchain/digest-verified
archive. Reduce Motion owns a separate runner. The existing critical check name,
98-test inventory, 78 expected matrix captures (13 routes, two appearances, three
sizes), audio recovery probe, exact-SHA dispatch and publication checks remain.
Focused and legacy-comparison invocations retain a distinct final check name.
Missing, skipped, failed, stale or incomplete phases fail the full-suite gate.

Earlier fan-out runs the other phases even if critical interactions fail. This
reduces latency when capacity is available but can spend additional runner
minutes on failed candidates. Runner queue delay must be included in the result.

## Measurements

Pending hosted benchmarks. Historical runs at
`9ff70b7ca4a9616658115d4bacc43c4c4ffa8f18` failed before the UI matrix and are
partial evidence only, not a successful full-suite baseline. The proposed
9–12 minute warm build-plus-critical target is an estimate to evaluate.
