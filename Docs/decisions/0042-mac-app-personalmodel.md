# 0042. Mac app: PersonalModel

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Services/PersonalModel/`, `LokalBotTests/Services/PersonalModel/`.

## Decisions

### `LokalBot/Services/PersonalModel/DictationLearningLog.swift`

#### Dictation kept for overnight learning: raw, redacted, sealed, max two days
`DictationLearningLog`: What the person dictated into other apps, kept only for the overnight
learning pass (Personal Context → Learn from my dictation, off by default).
Raw spoken words only, never Compose's drafts, with card numbers and IBANs
redacted. Sealed with the `chat-key` like the personal model, 0600. Each
entry goes once the pass has read its day, and never lasts more than two
days; turning the setting off deletes the file.

#### Append drops expired entries and oldest beyond the cap
`DictationLearningLog.append`: Adds one dictation, dropping expired entries and the oldest beyond the cap.

#### After learning pass drop that day, earlier, and expired entries
`DictationLearningLog.removeEntries`: After the learning pass for `day`: drops that day and everything
before it, and anything expired.

#### Unreadable file reads as empty; short-lived buffer replaced on next save
`DictationLearningLog.current`: Unexpired entries. An unreadable file reads as empty: it is a
short-lived buffer, and the next save replaces it.

#### Surface read once after paste, only while learning on; held in memory
`DictationLearningSurface`: The window and page a dictation was pasted into, read once right after the
paste and only while Learn from my dictation is on. Held in memory to
decide whether to keep the words, then dropped.

#### Same exclusions as nearby-text context, plus never LokalBot itself
`DictationLearningPolicy`: Which dictations may be kept for learning: the same app, website, and
private-window exclusions as nearby-text context, plus never LokalBot itself
(Ask questions are read from the conversation).

#### Browser with unreadable address is not kept; website exclusions unverifiable
`DictationLearningPolicy.permits`: A browser whose page address can't be read can't be checked against
the website exclusions, so its dictation is not kept.

### `LokalBot/Services/PersonalModel/PersonalClaim.swift`

#### Claims are stated or learned with meeting evidence; principles are never learned
`PersonalClaim`: One thing LokalBot knows about the person: a fact about them, how they want
help, a goal, or a principle they decide by
(Docs/designs/personal-world-model-rfc-2026-10-14.md). Stated claims are the
person's own words. Learned claims come from what the person said in a
meeting; they carry that meeting as evidence and retract with it.
Principles are never learned.

#### Said origin means a Remember message typed in Ask or Quick Recall
`PersonalClaim.Origin.said`: "Remember …" typed in Ask or Quick Recall.

#### Added origin means entered in Settings Personal Context
`PersonalClaim.Origin.added`: Added in Settings → Personal Context.

#### Learned origin is picked up overnight from the person's own meeting line
`PersonalClaim.Origin.learned`: Picked up overnight from the person's own line in this meeting.

#### Typed origin is picked up overnight from what the person typed that day
`PersonalClaim.Origin.typed`: Picked up overnight from something the person typed that day.

#### Work-memory origin is a goal or project kept for weeks; day is first seen
`PersonalClaim.Origin.workMemory`: A goal or project the overnight review kept for weeks; the day
is when it was first seen.

#### Coding-agent source is a Claude Code or Codex request saved by session reading
`PersonalClaim.TypedSource.codingAgent`: A request to Claude Code or Codex, saved by Read coding agent sessions.

#### Ask source is a question asked in Ask or Quick Recall
`PersonalClaim.TypedSource.ask`: A question asked in Ask or Quick Recall.

#### Dictation lines are kept only until the night's pass reads them
`PersonalClaim.TypedSource.dictation`: Words dictated into another app, kept by Learn from my dictation
only until the night's pass read them.

#### Sharing says who may read a claim besides LokalBot itself
`PersonalClaim.Sharing`: Who may read the claim besides LokalBot itself.

#### LokalBot-only sharing covers Ask and Quick Recall and is the default
`PersonalClaim.Sharing.lokalBotOnly`: Ask and Quick Recall only. The default for every claim.

#### Agents sharing also reaches external agents while the Personal context grant is on
`PersonalClaim.Sharing.agents`: Also external agents, while the Personal context grant is on.

#### Confirmed claims are used by Ask and, if shared, by agents
`PersonalClaim.Status.confirmed`: In use by Ask and, if shared, agents.

#### Proposed claims wait for review and are never used
`PersonalClaim.Status.proposed`: A learned preference waiting for the person's review; never used.

#### Stated authority covers the person's own statement or one they kept
`PersonalClaim.Authority.stated`: The person stated it or kept it as their own statement.

#### Learned authority is saved automatically from what the person said in a meeting
`PersonalClaim.Authority.learned`: Saved automatically from what the person said in a meeting.

#### Confirmed authority means learned, then confirmed by the person in review
`PersonalClaim.Authority.confirmed`: Learned, then confirmed by the person in review.

#### Always-use claims go first in every eligible prompt, ahead of ranking
`PersonalClaim.alwaysUse`: Included first in every eligible prompt, ahead of relevance ranking.

#### Nil evidence means no dependency on a meeting (stated or kept claims)
`PersonalClaim.evidence`: The meeting a learned claim came from. Nil means no evidence
dependency (stated claims, or a learned one the person kept).

#### Quote is the person's own line the claim came from, shown in review
`PersonalClaim.quote`: The person's own line the claim was learned from, shown in review.

#### Learned means not stated, even if later kept or restated via authority
`PersonalClaim.isLearned`: Learned automatically rather than stated (it may since have been
kept or restated, which `authority` records).

#### Fields added after Phase 1 default so older claims stay confirmed, stated, LokalBot-only
`PersonalClaim.init(from:)`: Fields added after Phase 1 decode with defaults that keep earlier
behavior: an older claim is a confirmed, stated, LokalBot-only one.

#### Only obvious English openings suggest a kind; principles are never guessed
`PersonalClaimKind.suggested`: A starting kind for a statement typed in Ask. Only obvious English
openings are recognized; principles are never guessed, because the
person decides what counts as one of their values.

#### PersonalModel is a pure value type; store persists, controller publishes
`PersonalModel`: The person's claims plus the rules every edit goes through. Pure value
type: the store persists it and the controller publishes it.

#### Forgotten or dismissed text is kept only as a one-way hash
`PersonalModel.Tombstone`: A forgotten learned claim or a dismissed suggestion, kept only as a
one-way hash so the same text isn't learned again.

#### Work sightings hash text with first-seen day so weeks-long items can be suggested
`PersonalModel.WorkSighting`: When a work-memory goal or project was first seen, as a hash of its
text, so one that lasts for weeks can be suggested.

#### Learned days store a line hash; pass reruns only when person's own lines change
`PersonalModel.LearnedDay`: A day the overnight learning pass has read, and a hash of the lines it
read. The review rebuilds days whenever their sources change; the pass
runs again only when the person's own lines did.

#### Changed source that still quotes the line refreshes evidence instead of retracting
`PersonalModel.refreshEvidence`: The source of a learned claim changed but still has the line it
quotes: tie the claim to the current evidence revision instead of
retracting it.

#### Over-long claim text is refused, not truncated, because cuts can drop a negation
`PersonalModel.validatedText`: Prompt-safe text, or why it can't be kept. Over-long text is refused
rather than truncated: a cut sentence can drop a negation.

#### Same text refreshes the existing claim; saved claims are never evicted
`PersonalModel.add`: Adds a claim, or refreshes the existing one when the same text is
already remembered. Saved claims are never evicted to make room.

#### Saying a learned claim makes it the person's stated claim
`PersonalModel.add`: Saying what LokalBot learned makes it the person's statement.

#### Editing into an existing claim keeps the edited one and drops the duplicate
`PersonalModel.update`: Editing into an existing claim merges them: keep the edited
one, drop the older duplicate.

#### Forgetting a learned claim leaves a tombstone; stated claims leave none
`PersonalModel.remove`: Forgetting a learned claim leaves a tombstone so tomorrow's review
doesn't learn it again; stated claims leave nothing behind.

#### Retraction leaves no tombstone so claim can be relearned from surviving evidence
`PersonalModel.retract(ids:)`: Source deletion or correction: the claim goes, with no tombstone, so
it can be learned again from evidence that still exists.

#### Deleting an Ask conversation retracts claims learned from it unless stated
`PersonalModel.retract(learnedFromConversation:)`: Deleting an Ask conversation takes back what was learned from the
questions in it, unless the person kept it as their own statement.

#### Quote is the person's own words; nil for work memory
`PersonalModel.LearningCandidate.quote`: The person's own words it came from; nil for work memory.

#### Nil evidence only for Ask questions, which retract with their conversation
`PersonalModel.LearningCandidate.evidence`: Nil only for Ask questions, which retract with their conversation.

#### Typing, work memory and cross-language-only grounding force review even for facts
`PersonalModel.LearningCandidate.needsReview`: From typing, from work memory, or grounded only by meaning across
languages: even a fact or goal waits for the person's review.

#### Facts and goals save at once; preferences wait; principles never learned
`PersonalModel.learn`: Facts and goals are saved and used at once; preferences, and items
grounded only by meaning across languages, wait for review;
principles are never learned. Duplicates, forgotten or
dismissed text, invalid text, and anything past the limits are skipped.

#### Near-duplicate at 70% word overlap because models restate known items
`PersonalModel.isNearDuplicate`: The same thing reworded: most content words of the shorter text appear
in the other. Models restate known items despite being told not to.

#### Dismissing a suggestion removes it and it won't be suggested again
`PersonalModel.dismiss`: Dismissing a suggestion: it goes and won't be suggested again.

#### Keeping as statement drops meeting dependency so deleting the meeting keeps it
`PersonalModel.keepAsStatement`: The person vouches for a learned claim: it no longer depends on the
meeting, so deleting that meeting keeps it.

#### Remember intent recognized in English and Serbian only; Settings Add is any language
`RememberIntent`: Recognizes "Remember …" messages typed in Ask, in English and Serbian
(Latin and Cyrillic). Pure; Settings → Add works in any language.

#### Question word after a trigger means asking about the past, not stating
`RememberIntent.questionCheckedTriggers`: After these triggers a question word means the message asks about
the past ("remember when …", "zapamti da li …") rather than stating
something to keep.

#### Parse returns nil for non-requests, including every question about the past
`RememberIntent.parse`: The statement to remember, or nil when the message is not a request
to remember something (including every question about the past).

### `LokalBot/Services/PersonalModel/PersonalContextAccessManager.swift`

#### Shared claims projection is kept in sync and removed on any failure, never stale
`PersonalContextAccessManager`: App-side owner of the Personal context grant (Settings → External Agents). While it
is on, the app keeps `control/personal-context.json` in step with the
claims the person shared, so `lokalbot-cli` and its MCP server can answer
without the app running and without reading the encrypted personal model.
Every failure removes the shared copy rather than leaving a stale one.

#### Nil claims means unreadable model, so nothing is shared
`PersonalContextAccessManager.refresh`: Rewrites the shared copy from `current`; nil means the personal model
couldn't be read, so nothing is shared until it can be.

#### Skip projection rewrites caused only by lastUsedAt, which agents never see
`PersonalContextAccessManager.refresh`: Answers stamp lastUsedAt, which agents never see; skip those rewrites.

### `LokalBot/Services/PersonalModel/PersonalContextBuilder.swift`

#### Selection is deterministic; claims over the budget are skipped, not truncated
`PersonalContextBuilder`: Picks the smallest useful slice of the personal model for one question and
renders it as a prompt block. Pure and deterministic, so the same inputs
always produce the same prompt and the selection is testable offline.

Priority follows `PersonalContextSelection`, the same order agents get;
the question and the person's previous two messages are the query.
Claims that don't fit the character budget are skipped, not truncated.

### `LokalBot/Services/PersonalModel/PersonalLearning.swift`

#### Overnight pass reads only the person's own words, max three grounded items
`PersonalLearning`: The overnight learning pass (personal world model, Phase 3). After the
day's review, it reads only the person's own words from that day: their
lines in meetings, what they typed to coding agents or in Ask, and, when
Learn from my dictation is on, what they dictated into other apps. It asks
the Think model for at most three durable things about them. Every result
must point at one of those lines and be grounded in it; anything else is
dropped. Facts and goals from meetings are saved; preferences, and
anything learned from typing, wait for review; principles are never
learned (`PersonalModel.learn`).

#### Handle is what the model cites for a line
`PersonalLearning.Utterance`: One line of the person's own words. `handle` is what the model cites.

#### Meeting source joins consecutive microphone segments of one meeting
`PersonalLearning.Utterance.Source.meeting`: Consecutive microphone segments of one meeting, joined.

#### Label is the meeting title or typed-to text shown to the model
`PersonalLearning.Utterance.label`: The meeting title or "typed to Claude Code", shown to the model.

#### Typed lines share the budget but never crowd meetings out
`PersonalLearning.maxTypedUtterances`: Typed lines share the budget but never crowd meetings out.

#### Skip meetings whose microphone was shared by several diarized local voices
`PersonalLearning.utterances`: The person's turns from `day`'s meetings, most self-descriptive first
within the budget, then put back in meeting order with handles. A
meeting whose microphone was shared by several diarized local voices is
skipped: there is no telling which of them is the person.

#### Typed lines exclude scheduled runs and Remember messages; dictation read once
`PersonalLearning.typedLines`: The day's typed lines: requests the person sent to coding agents
(scheduled runs excluded), questions asked in Ask, and dictation kept
for learning. A "Remember …" message is already saved, so it is
skipped, and a dictation that became one of those requests is read
once, from the request.

#### Fingerprint omits dictated lines since they are deleted once read
`PersonalLearning.fingerprint`: What the pass read for a day, independent of order and handles.
Dictated lines are left out: they are deleted once read, so a later
review of the same day would otherwise always look changed.

#### Quote matching ignores case, accents, punctuation and truncation
`PersonalLearning.quoteStillSaid`: Whether `lines` still contain the line a learned claim quotes, ignoring
case, accents, punctuation, and where a long line was cut off.

#### Fold to letters and digits so dictation matches the request it became
`PersonalLearning.foldedForDuplicate`: Letters and digits only, case- and accent-folded, so a dictation and
the request it was pasted into compare equal despite punctuation.

#### Own-speech rules: dominant voice needs four times the next, else meeting skipped
`PersonalLearning.ownTurns`: Joins consecutive segments of the person's own speech into turns.

Own speech is microphone speech ("me", "local", "local N", also behind
a merged recording's "source:" prefix) whose attribution is the user:
echo, overlapping voices, and voices corrected to someone else are
left out. Diarization labels the person "local 1" and leaves some of
their segments as plain "local", so those are one voice. A voice the
person confirmed as theirs wins. Otherwise, when diarization found
several voices on the microphone, the meeting counts only if one of
them clearly dominates (four times the next), and then only that
voice is used; with no clear winner the microphone was shared and the
meeting is skipped, since there is no telling which voice is the person.

#### Older transcripts without attribution follow the microphone-is-me setting
`PersonalLearning.isOwnSpeech`: Microphone speech attributed to the user. Older transcripts carry no
attribution; their microphone labels follow "My microphone is me".

#### Numbered local keys denote one voice diarization told apart
`PersonalLearning.isNumberedVoice`: "local 1", "source2:local 3": one voice diarization told apart.

#### Lines without first-person words are not about the person and never sent
`PersonalLearning.selfReferenceScore`: How many first-person words a line has (English and Serbian). Lines
without any are not about the person and are never sent.

#### Proposals keep items citing a real line; grounding happens afterwards
`PersonalLearning.proposals`: Every item that cites a real line with a learnable kind, in reply
order. Grounding happens after this.

#### Word-overlap grounding only; production uses groundedCandidates, tests use this
`PersonalLearning.candidates`: Word-overlap grounding only. At most `maxPerNight`. `run` calls
`groundedCandidates`, which applies the same rule to items in the
line's language; only tests call this.

#### Embed returns L2-normalized vectors or nil without an embedder
`PersonalLearning.Embed`: Vectors for texts, L2-normalized, or nil when no embedder is available.

#### Cross-language similarity floor 0.82 and confident 0.90 from measurements; recalibrate on model change
`PersonalLearning.crossLanguageFloor`: EmbeddingGemma 2 with the sentence-similarity prompt, measured on
Serbian lines against English items (2026-10-14): correct
translations 0.83–0.95, unrelated claims 0.73–0.79, and a wrong
detail ("doctor" for engineer, the wrong city) 0.80–0.90. Below the
floor an item is dropped. Above it, a fact or goal is saved only with a
shared word root or a very high score; otherwise it waits for review,
because embeddings alone can't tell a wrong detail from a right one.
Recalibrate whenever the embedding model changes.

#### Translated items are grounded by embedding meaning, not word overlap
`PersonalLearning.groundedCandidates`: Word overlap for items in the line's language. An item the model
translated (the line is Serbian, the item English) can't share words,
so it is compared by meaning instead, when an embedder is available.

#### Unknown language counts as same, taking the stricter path
`PersonalLearning.isCrossLanguage`: True when the two texts' dominant languages differ, so word overlap
can't apply. Unknown counts as the same language: the stricter path.

#### Shared word root tolerates inflection and transliteration, e.g. maraton
`PersonalLearning.sharesWordRoot`: A content word of the item and of the line (Cyrillic transliterated)
start the same way: "platform" in "platformu", "marathon" in
"maraton", "sad" in "sadu".

#### Provenance ties items to meeting or agent evidence; Ask retracts via conversation
`PersonalLearning.provenance`: What a learned item depends on: its meeting, or the day's activity
evidence for a coding-agent request (deleting saved agent sessions
retracts it). An Ask question has none; deleting its conversation
retracts the item instead.

#### Skip the model call when the day has no own lines
`PersonalLearning.run`: One night's pass. Returns no candidates without calling the model when
the day has none of the person's own lines.

#### Caller checks fingerprint against read days before running
`PersonalLearning.run(lines:)`: The pass over lines already gathered (`utterances`), so the caller can
first check `fingerprint` against the days already read.

### `LokalBot/Services/PersonalModel/PersonalModelController.swift`

#### Controller loads lazily, refuses edits when unreadable, retracts on evidence changes
`PersonalModelController`: The app's single owner of the personal model. Ask reads and adds claims
through it; Settings → Personal Context edits them; the overnight
review adds learned ones. Loads lazily on first use so launch never
touches the Keychain for it. If the saved file can't be read, every edit
is refused instead of overwriting it. Learned claims are checked against
the Dream evidence revisions on every use: a deleted or corrected meeting
retracts them, and while a revocation is pending they are withheld.

#### Nil revision means unknown, so changed source retracts the claim
`PersonalModelController.sourceStillQuotes`: Whether a learned claim's source still has the line it quotes, and
the evidence revision to tie it to if so. Nil revision: can't tell,
so a changed source retracts the claim as before.

#### onChange fires after every change so agent projection never lags
`PersonalModelController.onChange`: Called after every saved change, forget-all and reload, so the
agent-facing projection never lags behind (nil claims: unreadable).

#### Claims ordered newest first, as Settings shows
`PersonalModelController.orderedClaims`: Newest first, the order Settings shows.

#### Current claims include suggestions
`PersonalModelController.currentClaims`: Everything stored, suggestions included.

#### Scoped Ask gets only stated claims to respect source boundary
`PersonalModelController.usableClaims`: Confirmed claims safe to put in a prompt now. Scoped Ask questions pass
`includeEvidenceBacked: false` and get only what the person stated:
like work memory, learned claims would carry meeting content past the
question's source boundary. A claim learned from an Ask question or a
dictation has no evidence to depend on, but it is learned all the same.

#### Agent access fails closed on nil instead of sharing nothing
`PersonalModelController.readableClaims`: The claims agents may be offered, or nil when the saved file couldn't
be read. Agent access fails closed on nil instead of "nothing shared".

#### Retract learned claims when source loses their quoted line; withhold while revocation pending
`PersonalModelController.retractInvalidated`: Learned claims whose source changed since they were learned keep their
place while that source still has the line they quote (a rebuilt
review, a re-read agent session, an unrelated edit to the meeting) and
are retracted once it doesn't (the meeting or session deleted, the
line corrected or no longer the person's). False when evidence can't
be checked (a revocation is pending), so callers withhold
evidence-backed claims meanwhile.

#### Skip unloaded model because every read checks evidence anyway
`PersonalModelController.retractIfLoaded`: After a meeting is deleted or corrected. Skips an unloaded model:
every read checks evidence anyway, so there is nothing to clean yet.

#### Learning saves facts and goals, suggests preferences, prunes, records day read
`PersonalModelController.learn`: The overnight review's findings: facts and goals are saved, preferences
become suggestions. Expired suggestions and tombstones are pruned. With
a day and fingerprint, the day is recorded as read.

#### Deleting an Ask conversation retracts what was learned from it
`PersonalModelController.retractLearned`: Deleting an Ask conversation takes back what was learned from it.

#### Keep All confirms every listed suggestion in one save
`PersonalModelController.confirm(_:)`: Keep All in review: every listed suggestion in one save.

#### Used timestamps are best effort; a failed write only loses the stamp
`PersonalModelController.markUsed`: Stamps claims that went into an answer. Best effort: a failed write
only loses the timestamp.

### `LokalBot/Services/PersonalModel/PersonalModelStore.swift`

#### Personal model is AES-GCM encrypted with the chat key; app-only writes
`PersonalModelStore`: Persists the personal model as `memory/personal-model.json.enc`, sealed
with AES-GCM under the same per-install `chat-key` as saved conversations:
these claims are as sensitive as the questions they came from.

A plaintext `memory/personal-model.json` (demo seeds, upgrade fixtures) is
accepted and re-encrypted on the next save. Writes are atomic and 0600.
Only the app writes; headless `--chat` reads. Evidence-backed claims
(RFC Phase 3) move this under `DreamStore`'s lock so retraction updates
them in the same critical section as Dream memory.

#### Load throws on unreadable data so callers never overwrite it
`PersonalModelStore.load`: The saved model; empty when nothing was ever saved. An encrypted copy
wins over a leftover plaintext one. Throws instead of returning empty
for anything unreadable, so a caller never saves over it.

#### Save seals, writes atomically at 0600, then drops plaintext copy
`PersonalModelStore.save`: Seal → atomic write → 0600, then drop any plaintext copy.

#### Forget everything removes both encrypted and plaintext copies
`PersonalModelStore.deleteAll`: "Forget everything about me": removes both copies.

### `LokalBot/Services/PersonalModel/WorkMemoryPromotion.swift`

#### Goals seen 14+ days and in the last week are suggested without a model call
`WorkMemoryPromotion`: Suggests long-running work as Personal Context items. The overnight review keeps
short-lived work memory (projects and goals that age out after 30–45
days); a goal or project it keeps seeing for two weeks or more, and saw in
the last week, says something durable about the person. No model call:
the review already distilled the day's meetings, digest, and timeline.
Every promotion waits for review and depends on the review's evidence.

### `LokalBotTests/Services/PersonalModel/PersonalLearningRereadTests.swift`

#### local 1 and local are one voice; several voices need a clear winner
`PersonalLearningMicrophoneTests`: Which microphone lines are the person's: diarization's "local 1" and
plain "local" are one voice; several voices count only with a clear winner.

#### Learning rereads a day only when person's lines changed; claims survive
`PersonalLearningRereadTests`: Learning reads a day again only when the person's lines from it changed,
and a learned claim survives a changed source that still has its line.

### `LokalBotTests/Services/PersonalModel/PersonalModelTests.swift`

#### Principles are the person's call, never guessed
`PersonalClaim.Kind.suggested`: Principles are the person's call, never guessed.

#### A duplicate still refreshes when the model is full
`PersonalModel.add`: A duplicate still refreshes when full.

#### Scoped questions get only stated items, not Ask or dictation learned ones
`PersonalModelStoreTests.testScopedQuestionsGetStatedItemsNotOnesLearnedFromAskOrDictation`: A question limited to some sources or days gets only what the person
stated. An item learned from an Ask question or a dictation and kept
in review has no meeting behind it, and went out with those questions
as if it were a statement.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
