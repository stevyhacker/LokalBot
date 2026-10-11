**Validation and reproduction — cancellation study, 11 October 2026**

Two unsigned Release benchmark builds succeeded. The final one adds replay-only adaptive prefill controls; neither changes the production factory. **282 relevant non-UI XCTest cases passed, zero failures/skips**, with E2B and pinned Qwen fixtures present. The new tests enforce native-only bounded replay controls, an unchanged production factory, and exact cold/warm outputs around 255/256/257/511/512/513-token chunk boundaries. No existing expected output was relaxed.

**Two Python analysis tests passed.** They check clustering of correlated repeats and ensure a faster cancellation cannot conceal a slower replacement; an undelivered timer is not credited. Full strict SwiftLint with caching disabled and diff checks passed. Documentation links and every archived member's hash were checked. Project configuration and dependency pins are unchanged; no source files were added/removed from the app targets.

The benchmark processes completed without replay errors. Every input/raw hash in the receipts was checked. Each phase's instrumented default matched all 56 outputs (48 measured + eight warmups) from the copied installed app, including prompt and suppression. This is output validation; the instrumented default is the timing comparator within each cohort. Source snapshots and binary hashes distinguish the two benchmark builds.

The installed executable remains `322e74f16ffe42bc77cd60f3a56aeae2e0a1ca05ad0ba78d579f465bf6160379`, corresponding to `1d39a5ea796d90ed391290ce260eb08370ab8c0b`. Its E2B model hash also remains unchanged. **No app was reinstalled or released in this study.** The experimental runtime controls are only available through explicit headless replay input; ordinary autocomplete keeps its existing policy. No local UI tests were run. No CI workflow was changed, dispatched or retried; the PR stays draft under the user's earlier instruction.

[Test receipt and exact commands](test-receipt.json) · [Filtered XCTest output](test-summary.txt) · [Source/binary hashes](source-file-sha256.json) · [Unchanged installation](unchanged-app-receipt.json)

The XCTest invocation used the eighteen selectors recorded in the receipt, Debug, `-parallel-testing-enabled NO`, `TEST_RUNNER_LOKALBOT_STORAGE_ROOT` pointing to isolated test storage, and `TEST_RUNNER_LOKALBOT_CANDIDATE_TEST_MODEL` pointing to the pinned E2B file. No UI-test selectors were selected. Release benchmarks used `CODE_SIGNING_ALLOWED=NO` and are not signing/installation artifacts.

**Recompute the analysis without model inference**

Extract the evidence archive to a new directory. It includes `fixed/` and `adaptive/` frozen runners, plans, inputs, synthetic corpus, metadata, raw outputs/stderr/receipts, source patches, run order and rejection decision. `claude-generic/` contains the generic advice and proof of what was supplied. `final-source/` and `validation/` identify the tested implementation. Models, app bundles, private preferences and personal typing are excluded.

```sh
mkdir -p /tmp/lokalbot-cancellation-evidence
tar -xzf Benchmarks/Cotyping/results/2026-10-11-cancellation/evidence.tar.gz \
  -C /tmp/lokalbot-cancellation-evidence
uv run --no-project python /tmp/lokalbot-cancellation-evidence/adaptive/cancellation_experiment.py \
  --root /tmp/lokalbot-cancellation-evidence/adaptive \
  analyze --phase confirmation --arm early192sync --rounds 1,2
```

This reproduces the confirmation statistics from saved observations. `decision.json` is authoritative for the rejection-only early stop; the frozen `confirm_selected.py` records that policy. Recomputing an analysis does not constitute a new benchmark.

**Run fresh model measurements**

Use the recorded source base plus the corresponding archived patch for historical reproduction; the final checked-in source supports all fourteen arms. Copy the selected phase's frozen `inputs/`, `case-meta.json`, `corpus.json` and `plan.json` into a new run directory. Do not invoke `prepare` over frozen evidence: it creates the original 5/20-ms corpus, while the adaptive inputs additionally include 60-ms events. Build a new Release app, then pin it in that directory:

```sh
uv run --no-project python Benchmarks/Cotyping/cancellation_experiment.py \
  --root /tmp/new-cancellation-run --model /path/to/pinned-E2B.gguf \
  pin --app /path/to/new/Release/LokalBot.app
uv run --no-project python Benchmarks/Cotyping/cancellation_experiment.py \
  --root /tmp/new-cancellation-run --model /path/to/pinned-E2B.gguf \
  confirm --arm early192sync
```

The generic `confirm` command runs all four counterbalanced rounds; the archived selected-run wrapper used the predeclared rejection-only early stop and contains dated local paths that must be updated for a fresh machine. `screen` also requires a separately copied/pinned `baseline.app` and `baseline.json` for the installed A/A check. The runner refuses to replace existing run directories. Never compare cohorts without matching their binary/input pins, and never run native measurements concurrently with builds or model tests. Native timings do not establish visible UI latency.
