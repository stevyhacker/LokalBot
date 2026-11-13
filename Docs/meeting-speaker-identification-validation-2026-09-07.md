# Meeting speaker identification — implementation and validation

7 September 2026 · Implementation and local validation, based on `879314487d32`.

Historical report: the Google Meet participant observer described here was removed in LokalBot 0.9.1, and LokalBot no longer reads Meet participant names or speaking activity. What it says about that observer is retained as context, not current behavior. See [DEVELOPMENT.md](../DEVELOPMENT.md#transcription--speakers).

The [9 September follow-up](speaker-attribution-fixes-2026-09-09.md) updates the original foreground-only provider, Accessibility contracts, microphone sample selection, and diagnostics. The historical validation below does not establish live compatibility for that update.

**The implementation and deterministic checks are ready for review. Release validation is incomplete.** No live Meet compatibility, recognition-accuracy, timing-harness, or Release-performance result is claimed. Both new settings default to off.

## Implemented behavior

- **Recording:** a separate observer follows start, stop, cancellation, calendar handoff, pause, and audio-source changes. It validates the foreground Chrome/Meet source, permissions, exclusions, secure/private windows, source-change notifications, and frame freshness. Unsupported layouts produce an unavailable state. Work is single-flight at no more than 2 Hz; only a latest bounded frame is retained, and no pixels enter the screenshot archive.
- **Timing:** Core Audio host timestamps travel as primitives through the existing buffer handoff. Only successful file writes establish anchors. Accessibility read uncertainty and ScreenCaptureKit display timestamps map onto those recorded frames. Dropped buffers, invalid timestamps, backwards clocks, incompatible sample rates, and recovery padding cannot create continuous evidence. Compact clock spans accompany encrypted evidence chunks.
- **Names:** repeated visual evidence can produce an automatic alias; weaker evidence offers up to three candidates with playback. Visual and voice-profile evidence use separate rules and conflicts require review. The microphone label is excluded from remote visual attribution. Calendar-only naming remains a fallback.
- **Remembered choices:** one revision-checked command records user choices before transcript projection. Request IDs make retries idempotent. Reset/undo suppress automatic reapplication until explicitly resumed. Retained turn anchors and an audio digest remap identities when acoustic labels reorder or split; conflicting merges remain unresolved. A user can distinguish two labels that were previously inferred to be the same voice. Unresolved prior choices remain available for manual reassignment.
- **Optional profiles:** the pinned FluidAudio 0.15.5 chunk vectors reuse the existing diarization pass and retained model assets. Only explicit confirmations can enroll sufficiently long, independent, consistent speech. Profiles have bounded exemplars, model fingerprints, contribution provenance, database revisions, and revocation tombstones. Unknown/confusable voices reject or remain suggestions. Automatic guesses never enroll themselves.
- **Review and cleanup:** the existing rename sheet includes automatic provenance, evidence playback, dismissal, undo/reset/resume, local-profile selection, and **This meeting only**. Settings offers Rename, Forget, and Clear all. Deleting a source meeting revokes its contributions first. Expiry removes raw evidence, suggestions, and transient query vectors while retaining applied names and minimal decision anchors. Corrections invalidate derived evidence and expose an explicit summary refresh action.
- **Privacy:** applied aliases remain the existing public transcript fields. Suggestions, observation provenance, voice vectors, and profile links stay in encrypted private sidecars, outside prompts, ordinary exports, FTS/semantic search, CLI/MCP, and diagnostics. Day Memory scheduling is unchanged. Privacy/default-setting documentation now agrees with `AppSettings`.

The native adapter currently accepts explicitly participant-labelled Accessibility containers and an English speaking-state contract. Its visual fallback requires a same-tile readable name together with a blue active border and equalizer shape. **These contracts have not been verified against the current live Meet interface.** Their conservative rejection behavior may leave real layouts unavailable until staged provider fixtures confirm or refine the adapter. Drawn light/dark, camera-off, pinned/silent, and arbitrary-blue fixtures are unit fixtures, not live compatibility evidence.

## Completed local checks

| Check | Result |
| --- | --- |
| Native app compilation | Passed, arm64, macOS deployment target 15.0 |
| Standalone `lokalbot-cli` compilation | Passed; no speaker-evidence/profile types added to its source graph |
| Relevant native tests | **233 passed, 0 failed, 0 skipped**: 49 new checks plus 184 existing recording, live-preview, transcript, calendar naming, settings, privacy, and pipeline checks |
| Strict SwiftLint | **0 violations across 525 files** |
| Evaluation-script checks | Six passed: exact precision-bound boundaries, empty-data rejection, percentile calculation, duplicate assignment rejection |
| Diff whitespace | Passed |
| Hosted UI test compilation | Passed with `build-for-testing`; no UI test executed |
| Hosted UI test execution | Not run; a focused opt-in/profile-manager UI case was added alongside the existing rename coverage |

Native result bundle: `.build/XcodeDerivedData/Logs/Test/Test-LokalBot-2026.09.07_20-38-15-+0200.xcresult`. Local test execution explicitly used `-skip-testing:LokalBotUITests`. UI automation has not run on this MacBook.

The new tests cover timing/gaps, threshold boundaries, contradictory evidence, overlapping speakers, unknown/confusable/incompatible vectors, correlated chunks, source/privacy contracts, stale source callbacks, stop/start races, source-app rejection, authenticated/truncated storage, Keychain-key mismatch, cross-meeting replay rejection, corrections, reset/resume, relabeling/splits/merges, request idempotency, evidence deletion during matching, disabled remembering, enrollment-source deletion, and forgotten-profile resurrection attempts. Service fixtures exercise the complete assignment/enrollment/recognition policy with synthetic vectors. They do not run speech-recognition inference or prove accuracy on human voices.

## Release gates still requiring evidence

| Gate | Target | Current evidence |
| --- | --- | --- |
| Visual-only automatic precision | At least 99%; one-sided 95% lower bound at least 99% | No held-out live assignments; errors, denominator, and interval unavailable |
| Profile-only automatic precision | Same target, evaluated independently | No held-out human-voice query meetings; errors, denominator, and interval unavailable |
| Combined automatic precision | Same target, evaluated independently | No held-out combined decisions; errors, denominator, and interval unavailable |
| Unknown-voice false acceptance | Report unenrolled false acceptance and enrolled-person confusion separately, including one saved profile | Unmeasured; rule-vector tests are not recognition evidence |
| Unknown / false rejection coverage | Report rejected genuine voices and all unresolved cases | Unmeasured |
| Suggestion usefulness | At least 95% top-three recall; also report top-one precision and candidate count | No held-out eligible uncertain matches; unmeasured |
| Eligible speaker coverage | At least 70% for speakers with three clear visible turns | Unmeasured; automatic/suggestion/all-speaker coverage and usable visual time also unmeasured |
| Clock mapping | p95 at most 250 ms | Unit conversions pass; controlled capture-harness error is unmeasured |
| Meet indicator delay / sampling | Measure separately from clock error | Unmeasured; the transition guard remains provisional |
| Incremental CPU | At most 5% of one core on average | Unmeasured in a Release recording comparison |
| Extra peak memory | At most 64 MiB | Bounded implementation; measured peak unavailable |
| Evidence storage | At most 2 MiB per recorded hour | Bounded implementation; measured hourly cost unavailable |
| Profile cost | Report post-processing time, memory, and encrypted storage separately | Unmeasured on real recordings |
| Recording reliability | No observer-induced audio drops or blocking | Existing recorder regressions pass; a live capture comparison remains required |
| Privacy / lifecycle | Zero forbidden-source writes, cross-session data, or unexpected external payloads | Deterministic gates/persistence tests pass; live-provider and external-payload instrumentation remain required |
| Remembered choices | Restart/retry/expiry/correction persistence and later-meeting recognition | Deterministic persistence/rule tests pass; held-out later-meeting recognition remains unmeasured |
| Native UI | Hosted synthetic UI pass and current Meet validation | UI execution and current-provider validation remain pending |
| Diarization regression | Name matching must not alter audio segmentation | Label/timeline mapping tests pass and inference configuration is unchanged; paired real-audio output comparison remains required |

Provisional thresholds remain implementation rules, not probabilities. The evaluator reports each path independently and cannot mark missing gates green. Final evaluation should hold out entire meetings and people used for threshold tuning. Cross-meeting profile queries must use different recordings from enrollment, including changed channels and unenrolled people. Repeated people or meetings require an explicit review of the independence assumption behind binomial confidence bounds.

## Running the held-out evaluation

`Scripts/test/evaluate-speaker-identification.py` accepts annotated decisions and measurements from staged runs. It does not produce or infer ground-truth identities. Use opaque identity IDs so duplicate display names cannot count as a correct match by text equality. One row represents one acoustic speaker in one meeting; retries and frames must not add rows.

```sh
python3 Scripts/test/evaluate-speaker-identification.py --self-test
python3 Scripts/test/evaluate-speaker-identification.py /path/to/held-out-decisions.json > /path/to/report.json
```

Input shape (an example of the format, not measured results):

```json
{
  "holdout_reviewed": false,
  "independence_reviewed": false,
  "live_provider_validated": false,
  "hosted_ui_passed": false,
  "tuning_people": [],
  "assignments": [
    {
      "meeting_id": "query-meeting-id",
      "speaker_id": "acoustic-speaker-id",
      "person_id": "held-out-person-id",
      "path": "profile",
      "expected_identity": "person-opaque-id",
      "assigned_identity": null,
      "suggestions": [],
      "eligible": true,
      "clear_visible_turns": 0,
      "enrolled": true,
      "saved_profile_count": 1,
      "enrollment_meeting_ids": ["different-enrollment-meeting-id"],
      "audio_sha256": "query-file-digest",
      "enrollment_audio_sha256": ["different-enrollment-file-digest"]
    }
  ],
  "measurements": {}
}
```

`path` is `visual`, `profile`, `combined`, or `none`; include unresolved speakers. `expected_identity` is null for a voice that should not resolve to an enrolled identity. Private assignment provenance retains both supporting matches; `evidencePath` identifies `combined` when both independently qualify for the automatic tier, otherwise it identifies the automatic assignment's primary source. Use that path when annotating decisions. Optional measurements are `clock_mapping_error_ms` and `indicator_lag_ms` arrays; `incremental_cpu_percent_one_core`, `extra_peak_memory_mib`, `evidence_mib_per_hour`, `profile_processing_seconds`, `profile_peak_memory_mib`, `encrypted_profile_bytes`, `usable_visual_seconds`, `observer_induced_audio_drops`, and `forbidden_writes_or_payloads` scalars. CPU and storage values should come from duration-weighted Release capture comparisons, not debug tests.

The script rejects duplicated speaker/meeting rows, enrollment/query overlap, reused enrollment clips, and tuning/evaluation-person overlap. It reports exact one-sided binomial precision bounds, confusion/rejection metrics, suggestions, coverage, timing, and costs separately. Its unknown-voice rejection gates conservatively require a 99% lower bound on rejection as well; this is an evaluation criterion to review with the staged corpus, not an observed result.

The next validation step needs a remote Mac and staged Google Meet recordings. Start with the plan's ten meetings/fifty speaker-meeting identities, then expand the held-out corpus to substantiate the automatic precision gates. No local UI automation or personal meeting reprocessing is needed to review this code candidate.
