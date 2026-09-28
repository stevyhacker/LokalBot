# CI compilation cache and parallel UI validation

Measured on 2026-09-28 using GitHub-hosted macOS 15 ARM64 runners and Xcode 26.3.
Across three unchanged-source warm attempts per workflow, median compilation was
**2m11s for Build** and **2m24s for UI Tests**.
Every warm attempt reused all cacheable tasks. Full UI validation remains red:
the original workflow and the candidate fail the same test cases and capture checks.

## Measured results

[Machine-readable evidence](measurements.json) preserves exact commits, source
fingerprints, compiler identities, task hits, job queues, phase durations, product
digests and test outcomes. Each row links to its exact workflow attempt.

The warm benchmark commit is `ddc5cb5b50fee32d4d7458aed0fced89b41d0a66`.
The original graph ran at master `769068eab523eb158d74c4657d29934287a336bf`;
app, CLI and Swift test sources, project settings and dependency pins are identical between
those revisions. Native and package dependencies were warm for the primary
comparisons. The empty-store samples were first `warm` dispatches with absent
compiler keys and zero hits, which seeded the subsequent warm attempts.

“Compile” uses the compiler process timer. The original UI workflow predates that
timer, so its value is the enclosing build step, including display preparation.
Wall time starts at dispatch/rerun and includes queues. “Build + critical” ends
when the existing critical check completes; the original check also contained
Reduce Motion and product upload. macOS minutes sum occupied job time, including
downloads; they are neither wall time nor billing multipliers. The JSON also
includes per-job rounded minute estimates. Phase totals sum concurrent jobs.

### Build

| Sample | Compile | CAS hits | Workflow wall | Build + critical | macOS minutes | Longest queue |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| [build-empty-store](https://github.com/stevyhacker/LokalBot/actions/runs/36440912991/attempts/1) | 10m01s | 0/636 | 19m15s | — | 17.75 | 1m16s |
| [build-warm-1](https://github.com/stevyhacker/LokalBot/actions/runs/36440912991/attempts/2) | 2m41s | 636/636 | 13m40s | — | 11.30 | 2m08s |
| [build-warm-2](https://github.com/stevyhacker/LokalBot/actions/runs/36440912991/attempts/3) | 1m59s | 636/636 | 10m39s | — | 8.23 | 2m17s |
| [build-warm-3](https://github.com/stevyhacker/LokalBot/actions/runs/36440912991/attempts/4) | 2m11s | 636/636 | 8m28s | — | 8.12 | 0m13s |
| [build-small-edit](https://github.com/stevyhacker/LokalBot/actions/runs/36449054857/attempts/1) | 5m57s | 608/636 | 16m45s | — | 13.92 | 2m43s |
| [build-cache-disabled](https://github.com/stevyhacker/LokalBot/actions/runs/36455010030/attempts/1) | 6m57s | off | 11m53s | — | 11.58 | 0m12s |
| **Warm median** | **2m11s** | — | **10m39s** | **—** | **8.23** | — |

### UI Tests

| Sample | Compile | CAS hits | Workflow wall | Build + critical | macOS minutes | Longest queue |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| [before-ui-warm-dependencies](https://github.com/stevyhacker/LokalBot/actions/runs/36449497190/attempts/1) | 6m49s | — | 34m57s | 19m46s | 54.20 | 4m18s |
| [ui-empty-store](https://github.com/stevyhacker/LokalBot/actions/runs/36440908228/attempts/1) | 8m35s | 0/629 | 29m48s | 22m18s | 67.37 | 6m38s |
| [ui-warm-1](https://github.com/stevyhacker/LokalBot/actions/runs/36440908228/attempts/2) | 2m31s | 629/629 | 22m01s | 14m49s | 55.03 | 3m31s |
| [ui-warm-2](https://github.com/stevyhacker/LokalBot/actions/runs/36440908228/attempts/3) | 1m57s | 629/629 | 22m51s | 13m47s | 54.90 | 4m08s |
| [ui-warm-3](https://github.com/stevyhacker/LokalBot/actions/runs/36440908228/attempts/4) | 2m24s | 629/629 | 28m22s | 16m13s | 55.20 | 12m00s |
| **Warm median** | **2m24s** | — | **22m51s** | **14m49s** | **55.03** | — |

The cache-disabled Build control compiled in
6m57s; warm compilation had a
2m11s median. Its full workflow took
11m53s, compared with the 10m39s
warm median. The original UI graph took 34m57s, compared
with the 22m51s candidate warm median. Original UI
macOS usage was 54.20 minutes, versus a
55.03-minute warm median. Aggregate UI runner
usage is slightly higher in these measurements despite the shorter turnaround.

These are shared-runner observations, not an isolated capacity guarantee. Runs
from both workflows overlapped, including the original-graph comparison; no other
workflows were cancelled or account capacity changed. The longest UI consumer
queues ranged from 3m31s to 12m00s across warm
attempts. Compare job durations and queues alongside wall time.

## Cache benefit, cost and source invalidation

Warm cache identification, restoration, validation and compiler-evidence upload
took 13.35–28.49 seconds per producer, well below the
observed compilation savings. Exact cache hits skip sealing and saving. Initial
stores held about 1.17 GB for UI and 1.25 GB for unit builds, below the 2 GiB bound.
The empty-store path is slower than a populated cache and includes first-save
costs; it is not evidence of a warm speedup.

Test-product transfer remains significant. A UI archive was approximately
699 MB, downloaded by seven consumers instead of five. This adds
two downloads (about 1.40 GB) per complete run. Warm UI
artifact-transfer steps totaled 5m53s–6m49s
across jobs; that sum overlaps in wall time. Earlier fan-out also spends runner
minutes on the matrix when critical tests fail. The complete gate still fails.

The small-edit experiment at `b4aa7eedb78b136b1a702bffb0b8c4fc20cdb1ba` changed an
existing `CountLabel` implementation equivalently and added an assertion diagnostic
to its existing unit test. Both workflows restored the same compatibility identity
as their warm runs while the source fingerprint changed. Build reused
608/636 tasks and
compiled in 5m57s; UI reused
611/629 tasks and
compiled in 3m47s. Its products then passed the
existing `RedesignUITests/testHighContrastKeepsActionsAccessible` smoke test and
the distinct focused-run gate. This source-invalidation check builds all UI targets
but is not a fourth full-suite warm sample or a full-suite wall-time comparison.
A high hit count does not imply
the unchanged-source compile time: the rebuilt tasks have different costs.

The hosted unit-test Mach-O contained `CI_CACHE_EDIT_PROBE_2026_09_28`. Its archive
digest and exact commit/run/attempt identity were verified by reading ZIP/tar
bytes, without extracting or launching the app. Both temporary Swift edits were
restored before the final PR. The final quoting fix for dispatch choices changes
the conservative cache key, so its first cached run seeds a new store; compiler
and sharding behavior are unchanged from the frozen warm benchmark.

## Correctness and limits

Every Build sample reports 2,499 tests, 22 existing skips and zero failures, plus
successful SIGKILL audio recovery (68,096 frames). All full-suite UI samples execute the same
98-test inventory and produce 78 PNGs. Critical interactions (16 tests), Reduce
Motion, and the 1440×900 visual phase pass. Ten functional cases and the 1000×700
and 1180×740 visual phases fail in both original and candidate workflows. Eight
1000×700 captures are actually 1000×704; only 70 of 78 have the requested dimensions.
Exact failing case names and capture filenames are retained in the JSON. No UI
assertion, selected test, capture requirement or publication check was relaxed.

The proposed 9–12 minute warm build-plus-critical target is **not established**:
the observed median is 14m49s.
There is no successful full-suite timing for these app inputs. Existing UI test
and capture failures must be resolved before a green full-suite result or release
readiness can be claimed. Further latency work should address product transfer,
critical-test duration and runner availability using separate measurements.

Earlier master runs with cold native dependencies are retained as context in the
JSON, not used as wall-time controls. Historical
[Build](https://github.com/stevyhacker/LokalBot/actions/runs/36421369713) and
[UI](https://github.com/stevyhacker/LokalBot/actions/runs/36421369758) runs also
failed; the latter stopped before the matrix and is not a full-suite baseline.

## Reproduction and safeguards

Dispatch **Build** or **UI Tests** on a pushed branch with `candidate_sha` set to
its exact HEAD. Use `cache_mode=warm` to restore compatible compiler data,
`cache_mode=cold` to start empty without saving, or `cache_mode=off` to disable
compiler caching. Do not overlap dispatches of the same workflow/ref: superseded
run cancellation remains enabled. Rerun the whole workflow so producers and
consumers share the same attempt. Save evidence before a rerun replaces artifacts:

```sh
uv run --no-project python Scripts/ci/ci-timings.py RUN_ID --attempt 1 \
  --evidence /path/to/source.json --output /tmp/run.json
```

Download `compiler-build` for `source.json`, compiler diagnostics and `compile.json`;
save phase artifacts and job logs for complete-suite comparisons. The collector
accepts a UI phase report as provenance too. A PR head differs from the tested
merge commit; without bound evidence, its actual checkout is left unknown.

Every CI producer runs `build-for-testing` with fresh DerivedData. Only the
compiler's content-addressed store is reusable; compiled products and reuse stamps
are never a cross-run cache. Identity includes actual Xcode/Swift/SDK builds,
architecture, Debug configuration, signing, XcodeGen version, authoritative
`project.yml`, dependency pins and build scripts/workflows. Source content forms
the suffix. Generated PBX object IDs are excluded because identical XcodeGen
inputs produced five raw project variants in ten local generation-only checks; all ten
produced one compatibility key. Hosted warm reuse also succeeded after a PBX hash
change. Raw generated-project hashes remain diagnostic evidence.

SHA-256 manifests reject incompatible, tampered, empty, oversized or symlinked
compiler stores. Cached-build failure retries once from clean products with
caching disabled; a failed fallback cannot publish test products or a reuse stamp.
Restore/save steps are optional and bounded to three minutes. Successful warm
builds alone save caches. Scope follows
[GitHub's branch and PR cache restrictions](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching).
The feature uses Apple's documented
[compilation caching](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes)
and [build settings](https://developer.apple.com/documentation/xcode/build-settings-reference).

All seven UI consumers verify the same commit/run/attempt/toolchain/digest-bound
archive. Reduce Motion owns a separate runner. The critical check name, complete
coverage checks, audio probe, exact-SHA dispatch and publication gates remain.
Focused and legacy comparisons use their distinct final check name; missing,
failed, cancelled, skipped, stale or incomplete full-suite phases cannot pass.
Local validation covers 66 non-UI helper tests; UI execution stays on hosted Macs.
