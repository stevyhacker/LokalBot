# Prevent silent meeting-audio loss

Status: implemented on `codex/native-ui-refresh` for PR #100. Installation and
release remain separate. Validation and residual release gates are below.

## Incident and recovered content

A verified Google Meet call lost its Accessibility document. About 122 seconds
later, the old detector stopped recording with an uncertain end despite ongoing
system audio. Finalization then trimmed approximately 124 seconds of saved audio
from derived content. A manual restart recorded mostly quiet microphone audio;
nine system-attachment attempts expired shortly before the call became visible
again. The recovered tail was already in the original raw recording and has
been rebuilt into the transcript and notes. Audio never captured after the
premature stop cannot be reconstructed.

## Implemented behavior

1. **Uncertainty keeps recording.** Missing controls, AX timeouts, missing hosts,
   minimized windows, and hidden tabs cannot end an established recording.
   Explicit end evidence or continuously verified closure can; closure checks
   inspect other windows before deciding the bound tab is gone. Uncertain end
   events cannot stop or release either manual or automatic recording ownership.
2. **Captured content remains available.** Observation time is diagnostic only.
   Automatic boundaries require a confirmed end and never replace user-reviewed
   ranges. Optional boundary provenance preserves legacy decoding. “Review
   additional saved audio” opens the existing boundary editor without changing
   any old range until the user saves; rebuilds retain the existing evidence
   invalidation and manual-correction reconciliation behavior.
3. **Recovery lasts for the session.** Persisted intent distinguishes meeting
   capture from microphone-only recording and retains the app/room binding.
   `MeetingAudioRecovery` has one recording-owned loop: 0.5/1/2/4/8/15 seconds,
   then 30-second retries without an attempt limit. Verified detector events
   attach to the active recording before joining the lifecycle. Stop cancels
   work; generation checks reject stale attempts. A replacement browser host
   requires verification of the same call. Existing helper recovery preserves
   writers and the synchronized timeline. Missing callbacks rearm recovery;
   flowing silent buffers alone do not justify destructive retargeting.
4. **Failures stay visible.** The live health strip and menu-bar indicator show
   pending/missing sources, write errors, low disk space, and dropped buffers.
   A one-second watchdog uses five-second write freshness; denied notifications
   do not hide the persistent UI. Browser uncertainty includes the process-wide
   audio limitation and keeps the existing Stop controls available. A bounded
   `recording-health.json` retains transitions, attempts, dropped buffers, last
   observation, and completion. A capture-failure notice remains visible in the
   completed workspace even when transcription or summarization later fails.
5. **PCM survives encoder failure.** Each buffer attempts PCM independently of
   AAC. A failed primary sink is not reopened over existing audio. Live CAF and
   closed PCM checkpoints are separate sinks. Checkpoints close and synchronize
   around a two-second target at buffer boundaries, then save an atomic manifest
   with frame offsets, format, counts, hashes, and inserted-padding intervals. Reconstruction validates
   contiguous coverage, salvages a verified prefix, and preserves longer prior
   reconstructions if source chunks subsequently disappear. Corrupt, incomplete,
   or unmanifested coverage retains originals and a recovery notice. Redundant
   copies require complete AAC decoding and a 100 ms encoder tolerance. Startup
   failure/cancellation retains existing audio bytes; relaunch only repairs
   existing media and cannot authorize new recording.
6. **Capture precedes processing.** New jobs wait during recording. Running work
   yields at track/model phase boundaries, with completed results retained.
   Recording no longer starts model prewarm. Typed no-speech diarization results
   permit normal transcription of valid audio; other failures remain retryable.
   Empty transcripts say no speech was detected and retain playback/export.

## Privacy and storage

[PRIVACY.md](../../PRIVACY.md) and [DEVELOPMENT.md](../../DEVELOPMENT.md) describe the new
continuity policy. New starts still require positive call evidence. Recovery
cannot widen a known app/room binding or convert microphone-only intent into
system capture. Browser audio is process-scoped and may include other tabs in
that process when the call becomes unobservable; it is not tab-isolated audio.

Each 16 kHz mono float PCM copy consumes approximately 230 MB/hour per track.
The live CAF and checkpoints are temporary duplicate sources during healthy
capture. Recovery files stay in the meeting folder and follow meeting deletion;
no new network destination or retention exemption is introduced.

## Verification

Focused non-UI suites cover:

- The 122-second incident and 10-minute observation loss without stopping;
  missing hosts/controls, explicit end, and continuous positive closure grace.
- Attachment after the old deadline, event-driven wake, wrong app/room,
  microphone-only intent, and a canceled task resuming after a new generation.
- Successful writes versus missing buffers, full-range user edits, and metadata
  round trips.
- Forced primary failure with actual PCM sample-count/waveform assertions across
  a 90-second gap; lost/partial manifests; corrupt/missing checkpoints; retaining
  the only complete reconstruction; independent sink failure and safe cleanup.
- Durable queued processing waiting for capture without consuming retry attempts.

`bash Scripts/tests/audio-recovery-crash.sh` launches a synthetic writer, sends
SIGKILL with open containers, removes the growing CAF, and verifies exact samples
in every committed checkpoint interval. The hosted unit workflow runs it too.
The remote UI regression opens additional-audio review, cancels without changing
a legacy boundary, and checks that the capture warning remains visible beside
completed notes. UI tests must only run on hosted CI or a remote Mac.

## Limits and release gates

A two-second checkpoint target is not a guaranteed maximum loss bound. It occurs
at writer-buffer boundaries and cannot save callbacks never delivered, queued
buffers not yet written, or bytes rejected by a full/failed disk. The final open
checkpoint is recovered opportunistically. A process-kill test does not establish
power-loss durability; directory synchronization and hardware fault testing would
be required before making that claim.

An already executing inference call is not forcibly preempted. Before release,
run a remote two-source soak across helper/browser restarts, AirPods/USB changes,
sleep/wake, permission revocation, and disk pressure while earlier processing is
active. Compare recorded waveform coverage with injected signals, including gaps,
and validate the five-second health threshold on real devices. Verify the signed
installed build separately. Passing unit/CI tests or updating this PR alone does
not establish that these changes are installed or released.
