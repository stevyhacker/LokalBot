# Faster CI and releases

Rollout plan based on the successful 0.8.0 candidate `8f39eb213e528b80005531e374040f0c35b1a433` and its hosted runs on 7 September 2026.

PR #65 implements all four phases: atomic metadata preflight, pinned Xcode, shared production/unit and UI build products, disjoint smoke and parallel UI shards, Swift package caching, trusted archive preparation/reuse, and capture readiness with a retained legacy comparison mode. Hosted validation and timing evidence are recorded below; the time targets remain hypotheses until the required measurements are complete.

## Objective

Bring a first-attempt release from approximately 57 minutes to a measured target of 25–35 minutes, and expose compilation or focused regression failures within 6–10 minutes. These are targets to validate, not promised savings. Preserve full release coverage, exact-commit provenance, signed/notarized distribution, and independent public-download verification. All UI automation remains hosted.

## Measured baseline

| Stage | Observed time | Evidence |
| --- | ---: | --- |
| Complete hosted UI workflow | 41.1 min | [UI run](https://github.com/stevyhacker/lokalbot/actions/runs/34118306359) |
| Initial UI compilation plus accessibility check | 6.0 min | Same run, first test step |
| Focused critical interactions | 5.3 min | Same run, six script invocations |
| Dedicated Reduce Motion check | 0.95 min | Same run |
| Full UI step | 28.5 min | Same run; 65 tests, one skipped, no failures |
| Visual matrix alone, within the full suite | 13.1 min | `testWorkspaceVisualMatrix`, 786.613 seconds |
| Unit workflow, including compilation | 7.1 min | [Unit run](https://github.com/stevyhacker/lokalbot/actions/runs/34118306328) |
| Release workflow after validation | 16.2 min | [Release run](https://github.com/stevyhacker/lokalbot/actions/runs/34122053715) |
| Release archive compilation | 13.5 min | Same release run, 808 seconds |
| App and DMG notarization/stapling combined | 95 seconds | Same release run, 49 + 46 seconds |

The successful path is roughly 41 + 16 minutes because release compilation starts only after validation. The much longer overall 0.8.0 session also included failed candidates and repeated validation. Apple notarization is not the main bottleneck.

Source observations:

- `Scripts/test/ui-tests.sh` calls `build-for-testing` every time, including nine invocations in the successful UI workflow. Later calls can be incremental, so they are overhead, not nine cold builds.
- Focused tests run again in the full suite. Reduce Motion has a separate environment and must retain its dedicated run.
- Build and Tests independently compile the production target on separate runners; the UI host is a distinct target and cannot substitute for production compilation.
- Only `Vendor` is explicitly cached in these workflows. Swift packages and compiled test products are not explicitly shared across jobs.
- The visual matrix serially launches 72 cases: 12 routes × three sizes × two appearances. Each capture schedules an eight-second delay and a further one-second compositing delay in `AppLifecycle.swift`.
- The workflows select `latest-stable` Xcode, so the actual compiler is not pinned despite the Build workflow's comment.

## 1. Make failures cheap and preparation atomic

Files: `Scripts/test/ui-tests.sh`, CI workflow definitions, `RELEASING.md`, and a new release-preflight script.

- Finalize version, build number, release notes, and their validation in one candidate commit before pushing. Check both version sources, the changelog base, tag availability, and the staged file list.
- Pin the same explicit Xcode version across validation and release jobs; record Xcode build number, SDK, runner image, architecture, and dependency lock hash in artifacts.
- Compile the production/unit-test and UI-test targets in preflight. A successful app-only build must not conceal a test compilation error.
- Run a declared smoke group plus regressions relevant to changed features before expensive captures. The waveform regression already runs early as of 0.8.0.
- Fail the smoke stage promptly, while retaining logs and result bundles. Do not continue through long visual captures after a compile or functional failure.
- Publish step durations and test failures in the job summary. Report meaningful stage changes and failures to the user instead of repeating unchanged minute-by-minute status messages where the interaction environment permits.

Acceptance: an intentional test compilation error and a failing waveform assertion both prevent the long suite from starting. Version/note errors fail before a candidate is pushed. Normal successful releases require no follow-up metadata correction.

## 2. Compile test bundles once and run independent UI work in parallel

Files: `Scripts/test/ui-tests.sh`, `project.yml`, `.github/workflows/build.yml`, `tests.yml`, and `ui-tests.yml`.

- Give the test script explicit build-only and run-existing-build modes, multiple include/exclude filters, and distinct result paths.
- Compile the production app plus unit tests once, then execute unit tests without rebuilding. Keep Build and Tests independently visible as gate results.
- Compile the UI host plus UI tests once. Store the complete test products and `.xctestrun` configuration as an artifact tied to the exact SHA and toolchain.
- Run functional UI tests and the visual matrix in separate jobs after smoke passes. Start with two functional shards and three visual shards, balanced from measured test durations.
- Give each shard a separate hosted runner/session. Running multiple XCUITest workers against one desktop risks competing for focus and input.
- Make the visual matrix filterable by size/appearance or route. Initially preserve every one of the 72 cases and the current capture timing.
- Avoid rerunning successful smoke cases in the functional remainder. Keep the distinct Reduce Motion configuration covered. An aggregate gate must verify that the union covers the complete required test inventory and all 72 captures.
- Verify artifact portability on a clean runner, including absolute paths in `.xctestrun`, executable permissions, and bundled native libraries. Reject mismatched SHA/toolchain artifacts; never fall back silently to a different candidate's binaries.
- Add Swift package caching keyed by toolchain and lockfile. Treat broader incremental build caching as a measured experiment; within-candidate artifact reuse is the first implementation.

Acceptance: all existing functional tests and 72 correctly sized captures remain accounted for; a missing or failed shard fails the aggregate UI gate. Benchmark artifact transfer, queue time, wall time, and total runner minutes before increasing concurrency. More shards may reduce elapsed time while increasing cost.

## 3. Overlap archive preparation with validation, gate publication

Files: `.github/workflows/release.yml`, a candidate orchestration workflow/script, and `RELEASING.md`.

- For an explicitly selected, trusted release candidate, start the signed Release archive after preflight succeeds while the remaining hosted suites run.
- Keep preparation separate from publication. The archive may finish early; tag creation, notarization/publication sequencing, and asset upload must still obey the release gates. Start with notarization after all gates pass.
- Keep signing credentials confined to the trusted candidate workflow. Ordinary PR jobs cannot invoke the signing stage or supply replacement artifacts.
- Bind the prepared archive to its commit, source tree, version/build, toolchain, workflow run, and artifact digest. A changed candidate invalidates it.
- Once all five gate results pass on that exact commit, create the matching tag and consume the prepared archive instead of recompiling it. Retain a cold-build fallback when no verified archive exists.
- Preserve the existing final-byte ordering: app signing/notarization/stapling, DMG creation/signing/notarization/stapling, then Sparkle signing. Re-run independent public-download checks after publication.

Acceptance: a failed or superseded candidate cannot create a release; a mismatched artifact is rejected; successful publication does not launch another archive build. Account for wasted archive minutes on candidates that later fail.

## 4. Optimize capture waits only after the pipeline is stable

Files: `LokalBot/AppLifecycle.swift`, `LokalBotUITests/RedesignUITests.swift`, and the UI harness.

Replace the fixed startup wait with explicit readiness for route selection, data, window geometry, and asynchronous content, followed by a bounded material/compositing settle period. Preserve atomic PNG publication and a clear timeout failure. Do not simply reduce the eight-second constant: the current code documents previous activation and vibrancy failures.

Acceptance: compare the complete 72-image output against the existing path on hosted runners, including correct dimensions, populated content, selection state, and light/dark materials. Retain the old path until the replacement is reliable. This is additional upside, not a prerequisite for the initial speed target.

## Rollout and measurement

The four phases are implemented together in PR #65; measure them independently where possible. Measure the same representative source revision before and after, using at least three warm-cache runs and one cold-cache run. Record queue time separately from execution time, time to first actionable failure, total runner minutes, cache hit/transfer costs, and retries. Validate artifact rejection and gate failures using deliberately failing fixtures.

Initial targets: actionable failures in 6–10 minutes; complete candidate validation in 15–25 minutes; first-attempt public release and verification in 25–35 minutes once archive overlap is enabled. Do not claim success from averages alone: keep per-stage timings and failure/skip counts visible.

Preserve the tag-triggered cold release route during rollout. Disable artifact reuse or parallel scheduling independently if needed. Do not weaken release coverage or use local UI automation to meet a timing target.

## Implemented controls and operation

- `build.yml` now owns the separately visible **xcodebuild (macOS)** and **xcodebuild test (macOS)** jobs. `tests.yml` is retired. Only the build job compiles; the test job verifies and consumes its complete test products.
- UI builds once, runs 10 critical tests plus Reduce Motion, then starts two functional shards and three size-based visual shards. The functional split uses durations from baseline run `34118306359` (`Scripts/ci/ui-durations.json`); unknown new tests default to 30 seconds.
- `ui-shards.py` inventories parameterless XCTest methods, rejects unsupported test declarations, and verifies actual `.xcresult` leaf results against each shard. The aggregate requires all 65 current tests, no unexpected skips or duplicates, and all 72 exported PNGs with correct dimensions. Each visual method executes once per size.
- Portable tar artifacts carry the complete Products directory, including executable permissions, native libraries and `.xctestrun`. Consumers validate commit, lock, architecture, Xcode, signing mode, workflow run/attempt and SHA-256 before relocation. UI consumers never regenerate the project or rebuild.
- `Scripts/release/prepare-release.sh VERSION` explicitly dispatches signed archive preparation on the current pushed `master` candidate. It can run while push validation is active. It does not tag, notarize or publish. The tag route verifies all five gate jobs from exact-SHA trusted master push workflows, rejects superseded candidates, then consumes a verified prepared app or cold-builds if none exists. Corrupt/mismatched artifacts fail rather than falling back.
- Capture readiness waits for populated route-specific accessibility content and requested window dimensions, then acknowledges an in-process capture. Meeting selection is reapplied while waiting; the existing one-second activation/material settle is preserved. A bounded timeout fails without publishing a PNG. `capture_mode=legacy` retains the original eight-second timer for hosted comparison; comparison and filtered workflows use a separate check name and cannot satisfy the aggregate release gate.
- Keep the five check names in branch protection. Their Build/Tests workflow grouping changed; repository protection settings are not changed by this PR.

Validation: 29 local control-flow tests, Swift UI-test source type-checking, and workflow/static checks pass. Hosted unit execution has exercised cross-runner reuse with 1,881 cases, 13 skips and zero failures. A complete 72-image readiness/legacy comparison found 62 pixel-identical images; the other ten differed only in displayed timestamps. The legacy matrix took 793.92 seconds. See [PR #65](https://github.com/stevyhacker/lokalbot/pull/65) for the latest exact-head gate results and workflow timing evidence.

Real signing, notarization and publication are not triggered by this implementation PR. Three warm-cache runs, one cold-cache run and a real candidate release remain measurement work; no end-to-end release speed target is claimed yet.
