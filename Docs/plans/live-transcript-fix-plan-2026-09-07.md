# Live transcript fixes — 7 September 2026

## Implementation order

1. Replace the within-chunk relative-volume speech heuristic with the existing Silero speech detector. Keep cheap silence/rumble filtering, use bounded mono chunks, and do not send uncertain noise to ASR when detection fails. Reuse the detector's existing per-file result cache when the selected ASR engine requests speech spans.
2. Make preview state explicit: off, running, paused, failed. Keep per-track cursors across retry/resume; count only actual successful ASR as recovery; apply per-track retry backoff and guard all asynchronous publication against obsolete sessions.
3. Observe the transcriber directly in the live pane. Preserve lines while paused/failed, display actionable failure state, add pause/resume/retry controls, and follow the last line ID rather than the bounded line count.
4. Preserve preview opt-in across the real calendar stop/start transition, but clear it on ordinary stop or failed recording start.
5. Remove the fixed four-second startup delay. On first activation, default to the latest 12 seconds with a clear disclosure and an explicit “from beginning” option. Resume/retry never change the established cursor. Drain available work without a fixed productive-loop sleep.
6. Add regression coverage for continuous speech, detector failure/noise rejection, retries, cancellation, bounded lines, pause/resume, late starts and calendar stop/start. Run relevant non-UI suites and lint, then verify a signed permission-preserving reinstall. UI automation stays on a hosted runner.

## Acceptance

- Continuous speech is not rejected merely because its RMS stays high.
- Non-speech rejection is handled by VAD, with silence/rumble prefiltering retained.
- Quiet-track progress cannot reset another track's ASR failures.
- Retry/resume do not duplicate accepted chunks; stale tasks cannot alter the new session.
- Failed/paused preview keeps existing lines and shows its state; recording remains independent.
- Follow-live still reacts after 400 lines.
- Calendar handoff retains active preview; a regular stop clears the opt-in.
- Late activation has a visible start policy and no unconditional startup sleep.

## Scope

Meeting live preview only. Full post-recording transcription and dictation preview are unchanged. Preserve the current waveform changes and unrelated audit documents. No commit or push is part of this task.

## Implementation and verification

All seven reported bugs are addressed, along with the startup/backlog and DSP improvements:

- Continuous speech now reaches the shared Silero detector; the inexpensive prefilter only rejects silence and dominant rumble. Detector uncertainty produces a bounded preview failure.
- The live pane observes `LiveMeetingTranscriber` directly. Off/running/paused/failed states drive its controls and error presentation; retained lines remain visible after pause or failure.
- Failure accounting and exponential retry backoff are per track. Accepted lines and cursor advancement commit together. Retry/resume retains cursors, and cancelled generations cannot publish into a new recording.
- Follow-live observes the newest line identity, which changes even when the 400-line limit keeps the count constant.
- The actual calendar stop/start boundary explicitly retains active preview opt-in. Ordinary stop and failed restart clear it.
- First activation starts immediately with the latest 12 seconds, with an explicit from-beginning option. Lagging/missing tracks share the same disclosed start; resume/retry preserves the previous position. Available backlog drains without an unconditional sleep.
- Vectorized energy reductions reduce signal-preparation work.

Validation on 7 September 2026:

- 72 non-UI tests passed, zero skipped or failed: `LiveMeetingTranscriberTests`, `LiveTranscriptChunkerTests`, `RecordingControllerTests`, and `AudioPreviewTeeTests`.
- The checked-in generated-speech fixture passes both preparation and the installed Silero VAD; a steady 400 Hz hum produces no VAD speech segments. No model download or personal audio was used for this test.
- Strict targeted SwiftLint and `git diff --check` passed.
- The same 12-second generated-signal/20-run benchmark used in the review measured 14.81 ms median in Debug and 0.44 ms in Release, versus approximately 69–71 ms and 0.91 ms before. This measures cut search plus signal prefiltering; it excludes file I/O, VAD and ASR inference.
- XCTest result bundle: `/private/tmp/lokalbot-live-fix-final-tests.xcresult`.
- Signed Debug build reinstalled in place at `/Applications/LokalBot.app` and relaunched. Bundle ID, team, designated signing requirement and entitlements match the previous installation; strict signature verification passed. The installed executable SHA-256 matches the exported build (`07a84384d7b260f0744be685a3e788fe156faabc8ffee0195b63a9fc88306442`).

UI automation was not run on this Mac. Rendering, retained-line error banners, pause/resume controls and follow-live scrolling beyond 400 lines still require hosted UI validation. Full live ASR latency/accuracy and a hardware-backed calendar handoff were not measured by these non-UI tests.
