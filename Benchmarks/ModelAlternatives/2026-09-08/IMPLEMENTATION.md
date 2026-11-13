# Local model integration — 8 September 2026

Harrier is now the semantic-search default in the source. Granite Speech 5 is
available as an optional English fast mode, and zero-budget local requests
explicitly disable the thinking turn in the chat template. Qwen3.5-4B remains
the main default and Granite Speech 4.1 Q4 remains the speech default.

## Changes

- **Search:** the pinned Harrier 0.6B Q8 GGUF replaces Qwen's embedding model.
  The immutable model revision and SHA-256 match the tested September 7
  artifact. Last-token pooling, 1,024 dimensions, prompts, chunking and score
  thresholds stay consistent with the tested retrieval contract. A new index
  version invalidates the old meeting and screen vectors; the existing local
  backfill builds compatible vectors from their source data. Current-version
  vectors survive reopening and repeated indexing does not duplicate them.
- **Speech:** Granite 5 has a native Swift/MLX encoder, feature extraction and
  CTC decoder. It uses the existing timestamped speech-span pipeline and model
  preparation UI, verifies pinned model/tokenizer checksums, reports download
  progress, and releases the model after two idle minutes. The picker identifies
  its English-only, unpunctuated output and unsupported vocabulary prompts.
  Explicit requests for other languages fail before loading the model.
- **Reasoning:** zero effective budgets now merge
  `chat_template_kwargs.enable_thinking = false` into llama-server requests.
  Existing template arguments survive; positive-budget requests retain their
  existing policy. This protects short replies and summary recovery attempts
  from consuming their allowance in a hidden thinking turn.

These changes take effect when this build is run. The validation below rebuilt
a temporary copy of the meeting library. The installed release was not replaced.

## Retrieval validation

The native `EmbeddingIndex` rebuilt **2,328 chunks from all 64 transcribed
meetings** in the current 73-meeting library. Rebuilding took 93.5 seconds on the
M4 Max. Every reconstructed baseline chunk was checked against the rows written
by Swift before running Qwen, so the two models received identical text.

The 32 authored queries cover 16 topics from eight meetings, each queried in
English and Bosnian/Croatian/Serbian. Relevant meetings were selected from the
existing summaries before the comparison. This is a targeted product check,
not a broad independently annotated retrieval benchmark.

| Metric | Qwen3-Embedding 0.6B Q8 | Harrier 0.6B Q8 |
|---|---:|---:|
| Expected meeting in first result | 24/32 | **28/32** |
| Expected meeting in first five results | 31/32 | **32/32** |
| English, first result | 11/16 | **14/16** |
| BCS, first result | 13/16 | **14/16** |
| Reciprocal rank, capped at ten results | 0.844 | **0.928** |

The app's existing 0.45 meeting-score cutoff was used. Results count ranked
chunks; repeated chunks from one meeting are not collapsed into a single result.
Meeting text, queries, identifiers and vectors stay in temporary local fixtures.
Repository results contain only deidentified scores and case identifiers.
Private screen content was not used; screen-vector migration has a synthetic
database regression test.

## Speech validation

Native Swift output matches the Python reference **exactly on all 44 public
clips** from the September 7 benchmark. Those clips total 271 seconds and include
24 AMI meeting clips and 20 LibriSpeech clips. A separate test exercises the
engine's checksum verification, model preparation, VAD/span handling and actual
file-based transcription using a temporary model directory.

The initial port differed on one spelling. Matching the reference's float64
window construction and fused linear operations restored 44/44 parity. The
final evidence contains the exact public outputs and per-clip timings. These
are debug-build model-core timings, not a release-build or complete-meeting
throughput claim. The earlier Python speedup should not be presented as a
measured speedup for the integrated app.

The native implementation follows the
[MIT-licensed mlx-audio reference](https://github.com/Blaizzy/mlx-audio/tree/0d3ad3c58220a0ceb4b09b07734b7ba07439d420/mlx_audio/stt/models/granite_speech5_ctc).
Its attribution is included in `THIRD_PARTY_NOTICES.md`. Weights use the
[Apache-2.0 IBM checkpoint](https://huggingface.co/ibm-granite/granite-speech-5.0-470m-turboctc).

## Build and regression checks

- Native speech tests: **7 passed**, including reference parity and engine loading.
- Native real-library index/retrieval integration: **1 passed**.
- Final persistence/migration tests: **12 passed**.
- Reasoning/request tests: **26 passed** in the broad suite; model-store tests
  (6) and settings tests (52) also passed.
- Strict SwiftLint for changed Swift files and `git diff --check`: passed.
- Broad non-UI suite: **1,920 passed, 14 failed, 5 skipped**. It is not all green.

The broad-suite failures are in the unchanged speaker-identification work:
five evidence-store tests, eight identity-service tests, and one observer
lifecycle test. Their failures include protected temporary-file read errors,
authentication errors reported as `corrupt`, and one missing-evidence assertion.
An independent synthetic-file probe reproduced the read error both inside and
outside the workspace sandbox: `.atomic` files are readable;
`.atomic` plus `.completeFileProtectionUnlessOpen` fails to reopen with
NSCocoaErrorDomain 257 / NSPOSIXErrorDomain 1 on this Mac. The model changes do
not alter that storage code or its tests. A separate investigation remains
necessary before calling the entire application regression suite green.

The final added screen migration case was run in the focused persistence suite
after the broad run. No local UI tests were run.

## Standalone PR validation

The model-only PR is based on `master` at
`879314487d32f4e2ae3f8f126aabc432cc07b9a6`. It excludes the speaker-identification
feature in PR #66. All seven benchmarked implementation fingerprints in
`environment.json` are identical after applying the scoped patch to this base.

`Scripts/test/unit-tests.sh` on this standalone branch passed: **1,886 passed,
0 failed, 6 skipped** out of 1,892 non-UI tests. Full-repository strict SwiftLint,
Python/JSON artifact validation, and `git diff --check` also passed. The earlier
14 failures above describe the combined development checkout; those speaker
tests are not part of this PR. Results are recorded in `results/pr-suite.json`.
Hosted UI checks remain the PR's UI validation; no local UI tests were run.

## Reproduction

1. Use the September 7 benchmark's pinned models, public audio and Python
   environment. `prepare-native-parity.py` creates a manifest with local paths.
2. Set `TEST_RUNNER_LOKALBOT_GRANITE5_REFERENCE` to that manifest and optionally
   `TEST_RUNNER_LOKALBOT_GRANITE5_REPORT` to a result path, then run
   `Scripts/test/unit-tests.sh GraniteTurboTests`.
3. For library testing, supply an authorized, manually labeled query JSON file
   to `prepare-library-fixture.py`, along with `--work` in a new temporary
   directory and `--model` pointing to the pinned Harrier GGUF. The helper uses
   the consent-enforcing meeting CLI and copies metadata/transcripts/summaries.
   It does not copy audio. Each query has `id`, `query`, `language`, and
   `relevant_meetings` (eight-character meeting IDs).
4. Set `TEST_RUNNER_LOKALBOT_EMBEDDING_FIXTURE` to the generated manifest and
   `TEST_RUNNER_LOKALBOT_EMBEDDING_REPORT` to a result path, then run
   `Scripts/test/unit-tests.sh EmbeddingIndexIntegrationTests`. The test requires a
   temporary library root and uses the app's embedder port; keep that port free.
5. After the native test stops its server, run `library-baseline.py --work ...`
   using the pinned Python environment. Run inference comparisons serially.

Model revisions/checksums are in the September 7 manifest; implementation
fingerprints are in `environment.json`. The current private fixtures live under
`/private/tmp/lokalbot-model-integration-20260908`. They are deliberately absent
from the repository, so exact future reproduction requires retaining or
re-authoring those queries and taking a fresh library snapshot.
