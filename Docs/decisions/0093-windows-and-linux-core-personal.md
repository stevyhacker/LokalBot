# 0093. Windows and Linux: core — personal

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-core/src/personal/`.

## Decisions

### `LinuxWindows/crates/lokalbot-core/src/personal/access.rs`

#### Personal grant: marker plus plaintext copy of shared claims; failures remove it
The Personal context grant (`PersonalContextAccessGate`,
`PersonalContextAccessManager`): a marker under `control/` plus a plaintext
copy of only the claims the person shared, so the CLI and MCP can answer
without the app running and without reading the encrypted model. Every
failure removes the shared copy rather than leaving a stale one.

#### Turning the grant off removes the shared copy so nothing lingers
`set_enabled`: Turns the grant on (and leaves the copy to [`refresh`]) or off, which removes
the shared copy too, so nothing lingers on disk.

#### Unreadable model shares nothing; errors are returned for Settings
`refresh`: Rewrites the shared copy from `current`; `None` means the personal model
couldn't be read, so nothing is shared until it can be. Returns what went
wrong, for Settings.

#### Skip rewrite when claims equal; answers stamp last-used time agents never see
`refresh`: Answers stamp the last-used time, which agents never see.

### `LinuxWindows/crates/lokalbot-core/src/personal/controller.rs`

#### Single owner of personal model: sealed file, refused edits, evidence retraction
The one owner of the personal model (`PersonalModelController`,
`PersonalModelStore`). Ask reads and adds claims through it; Settings →
Personal Context edits them; the overnight review adds learned ones. Nothing
touches the credential store until first use. If the saved file can't be read,
every edit is refused instead of overwriting it. Learned claims are checked
against the evidence revisions on every use: a deleted or corrected source
retracts them, and while a revocation is pending they are withheld.

`memory/personal-model.json.enc` is sealed under the `chat-key`. A plaintext
`memory/personal-model.json` (demo seeds, upgrade fixtures) is accepted and
re-sealed on the next save; a sealed copy wins over a plaintext one.

#### Unreadable files error rather than read empty, so nothing is overwritten
`Personal::read_file`: The saved model; empty when nothing was ever saved. Errors instead of
returning empty for anything unreadable, so nothing is saved over it.

#### Reload for when the key has only just become available
`Personal::reload`: Reads the file again, for when the key has only just become available.

#### Kept items are newest first, the order Settings shows
`Personal::kept`: Kept items, newest first, the order Settings shows.

#### Scoped Ask excludes evidence-backed claims to respect the source boundary
`Personal::usable_claims`: Confirmed claims safe to put in a prompt now. Scoped Ask questions pass
`include_evidence_backed: false`: like work memory, learned claims would
carry meeting content past the question's source boundary.

#### Changed sources keep claims while the quote exists; false while revocation pending
`Personal::retract_invalidated`: Learned claims whose source changed keep their place while that source
still has the line they quote, and are retracted once it doesn't. False
when evidence can't be checked (a revocation is pending), so callers
withhold evidence-backed claims meanwhile.

#### Unloaded model needs no cleanup since every read checks evidence
`Personal::retract_if_loaded`: After a meeting is deleted or corrected. Every read checks evidence
anyway, so an unloaded model has nothing to clean yet.

#### Check reads only that meeting transcript, day's agent requests or work memory
`Personal::source_still_quotes`: Does the source still have the line the claim quotes, as the person's own
words? Reads only that meeting's transcript, that day's agent requests, or
work memory.

#### Facts and goals saved, preferences suggested; expired suggestions and tombstones pruned
`Personal::learn`: The review's findings: facts and goals are saved, preferences become
suggestions. Expired suggestions and tombstones are pruned.

#### Goals and projects kept for weeks are suggested
`Personal::promote_work_memory`: Suggests goals and projects the review has kept for weeks.

#### Deleting a conversation retracts its learned claims; reads file only if present
`Personal::retract_learned_from_conversation`: Deleting an Ask conversation takes back what was learned from it. Only
reads the file when there may be something to take back.

#### Forget all removes both copies even when unopenable
`Personal::forget_all`: Forget everything: both copies, even when they can't be opened.

#### Agents are offered only confirmed claims with valid evidence
`Personal::agent_eligible`: The claims agents may be offered: confirmed, with evidence still valid.

#### At launch the shared copy follows the grant: on writes, off removes
`Personal::start_access`: Keeps the shared copy in step at launch: on writes it, off removes it.

#### Mirrors PersonalContextSettings.metaLine on macOS
`meta_source`: `PersonalContextSettings.metaLine`: where an item came from and the day.

### `LinuxWindows/crates/lokalbot-core/src/personal/dictation_log.rs`

#### Dictation buffer: raw words, redacted, sealed, two-day cap, off deletes it
What the person dictated into other apps, kept only for the overnight learning
pass (Learn from my dictation, off by default). Raw spoken words only, never
Compose's drafts, with card numbers and IBANs redacted. Sealed with the
`chat-key` in `memory/dictation-for-learning.json.enc`. Each entry goes once
the pass has read its day and never lasts more than two days; turning the
setting off deletes the file (`DictationLearningLog`).

#### After the learning pass, drop that day and earlier
`DictationLog::remove_through`: After the learning pass for `day`: drops that day and everything before.

#### Unreadable file reads empty: short-lived buffer replaced on next save
`DictationLog::current`: Unexpired entries. An unreadable file reads as empty: it is a short-lived
buffer, and the next save replaces it.

### `LinuxWindows/crates/lokalbot-core/src/personal/learning.rs`

#### Learning reads only first-person own lines; other speakers never included
The deterministic half of the overnight learning pass (`PersonalLearning`):
which of the person's own lines from a day may be read. The model call and
the grounding checks are in `lokalbot-ai`. Lines without a first-person word
are never sent; other speakers' lines are never included.

#### Typed lines share the budget but never crowd out meetings
`MAX_TYPED_UTTERANCES`: Typed lines share the budget but never crowd meetings out.

#### The handle is what the model cites
`Utterance`: One line of the person's own words. `handle` is what the model cites.

#### Counts first-person words in English and Serbian
`self_reference_score`: How many first-person words a line has (English and Serbian).

#### Older transcripts follow My microphone is me
`is_own_speech`: Older transcripts follow "My microphone is me".

#### Keys like local 1 are one diarized voice told apart
`is_numbered_voice`: "local 1", "source2:local 3": one voice diarization told apart.

#### Own-turn selection: confirmed voice wins, dominant voice 4x, else skip meeting
`own_turns`: Joins consecutive segments of the person's own speech into turns. A voice they
confirmed as theirs wins. Otherwise, when diarization found several voices on
the microphone, the meeting counts only if one dominates (four times the next),
and then only that voice is used; with no clear winner the microphone was
shared and the meeting is skipped.

#### Fold letters and digits so dictation matches the request it was pasted into
`folded_for_duplicate`: Letters and digits only, case- and accent-folded, so a dictation and the
request it was pasted into compare equal despite punctuation.

#### Typed lines exclude scheduled runs and Remember messages; dictations deduped against requests
`typed_lines`: The day's typed lines: requests sent to coding agents (scheduled runs
excluded), questions asked in Ask, and dictation kept for learning. A
"Remember …" message is already saved, so it is skipped, and a dictation that
became one of those requests is read once, from the request.

#### Most self-descriptive lines chosen within budget, then reordered with handles
`utterances`: The person's turns from `day`'s meetings and what they typed, most
self-descriptive first within the budget, then put back in order with handles.

#### Dictated lines excluded from fingerprint since they are deleted once read
`fingerprint`: What the pass read for a day, independent of order and handles. Dictated lines
are left out: they are deleted once read, so a later review of the same day
would otherwise always look changed.

#### Quote matching ignores case, accents, punctuation and truncation
`quote_still_said`: Whether `lines` still contain the line a learned claim quotes, ignoring case,
accents, punctuation and where a long line was cut off.

### `LinuxWindows/crates/lokalbot-core/src/personal/mod.rs`

#### Personal context privacy: who reads the model and what never does
Personal Context (`Services/PersonalModel/*`, `CLISupport/PersonalContextAccess.swift`):
what the person told LokalBot about themselves, and what it learned from their
own words. Saved claims are the person's; learned ones carry the source they
came from and retract with it. Principles are never learned.

`memory/personal-model.json.enc` is private by default. Ask and Quick Recall
read it; external agents get only items marked for them, through the plaintext
copy in `control/personal-context.json`, and only while that grant is on.
Agent Mode, Autocomplete, notes, exports and diagnostics never read it.

#### Only obvious English openings recognized; principles never guessed
`ClaimKind::suggested`: A starting kind for a statement typed in Ask. Only obvious English
openings are recognized; principles are never guessed.

#### Swift encodes cases as case-keyed objects, empty braces for fieldless cases
`Origin`: Where a claim came from. Swift encodes these as `{"case":{...}}`, with `{}`
for a case without fields.

#### Dictated words are kept only until the night's pass
`TypedSource::Dictation`: Words dictated into another app, kept only until the night's pass.

#### Default sharing is Ask and Quick Recall only
`Sharing::LokalBotOnly`: Ask and Quick Recall only. The default for every claim.

#### Agents see a claim only while the Personal context grant is on
`Sharing::Agents`: Also external agents, while the Personal context grant is on.

#### Proposed suggestions await review and are never used
`Status::Proposed`: A learned suggestion waiting for review; never used.

#### Always-use claims go first in every eligible prompt
`Claim.always_use`: Included first in every eligible prompt, ahead of relevance ranking.

#### None means the claim has no evidence dependency
`Claim.evidence`: What a learned claim came from. `None` means no evidence dependency.

#### Dictated words vanish once read, so nothing can retract the claim
`Claim::has_removable_source`: Dictated words are gone once read, so nothing can retract the item.

#### Mirrors PersonalContextSettings.keepLabel on macOS
`Claim::keep_label`: `PersonalContextSettings.keepLabel`.

#### Mirrors PersonalContextProjection source strings on macOS
`Claim::projection_source`: `PersonalContextProjection.Claim`'s source string.

#### App and CLI rank items with the same PersonalContextSelection rules
`ContextItem`: `PersonalContextSelection`'s view of an item, so the app (all claims) and the
CLI (the shared copy) rank with the same rules.

#### Folded 3+ letter words minus stopwords, any script incl. Serbian Cyrillic
`content_words`: Case- and diacritic-folded words of three or more letters, minus stopwords.
Works for any script, so Serbian Latin and Cyrillic match themselves.

#### Context order: always-use, principles and preferences, matching facts, rest
`ordered`: `PersonalContextSelection.ordered`: always-use items, then principles and
preferences, then facts and goals sharing words with the query (most shared
first), then the rest; newest first within each step.

#### Stable sort keeps newest first among ties
`ordered`: A stable sort keeps newest first among ties.

#### Over-long text is refused, not cut, since a cut can drop a negation
`EditError`: Why an item can't be kept. Over-long text is refused rather than cut: a cut
sentence can drop a negation.

#### Forgotten claims are remembered only as a one-way hash
`Tombstone`: A forgotten learned claim or a dismissed suggestion, as a one-way hash.

#### None only for Ask questions, which retract with their conversation
`LearningCandidate.evidence`: `None` only for Ask questions, which retract with their conversation.

#### Typed, work-memory or cross-language-grounded items wait for review
`LearningCandidate.needs_review`: From typing, work memory, or grounded only by meaning across languages:
even a fact or goal waits for review.

#### Case, width and diacritic-insensitive key merges duplicates
`duplicate_key`: Case-, width- and diacritic-insensitive key used to merge duplicates.

#### Models restate known items, so reworded duplicates are detected by shared words
`is_near_duplicate`: The same thing reworded: most content words of the shorter text appear in
the other. Models restate known items despite being told not to.

#### Adding refreshes same-text claim; saved claims never evicted
`PersonalModel::add`: Adds a claim, or refreshes the one with the same text. Saved claims are
never evicted to make room.

#### Restating a learned claim makes it the person's own statement
`PersonalModel::add`: Saying what LokalBot learned makes it the person's statement.

#### Editing into another claim merges them, edited one stays
`PersonalModel::update`: Editing into another claim merges them: the edited one stays.

#### Forgetting learned claims leaves tombstone; stated claims leave nothing
`PersonalModel::remove`: Forgetting a learned claim leaves a tombstone so tomorrow's review
doesn't learn it again; stated claims leave nothing behind.

#### Source deletion leaves no tombstone so evidence can be relearned
`PersonalModel::retract`: Source deletion or correction: the claim goes, with no tombstone, so it
can be learned again from evidence that still exists.

#### Deleting a conversation retracts learned claims unless kept as statement
`PersonalModel::retract_learned_from_conversation`: Deleting an Ask conversation takes back what was learned from the
questions in it, unless the person kept it as their own statement.

#### Changed source still quoting claim: update revision instead of retracting
`PersonalModel::refresh_evidence`: The source changed but still has the line a claim quotes: tie the claim
to the current revision instead of retracting it.

#### Learning rules: facts, goals saved; preferences wait; principles never; skip lists
`PersonalModel::learn`: Facts and goals are saved and used at once; preferences, and items that
need review, wait; principles are never learned. Duplicates, forgotten or
dismissed text, invalid text and anything past the limits are skipped.

#### Person vouches for claim, so it no longer depends on its source
`PersonalModel::keep_as_statement`: The person vouches for a learned claim: it no longer depends on its source.

#### After these triggers a question word means asking about the past
`QUESTION_CHECKED_TRIGGERS`: After these a question word means the message asks about the past.

#### Mirrors RememberIntent.parse; English and Serbian; questions never remember
`remember_statement`: `RememberIntent.parse`: the statement to remember, or `None` when the message
isn't a request to remember something (including every question about the
past). Recognizes English and Serbian, Latin and Cyrillic.

#### Claims that exceed the budget are skipped, not cut
`select_context`: The smallest useful slice, as a prompt block. Claims that don't fit the budget
are skipped, not cut.

### `LinuxWindows/crates/lokalbot-core/src/personal/promotion.rs`

#### Work-memory promotion: 14 days seen, last 7, no model, needs review
Suggests long-running work as Personal Context items (`WorkMemoryPromotion`).
The review keeps short-lived work memory; a goal or project it keeps seeing
for two weeks or more, and saw in the last week, says something durable about
the person. No model call. Every promotion waits for review and depends on the
review's evidence.

#### Records first sightings, forgets dropped items, returns qualifying ones
`promotion::evaluate`: Records when each current goal and project was first seen, forgets ones the
memory no longer holds, and returns those that qualify.

### `LinuxWindows/crates/lokalbot-core/src/personal/tests.rs`

#### Test fixture is personal-model.json as macOS JSONEncoder writes it
`MAC_MODEL`: `memory/personal-model.json` as the Mac's `JSONEncoder` writes it.

#### Tombstones last 180 days, unreviewed suggestions 14
`forgetting_leaves_a_180_day_hash_so_it_isnt_learned_again`: Tombstones last 180 days; unreviewed suggestions 14.

#### Pending revocation withholds learned items
`scoped_questions_get_only_what_the_person_stated`: While a revocation is pending, learned items are withheld.

#### Retraction leaves no tombstone so it can be relearned
`a_learned_item_goes_when_its_meeting_is_deleted_unless_kept`: No tombstone: it can be learned again from evidence that still exists.

#### Asserted JSON fields are what the macOS decoder needs
`agents_see_only_shared_items_and_only_while_the_grant_is_on`: What the Mac's decoder needs.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
