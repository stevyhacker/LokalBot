# Speaker capture, microphone matching, and outcome ownership

9 September 2026. Follow-up to the speaker identification and attribution changes.

Historical report: the Google Meet participant observer described here was removed in LokalBot 0.9.1, and LokalBot no longer reads Meet participant names or speaking activity. What it says about that observer is retained as context, not current behavior. See [DEVELOPMENT.md](../DEVELOPMENT.md#transcription--speakers).

## Changes

- A recording-bound Google Meet window can be observed while another application is foreground. Chrome must still have the verified meeting selected in that window. An unbound background window, a different meeting, an excluded/private source, a minimized window, a locked screen, or a source change cannot supply evidence. Frames stop on source loss or when visual identification is disabled.
- The Accessibility reader requests Chromium's web accessibility tree, fetches node attributes in batches, and distinguishes permission, timeout, traversal-budget, and source errors. It accepts participant-labelled containers and matching participant-name/control pairs, ignores embedded documents, and deduplicates nested tile containers without merging distinct people. Revalidation checks identity and layout separately from changing speaking indicators. Paired/shared-room tiles remain ambiguous.
- Observation counters and fixed failure codes are checkpointed even when no activity interval is captured. The encrypted session retains the diagnostics, and a content-free final count appears in the debug log. Names, URLs, screenshots, and voice vectors are absent from these logs. Storage read failures remain I/O failures instead of being reported as corrupt ciphertext.
- Microphone speech defaults to the user, displayed as “Me,” with or without echo removal, speaker separation, visual identification, or remembered profiles. This also resolves older microphone track/diarization records when read. Explicit “Someone else” corrections take precedence and survive reprocessing. Overlapping voices and echo-marked speech remain unresolved; independently proven speaker bleed can still be removed. Resetting a microphone correction returns to this default. Summaries and action ownership use the same user identity as the transcript.
- Echo removal is no longer a blanket prerequisite for microphone voice material. Clear, separated microphone samples may also qualify when both recorder clocks map the entire padded window and the actual system waveform is quiet. Remote speech, short sound bursts, missing/truncated reference data, clock gaps, and ambiguous/echo-marked microphone segments reject the sample. Remembered microphone names remain suggestions until confirmed. The default microphone identity never trains a profile by itself; explicit enrollment still requires sufficient clean samples.
- Action ownership accepts explicit conversational acceptance and discourse markers, including “Yeah, I can do that” and “And I'll be doing this.” Quotes must still match the cited speaker and surrounding source clause. Questions, negatives, hypothetical promises, reported speech, and ambiguous collective plans remain unresolved. Unique first-name requests can identify a speaker already named in the full roster. Named requests remain requests; they do not become accepted commitments. Owner labels and source quotes are preserved when the output language differs.
- Unresolved actions retain a fixed rejection reason. Their ownership, ordering, and shared limit with other participants' actions remain unchanged.

## Validation and limits

The tests use native policy fixtures, encrypted temporary stores, and generated PCM reference windows. They exercise data flow and rejection behavior; they do not prove human voice accuracy or compatibility with every live Meet layout. No UI tests run locally.

The microphone-default follow-up passed 130 focused native tests with no failures or skips, including transcript/summary rendering, action ownership across echo modes, explicit corrections after reopening/reprocessing, and reset without speaker separation or identification enabled. Strict SwiftLint and app/test compilation passed. Protected-file storage and service tests ran successfully in the unlocked session. The earlier three attribution fixes also passed the full hosted native suite: 1,998 passed, 17 skipped, zero failures. Exact commit and current hosted results are recorded in the PR.

Missing visual evidence from an earlier recording cannot be recreated by this change. A current live Meet recording is still needed to measure observation coverage and naming accuracy. Existing generated summaries and action lists need regeneration to reflect newly resolved microphone ownership.

## Provider references

- Chromium documents enabling its macOS accessibility tree through `AXEnhancedUserInterface`: [Accessibility Technical Documentation](https://www.chromium.org/developers/design-documents/accessibility/).
- Meet changes tile arrangements with window size and presentations: [Learn how to view people in Google Meet](https://support.google.com/meet/answer/9292748?co=GENIE.Platform%3DDesktop&hl=en).
- Paired participant tiles can both have a speaking border, so a border alone is not an identity: [Pair tiles in Google Meet](https://support.google.com/meet/answer/14074665?hl=en).
- Apple's protected-file option permits creation while locked but prevents reopening until unlock: [completeFileProtectionUnlessOpen](https://developer.apple.com/documentation/foundation/nsdata/writingoptions/completefileprotectionunlessopen).
