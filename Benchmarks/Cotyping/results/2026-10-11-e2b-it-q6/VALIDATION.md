**Validation and reproduction — E2B IT Q6 follow-up**

The native experiment and the requested blind Claude quality judgment are complete. This update changes benchmark/reporting files only. It does not change app code, the model catalog, dependency pins, production thresholds or installed settings.

The frozen Release replay executable has SHA-256 `23562c21a51b6ef3cf32e3a6bab2b59f1c9ed2c8bf6b2e0f12b77921e3c48cf9`. Its six recorded runtime/test/helper hashes were checked against PR source commit `0cb3488d3b504522ff09881e3390e224cc996791`. The existing decoder uses certified prefix search, the selective hybrid, two generation and two prefill threads and 256-token prefill chunks. Prompt, sampler, six-token/four-word budgets and production gates 0.1/0.31 remain fixed. [Source verification](source-before.json).

All **39 processes** exit successfully: 7,776 measured observations plus 312 excluded warmups. The saved-data validator checks input, raw-output, executable and model hashes; exact case IDs; prompt equality; no prompt overrides or private context; 3,888 deterministic repeated non-cancellation outputs; 864 production/trace pairs; 1,728 native matched/trace pairs; 1,152 unchanged midword outputs across matched rounds; and 288 replacement/cold recovery pairs. Every matched arm shows 112 English and 109 Serbian Latin suggestions. Matching changes zero current-Q6 texts. [Validation receipt](validation.json).

Before inference, original download hashes, tensor shapes, precision mix and input-tokenizer metadata were inspected. Both IT evaluation files differ from their originals in exactly the automatic-BOS boolean byte. All 402 distinct prefixes tokenize identically using the actual app's linked `libllama`. The initial over-strict token-type assertion and subsequent pre-inference stopping-metadata clarification are preserved. [Provenance](PROVENANCE.md) · [BOS receipts](bos-alignment.json) · [Tokenization fingerprints; full sequences in archive](input-tokenization-summary.json) · [Frozen controls](pre-inference-controls.json).

**Eleven existing focused Python tests pass.** They cover exact matching, fallback probability mass, preserving ungated midwords, rejecting unmatchable ties, Unicode fragment/reference handling, retaining silence in quality denominators, scenario clustering, actual cancellation issuance, anonymous packets, missing ratings and contradictory preferences. No existing test expectation changes. [Test log](python-tests.log).

**All 25 frozen Claude batches are complete.** Direct Anthropic Messages API responses identify `claude-opus-5-5`, with high effort and no tools. They cover 272 primary cases, 24 reversed-order repeats and 504 nonempty option ratings; 16 all-silent cases remain in the 288-checkpoint denominator. The validator checks every original request against the exact frozen system/rubric/packet, every raw response/model/stop reason, all case/option coverage, all response/receipt hashes and normalized ratings. No implementation labels, timings, future references, source code or personal text are supplied. Both `judgeCompleted` and `judgeCoverageVerified` are true. All earlier native summary fields are identical to the previously published report. [Status](judge-status.json) · [Direct-API amendment](judge-direct-api-amendment.json).

The archive preserves the 25 CLI quota failures, one OpenRouter guardrail failure and one direct-API schema-format preflight that returned no ratings. The latter used equivalent integer enums for the API’s schema constraints but produced an empty case. Its original adapter, request, response, usage and amendment are retained under `judge/anthropic-format-failures/primary-01/`. The successful format uses plain JSON requested by the unchanged rubric, with local coverage validation; no valid score is overwritten, discarded or rerated. All 25 successful batches pass on their first plain-JSON attempt. User-authorized credentials were read in memory only and are absent from artifacts. The old [transport attempt record](judge-transport-amendment.json) is historical.

The successful API requests consumed 47,027 input and 71,744 output tokens, including 33,233 thinking tokens. The failed format preflight consumed 2,655 input and 1,549 output tokens separately. These are provider usage receipts, not local-generation latency. The 24 repeats contain 39 options: 29 agree exactly and 36 agree on positive versus nonpositive utility. There are no contradictory preferred-option lists. [Fresh 11-test follow-up log](judge-followup-tests.log).

The installed executable and current-Q6 hashes are identical at the start and end of native testing. No app build or reinstall, local UI test, release, CI retry/dispatch or workflow change was performed. A vocabulary-only C probe was compiled for tokenization verification; that is separate from building the app. [Native-study installation receipt](unchanged-app-receipt.json) · [Post-judge installation hash check](judge-followup-installation-receipt.json).

**Recompute the saved native and quality results**

The [archive](evidence.tar.gz) contains frozen scripts/plans, model provenance, public cards, synthetic inputs, raw native outputs and logs, matching thresholds, frozen judge packets, original successful API requests/responses, parsed ratings, failed-service receipts and explicit format amendments. It excludes model weights, app/probe binaries, credentials, raw desktop process inventory and profiling data. The [manifest](evidence-manifest.json) gives every member's hash. Recalculation does not run models or contact Claude.

```sh
mkdir -p /tmp/lokalbot-e2b-it-q6-evidence
tar -xzf Benchmarks/Cotyping/results/2026-10-11-e2b-it-q6/evidence.tar.gz \
  -C /tmp/lokalbot-e2b-it-q6-evidence
UV_CACHE_DIR=/private/tmp/lokalbot-q6-uv uv run --no-project python \
  /tmp/lokalbot-e2b-it-q6-evidence/it_q6_analysis.py \
  --root /tmp/lokalbot-e2b-it-q6-evidence
UV_CACHE_DIR=/private/tmp/lokalbot-q6-uv uv run --no-project python \
  /tmp/lokalbot-e2b-it-q6-evidence/validate_evidence.py
UV_CACHE_DIR=/private/tmp/lokalbot-q6-uv uv run --no-project python \
  /tmp/lokalbot-e2b-it-q6-evidence/make_tables.py
UV_CACHE_DIR=/private/tmp/lokalbot-q6-uv uv run --no-project python \
  /tmp/lokalbot-e2b-it-q6-evidence/make_examples.py
```

The publication check extracts into a new directory, verifies every archive member, recomputes `summary.json`, `validation.json`, `TABLES.md`, `quality-examples.json`, `EXAMPLES.md` and `judged-example-selection.json`, and requires byte-for-byte equality. [Reproduction receipt](archive-reproduction.json).

**Run another experiment**

Do not rerun successful judge batches or overwrite this evidence. A new quality study should use a new directory and document its sample, protocol and authorized external destination. The archived direct API adapter reads only `ANTHROPIC_API_KEY` from an explicitly supplied environment file; the environment file itself is never copied. API and CLI adapters remain separate, and no provider guardrails were changed. No new native timing is implied by completing these saved blind packets.

For a new native study, use a new directory and rebase the recorded local paths. Obtain the pinned public artifacts, verify hashes, reproduce the documented BOS alignment and tokenization check, and use the recorded Release runtime or explicitly declare any change. The wrapper commands are `prepare --app /path/to/LokalBot`, `production`, `steady`, `trace`, `match`, `matched`, `judge-prepare`, all with `--root <new-root>`. The runner refuses to overwrite existing plans/runs. Run native timing serially, without downloads, builds or judge requests. This study used an M4 Max on AC power with an interactive desktop and resident services present; it is not a continuously isolated machine measurement.
