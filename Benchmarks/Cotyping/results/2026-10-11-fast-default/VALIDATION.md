**Faster E2B default — activation and installation, 11 October 2026**

**Historical stage:** this records the initial default-on rollout. The subsequent [always-enabled integration](../2026-10-11-always-hybrid/VALIDATION.md) removes the toggle and ignores old saved off choices; the measurements and receipts below remain unchanged.
At the user's request, the fastest confirmed candidate is now the app's default experimental hybrid: `certified` prefix search, two generation threads and two prefill threads. Gemma 4 E2B Q6_K remains selected and remains the catalog default. Model weights, prompt, sampler, confidence gates (0.1/0.31), four-path search width and 32-expansion budget are unchanged.

The hybrid preference defaults on for new settings and missing keys. An explicitly saved false is preserved. Autocomplete itself remains opt-in. **Settings → Writing → Autocomplete → Experimental hybrid suggestions** turns off the hybrid confidence fallback and prefix-search path, restores baseline search and the old automatic thread policy, cancels pending work and invalidates cached suggestions. No restart is required.

The production factory is separate from replay defaults: historical headless fixtures still default to baseline. XCTest checks the exact production factory's enabled/disabled configuration and exercises that factory against cold/warm native Unicode outputs. Signed-app replay uses explicit controls matching that factory; it does not test the event tap or overlay.

**Installation**

Built, signed, installed in place and relaunched via `CONFIGURATION=Release Scripts/reinstall-preserve-permissions.sh`. The installed app is `/Applications/LokalBot.app`, version 0.10.3 (47). Bundle `me.dotenv.LokalBot`, team `3N8B4562P4`, designated requirement and entitlements match the previous installed app. Strict deep signature verification passed; the installed executable equals the signed export. This verifies identity continuity, not a fresh audit of macOS permission grants. No release or notarization submission was performed.

Saved settings after relaunch: autocomplete on, in-process runtime on, hybrid on, model `gemma4-e2b-base-q6`. No test storage override is present. The existing model file still matches its pinned SHA-256.

- Installed/exported executable: `f4cfd2a81c9aaac0a7763a10f00e72fdc831c4c83371b46c719fdeab0a0b2a5e`
- Previous installed executable: `ef6783c6e24a1d42f10ff76a353670c9e418132ddc33b73c2cd20d76baeb7b37`
- E2B model: `20f49b221691c71d955e1d5a840b6e26329db4a5e1626f702fa4226e80a9c629`

See the [installation receipt](install-receipt.json) and [source hashes](source-sha256.json). The source patch is included in the evidence archive; the final commit contains exactly these app/test bytes.

**Validation**

- **198 non-UI XCTest cases passed, zero failures/skips**: the 195-case focused autocomplete suite plus three cache-fingerprint cases. Native E2B and pinned Qwen fixtures were available. The cache and selector fixtures now explicitly begin with the hybrid off so their off→on checks remain meaningful.
- Strict SwiftLint and `git diff --check` passed. XcodeGen regeneration produced no tracked project or dependency changes. No local UI tests or manual CI dispatch/retry.
- **728/728 comparable completed outputs match the frozen faster candidate**, including prompt bytes, normalized suggestion, suppression and error state. Eight warmups per run are excluded from these totals.
- **288/288 rollback outputs match the previous installed app** under the same replay input. Both rollback arms show 225/288 suggestions. The regression fixture retains its dated evaluation threshold overrides; the app's thresholds were not calibrated or changed.

| Candidate workload | Comparable outputs | Mismatches |
|---|---:|---:|
| Prior regression set | 288 | 0 |
| Fresh English + Serbian Latin | 144 | 0 |
| Typing/backspace/recovery | 192 | 0 |
| Long fields and prewarm | 48 | 0 |
| Unicode/digraph/code-switch edges | 32 | 0 |
| Cancellation recovery/cold references | 24 | 0 |

Fresh suggestion frequency remains **111/144**; regression frequency remains **250/288**. This is installation parity, not a new independent quality or latency study. Claude was not re-asked to rate identical suggestions.

**Cancellation timing edge**

The initial comparator assumed all 24 timer-driven cancellation attempts must remain cancelled. In this install check, 23 did; one 130 ms cancellation timer did not execute before the generation finished at 134.1 ms (`cancellationRequestedAfterMs` is null). That extra completed suggestion and its recovery match both its installed and frozen cold references. It is excluded from the 728 paired count and is not counted as a successful cancellation.

The original failure receipt, raw observations and log are preserved. Reanalysis accepts this case only when no cancellation was issued and both cold references match exactly; it revalidates the original input/output/binary hashes and does not rerun or overwrite observations. All other output and cancellation checks retain their original assertions. See [parity summary](parity.json).

**Expected benefit and limitations**

The earlier controlled study measured mean **67.0→51.6 ms** and p95 **142.4→98.9 ms**, with identical suggestions, on this M4 Max. The user selected its fastest normal-generation configuration. The separate long-prefill cancellation follow-up was slower to return with two/two threads (95.6 vs 80.8 ms); the independent contribution of the skip proof, other hardware, and first-visible UI latency remain unestablished. These historical figures are not remeasured or relabeled by the installation checks. [Full latency study](../2026-10-11-latency/REPORT.md).

**Reproduction and evidence**

[Verified archive](../2026-10-11-fast-default.tar.gz) · [SHA-256 manifest](../2026-10-11-fast-default-manifest.json) · [verification runner](verify_install.py) · [test receipt](test-receipt.json).

The archive contains 58 files: immutable input/output observations, frozen comparison rows, initial and validated receipts, test summaries, source patch, install log and runner. No models, app binaries, screenshots or private typing are included. Archive SHA-256: `451e2e2d587a8a415e1036851d5bc958e52d48c88857a40ed5b7a9c6d000e103`.

Run the verifier with `uv run --no-project python verify_install.py --app <installed.app> --baseline-app <previous.app> --model <E2B.gguf> --latency-evidence <extracted-latency-study> --output <new-directory>`. It isolates defaults, home and storage; it never modifies the installed app's preferences. The defaults switch and production factory are covered separately by XCTest.

The PR remains an experimental draft. This activation is built, tested and installed; it is not a release or merge recommendation.
