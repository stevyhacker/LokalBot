# Transcription attribution: implementation and validation

8 September 2026. Stacked on `cefea2d7f9ef41a3222d9f39ffdebd78c3081286`, the speaker-identification implementation in PR #66. This implements the [approved attribution scope](../plans/transcription-summary-attribution-plan-2026-09-08.md). Deterministic validation is separate from the pending audio/model release gates below.

## Resulting behavior

| Area | Implementation |
| --- | --- |
| Action ownership | First-person prose cannot select an owner. Extraction validates a speaker reference, ownership basis, and verbatim source quote. Contradictory metadata stays unresolved through construction and reload. Indexes and action threads honor resolved ownership and manual corrections. |
| Source and identity | Transcript segments store microphone/system source, user/other/unresolved identity, and attribution method independently of text confidence. Historical microphone labels display as local speech. An alias named "Me" does not make a remote speaker the user. |
| Audio/text boundaries | Both tracks are diarized before bounded ASR. Gaps remain unclassified; overlapping voices stay unclear. No proportional text splitting or dominant-speaker assignment is used. Only actual acoustic turns can support visual matching; ASR chunks cannot multiply its votes. |
| Confirmation and profiles | Supported acoustic clusters offer playback, "This is me", and "Someone else". Confirmations use revision-checked sidecars and audio anchors. Microphone-only confirmation works without enrollment. Remembering retains its existing opt-in; microphone samples need compatible provenance, and microphone matches remain suggestions. |
| Echo | Both recorders retain compact host/file clocks. AEC uses bounded local alignment, gap boundaries, drift mapping, and conservative acceptance. Original audio is retained. Effective status is persisted and visible. Exact lexical duplicates are retained as uncertain unless narrow waveform evidence supports removal. Mixed phrases are retained because the pipeline has no validated word alignment for safe partial deletion. |
| Narrative grounding | Direct and chunked summaries use structured speaker/source/quote claims. IDs and quotes survive context fitting, checkpoints, and fallback. Rendering supplies the source speaker deterministically, including unconfirmed labels. Decisions and requests preserve attribution and modality. |
| Repair and concurrency | Changed transcript revisions back up previous outputs, invalidate active artifacts, and reject stale generation writes. Selected meetings can repair summary/action ownership without rerunning ASR. Unambiguous source/text matches preserve workflow state; unmatched edits remain available for review. Track checkpoints bind to source audio and processing settings. |

New public metadata contains meeting-local speaker references, source provenance, quotes, and timing. Voice vectors and cross-meeting profiles remain in the encrypted store. This change introduces no new inference provider or transmission path and does not change echo/remembering settings.

## Deterministic validation

| Check | Result |
| --- | --- |
| Complete native suite before final repair/template follow-up | 1,950 passed, 0 failed, 3 skipped; 1,953 total |
| Subsequent complete native run including manual-repair regression | 1,936 passed, 15 failed, 3 skipped; 1,954 total. Protected speaker-file reads were denied by macOS; see the reproduction below. |
| Final focused summary, attribution, action-state, and daily-evidence tests | 37 passed, 0 failed, 0 skipped. Includes the final manual-correction and freeform-heading changes. |
| App/test compilation | Passed with the final focused run; no compiler warnings in that log |
| Standalone `lokalbot-cli` Debug build | Passed; no compiler warnings |
| SwiftLint | Strict lint passed |
| XcodeGen | Project generation passed |
| Patch formatting | `git diff --check` passed |

The later complete run is **not an all-green result**. It failed 14 speaker-store/service tests and one observer lifecycle test while protected files could not be reopened. A standalone Foundation probe reproduced the same `NSCocoaErrorDomain 257` / `EPERM` after writing a new synthetic temporary file with the existing `.completeFileProtectionUnlessOpen` option. This reproduces the OS read restriction without the app's serialization or encryption code. The earlier complete run had passed these tests. File protection was not weakened, and these failures are not counted as skips or passing results; hosted validation remains necessary.

Relevant regressions cover production parser/reload/synchronizer ownership, explicit remote-to-user requests, aliases named "Me", contradictory flags, local cluster confirmation, overlap/gaps, microphone-only restart/reordering, source-domain profiles, startup/drift/backward clocks, waveform positives/negatives, acoustic turns versus ASR chunks, summary citation/chunk validation, stale jobs, and ambiguous workflow-state repair. Saved manual owner/text edits now invalidate the narrative while retaining actionable records; regeneration projects the corrections into summary action sections.

Native commands used `xcodebuild -scheme LokalBot -destination 'platform=macOS' -only-testing:LokalBotTests test`, followed by a focused run of `AttributionSafetyTests`, `ActionThreadRevisionTests`, `MeetingSummaryGeneratorTests`, and `DailyEvidenceIntegrationTests`. All runs excluded UI tests. The CLI used `xcodebuild -scheme lokalbot-cli -configuration Debug build`. All builds used the isolated checkout and its derived-data directory.

The suite uses synthetic audio and model-output fixtures. These establish code invariants; they do not measure human voice recognition, real ASR, or the accuracy of generated paraphrases. Current hosted Build, native-test, Lint, XcodeGen, and UI results are reported on the PR at its exact head; they are separate from the local results above. Workflow files are unchanged.

The [first hosted UI run](https://github.com/stevyhacker/lokalbot/actions/runs/34216518145) passed the build/critical tests and all three visual shards, but failed two functional assertions. The toolbar assertion still expected `Re-summarize` after the action was renamed to `Repair summary and action owners`. The speaker-settings assertion searched by label, while the saved accessibility hierarchy exposed the two switches with identifiers and values but no labels. The follow-up supplies explicit accessibility labels, addresses the switches by their stable identifiers, asserts their labels and independent opt-in values, and updates the expected repair action. Current hosted rerun results are recorded on [PR #68](https://github.com/stevyhacker/lokalbot/pull/68).

The [first hosted native run](https://github.com/stevyhacker/lokalbot/actions/runs/34219065211) executed 1,966 tests with 16 skips and two failures. Both automation-gate tests used missing-audio fixtures, but model preparation ran before audio validation and started real speaker-model downloads on the clean runner. The pipeline now rejects unavailable audio before preparing those models. The protected-file tests that failed locally passed on this hosted runner.

## Open release gates

| Metric or gate | Result | Consequence |
| --- | --- | --- |
| Held-out microphone identity precision | Not measured | Automatic microphone identity stays disabled; matches are suggestions. |
| One-sided 95% precision lower bound | Not measured | The proposed 99% standard is unproven. |
| Wrongly user-attributed speech | Not measured on human recordings | No end-to-end accuracy improvement is claimed. |
| Genuine user-word loss | Not measured on human recordings | Uncertain/mixed phrases are retained; AEC still needs staged comparison. |
| ASR word error rate | Not measured | Per-turn transcription quality remains a rollout gate. |
| Action-owner precision | Not measured on annotated meetings | Deterministic evidence checks do not prove semantic correctness. |
| Action-owner recall | Not measured | Conservative speech-act patterns can leave valid work unresolved, especially outside supported phrasing/languages. |
| Unresolved attribution coverage | Not measured | Review burden and useful coverage need measurement. |
| End-to-end processing time | Not measured on representative long recordings | Extra diarization, bounded ASR calls, and audio hashing need benchmarking. |
| Peak resident memory | Not measured | Bounded file processing does not substitute for a Release benchmark. |
| Hosted UI suite | See current-head checks on PR #68 | Local UI tests were not run. |
| Real capture modes/device changes | Not exercised in this task | Remote staged recordings are required. |
| Narrative paraphrase entailment | Model-dependent; no annotated evaluation | Exact quotes and speaker IDs constrain attribution, but do not establish every paraphrase's semantics. |

The next release-validation step is a controlled remote-Mac corpus with annotated identities, speech, requests/commitments, and genuine replies, including unenrolled speakers and different enrollment/query meetings. Compare against the baseline on the same inputs. A synthetic all-green test suite alone does not close these gates.
