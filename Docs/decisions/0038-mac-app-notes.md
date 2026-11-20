# 0038. Mac app: Notes

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Services/Notes/`, `LokalBotTests/Services/Notes/`.

## Decisions

### `LokalBot/Services/Notes/FollowUpDraftGenerator.swift`

#### Follow-up draft is explicit, grounded in outcomes, local-only, never sent
`FollowUpDraftGenerator`: Writes a follow-up email draft from one meeting's own outcomes with the
on-device Think model. It is explicit (the user asks for it), grounded
(only the meeting's recap, decisions, corrected actions, and open
questions), and never sends anything. `generate` takes any engine: its
caller, `FollowUpDraftSheet`, refuses unless Think runs on this Mac
(`UpcomingMeetingLocalGenerationPolicy`).

#### Calendar display names only, used for greeting
`FollowUpDraftGenerator.Evidence.participantNames`: Calendar display names only, for the greeting.

### `LokalBot/Services/Notes/GenerationMetricsStore.swift`

#### Narrow metric; tokensPerSec derived so it cannot drift from inputs
`GenerationMetric`: One recorded local-generation pass — narrow on purpose: just what a Settings →
Performance row shows. `tokensPerSec` is derived so the throughput figure can't
drift out of sync with the duration/token inputs it's computed from.

#### Non-positive duration reads as 0 to avoid infinity/NaN averages
`GenerationMetric.tokensPerSec`: Throughput, guarding the divide so a zero/negative duration reads as 0
rather than infinity or NaN poisoning a displayed average.

#### In-memory bounded ring, deliberately not persisted
`GenerationMetricsStore`: In-memory ring of the most recent local-generation timings, published for a
live Settings → Performance readout. Deliberately not persisted: these numbers
matter only while you're watching them, and a bounded window keeps the array
renderable without virtualization. Merges Cotabby's two metrics stores into the
single shape LokalBot needs (rolling window + per-pass throughput).

#### Window of 20; old entries drop so recent.last is newest
`GenerationMetricsStore.maximumMetrics`: Retained window size. Old entries fall off the front, so `recent.last` is
always the newest pass and the array stays in chronological order.

#### Initializer not private so tests use isolated instances
`GenerationMetricsStore.init`: Not private despite the singleton: tests construct isolated instances to
exercise the ring without mutating `shared`.

### `LokalBot/Services/Notes/MeetingGenerationBudget.swift`

#### Budget per summary job applies to every Think backend
`GenerationBudgetPreset`: How much time and compute one summary + outcomes job may spend before it
checkpoints and asks the user to summarize again. Applies to every Think
backend (built-in, Apple Intelligence, Ollama, OpenAI-compatible).

#### Unlimited preset stays finite so stalled servers cannot wedge the queue
`GenerationBudgetPreset.unlimited`: Finite on purpose: run() races a Task.sleep deadline and
allowance() converts seconds * 35 to Int, and a stalled server
must not wedge the serialized job queue forever.

#### One allowance per summary job including transport replays via task-local
`MeetingGenerationBudget`: One allowance for the entire summary + outcomes job, including transport
replays. Task-local propagation keeps provider and runtime retries inside it.

#### Limits cover four parts and grow for longer meetings
`MeetingGenerationBudget.Limits.scalesWithParts`: Treat these limits as covering `partsPerBudget` meeting parts and
grow them for longer meetings. Otherwise a long meeting spends the
whole allowance before its last parts get their repairs.

#### Allocate output to processable parts, reserving one repair per part
`MeetingGenerationBudget.allowance`: Allocate useful output to the parts this run can actually process,
reserving one possible repair per part. Very long meetings continue
from verified checkpoints instead of starving every part with a tiny
allowance divided across work that cannot fit the request limit.

#### Unknown usage retains the reservation; absence is never zero
`MeetingGenerationBudget.finish`: Unknown usage retains the reservation; absence is never zero usage.

#### standardParts keeps allowance equal when a model plans fewer larger parts
`MeetingGenerationBudget.recordPlan`: `standardParts` counts the work in standard-size parts, so a model
that plans fewer, larger parts keeps the allowance the same meeting
gets in standard parts.

#### Cancellation reaches URLSession and lease; group waits for cleanup
`MeetingGenerationBudget.run`: URLSession and the inference lease both respond to task cancellation.
Structured concurrency waits for their cleanup before another job starts.

#### Deadline re-read each second because planning extends it
`MeetingGenerationBudget.run`: Re-read the deadline: planning a long meeting extends it.

#### Never recreate a deleted meeting root when writing metrics
`MeetingGenerationBudget`: Never recreate a meeting root after deletion. Creating only the
direct child fails safely if the root disappeared concurrently.

#### Content-free; unreported provider values stay absent
`GenerationCallTelemetry`: Content-free diagnostics. Optional runtime values stay absent when a
provider does not report them (especially cache and reasoning usage).

#### Only the structured notes validator may salvage truncated content
`TruncatedStructuredResponse`: Only the structured notes validator may salvage this content. Other text
consumers continue to receive the ordinary outputTruncated error.

### `LokalBot/Services/Notes/MeetingNotesEvidence.swift`

#### Model IDs are local to snapshot; durable artifacts use stable IDs
`MeetingNotesEvidence`: Shared compact evidence for narrative facts and actionable outcomes. Model
IDs are local to this immutable snapshot; durable artifacts use stable IDs.

#### Marks unresolved action replaced, not appended, by ownership repair
`MeetingNotesEvidence.Rejection.actionID`: Identifies an unresolved action that must be replaced, not appended
to, if a targeted ownership repair succeeds.

#### Ledger text is data, never instruction or evidence substitute
`MeetingNotesEvidence.Record`: Compact, source-bound ledger for paging. Text is data, never a new
instruction or a substitute for the original evidence on the next page.

#### English-only wording checks veto tasks only in mostly-English meetings
`MeetingNotesEvidence.isEnglishMeeting`: English-only wording checks may veto a task only when the meeting is
mostly English.

#### Suspected echo is never shown or cited; remote segment carries the words
`MeetingNotesEvidence.init`: Likely echo repeats a remote participant; the remote segment carries
those words, so the echo is never shown or cited as evidence.

#### Language sampled across meeting so odd openings do not decide it
`MeetingNotesEvidence.init`: Sampled across the meeting: a foreign-language opening, or noise
transcribed as one, must not decide the language of the rest.

#### User undertakings listed for model and re-read once when uncited
`MeetingNotesEvidence.init`: The user's own undertakings are listed for the model and re-read
once when no task cites them.

#### Count enum values per occurrence, as hosted servers limit them
`MeetingNotesEvidence.enumValueCount`: Every enum value in a schema, counted the way hosted servers limit
them: once per occurrence.

#### Run after whole-meeting scan, since pending pages may still list decisions
`MeetingNotesEvidence.statedDecisions`: Decisions a speaker stated outright that no finished part listed, as
source-linked notes. Run once the whole meeting is scanned: a page or
repair still in progress may yet list them.

#### Bounded array must not silently represent a scan with more work
`MeetingNotesEvidence.validate`: A bounded array must not silently represent a scan that had more work.

#### Repair anchors on primary source; rebuild context from transcript, not model context
`MeetingNotesEvidence.validate`: The primary source anchors repair. Rejected model-selected
context may be the very reason an unrelated task was inferred.
Rebuild its neighborhood from the transcript instead of feeding
those untrusted context references back into the repair.

#### Strip one balanced quote wrapper some providers add
`MeetingNotesEvidence.validate`: Some providers wrap a copied clause in quotation marks.
Removing one balanced wrapper cannot invent evidence.

#### Verbatim quote in one cited row re-anchors the task
`MeetingNotesEvidence.validate`: A quote found word for word in one cited row re-anchors the task there.

#### Re-anchoring must not push contexts beyond eight rows apart
`MeetingNotesEvidence.validate`: Two contexts eight rows either side of the old source
must not become sixteen rows apart after re-anchoring.

#### Unrecognized phrasing loses ownership claim only; English checks gate vetoes
`MeetingNotesEvidence.validate`: Unrecognized phrasing must not lose a task; it only loses
the ownership claim. A negated or questioned undertaking
and a status report are still not tasks. Those checks read
English wording, so elsewhere only a question mark can
veto; every quoted commitment would otherwise look like a
status report and be deleted.

#### Reject past-tense status reports as tasks without rewriting prose
`MeetingNotesEvidence.validate`: A past/status report is not a pending task. This catches the
explicit English failure mode without rewriting unknown prose.

#### User reply must be the next turn; pauses and others end the exchange
`MeetingNotesEvidence.userReply`: The user's speaker key when the user speaks the next turn after a
request. Mixed or echoed speech is not a turn; a long pause ends the
exchange, and any other participant's reply means it was not the user's.

#### Qwen3.5 4B sometimes copied source IDs into due
`MeetingNotesEvidence.spokenDue`: The due date as spoken, or "" when there is none. The built-in
Qwen3.5 4B sometimes copied a cited source ID ("s268") into `due`,
which rendered as "due s268".

#### Unspoken years are model guesses; drop due phrase, keep action
`MeetingNotesEvidence.spokenDue`: A year nobody said is the model's guess, not a deadline: an invented
"2024-01-01" resolved into the past and topped Today as overdue. The
action stays; only the unsupported due phrase goes.

#### Strip leading speaker ID only when it matches resolved speaker
`MeetingNotesEvidence.prose`: A redundant leading ID can be removed only when it exactly matches
the independently resolved speaker. A conflicting ID is rejected.

#### Take unlisted stated decisions from rows because small models misfile them
`ExplicitDecisions`: Decisions a speaker states outright ("Decision made: we shoot in the
studio", "we decided the launch stays on the 20th"). Small models can file
these under Key points, which leaves a meeting with no cited decisions, so
a stated decision the model did not list is taken from its row. English
only, like the other wording checks.

#### rows holds rows no Decisions note cites
`ExplicitDecisions.missing`: One note per stated decision that isn't already listed. `rows` holds
the rows no Decisions note cites.

#### A request after the decision is an action, not part of it
`ExplicitDecisions.statement`: A request after the decision is an action, not part of it.

#### Conditional or negated openings settle nothing
`ExplicitDecisions.statement`: "If we decided…", "what we decided…", "no decision, …" settle nothing.

### `LokalBot/Services/Notes/MeetingNotesGenerator.swift`

#### One transcript scan; no recursive recovery or second synthesis pass
`MeetingNotesGenerator`: One transcript scan produces facts, actions, decisions and questions. There
is no recursive recovery or second full-transcript outcomes/synthesis pass.

#### Without native tokenizer use UTF-8 bytes as conservative upper bound
`MeetingNotesGenerator.tokenCount`: Model tokenization includes all prompt text. Providers without a native
tokenizer use UTF-8 bytes as a conservative upper bound, plus envelope
and structured-output headroom; punctuation/numerals are never dropped.

#### Estimate only picks part size; bytes remain the hard bound
`MeetingNotesGenerator.promptSize`: The estimate only chooses an efficient part size. UTF-8 bytes remain
the hard context/input-budget bound when a tokenizer is unavailable,
including for punctuation-heavy and non-Latin transcripts.

#### Parts fit window step and hosted enum limit; IDs listed three times
`MeetingNotesGenerator.makeChunks`: Parts fit the window's step and, on hosted servers, the provider's
limit on schema enum values: each part's schema lists its source IDs
three times.

#### 6,000-token step plans identical parts for windows 24K to 64K
`MeetingNotesGenerator.makeChunks`: Without a tokenizer the 6,000-token step admits about 18 KB, so
windows from ~24K up to 64K plan identical parts (and keep
checkpoints); larger known windows take larger steps.

#### Two-turn overlap retains context; tiny chunks still advance
`MeetingNotesGenerator.makeChunks`: Two source turns retain context at boundaries without restarting
extraction. A tiny chunk must still advance.

#### retryingStoppedParts is explicit user request; automatic runs keep stop
`MeetingNotesGenerator.generate`: `retryingStoppedParts` is a person's explicit request: a part an earlier
run stopped (no further progress, invalid evidence IDs) gets another
scan instead of failing at once. Automatic runs keep the stop.

#### Direct callers and replays get the same deadline as pipeline
`MeetingNotesGenerator.generate`: The pipeline installs the allowance before model preparation; direct
callers (including offline replays) get the same deadline here.

#### Larger parts get proportionally more output and records
`MeetingNotesGenerator.generate`: A part larger than the standard step gets proportionally more
output and records, so fewer, larger parts keep the same coverage.

#### Stated decisions keyed after last part so they follow model output
`MeetingNotesGenerator.generate`: Keyed after the last part, so the decisions follow what the model wrote.

#### Reasoning providers spend completion on thinking; one larger bounded retry
`MeetingNotesGenerator.request`: Reasoning providers count hidden tokens against the
same completion ceiling as the JSON envelope. A
4K request can therefore spend the whole response on
thinking and return no usable records. Give every
structured call one larger, budgeted retry before
handing partial content to the evidence validator.
The retry is deliberately bounded: a genuinely huge
response still falls through to checkpointed recovery
instead of consuming the job indefinitely.

#### On retry failure preserve first call's usable prefix
`MeetingNotesGenerator.request`: The first call may have consumed the remaining
allowance, or the provider may reject the
expanded request. Preserve its usable prefix
and let checkpointed recovery report the
incomplete part instead of replacing progress.

#### When both calls truncate keep prefix with most recoverable records
`MeetingNotesGenerator.request`: A larger completion ceiling does not guarantee a
longer visible prefix: reasoning can consume the
extra allowance and leave fewer complete records.
When both calls truncate, keep the prefix with the
most recoverable structured records. Ties retain
the first response because the retry has not made
source-linked progress.

#### Managed engines replay transients; others get one charged replay
`MeetingNotesGenerator.request`: Managed and gated engines replay transient failures
themselves. Any other engine gets one replay charged to this job.

#### One bounded retry for GLM-5.3's 4K reasoning plus 4K visible split
`MeetingNotesGenerator.expandedStructuredOutputTokens`: One retry gives an always-reasoning provider room for visible JSON. The
cap keeps a standard job bounded while still covering the common 4K
reasoning + 4K visible-token split observed with GLM-5.3.

#### Interleave parts' takeaways so first bullets span whole meeting
`MeetingNotesGenerator.interleavingTLDR`: Each part writes up to three TL;DR takeaways for its stretch of the
meeting. Concatenated, a long meeting's first bullets, which the recap
card, briefs, and digest read, came from its first parts only. Taking
every part's first takeaway, then every part's second, and so on keeps
every takeaway while the first bullets span the whole meeting.

#### Missing TL;DR rendered from accepted facts without another model call
`MeetingNotesGenerator`: Rendering already accepted, source-linked facts needs no further model call.

#### Sample first, middle and last facts when no outcomes distinguish them
`MeetingNotesGenerator.overviewClaims`: When no explicit outcome distinguishes facts, sample the complete
meeting instead of repeating only its first three introductory rows.

### `LokalBot/Services/Notes/MeetingNotesPartial.swift`

#### Partial snapshots never enter completed index or replace final artifacts
`MeetingNotesPartial`: A coherent, revision-checked snapshot for the meeting detail view. Partial
work never enters the completed outcome index or replaces final artifacts.

#### Show previous-version progress without rewriting the library
`MeetingNotesPartial.load`: Show progress saved by the previous app version as soon as the
fixed app opens, without rewriting the user's meeting library.

#### Published result supersedes checkpoint even if cleanup was interrupted
`MeetingNotesPartial.load`: A successfully published result supersedes an earlier checkpoint,
including if cleanup was interrupted after the final write.

#### Render from revision-checked evidence, not possibly stale Markdown
`MeetingNotesPartial.legacy`: Render from revision-checked evidence rather than trusting a Markdown
file that could be left behind by an interrupted multi-file save.

### `LokalBot/Services/Notes/MeetingNotesRecovery.swift`

#### Tasks with unbound ownership repairs stay visible as owner-unclear
`MeetingNotesGenerator.Recovery.settledOwnership`: Tasks (normalized text) whose ownership repairs answered in full
but could not bind them; they stay visible as owner-unclear.

#### Complete repair answer without task is final; re-asking repeats it
`MeetingNotesGenerator.Recovery.answeredCommitments`: Rows the commitment check flagged that a complete repair answered
without a task for the user. The check only matches wording ("I'll
be honest" passes it), so that answer is final: asking again gets
the same reply and would leave the part partial for good.

#### Per-part call caps: three extraction pages, two repairs, shared allowance
`MeetingNotesGenerator.generatePart`: At most three extraction pages and two repair calls per part in this
attempt, plus two for records queued behind a task whose owner the
repairs could not bind. Every call also consumes the shared job
allowance. A restart resumes the ledger and pending repairs, including
legacy checkpoints.

#### Old checkpoints' source-less rejections trigger a fresh scan
`MeetingNotesGenerator.generatePart`: Older checkpoints retained source-less rejections forever. Start one
fresh scan, preserving accepted evidence, instead of an impossible repair.

#### Pre-recovery builds stored source-less state as terminal failure; clear it
`MeetingNotesGenerator.generatePart`: Pre-recovery builds persisted this source-less state as a
terminal provider failure. Clear that marker before the guard
below so the fresh scan can actually run.

#### Explicit retry clears terminal stop; 2026-10-07 every Summarize again failed
`MeetingNotesGenerator.generatePart`: The stop exists so automatic runs do not cycle on a provider that
keeps failing. A person asking again may have changed the model or
its reasoning; on 2026-10-07 every "Summarize again" failed in 0.2 s.

#### Keep pending IDs stable across pages so repair replacement ID survives
`MeetingNotesGenerator.generatePart`: Keep pending IDs stable across extraction pages. Merging their
citations/text first would strand the repair's replacement ID.

#### Continue only from accepted records; empty ledger continue returned empty
`MeetingNotesGenerator.generatePart`: Continue only from accepted records. A page cut off before any
record (reasoning used the whole output) is scanned again; on
2026-10-07 "continue the unfinished work" with an empty ledger
got empty answers until the part was stopped.

#### Empty final page cannot certify a substantial untouched transcript
`MeetingNotesGenerator.generatePart`: An empty final page may finish a previously populated scan, but
empty output cannot certify a substantial untouched transcript.

#### Source-less malformed records stay in telemetry, not repair queue
`MeetingNotesGenerator.generatePart`: A malformed optional record may have no usable source at all
(for example an action omitted `source`). It cannot be repaired
without evidence, but it must not poison otherwise valid notes
or turn a provider-shape error into an evidence-ID failure. Keep
the rejection in validation telemetry and only queue source-bound
records for targeted repair.

#### One bounded re-read for provider envelope glitches
`MeetingNotesGenerator.generatePart`: Some OpenAI-compatible providers occasionally return an
incomplete envelope or a source-less optional action even though
the request itself succeeded. One bounded, explicit re-read can
recover a useful summary; without it the no-progress guard would
turn a provider shape glitch into a failed meeting.

#### Repeated full pages stop the loop; accepted facts kept for later resume
`MeetingNotesGenerator.generatePart`: A provider repeating a full page must not spend the entire job
cycling. Keep its accepted facts and resume explicitly later.

#### Ownership repairs first; settled tasks stay owner-unclear to avoid failing meeting
`MeetingNotesGenerator.generatePart`: Ownership repairs run first. A task whose latest repair answered in
full but still could not bind it to one undertaking stays visible
as owner-unclear, like a wrong-owner claim: the same evidence fails
every retry, so holding the part open would fail the meeting each
time. Records queued behind ownership repairs then get their own
two repairs. A settled task near the user's own commitment covers
it: the task stays visible, and one spoken on this Mac's microphone
is marked as likely the user's.

#### Never repair an invented source using unrelated evidence
`MeetingNotesGenerator.generatePart`: Never repair an invented source using unrelated evidence.

#### Ownership repairs fix task text, which identifies it across IDs
`MeetingNotesGenerator.generatePart`: Ownership repairs keep each task's text fixed, so the text
identifies the task across replacement IDs.

#### Unsupported records may be omitted after complete repair
`MeetingNotesGenerator.generatePart`: Unsupported records may be omitted after a complete repair;
independently validated facts never depend on their survival.

#### Uncovered commitments do not change on retry so they do not hold part open
`MeetingNotesGenerator.generatePart`: A commitment still uncovered here was answered without a task, or
sits beside several owner-unclear tasks that proximity cannot choose
between. Neither changes on a retry, so neither holds the part open.

#### Ownership repairs fix text; failure keeps task visible; replacement atomic
`MeetingNotesGenerator.acceptOwnershipRepairs`: Ownership repairs keep each existing task's text fixed so
a different promise from the same neighborhood cannot replace it. The
unresolved task remains visible on failure, and replacement is atomic.

#### Grounded repair can find task negated, completed or conversation management
`MeetingNotesGenerator.acceptOwnershipRepairs`: A grounded repair can discover that the alleged task was
negated, completed, or just conversation management.

#### Proximity only schedules re-read; never establishes ownership or merges
`MeetingNotesGenerator.queueMissingCommitments`: Finish repairing a nearby existing task before extracting an omission
from the same exchange. Proximity only schedules a model re-read; it
never establishes ownership or merges different task descriptions.

#### Ledger trimmed to newest records; it only discourages repeats
`MeetingNotesGenerator.fittedPage`: Parts are planned to fill the context beside a full output allowance,
so a continuation's ledger and recovery text come out of that
allowance. The ledger only discourages repeats (accepted keys are
deduplicated anyway), so a long one keeps its newest records rather
than blocking the page.

#### Output allowance reduced to fit input; nil below structured minimum
`MeetingNotesGenerator.outputRoom`: The output allowance that fits beside this request's input, reduced
as needed, or nil when even the structured-output minimum cannot fit.

#### Settled task citing same speaker nearby covers the undertaking
`MeetingNotesGenerator.missingCommitments`: The user's undertakings that no user task cites. A settled task citing
the same speaker near the undertaking covers it: the repairs already
tried to bind that task to the user and could not.

### `LokalBot/Services/Notes/MeetingSummaryGenerator.swift`

#### Smallest OpenRouter endpoint window, checked Oct 2026; exact ids only
`MeetingSummaryGenerator.verifiedOpenRouterContextTokens`: The smallest context window OpenRouter advertised across every endpoint
of these models (`/api/v1/models/<id>/endpoints`; 1 October 2026, and
7 October for Qwen3.8 27B and GPT-5.6 Luna), used when the live lookup
has never answered. Exact ids only: variants such as `:free` route to
other endpoints. The window also sets the notes part size
(`notesPartTokens`).

#### Cerebras free-tier windows (7 Oct 2026); models API lists ids only
`MeetingSummaryGenerator.verifiedCerebrasContextTokens`: Cerebras's documented free-tier windows on 7 October 2026
(inference-docs.cerebras.ai/models/overview); its models API lists ids
only. Paid tiers allow about twice as much; the smaller window holds
for every key.

#### OpenAI windows by family at smallest variant; API reports none
`MeetingSummaryGenerator.openAIContextTokens`: OpenAI's documented windows by model family, at the family's smallest
variant (`gpt-5-chat` and `o1-mini` have 128K). Its models API reports
none.

#### GPT-6 models take at most 922K input of a 1.05M window
`MeetingSummaryGenerator.openAIContextTokens`: Every GPT-6 model takes at most 922K input tokens of a 1.05M window.

#### Documented window used where API reports none; OpenRouter's comes first
`MeetingSummaryGenerator.documentedContextTokens`: The window a provider documents for the model, where its API does not
report one. OpenRouter's published window comes first
(`contextTokenLimit(for:catalog:)`).

#### OpenRouter serves OpenAI models with OpenAI's windows
`MeetingSummaryGenerator.documentedContextTokens`: OpenRouter serves OpenAI's models with OpenAI's windows.

#### Fixed part steps avoid re-planning when windows drift; 6,000 default
`MeetingSummaryGenerator.standardNotesPartTokens`: Notes parts target 6,000 estimated tokens on the built-in model and on
servers whose window is unknown: small windows, slow prefill, and
frequent checkpoints. A model with a known larger window takes bigger
parts, so a 20-minute meeting on Cerebras Qwen is two requests instead
of four (its schema enum limit keeps it from one; see `makeChunks`). Fixed steps, not a fraction of the window, keep a window that
drifts between OpenRouter lookups from re-planning a meeting and
discarding its saved parts. Even at one token per UTF-8 byte a part
stays well inside its step's window beside the output allowance.

#### Unknown servers and models retain 16K window
`MeetingSummaryGenerator.contextTokenLimit(for:)`: The selected provider's documented window for the model. Unknown
servers and models retain 16K.

#### Every ChatGPT-plan model has at least 128K
`MeetingSummaryGenerator.contextTokenLimit(for:)`: Every model offered on a ChatGPT plan has at least 128K.

#### Claude Code default window on subscription plans is 200K
`MeetingSummaryGenerator.contextTokenLimit(for:)`: Claude Code's default window on subscription plans.

#### Antigravity serves Gemini 1M, Claude 200K, GPT-OSS 128K
`MeetingSummaryGenerator.contextTokenLimit(for:)`: Antigravity serves Gemini (1M), Claude (200K), and GPT-OSS (128K).

#### Gemini CLI models advertise a 1M context window
`MeetingSummaryGenerator.contextTokenLimit(for:)`: Gemini CLI models advertise a 1M-token context window.

#### Server-reported window wins, even below 16K; then documented, then 16K
`MeetingSummaryGenerator.contextTokenLimit(for:catalog:)`: The window the server reports for the selected model wins, including
one smaller than 16K: OpenRouter's published endpoints, or another
server's model list (`ServerContextWindowCatalog`). Otherwise the
provider's documented window, then 16K.

### `LokalBot/Services/Notes/MeetingSummaryOutcomeSynchronizer.swift`

#### Summary outcome sections align with cards; model cannot invent outcomes
`MeetingSummaryOutcomeSynchronizer`: Keeps outcome sections in `summary.md` aligned with the grounded artifact
used by the Decisions and Action items cards. The narrative model still
owns the recap, but it cannot independently invent or omit outcomes.

#### Failed regeneration never manufactures a completed summary
`MeetingSummaryOutcomeSynchronizer.synchronizeExisting`: A failed regeneration may still produce verified outcomes. Keep an
earlier recap aligned with the cards, but never manufacture a completed
summary when only the independent outcomes pass succeeded.

#### Action corrections change only list; claims-less summary returns false
`MeetingSummaryOutcomeSynchronizer.applyActionCorrections`: A correction to an action's owner, text, or due date changes only the
action list. A summary rendered from claims keeps the rest: each line
is reported speech whose speaker comes from the transcript, which a
correction leaves unchanged. Returns false when the saved summary has
no claims behind it, so its prose may still name the old owner.

#### Exports show corrections and completed actions that summary.md lacks
`MeetingSummaryOutcomeSynchronizer.replacingActionItems`: The summary with its action list replaced by `lines`. Meeting note
exports use it to show corrections and completed actions, which
`summary.md` does not record.

### `LokalBot/Services/Notes/PromptTemplates.swift`

#### One bounded extraction contract; app validates identity and quotes, renders document
`PromptTemplates.meetingNotesSystem`: One bounded extraction contract for every transcript part. The app
validates identity and selected quotes, then renders the final document.

#### All prompts live here except chat agent's, co-located with its parser
`PromptTemplates`: Every prompt the app ships lives here (the chat agent's system prompt is
the one exception — it is co-located with its tool-call parser in
`ChatAgent`). Views and engines reference these instead of owning copy.

#### Final recap groups pre-filtered candidates by task, ranked by work value
`PromptTemplates.dayDigestSystem`: Final task recap. A first pass has already rejected low-signal activity
and extracted substantive work candidates; this pass groups candidates
by task and ranks them by work value rather than time spent.

#### Fallback recap used only when strict pass accepts no candidates
`PromptTemplates.dayDigestFallbackSystem`: Best-available recap used only when the strict substantive-work pass
accepts no candidates. It keeps weak but identifiable work visible
without weakening the normal task-first digest.

#### Focus gate separates primary tasks from lightweight activity and noise
`PromptTemplates.dayDigestFocusSystem`: Substantive-work gate for one bounded evidence segment. It separates
primary tasks from lightweight but identifiable activity, while truly
generic app and system noise remains rejectable.

#### 500-character cap so custom guidance cannot crowd out evidence
`PromptTemplates.dayDigestCustomPromptMaxCharacters`: Ceiling for the user's optional digest instructions — enough for tone
and emphasis, small enough that guidance can never crowd out evidence.

#### Custom guidance sanitized, capped and appended; empty returns base
`PromptTemplates.dayDigestSystem(custom:)`: Day digest system prompt with the user's optional instructions from
Settings folded in. Empty (or whitespace-only) guidance returns the
base prompt unchanged; anything else is sanitized, capped, and
appended so it shapes the digest without replacing its structure.

#### Chat-backend autocomplete fallback; built-in server uses raw endpoint
`PromptTemplates.autocompleteSystem`: Chat-backend autocomplete fallback (cotyping via Ollama / Apple
Intelligence; the built-in llama-server uses the raw endpoint instead).

### `LokalBot/Services/Notes/SummaryClaimEvidence.swift`

#### App resolves claim speaker; identity never from model prose or alias
`SummaryClaimEvidence`: The model selects and paraphrases claims; the app resolves their speaker.
Source identity never comes from the model's prose or a display alias.

#### Safe to log or send as repair feedback; no meeting content
`SummaryClaimEvidence.ValidationError`: Safe to log or send as repair feedback: never contains model output,
transcript text, speaker aliases, or other meeting content.

#### Narrative claims stay explicit reported speech
`SummaryClaimEvidence.render`: Every narrative claim remains explicitly reported speech.
First-person prose cannot silently become the reader's words.

### `LokalBotTests/Services/Notes/MeetingNotesGeneratorTests.swift`

#### Qwen3.5 4B copied cited source IDs into due (2026-10-01)
`MeetingNotesGeneratorTests.testSourceIDInDueIsNotADueDate`: The built-in Qwen3.5 4B copied cited source IDs into `due`, and the
notes rendered "due s268" (2026-10-01).

#### First answer citing only the status row proves nothing
`MeetingNotesGeneratorTests.testOwnershipRepairReplacesTheUnresolvedTask`: The first answer cites only the status row, which proves nothing.

#### User's own half of a sentence is asked for once
`MeetingNotesGeneratorTests.testMixedActorRepairCanUseTheActualOtherSpeakersCommitment`: The user's own half of that sentence is a commitment no task
covers yet, so the model is asked for it once.

#### Citing the status row with unsaid words stays unresolved until repaired
`MeetingNotesGeneratorTests.testOwnershipRepairKeepsItsReplacementIdentity`: Cites the status row with words nobody said: unresolved until repaired.

#### Ambiguous evidence leaves the task with unclear owner, not a failed meeting
`MeetingNotesGeneratorTests.testRepeatedOwnershipRepairCannotSubstituteAnotherTask`: Repeated ambiguous evidence leaves the task visible with an unclear
owner instead of failing the meeting on every retry.

#### A task between two others whose evidence names both cannot bind to one quote
`MeetingNotesGeneratorTests.unbindableTask`: A task between two other participants whose only evidence names both
actors, so no quote can bind it to one undertaking.

#### Malformed successful JSON triggers one focused re-read, not meeting failure
`MeetingNotesGeneratorTests.testMalformedProviderShapeGetsOneBoundedRecoveryRetry`: A provider can return a successful JSON response with an optional
action that has no source (or even omit the notes array). That shape
must trigger one focused re-read, not fail the whole meeting.

#### At temperature 0 re-asking gives the same answer
`MeetingNotesGeneratorTests missing user commitment`: Asked again at temperature 0, the model gives the same answer.

#### Tokenizer-less byte ceiling plus continuation ledger overran output reservation
`MeetingNotesGeneratorTests.testContinuationOfAPartPackedToTheContextLimitShrinksItsOutput`: Escaped bug: without a provider tokenizer, parts are packed to a byte
ceiling beside a full output reservation. The continuation ledger then
pushed the page over that reservation, and every retry failed before
sending a request.

#### Chunks use tokenizer-less byte bound at 16K context like unknown OpenRouter models
`MeetingNotesGeneratorTests.packedContinuationScript`: First part pages once with `notes` long records; every other part
answers in one page. Chunks use the byte bound of a tokenizer-less
provider at a 16K context, as an unknown OpenRouter model does.

#### Qwen 4B filed a decision under Key points on 2026-11-04
`MeetingNotesGeneratorTests.testAStatedDecisionReachesTheFinishedNotes`: Filmed on 2026-11-04: Qwen 4B filed "Decision made…" under Key points,
so the notes said "No cited decisions" for a meeting that made two.

#### At one token per byte a part fits window with output and envelope headroom
`MeetingNotesGenerator.makeChunks`: Even at one token per byte a part stays inside its window with
the full output and envelope headroom.

#### Parts follow model window in steps so drifting windows keep saved parts
`MeetingNotesGenerator.makeChunks`: Parts follow the model's window in steps: windows within a step plan
identical parts, so a window that drifts between lookups keeps a
meeting's saved parts, and each larger step plans fewer, larger parts.

#### Larger part gets output and record caps of the standard parts it covers
`MeetingNotesGeneratorTests.testALargerPartGetsTheOutputAndRecords`: On 2026-10-07 a 21-minute standup on Cerebras Qwen (64K window) was
planned as four standard parts. A larger part now gets the output and
record caps of the standard parts it covers.

#### Part cut off before any record is rescanned, not continued from empty list
`MeetingNotesGeneratorTests.testAPartCutOffBeforeAnyRecordIsScannedAgain`: On 2026-10-07 reasoning used every output token of a standup's first
part. The next runs asked the model to continue from an empty list of
accepted records, got empty answers, and stopped the part for good.

#### Automatic runs keep a stopped part stopped; asking again scans it
`MeetingNotesGeneratorTests.testSummarizeAgainRetriesAPartAnEarlierRunStopped`: Automatic runs keep a stopped part stopped; asking again scans it.

#### Popular models resolve provider window without network; 20-minute meeting is 1-2 requests
`MeetingNotesGeneratorTests.testPopularModelsPlanAMeetingFromTheirProvidersWindow`: Each popular model resolves its provider's window without a network
lookup, and a 20-minute meeting with calendar context (like the
2026-10-07 standup, planned as four parts) becomes one or two requests
whose schemas fit the provider.

#### Cerebras rejects schemas over 500 enum values
`MeetingNotesGeneratorTests.testPartsKeepTheirSchemaWithinTheProvidersEnumLimit`: On 2026-10-07 the standup's 228 rows became one part whose schema held
709 enum values, and Cerebras rejected it ("cannot exceed 500").

#### One part fits 16K but not its ledger beside full output allowance
`MeetingNotesGeneratorTests.testVerifiedWindowKeepsTheFullOutput`: One part that fits 16K, leaving less room than its own ledger needs
beside the full output allowance.

#### A short deadline may expire during planning before any request
`MeetingNotesGeneratorTests.testDeadlineCancelsInFlightGeneration`: A short deadline may run out during planning, before an HTTP request.

#### Unlimited budget must stay finite and Int-safe for deadline race and allowance
`MeetingNotesGeneratorTests.testGenerationBudgetPresetLimits`: run() races a Task.sleep deadline and allowance() converts
seconds * 35 to Int — even Unlimited must stay finite and Int-safe.

#### Speakers' wording differs so neither turn reads as the other's echo
`MeetingNotesGeneratorTests.thirtyMinuteTranscript`: About 6,000 words over 30 minutes from two speakers. Their wording
differs so neither turn reads as the other's echo.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
