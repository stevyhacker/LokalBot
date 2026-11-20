# 0064. Windows and Linux: ai — notes

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-ai/src/notes/`.

## Decisions

### `LinuxWindows/crates/lokalbot-ai/src/notes/budget.rs`

#### Mirrors MeetingGenerationBudget.swift job allowance
The job allowance for one notes run (`MeetingGenerationBudget.swift`).

#### Standard limits cover four parts and grow with meeting length
`Limits.scales_with_parts`: Standard limits cover four meeting parts and grow with the meeting.

#### Time allowance assumes 35 output tokens per second
`TOKENS_PER_SECOND`: Output tokens per second the time allowance assumes.

#### standard_parts counts work in standard-size parts
`Budget::record_plan`: `standard_parts` counts the work in standard-size parts.

#### Share output tokens fairly across remaining parts, reserving one repair each
`Budget::allowance`: Output tokens for the next call: the desired amount, shared fairly with
the parts this run can still process (one repair reserved per part).

#### Unknown usage keeps the reservation; absence is never zero
`Budget::finish`: Unknown usage keeps the reservation; absence is never zero usage.

#### Time cap of 300 s at 35 tokens/s limits each part to about 3,500
`standard_limits_scale_with_long_meetings`: Three processable parts: 4,096 output tokens each, but 300 s at
35 tokens/s caps each at about 3,500.

### `LinuxWindows/crates/lokalbot-ai/src/notes/evidence.rs`

#### Model IDs are local to a snapshot; accepted records carry stable segment IDs
Compact evidence and its validation (`MeetingNotesEvidence.swift`).

Model IDs (`s#`, `p#`) are local to one transcript snapshot; accepted
records carry the stable `segment-…` IDs.

#### Evidence row format is s#|p#|text
`Unit`: One evidence row: `s#|p#|text`.

#### Rejected model record is queued for repair
`Rejection`: A record the model returned that did not pass a check, queued for repair.

#### Unresolved action replaced by a successful ownership repair
`Rejection.action_id`: An unresolved action that a successful ownership repair replaces.

#### Accepted records listed on continuation pages so the model doesn't repeat them
`Record`: An accepted record, listed on continuation pages so the model does not repeat it.

#### Narrative fact as reported speech of one speaker, mirrors SummaryClaimEvidence
`Claim`: A narrative fact, reported speech of one speaker (`SummaryClaimEvidence.Claim`).

#### Mirrors OutcomeTextSimilarity.normalized: folded alphanumeric words
`similarity_normalized`: `OutcomeTextSimilarity.normalized`: case- and diacritic-folded alphanumeric words.

#### Similarity is Jaccard of token sets at or above threshold
`is_similar`: Jaccard similarity of the token sets ≥ `threshold`.

#### Rendered sections per template, mirrors SummaryClaimEvidence.sections
`claim_sections`: Rendered sections per template (`SummaryClaimEvidence.sections(for:)`).

#### Allowed sections are template's plus Decisions and Open questions
`sections`: Sections the model may use: the template's plus Decisions and Open questions.

#### Maps p# model handle to canonical speaker key
`Evidence.speakers`: `p#` → canonical speaker key.

#### Drop suspected echo rows since the remote participant's row carries the words
`Evidence::new`: Suspected echo repeats a remote participant, whose own row carries the words.

#### User's own undertakings are flagged for the model
`Evidence::new`: The user's own undertakings are listed for the model.

#### Mirrors MeetingNotesGenerator.prompt
`Evidence::prompt`: The user prompt for some units (`MeetingNotesGenerator.prompt`).

#### Mirrors MeetingNotesEvidence.validate
`Evidence::validate`: `MeetingNotesEvidence.validate`.

#### Quote found verbatim in one cited row re-anchors the task there
`Evidence::validate`: A quote found word for word in one cited row re-anchors the task there.

#### Past or status reports are not pending tasks
`Evidence::validate`: A past/status report is not a pending task.

#### Returns user's key when the user speaks next turn after a request
`Evidence::user_reply`: The user's key when the user speaks the next turn after a request.

#### Model text becomes prose, rejected if it names a speaker ID
`Evidence::prose`: Model text as stored prose, or `None` when it names a speaker ID.

#### Drop copied source IDs and years nobody said; mirrors spokenDue
`spoken_due`: The due date as spoken, or "" (`MeetingNotesEvidence.spokenDue`): a copied
source ID or a year nobody said is dropped.

#### Mirrors MeetingNotesEvidence.schema
`schema`: `MeetingNotesEvidence.schema`.

#### Expected enum count 26 breakdown by field
`units_roster_and_prompt_follow_macos`: section 4 + source 3, then source 3 + context 3 + owner 4 + basis 4 + importance 5.

### `LinuxWindows/crates/lokalbot-ai/src/notes/mod.rs`

#### Per-part extraction with cited s# IDs, validation, repair, app-rendered Markdown
Meeting notes (`MeetingNotesGenerator.swift`, `MeetingNotesRecovery.swift`).

One extraction pass per transcript part yields notes, actions, decisions
and open questions. The model cites only `s#` row IDs; the app maps them
to stable segment IDs, checks every record against the cited speech,
repairs rejected records once or twice, and renders the Markdown itself.

#### summary.md holds header line then rendered sections
`MeetingNotes.summary_markdown`: `summary.md`: the header line, then the rendered sections.

#### summary-claims.json shape is version, transcriptRevision, claims
`MeetingNotes.claims`: `summary-claims.json`: `{version, transcriptRevision, claims}`.

#### Partial files saved when a checkpoint folder was given
`Incomplete`: Some parts could not be completed; partial files were saved when a
checkpoint folder was given.

#### Checkpoint after every part; None keeps everything in memory
`NotesOptions.checkpoint_dir`: The meeting folder: checkpoints after every part (`notes.parts.partial.json`)
and the partial files the UI can show. `None` keeps everything in memory.

#### User re-ask gives earlier stopped parts another scan
`NotesOptions.retrying_stopped_parts`: A person asked again: parts an earlier run stopped get another scan.

#### On-screen document titles are context only
`NotesOptions.screen_titles`: Titles of documents on screen during the meeting (context only).

#### Remove checkpoints only after final notes saved so a crash loses nothing
`remove_checkpoint`: Removes the checkpoint and partial files. Call it after the final notes are
saved, so a crash between the two can't lose the finished parts.

#### Mark likely echo so it is never shown or cited as evidence
`generate_meeting_notes_with`: Likely echo repeats a remote participant; the remote row carries those
words, so the echo is never shown or cited as evidence.

#### Time allowance assumes GPU decoding; CPU-only gets triple
`generate_meeting_notes_with`: The time allowance assumes GPU decoding; a CPU-only PC gets three times as long.

#### Header is title and date plus provenance line, from ProcessingPipeline.summarize
`header`: `# {title} — {date}` and the provenance line (`ProcessingPipeline.summarize`).

#### User notes plus meeting context capped at 2,400 characters, gated by settings
`context_items`: User notes, then the secondary meeting-context block (≤2,400 characters,
`MeetingGenerationContext`): the calendar title and invited names when
`meetingNotesUseCalendarContext` is on, the saved agenda when
`useCalendarAgenda` is on, and on-screen document titles.

#### Include scheduled title and invitee names, never email addresses
`calendar_lines`: The scheduled title and invited names; never email addresses.

#### Use native token counts else bytes bound context and bytes/3 plans parts
`prompt_size`: Native tokens when the server can count them; otherwise UTF-8 bytes bound
the context and bytes/3 plans part sizes.

#### Parts fit context, planning step and hosted schema enum limit; two-row overlap
`make_chunks`: Parts fit the context, the planning step, and a hosted server's limit on
schema enum values; neighbours overlap by two rows.

#### Truncated reply gets one larger retry except repairs; keep reply with more records
`request`: One structured call. A reply cut off at its limit gets one larger retry
(not for repairs); whichever holds more complete records is kept.

#### Transcript sent as context so prompt-caching servers reuse it
`request`: The transcript travels as context, so a server with prompt caching
(Anthropic) reuses it across this meeting's requests; every other
server gets it joined in front of the instruction as before.

#### None when even structured-output minimum cannot fit
`output_room`: The output room beside this request's input, or `None` when even the
structured-output minimum cannot fit.

#### Continuation ledger consumes output allowance; long ledger keeps newest records
`fitted_page`: A continuation's ledger comes out of the output allowance; a long one
keeps its newest records.

#### Repair context is plus-minus 2 rows for notes, plus-minus 8 for actions
`repair_evidence`: ±2 rows around a rejected note, ±8 around a rejected action.

#### Uncited user undertakings repaired by finishing nearby unclear task, else requesting action
`queue_missing_commitments`: Queue a repair for each user undertaking no user task cites: finish a
nearby owner-unclear task first, else ask for the missing action.

#### Ownership repairs keep task text fixed; replacement is atomic
`accept_ownership_repairs`: Ownership repairs keep each task's text fixed; replacement is atomic.

#### At most three extraction pages and two repair rounds per part
`generate_part`: At most three extraction pages and two rounds of repairs per part.

#### Empty output cannot certify a substantial untouched transcript
`generate_part`: Empty output cannot certify a substantial untouched transcript.

### `LinuxWindows/crates/lokalbot-ai/src/notes/ownership.rs`

#### Ownership mirrors Swift twins; identity comes from the cited row's voice
Whose task an action is, from the speech it cites (`SpokenUndertaking.swift`,
`OutcomeEvidencePolicy.swift`, `ActionOwnership.swift`).

Identity comes from the voice: the cited row's speaker as the transcript
attributes it. The model's owner, basis and quote are claims to check.

#### Word text is lowercased with straight apostrophes, no punctuation
`Word.text`: Lowercased, straight apostrophes, no surrounding punctuation.

#### Range is bytes within the row's own text
`Word.range`: Byte range in the row's own text.

#### Fillers and immediately repeated words are dropped from speaker rows
`words`: Words of one speaker's consecutive rows. Fillers and immediately repeated
words are dropped, so "I I have to" reads as "I have to".

#### Free-standing punctuation still closes the previous sentence
`words`: Free-standing punctuation still closes the sentence before it.

#### Cue range covers the subject and its undertaking verb
`Cue.words`: The subject and its undertaking verb ("i", "have", "to").

#### A bare acceptance's task is whatever was asked before
`Cue.names_no_task`: "I can do that", "Will do": the task is whatever was asked before.

#### Pattern for remarks about the conversation itself after I'll
`CONVERSATION_REMARK`: What a speaker says about the conversation itself, after "I'll".

#### cues returns every first-person undertaking, including refused ones
`cues`: Every first-person undertaking in `words`, refused or not.

#### Dropped subject at a sentence start still counts as a cue
`cues`: A dropped subject at a sentence start: "Still have to go through it", "Will do".

#### Bare that/it points at an earlier task; a named object names its own
`points_at_an_earlier_task`: "…do that", "…take it, but after lunch"; "…handle that migration" names its task.

#### A tag question after an undertaking still commits
`ends_in_question`: "I'll send it tomorrow, okay?" still commits.

#### I'll need you to... hands the work to someone else
`is_delegation`: "I'll need you to send it" hands the work to someone else.

#### Actor is another party's task in the same speech
`Actor`: Another party's task in the same speech: "you will send it", "Alice will review".

#### Modal length covers obligation or plan phrases like will, needs to
`modal_length`: Length of an obligation or plan at `index` ("will", "needs to", "is going to").

#### A passive names no actor
`modal_length`: A passive ("can be simplified") names no actor.

#### Alignment leads when the clause carries the task's leading verb
`Alignment.leads`: The clause carries the task's leading verb.

#### Quote matching tolerates casing and punctuation differences
`occurrences`: Where a model's quote occurs in `words`, tolerating casing and punctuation.

#### I can do that names no task of its own
`is_bare_acceptance`: "I can do that" names no task of its own.

#### Whole row being a conversation remark counts as management
`is_conversation_management`: The whole row is a remark about the conversation ("I'll be brief").

#### Negated only when every forward-looking sentence is a question or negation
`undertaking_is_negated_or_questioned`: Every forward-looking sentence of the row is a question or a negation.

#### Only a direct request to one listener counts
`is_second_person_request`: A direct second-person request to one listener.

#### A first-person undertaking anywhere in the text is a commitment
`is_commitment`: A first-person undertaking anywhere in the text.

#### Mirrors Swift OutcomeAttribution.RejectionReason
`RejectionReason`: Why an ownership claim was not accepted (`OutcomeAttribution.RejectionReason`).

#### Only quote-related rejections queue a repair
`RejectionReason::repair_reason`: The repair a rejection queues, if any.

#### Port of Swift OutcomeEvidencePolicy.resolve for one source row
`resolve_policy`: `OutcomeEvidencePolicy.resolve` for one source row.

#### Port of resolveTarget: request or assignment read from its row
`resolve_target`: `OutcomeEvidencePolicy.resolveTarget`: a request or assignment read from its row.

#### Quote's sentence must carry the speaker's own undertaking
`undertakes`: The sentence the quote sits in carries the speaker's own undertaking.

#### Owner is the speaker key; None for source or unknown
`Claim.owner`: Speaker key the model named, `None` for "source"/"unknown".

#### Anchor is the transcript index of the cited evidence row
`Finding.anchor`: Transcript index of the cited row the ownership evidence belongs to.

#### Port of Swift ActionOwnership deciding whose task an action is
`Ownership`: `ActionOwnership`: decides whose task an extracted action is.

#### Row text offered as evidence; None when outside the evidence
`Ownership.text`: Text a row offers as evidence; `None` when outside this evidence.

#### Commitment means the speaker's own unrefused one starts in this row
`Ownership::states_commitment`: The speaker's own unrefused commitment starts in this row.

#### Rival actors in one turn can split a mixed sentence
`Ownership::attribution_for`: "I'll prepare the policy, and you will send the measurements".

#### A bare acceptance answers an earlier request as its task
`Ownership::answers_primary`: "Could you send the draft?" / "Yeah, I can do that".

#### Fragment rows borrow the nearest earlier undertaking in the same turn
`Ownership::carried_undertaking`: The nearest undertaking earlier in the same turn, when the cited row
is a fragment of that speech.

#### A row without undertaking cannot back the model's claim alone
`the_voice_decides_a_commitment`: A row with no undertaking: the model's claim cannot stand alone.

### `LinuxWindows/crates/lokalbot-ai/src/notes/partial.rs`

#### Partial snapshot is revision-checked and never enters completed outcomes
A coherent, revision-checked snapshot for the meeting page
(`MeetingNotesPartial.swift`). Partial work never enters the completed
outcome index or replaces final notes.

#### Snapshot loads only for exact transcript unless final notes supersede it
`MeetingNotesPartial::load`: The snapshot for this exact transcript, unless final notes supersede
it, including when cleanup was interrupted after the final write.

### `LinuxWindows/crates/lokalbot-ai/src/notes/render.rs`

#### Markdown rendering mirrors Swift claim, synchronizer and merge types
Markdown from accepted records (`SummaryClaimEvidence.render`,
`MeetingSummaryOutcomeSynchronizer`, `MeetingOutcomesGenerator.merge`).

#### Claims render as reported speech with name and timestamp
`render_claims`: Sections of claims as reported speech: `- **Name:** text — [HH:MM:SS]`.

#### Recap outcome sections are replaced so they never disagree with cards
`synchronize`: Replaces (or appends) the outcome sections of `summary` with ones rendered
from `outcomes`, so the recap can never disagree with the cards.

#### Task text equal to its cited speaker's words is flagged
`repeats_its_source`: The task text is just its cited speaker's own words.

#### Deterministic cross-part deduplication mirrors Swift merge
`merge_outcomes`: Deterministic deduplication across parts (`MeetingOutcomesGenerator.merge`).

#### Interleave takeaways so first bullets span the whole meeting
`interleaving_tldr`: Every part's first takeaway, then every part's second, and so on, so
the first bullets span the whole meeting.

#### Fallback TL;DR of three source-linked facts when no part wrote one
`overview_claims`: Three source-linked facts for a TL;DR when no part wrote one.

### `LinuxWindows/crates/lokalbot-ai/src/notes/tests.rs`

#### Stub llama-server counts about four characters per token
`model`: A llama-server stand-in: `/tokenize` counts about four characters per token.

#### Snapshot stays until notes are saved; Mac decoder requires version
`one_pass_renders_notes_outcomes_and_header`: The snapshot stays until the caller has saved the notes, so a crash in
between can't lose the finished parts. The Mac's decoder requires `version`.

#### Later final notes supersede snapshot even if cleanup was interrupted
`one_pass_renders_notes_outcomes_and_header`: Final notes written later supersede it, even if cleanup was interrupted.

#### Automatic rerun keeps the stop; a person's retry scans again
`provider_failures_leave_partial_checkpoints`: An automatic rerun keeps the stop; a person's retry scans again.

### `LinuxWindows/crates/lokalbot-ai/src/notes/view.rs`

#### View is the transcript as notes pipeline reads it, with s# IDs
The transcript as the notes pipeline reads it (`Transcript.swift`,
`SpeakerAttribution.swift`): normalized text, resolved attribution, the
speaker roster, stable segment IDs and the short `s#` citation IDs.

#### Mirrors Transcript.normalizedText: control tokens stripped, empty without alphanumerics
`normalized_text`: `Transcript.normalizedText`: control tokens removed, whitespace collapsed,
empty when nothing alphanumeric remains.

#### Delegates to the Swift defaultSpeakerName equivalent
`default_speaker_name`: `Transcript.defaultSpeakerName(for:)`.

#### Mirrors legacy attribution with microphone default applied
`resolved_attribution`: `SpeakerAttribution.legacy(speaker:).applyingMicrophoneDefault`.

#### Label is You or name with identity-unconfirmed/other-speaker suffix
`Speaker::label`: "You", or the name with "(identity unconfirmed)" / "(other speaker)".

#### Mixed voices and suspected echo cannot outvote the speaker
`View::new`: Mixed voices and suspected echo cannot outvote the speaker.

#### s# citation IDs are one-based segment indexes
`View::index_of`: The segment a `s#` citation ID names.

#### Long segments split at word boundaries keep their s# id
`View::prompt_turns`: One prompt turn per piece of each non-empty segment; a segment longer
than `max_characters` is split at word boundaries, each piece keeping
the segment's `s#` (`summaryPromptTurns`).

#### Revision hash differs from Swift's bytes, so it is port-local
`evidence_revision`: SHA-256 over the transcript's sorted-key JSON: identifies the evidence a
summary or checkpoint was made from (`Transcript.evidenceRevision`; the
bytes differ from Swift's encoder, so the value is local to this port).

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
