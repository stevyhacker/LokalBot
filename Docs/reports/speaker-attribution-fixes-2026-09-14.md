# Speaker attribution follow-up — 14 September 2026

Historical report: the Google Meet participant observer described here was removed in LokalBot 0.9.1, and LokalBot no longer reads Meet participant names or speaking activity. What it says about that observer is retained as context, not current behavior. See [DEVELOPMENT.md](../development/transcription.md).

## Observed failure

The affected 35-minute recording logged 4,030 speaker-observation attempts, zero
usable intervals, zero named speakers, and zero name suggestions. The preceding
two recordings also logged zero usable intervals. Identification and remembering
were enabled. This establishes a capture failure, not a successful naming run.

In 953 attempts, the reader found participant tiles but could not associate the
Accessibility window with a ScreenCaptureKit window. The selector required exact
window-title equality across the two APIs, plus position and width. Title mismatch
is a plausible explanation for this failure; the diagnostic did not record which
comparison failed, and a live Meet reproduction is still needed.

The saved transcript also contains duplicated system/microphone speech. A separate
regression made the waveform verifier use only segments whose identity had already
been marked uncertain. Default microphone attribution therefore skipped the audio
check entirely. An end-to-end native test reproduces this defect with generated
PCM audio, without reading or changing the user's recordings.

## Changes

- Associate capture windows by process and all four frame dimensions. Require a
  unique match and keep the exact Meet URL, privacy, and post-capture source checks.
  Differing display titles no longer prevent an otherwise unique match.
- Keep acoustic-check candidates separate from identity uncertainty. Default
  microphone attribution reaches the waveform verifier; explicit user confirmation
  still wins. Text equality alone does not delete speech or change its identity.
- Show a recording-level explanation when visual naming was attempted but captured
  no usable observations, with a direct route to review transcript speakers.
  Remembering-only sessions do not produce this message. Diagnostics remain in the
  encrypted, expiring sidecar and stay out of normal exports and CLI/MCP output.

## Calendar guest suggestions

The affected meeting already retained 13 calendar guests, but none had a calendar
display name. The previous picker showed their email addresses and filled the
name field with an empty string when selected. The revised picker:

- Offers editable names from name-like email addresses, visibly marked **From
  email**. Actual calendar display names take priority; shared mailboxes and
  ambiguous handles still need a manually entered name.
- Places calendar guests first and exposes **Name speakers** in the meeting
  overview. Choose a speaker, use **Play voice**, select a guest, and save.
- Retains the original calendar metadata. A suggested name becomes a speaker
  alias only after explicit selection and saving; automatic attribution never
  treats an email-derived suggestion as a confirmed identity.
- Keeps attendee emails in local metadata and the picker, separate from transcript
  aliases and remembered voice profiles. Distinct guests with the same suggested
  name remain separate choices.

Running the actual suggestion implementation against this meeting's saved metadata
produced 13 editable suggestions. This works for the existing recording without
retranscription or visual evidence. Calendar membership does not establish who
spoke; listening and confirming the choice is still necessary.

## Validation

- The new audio-path test failed with the old verifier input: expected the echoed
  segment's index, received an empty set.
- With the fix, 91 affected native tests passed, with no failures or skips.
- The app composition prepared for installation passed 106 native tests, with no
  failures or skips. Strict SwiftLint and `git diff --check` passed.
- The calendar follow-up passed 123 native tests with no failures or skips,
  including email-derived suggestions, preservation of calendar metadata and
  distinct guests, no automatic assignment from email guesses, and persistence of
  an explicit calendar choice through reprocessing without visual observations.
  Strict SwiftLint and `git diff --check` passed again.
- Test results and installation evidence are under
  `.build/speaker-attribution-2026-09-14/`. No local UI tests ran.
- Installed the signed local update with `reinstall-preserve-permissions.sh`.
  The app relaunched, its executable and CLI helper hashes match the exported
  build, and its designated signing requirement and entitlements are unchanged.
  The prior app is retained at `/private/tmp/LokalBot-before-speaker-fix-20260914.app`.
- Installed the calendar follow-up with the same script and repeated those
  signature, entitlement, executable-hash, and relaunch checks successfully.
  The follow-up's tests and installation proof are in `calendar-suggestions.xcresult`
  and `calendar-install-proof.json` within the evidence directory above.

These tests establish the code paths and rejection rules. They do not establish
live Google Meet compatibility or human speaker-identification accuracy. A fresh
recording must demonstrate nonzero usable intervals and correct names. Reprocessing
an old recording cannot reconstruct missing visual observations; the narrow echo
fallback also does not remove arbitrary acoustic bleed or mismatched ASR text.

Apple documents that an existing desktop-independent window capture includes the
window even when covered by other windows:
[Take ScreenCaptureKit to the next level](https://developer.apple.com/videos/play/wwdc2022/10155/).
