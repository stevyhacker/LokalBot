# Transcription and summary attribution plan

8 September 2026. Approved scope from the source inspection of `cefea2d`. See the [implementation and validation report](../reports/transcription-summary-attribution-validation-2026-09-08.md) for delivery evidence and open release gates.

Another participant's statement must not become the user's statement merely because it arrived through the microphone or contains first-person language. Unresolved speech and ownership remain visible and reviewable. Explicit requests directed to the user remain actionable even when another participant speaks them.

## 1. Ownership follows evidence

Remove first-person wording as an ownership signal in extraction, decoding, indexing, and rendering. Preserve explicit non-user ownership. Contradictory metadata produces an unresolved owner. Legacy records may use unambiguous stored ownership with legacy provenance, but prose cannot establish identity. Manual ownership corrections remain authoritative.

Validate production parsing, save/reopen, action lists, and summary synchronization with remote first-person speech, contractions, duplicate names, an alias named "Me", explicit user work, missing flags, and conflicting fields. Supported user actions remain complete; retain the existing five-item limit for other owners.

## 2. Microphone source is separate from identity

Version transcript provenance so source track, acoustic speaker, identity state, and attribution method remain separate from ASR confidence. Preserve old records as legacy assumptions. Carry stable meeting-local speaker references into prompts, persisted corrections, and derived artifacts.

Diarize microphone and system audio before transcription. Transcribe bounded audio turns rather than assigning mixed text blocks to a dominant speaker. Overlap, unclassified audio, and unreliable identity remain unresolved. Live microphone text is provisional local speech.

Offer playback and "This is me" for a supported acoustic cluster. Reuse revision-checked corrections, turn anchors, and the encrypted profile store. Explicit confirmation can enroll eligible microphone samples only when remembering is enabled; automatic guesses cannot train profiles. Keep microphone and system voice domains separate. Remote visual evidence continues to use independent remote acoustic turns.

Confirming one person must not relabel another local person or overlapping speech. Support microphone-only meetings, restart, retranscription, label reordering, and concurrent processing. Automatic microphone recognition remains disabled until held-out microphone evaluation meets the precision gate below.

## 3. Echo handling preserves uncertain speech

Keep AEC before ASR and preserve the original recordings. Record both writer clocks after successful audio writes so alignment accounts for startup offsets, interrupted capture, recovery silence, and device changes. Recheck alignment in bounded windows over long recordings.

Persist per-run status: disabled, no reference, applied, uncertain, or failed. Echo results cannot establish user identity. Preserve existing settings. Expose unavailable or uncertain echo processing in the meeting view.

Text similarity alone cannot justify deleting repetitions, acknowledgments, or quiet replies. A duplicated phrase in mixed speech may be removed only with sufficiently precise word and waveform evidence; otherwise retain the words with uncertain attribution and source timing.

## 4. Ground narratives and repair selected meetings

Store owner speaker reference, resolution, ownership basis, exact supporting quote, and source IDs. Validate self-commitments against the resolved source speaker. Requests and assignments require an explicit target; they remain requests unless acceptance is evidenced. Ambiguous pronouns and unsupported ownership stay under "Owner unclear" with source playback.

Carry attributed claims and citations through direct summaries, chunk extraction, deduplication, and synthesis. The TL;DR and key points need speaker evidence as well as decisions and action cards. Resolve identity before applying user-oriented wording; aliases cannot establish identity.

Identity or transcript changes invalidate summaries, outcomes, checkpoints, and derived search/day evidence. Provide summary/outcome repair without ASR when transcript attribution is already correct; otherwise correct or retranscribe first. Transfer completion, manual text/owner edits, and due corrections only through an unambiguous action match. Preserve unmatched edits for review.

## Delivery and validation

Deliver ownership correction, the attribution contract, microphone/echo processing, and grounded repair in that order. Keep deterministic correctness, model accuracy, audio quality, and performance evidence separate.

Use annotated fixtures covering speakers/headphones, two people sharing a microphone, quiet speech, repetitions, short replies, overlap, mixed echo/replies, changed ASR wording, long meetings, drift, microphone modes, device switches, and missing/failed system capture. Include genuinely user-owned work so suppressing every user action cannot count as success.

Report every gate independently: wrongful user attribution; genuine-word loss; ASR word error; owner precision and recall; unresolved coverage; processing time; peak memory; and hosted UI results. Automatic microphone identity requires 99% precision with a one-sided 95% lower bound on held-out microphone recordings, including unenrolled people and separate enrollment/query meetings with speaker/meeting correlation accounted for. Thresholds and coverage remain unvalidated until measured.

Run native non-UI tests, lint, and app/CLI compilation locally. Run UI automation and staged capture on hosted CI or a remote Mac. An unmeasured gate remains open and prevents a release-readiness claim.
