# Bounded summary and action extraction — 9 September 2026

Meeting notes now come from one compact, cited extraction pass per transcript chunk. Facts, actions, decisions, and questions share the same evidence and job budget. Valid records survive rejected neighbors, truncation, interruption, and an unsuccessful repair. A partial result remains explicitly incomplete and does not replace the last complete summary.

The [10 September follow-up](transcription-efficiency-2026-09-10.md) fixes speech-runtime reuse, silence/repetition handling, GLM reasoning and chunk planning, overview selection, and per-attempt metrics. Measurements below describe the 9 September local-Qwen implementation.

## Implementation

The changes follow the six priorities from the efficiency audit:

1. **One job budget.** `MeetingGenerationBudget` covers model preparation, extraction, transport replays, repairs, and deterministic rendering. Its defaults are 600 seconds, 12 physical generation requests, 250,000 reserved input tokens, and 24,576 output tokens. Output allowances shrink with remaining time, tokens, and parts. The deadline cancels in-flight work and waits for cleanup. Queue time is measured separately. Unknown output usage retains its full reservation.
2. **Record-level validation and recovery.** Complete JSON records are validated individually and saved immediately. A truncated response contributes only fully received, valid records. Each chunk gets at most one targeted repair of fixable records and their local source context. Repairs start at the primary source and rebuild its neighborhood from the transcript; rejected model-selected context cannot contaminate the repair. Proven unsupported commitments and status-only tasks are omitted. Missing user commitments also enter repair. Remaining rejected records do not erase valid results from a complete scan. There is no recursive splitting/retry tree. Truncation, overflow, an empty substantial chunk, or an unrecovered user commitment leaves the job incomplete.
3. **Bounded output and canonical evidence.** Initial extraction allows at most 12 notes and 10 actions, with 280-character text and 80-character due dates. The schema constrains source IDs, owners, sections, arrays, and strings. The application resolves stable source IDs, speaker identity, and exact source quotes. An acceptance needs task context within eight source segments; distant tasks, unsupported commitments, conversational promises, and completed-work status reports cannot establish a pending user task. Repairs have smaller record and output limits. Hidden reasoning is disabled for this structured extraction; initial output has up to 4,096 tokens and repairs up to 2,048.
4. **One compact evidence format.** Short `sN|pN|speech` rows share a single speaker roster. Timestamps and stable IDs remain in the application source map. Native llama.cpp tokenization budgets the full prompt text, with 1,536 tokens of additional envelope/headroom. Other providers use conservative UTF-8 byte counts. Chunks target at most 6,000 input tokens with two overlapping source turns.
5. **Extract once, render once.** Summary facts and outcomes are merged and deduplicated together. Validated records render directly to Markdown without another full-transcript extraction or narrative generation. All user actions remain first; other and unclear-owner actions share the existing five-item selection. Source-revision checks and explicit speaker/action corrections remain authoritative. Completed parts resume only when the transcript, identity, engine, prompt, language, template, and user-note context fingerprint matches.
6. **Content-free measurements.** `notes-generation-metrics.json` persists successes and failures, request counts, stage timings, validation reasons, token usage, and native prefill/decode timings. Truncated calls are measured before their error is surfaced. Missing cache/reasoning/runtime fields remain unavailable rather than being reported as zero. Production records job/runtime queues and model preparation separately.

Checkpoints are `notes.parts.partial.json`, `summary.claims.partial.json`, `summary.partial.md`, and `outcomes.partial.json`. Complete artifacts are published only after every part verifies. “Summarize again” resumes compatible completed parts. A fresh transcription invalidates them.

## Validation method

The local replay harness runs production Swift extraction through native XCTest against private copies of the 26-minute audit transcript and a 91-minute transcript. It does not run UI tests or edit the source meetings. The machine is an Apple M4 Max with 48 GiB RAM, using the installed `Qwen3.5-4B-Q4_K_M.gguf` model and llama.cpp build `b10173` (AppleClang 21, Darwin arm64). Both the vendored and installed runtime report that build.

Cold total includes a fresh runtime process loading the model and becoming healthy, followed by extraction. Warm total uses the same loaded runtime with fresh output folders. Filesystem caches are not flushed. Compilation, XCTest launch, ASR, and unrelated production queue delays are excluded. The harness checks canonical sources/claims and user attribution; task meaning and coverage are reviewed against the private transcripts. Only aggregate measurements are committed.

The original audit observed 32 responses over 19m31s while the 26-minute meeting remained unfinished. About 93.8% of those response intervals ended in rejected work. This was an unfinished baseline, so it does not establish a completed old/new speedup ratio.

## Recorded results

All four replays completed and passed their mechanical source/ownership checks. Timings are below the requested limits in this local sample:

| Transcript | Cold total | Warm total | Target | Completed chunks | Requests per run |
| --- | ---: | ---: | ---: | ---: | ---: |
| 26m04s; 4,477 words; 644 segments | 59.8s | 33.4s | 300s | 3/3 | 5 |
| 91m07s; 11,229 words; 704 segments | 71.5s | 74.2s | 600s | 5/5 | 8 |

The normal replays retain the explicit user follow-up with the nearby request and acceptance citations. The long replays cover the opening material, middle topics, and final discussion, with no user tasks invented for the quiet local participant. Accepted tasks no longer appear a second time as decisions, and empty decision placeholders are omitted. The model's selected wording, other actions, decisions, and questions vary between runs; the semantic limits below still apply.

The [aggregate measurements](../../Benchmarks/think/SummaryEfficiency/results-2026-09-09.json) include stage timings, request/token counts, validation reasons, and output counts. Copied transcripts, model responses, generated meeting documents, runtime logs, and temporary authentication material are excluded from the repository.

The reproducible command and measurement definitions are in [the benchmark README](../../Benchmarks/think/SummaryEfficiency/README.md). Synthetic regressions cover shared request/deadline limits, cancellation cleanup, partial-record salvage, targeted repair, source membership, missing usage, checkpoint resume/invalidation, negation, speaker corrections, and invalid ownership/context.

The local full native run completed with 1,989 passed, five skipped, and 19 failed tests. The failures are in existing speaker-evidence storage/identity/lifecycle tests: protected `.sealed` fixtures cannot be reopened while the Mac is locked. The lock state was confirmed during triage. After the final source changes, all 33 focused extraction/merge tests passed with no failures or skips. Strict SwiftLint and `git diff --check` pass. UI tests run only on hosted CI; the existing menu assertion now expects “Summarize again”.

## Scope and limits

The latency target applies to summary plus actions after the transcript is available: under 300 seconds for the normal meeting and 600 seconds for the long meeting. Two transcripts and two runtime states are a local sample, not a multilingual recall/precision benchmark or a guarantee for every recording. Exact citation validation establishes source membership and identity, not full semantic entailment of every paraphrase. One replay retained an accepted request under Open questions; question status still needs semantic evaluation. Transcript recognition errors and some wording differences remain in the generated notes. Unresolved owners remain visible as such. Other providers and hardware need their own measurements.
