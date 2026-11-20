# 0024. Mac app: Dreaming

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Services/Dreaming/`, `LokalBotTests/Services/Dreaming/`.

## Decisions

### `LokalBot/Services/Dreaming/DreamBriefPresentation.swift`

#### Resolve citations against current library without rewriting persisted evidence
`DreamBriefPresentation`: Resolve the citation format used by both saved and newly generated dreams
against the current library without rewriting the persisted evidence.

#### Replace matches in reverse so ranges stay anchored to original text
`DreamBriefPresentation.markdown`: Reverse replacement keeps all ranges anchored to the original text.

#### Older briefs repeat the title before the id; turn that title into the link
`DreamBriefPresentation.markdown`: Older briefs sometimes say "Demo Day `12345678`". Turn the
existing title into the link instead of repeating it.

### `LokalBot/Services/Dreaming/DreamCompiler.swift`

#### Evidence is gathered up front so synthesis is a pure function of it
`DreamEvidence`: Everything one dream reads, gathered up front so the synthesis step is a
pure function of this value: the analyzed day's meetings with extracted
outcomes, the day digest, screen-memory stats, plus a bounded comparison
window of prior meetings and still-open action candidates.

#### Prior meetings carry titles and days only so recurring themes are spotted without transcripts
`DreamEvidence.priorMeetings`: Meetings from the preceding comparison window (titles + days only),
so the model can spot recurring themes without re-reading transcripts.

#### Pre-rendered candidate lines whose [A1] handles index openActionThreadIDs
`DreamEvidence.openActions`: Pre-rendered action-candidate lines from the window, `- [ ] [A1] …`
style. Each handle indexes `openActionThreadIDs`.

#### Thread ids in handle order tie a top action to its real thread
`DreamEvidence.openActionThreadIDs`: Thread ids for the rendered candidates, in handle order, so a model's
top action can be tied back to the real, checkable action thread.

#### Sources are the complete dependency set, conservatively including truncated inputs, never omitting reads
`DreamEvidence.sources`: Complete, app-owned dependency set for the rendered input, including
comparison-window actions and day-level screen/digest evidence. It may
conservatively include truncated inputs; it never omits a read source.

#### Emptiness ignores the comparison window since it is context about other days
`DreamEvidence.isSubstantivelyEmpty`: True when the analyzed day itself produced nothing worth a model pass:
no meetings, no digest, no saved moments, and less tracked time than a
brief wake-and-glance. The comparison window never counts — it is
context about other days, not evidence of this one.

#### Evidence gathering is deterministic and read-only, with a model-free fallback brief
`DreamCompiler`: Deterministic evidence gathering for one dreamed day plus the model-free
fallback brief. Read-only over the local library; pure enough that every
piece is unit-testable without an engine or a live database.

#### Look back 14 days including the dreamed day, as comparison only
`DreamCompiler.comparisonWindowDays`: The retrospective looks back at most this many days (the dreamed day
included) for recurring patterns — a comparison window, never new
primary material.

#### Cap the journal share since its raw log pushed other evidence past the limit
`DreamCompiler.digestCharacterLimit`: The journal's share of the pack. Its raw activity log can run to
hundreds of KB; unbounded, it pushed app totals, saved moments, the
comparison window, and action handles past `evidenceCharacterLimit`.

#### Under five tracked minutes a day is empty and wakes no model
`DreamCompiler.emptyDayTrackedSecondsFloor`: Under five tracked minutes a day is treated as empty rather than worth
waking a model for.

#### Sample meeting is excluded: made up, not a prior meeting, actions not followed up
`DreamCompiler.compile`: The sample meeting is made up: it is no prior meeting, and its
actions are nobody's to follow up.

#### Keep grounded sections, then as much raw activity log as fits the limit
`DreamCompiler.digestForDream`: The journal's grounded sections (day summary, meetings, agent sessions,
time allocation), then as much of its raw activity log as still fits
`digestCharacterLimit`.

#### Sanitize and hard-cap evidence so OCR-heavy days can't overflow the context window
`DreamCompiler.evidencePack`: The prompt material: every evidence section rendered as labeled plain
text, then sanitized and hard-capped like the summarizer's transcript
input so an OCR-heavy day can't blow the context window.

#### Fallback only restates evidence and never analyzes, so it can't invent
`DreamCompiler.fallbackReport`: The model-free brief: only restates evidence — counts, the day's open
questions, and carry-forward action candidates. It never analyzes,
so it can never invent.

### `LokalBot/Services/Dreaming/DreamEvidenceInvalidation.swift`

#### A meeting affects its day and later comparison windows, including targets without reports to cancel in-flight work
`DreamEvidenceInvalidation.dayKeys`: A meeting contributes to its own day and the following comparison
windows. Include targets without a report so in-flight work is cancelled.

### `LokalBot/Services/Dreaming/DreamEvidenceMutation.swift`

#### Source writes and revocation share one cross-process lock; failed revocation intent leaves source untouched
`DreamStore.withMeetingEvidenceMutation`: Source writes and derived-memory revocation share one cross-process
lock. Failure to persist revocation intent leaves the source untouched.

#### Screen, activity and agent evidence revokes only the dreamed day's reports
`DreamStore.withScreenEvidenceMutation`: Screen, activity, and coding-agent evidence is read only for the
dreamed day itself, never through another day's comparison window, so
it revokes that day's reports and leaves meeting-derived facts alone.

#### Cover adjacent UTC dates so timezone changes can't hide a screen dependency
`DreamEvidenceInvalidation.sourceDayKeys`: Provenance in older artifacts uses civil dates. Cover the adjacent UTC
dates so changing the Mac's timezone cannot hide a screen dependency.
This may retract a neighboring day's facts, which can be regenerated.

### `LokalBot/Services/Dreaming/DreamModels.swift`

#### Day keys are local yyyy-MM-dd, matching file naming and sortable lexicographically
`DreamDay`: Shared "yyyy-MM-dd" day keys for dreaming artifacts — local calendar days,
matching the journal and daily-export file naming, and lexicographically
sortable so "newest report" is a filename sort.

#### Reports record where the model ran to describe the real privacy boundary
`DreamInferenceProvenance`: Where the configured Main LLM processed a dream. Reports retain this
alongside the engine name so the morning surface can describe the actual
privacy boundary instead of assuming every successful engine was local.

#### Persist only scheme/host/port of approved remote; never paths, queries, credentials or keys
`DreamInferenceProvenance.origin`: Canonical scheme/host/port for approved remote inference. Paths, query
strings, credentials, and API keys are deliberately never persisted.

#### Plan approval entry names the provider, never an account
`DreamInferenceProvenance.init`: The plan's approval entry names the provider, never an account.

#### Fallback reason is separate from engine availability; reachable model may return unreadable output
`DreamFallbackReason`: Why an evidence-only brief was written. This is separate from engine
availability: a reachable model can still return an unreadable payload.

#### Model citation text is never used to decide retention of deleted or corrected evidence
`DreamEvidenceSource`: App-owned dependencies of generated memory. Model-written citation text is
never used to decide whether deleted or corrected evidence may be retained.

#### Id is a full meeting UUID or the local day key for day-level evidence
`DreamEvidenceSource.id`: Full meeting UUID, or the local day key for day-level derived evidence.

#### Revision is the store revision captured before gathering sources
`DreamEvidenceProvenance.revision`: The durable store revision captured before gathering these sources.

#### Legacy memory gets no invented links; outputs using it retract on next change
`DreamEvidenceProvenance.includesUnattributedContext`: Legacy memory cannot be assigned invented source links. Any output
which consumed it must also be retracted on the next evidence change.

#### Day-wide revisions may touch any source; activity revisions leave identity-tracked meeting sources
`DreamEvidenceProvenance.isInvalidated`: `revisions` are day-wide changes that may have touched any source on
that day. `activityRevisions` are screen, activity, coding-agent, or
digest changes that never alter a meeting; they leave meeting sources
(which are tracked by identity) untouched.

#### Persisted as dreams/day.json plus md; nil engineName marks evidence-only fallback
`DreamReport`: One overnight retrospective of a single local calendar day. Persisted as
`dreams/<day>.json` (+ a rendered `.md` sibling) and shown on Today the
next morning. `engineName == nil` marks a deterministic evidence-only
fallback; `fallbackReason` records whether the engine was unavailable or
returned an unreadable response.

#### Day is the analyzed day (yesterday at generation), not the display day
`DreamReport.day`: The analyzed local calendar day ("yyyy-MM-dd"), i.e. yesterday at
generation time — not the day the report is shown.

#### Nil only for version-1 reports predating provenance
`DreamReport.inferenceProvenance`: Nil only for version-1 reports written before provenance was tracked.

#### Nil for model reports and legacy evidence-only reports
`DreamReport.fallbackReason`: Nil for model-generated reports and legacy evidence-only reports.

#### Suggested checks are recurring review tasks each with a cadence
`DreamReport.suggestedChecks`: Proposed recurring review/check tasks, each with a suggested cadence.

#### Top actions ranked by expected leverage, at most three
`DreamReport.topActions`: Top actions for today, ranked by expected leverage (at most three).

#### Thread ids align by index, nil for non-candidates, absent in older reports
`DreamReport.topActionThreadIDs`: The action thread behind each top action, aligned by index; nil for
advice that is not one of the recorded action candidates. Absent in
reports written before actions were linked.

#### Shared by Today and Markdown so both state the same inference truth
`DreamReport.provenanceDescription`: Shared by Today and the Markdown rendering so both surfaces tell the
same truth about local/remote inference and fallback cause.

#### Credential scrubbing runs before persisting since reports derive from screen text and transcripts
`DreamReport.redacted`: Reports derive from screen text and transcripts, so the same
deterministic credential scrubbing applied to exports runs before
anything is persisted.

#### Memory merge in app code keeps day-stamping, retention and caps deterministic
`DreamMemoryUpdate`: The memory changes one dream proposes: full updated lists, merged into the
durable `DreamMemory` by `DreamMemory.merging` so day-stamping, retention,
and caps stay deterministic app code rather than model behavior.

#### True only with day evidence; nil keeps the older text-change rule
`DreamMemoryUpdate.Project.activeToday`: True only when the analyzed day's evidence shows work on this
project; false when it is carried forward from memory. Nil when a
backend omitted it, which keeps the older text-change rule.

#### True only when the day's evidence, not echoed memory, reinforced the goal
`DreamMemoryUpdate.Goal.reinforcedToday`: True only when evidence from the analyzed day, rather than the
existing memory echoed in the prompt, reinforced this goal.

#### Expired means completed or abandoned today; merge removes it
`DreamMemoryUpdate.Goal.expired`: True when the day's evidence shows the goal was completed or
abandoned; the merge removes it instead of carrying it forward.

#### Durable work memory stored as memory/memory.json and fed to next night's dream
`DreamMemory`: The durable structured work memory dreaming maintains: active projects,
current goals, and recurring patterns. Persisted as `memory/memory.json`
(+ a rendered `.md` sibling) under the storage root and fed back into the
next night's dream as context.

#### Projects idle 30 days go dormant; goals persist longer since reinforced less often
`DreamMemory.projectRetentionDays`: A project untouched for this many days is considered dormant and drops
out; goals persist longer because they are reinforced less often.

#### Last yyyy-MM-dd day a dream saw project evidence
`DreamMemory.Project.lastActiveDay`: Last day ("yyyy-MM-dd") a dream saw evidence of this project.

#### Pinned projects are exempt from age-out and cap eviction; dreams update but never remove
`DreamMemory.Project.pinned`: User-pinned entries are exempt from retention age-out and cap
eviction; a dream can update them but never remove them.

#### Horizon is free text as stated or inferred, never a normalized date
`DreamMemory.Goal.horizon`: Timeframe as stated or inferred ("this week", "Q3") — never a
normalized date.

#### Pinned goals exempt from age-out, cap eviction and model-proposed expiry
`DreamMemory.Goal.pinned`: User-pinned entries are exempt from retention age-out, cap
eviction, and model-proposed expiry.

#### Parallel metadata keeps string list compatible; missing entries mean unattributed legacy data
`DreamMemory.patternProvenance`: Parallel metadata keeps the public string list compatible with older
views and exports. Missing entries represent unattributed legacy data.

#### Deterministic merge rules: day-evidence freshness, kept-if-unmentioned, pinned immunity, capped lists
`DreamMemory.merging`: Deterministic merge of one night's proposed update:
- proposed projects update or insert by case-insensitive name; the day
  stamp refreshes when the model marks the project active today (or,
  when it omits the flag, when the entry is new or its text changed),
  and a project marked inactive is never inserted;
- goals refresh (and new goals insert) only when the model explicitly
  ties them to evidence from the analyzed day;
- a goal marked expired is removed (never inserted) — the one sanctioned
  removal besides age-out, because it requires day evidence, not absence;
- entries the model did not mention are kept (a small model forgetting
  a project must not erase it) but age out after the retention window;
- pinned entries sort first and skip the freshness filter, so neither
  retention, cap eviction, nor expiry can remove them;
- patterns are a full replacement list, including an explicit empty list;
- everything is capped so memory can never grow unbounded.

#### Freshness follows day evidence, not wording, so paraphrases and verbatim repeats age correctly
`DreamMemory.merging`: Freshness follows the day's evidence, not wording: a
paraphrase must not keep a dead project alive, and an
active project repeated verbatim must not age out.

#### Unchanged patterns keep dependencies; reworded or new ones depend on all synthesis inputs
`DreamMemory.merging`: An unchanged pattern keeps its original dependencies. Reworded
or new patterns depend on everything the synthesis could read.

#### Track full memory dependency closure conservatively since citations can't prove no influence
`DreamMemory.provenance`: A synthesis can use any memory item in its context. Track that complete
dependency closure conservatively; model citations cannot prove that a
different item had no influence on its output.

#### Source revocation overrides pinning; entries without provenance are removed, not guessed
`DreamMemory.retractingEvidence`: Source revocation overrides pinning. Without provenance an older entry
cannot safely be attributed to an unaffected source, so the first
evidence mutation removes it instead of guessing from its display text.

#### Redaction can collapse strings so merge both dependencies
`DreamMemory.redacted`: Redaction can collapse two strings; retain both dependencies.

#### Unparseable day stamps count stale so corrupt entries age out
`DreamMemory.isFresh`: Day-key freshness: parse both keys and compare against the retention
window. Unparseable stamps count as stale — a corrupted entry ages out
instead of living forever.

#### Decoding defaults missing pinned to false; missing provenance stays unknown
`DreamMemory.Project`: `pinned` postdates the first memory files. Custom decoding (in extensions,
so the memberwise initializers keep their defaults) treats a missing key as
false. Missing provenance stays unknown and is never guessed from model text.

### `LokalBot/Services/Dreaming/DreamPrompts.swift`

#### Constrained backends get schema, others prompt shape plus tolerant parse; all pure
`DreamPrompts`: Prompt, JSON schema, and tolerant parsing for the overnight dream pass.
Same split as `OutcomesExtractor`: grammar-constrained backends get the
schema, unconstrained ones rely on the prompt's shape plus the tolerant
parse, and everything here is pure so it tests without an engine.

#### Strict structured outputs require every property, so expired is required and prompted false
`DreamPrompts.schema`: Strict structured outputs require every declared
property. The prompt tells the model to return false
when the goal is still active.

#### Tolerant JSON extraction, strict decoding, hard caps; nil triggers deterministic fallback
`DreamPrompts.parse`: Tolerant extraction of the model's JSON object followed by strict typed
decoding. Every declared field must be present with the right type and
every supplied string must remain meaningful after cleanup. Hard caps
keep a rambling but otherwise valid model from oversizing artifacts.
Nil sends the service down the deterministic fallback path.

#### Blank report bullets are dropped; memory lists stay strict since they replace stored entries
`DreamPrompts.parse`: Report sections are advice, not memory: a blank bullet carries no
claim, so drop it instead of discarding the whole night's work.
Memory lists stay strict because they replace stored entries.

#### Strip handles, link threads; unknown handles removed unlinked and duplicates keep first link
`DreamPrompts.linkTopActions`: Strips candidate handles ("[A2] …") from top actions and maps each to
its action thread. Unknown or out-of-range handles are removed without
inventing a link; duplicates keep only their first link.

### `LokalBot/Services/Dreaming/DreamRollupService.swift`

#### Weekly and monthly lines carry review stamps; stale lines removed, few model calls nightly
`DreamRollupService`: After the overnight review: one line for each recent finished week and
month, condensed from that period's daily reviews, so the agent briefing
can show older time at lower detail (recent days in full, then weeks, then
months). Each line records a stamp of the reviews it came from; a deleted
or regenerated review makes it stale, and stale lines are removed here and
never shown. At most a few model calls a night, newest periods first.

#### Write lines at most every 20 hours to stop rewriting the same week per rebuilt day
`DreamRollupService.minimumGenerationInterval`: New lines are written at most this often. A night that rebuilds
several reviews runs this after each one; without the gap it rewrote
the same week after every rebuilt day.

#### Remove stale lines, write due ones unless recent, create engine only when due
`DreamRollupService.run`: Removes stale lines and lines for periods the briefing no longer
shows, then writes up to `limit` due lines, unless lines were written
within `minimumInterval`. The engine is made only when something is due.

### `LokalBot/Services/Dreaming/DreamScheduler.swift`

#### Report file is the once-per-day marker; gated, bounded catch-up
`DreamScheduler`: Wall-clock scheduler for the overnight dream. Same minute-tick design as
`DailyMemoryExportScheduler` (correct across sleep/wake and DST), with two
dreaming-specific twists:

- the durable once-per-day marker is the report file itself (via the
  injected `hasReport`), so a night the Mac slept through is caught up at
  the next launch or wake, right before the user opens Today;
- a `canRun` downtime gate keeps the dream from competing with recording,
  processing, dictation, or cotyping — it simply waits for the next tick;
- catch-up is bounded to the last `catchUpDays` local days, so a long
  pause never turns into a backlog of unattended model runs.

#### Catch-up covers yesterday plus six earlier days
`DreamScheduler.catchUpDays`: Yesterday plus the six days before it.

#### Evidence-only brief written only after three consecutive transient failures
`DreamScheduler.transientAttemptsBeforeFallback`: Automatic runs that hit a rate limit or dropped connection are retried
after the failure backoff; the evidence-only brief is written only
once this many consecutive attempts for the same day have failed.

#### Previous day dreamed only after configured hour; late sessions belong to evening
`DreamScheduler.Configuration.hour`: Local wall-clock hour (0...23) after which the previous day may be
dreamed. Before it, the previous day is considered still "in use"
(a late session past midnight belongs to the evening's context).

#### Persisted activation boundary; scheduler dreams oldest missing report forward
`DreamScheduler.Configuration.firstEligibleDayKey`: Persisted activation boundary for catch-up. The scheduler walks
forward from this local day and dreams the oldest missing report.

#### Target is immutable local-day snapshot; Calendar.current may change when traveling
`DreamScheduler.Target`: One immutable local-day interpretation shared by scheduling, evidence
compilation, and persistence. `Calendar.current` may change when the
user travels, so a run must not reconstruct any part of this target.

#### Nil in production so each tick snapshots current calendar; tests inject
`DreamScheduler.fixedCalendar`: Nil in production so every tick snapshots the then-current calendar.
Tests can inject a fixed calendar through `init(calendar:now:)`.

#### In-memory scan cursor avoids rescanning completed days every minute tick
`DreamScheduler.scanCursorDayKey`: In-memory high-water mark for the current calendar snapshot. A launch
may scan the persisted activation range once, but subsequent minute
ticks start at the first day not already proven complete.

#### Changed artifact resets scan cursor so next tick repairs the hole
`DreamScheduler.reconsiderReports`: A generated artifact changed behind the in-memory scan cursor. Reset
the high-water mark so the next tick can find and repair the hole.

#### Newer dream can depend on old source through durable memory
`DreamScheduler.reconsiderReports`: A newer dream can depend on an old source through durable memory,
even when its own day is outside the direct comparison window.

#### 15-minute failure backoff; failures visible but not retried every minute
`DreamScheduler.tick`: A failed dream (model unreachable mid-boot, disk error) should be
visible but not retried every minute; generation can also take a
while, so give the system room between attempts.

#### Busy gate does not burn the backoff; waits for quieter tick
`DreamScheduler.tick`: Not downtime yet — recording, processing, dictation, or cotyping is
active. Don't burn the backoff; just wait for a quieter tick.

#### Park scan cursor after yesterday unless boundary is a future opt-in day
`DreamScheduler.tick`: A canonical start after yesterday is either a future opt-in
boundary or the cursor parked on the next not-yet-eligible day.
Keep it intact. Otherwise the scanned range is complete, so park
directly after yesterday and avoid decoding it again next minute.

#### Manual dream ignores enablement, hour, existing report and downtime gate
`DreamScheduler.dreamNow`: Manual run from a user action: ignores whether overnight automation is
enabled, the hour, the existing report (the day is re-dreamed and its
files replaced), and the downtime gate. Still one dream at a time.

#### Deferred dreams retry after backoff and are not surfaced as errors
`DreamScheduler.start`: Retried after the usual backoff; not surfaced as an error.

#### Malformed boundary narrows to yesterday; valid future boundary waits across travel
`DreamScheduler.oldestMissingTarget`: Finds the oldest undreamed local day between the persisted activation
boundary and yesterday (inclusive), looking back at most `catchUpDays`
days. A malformed boundary is narrowed to yesterday for safe migration;
a valid future boundary waits, preserving the user's opt-in boundary
across date-line travel.

#### No same-day memory needed; writing report durably flips the flag
`DreamScheduler.shouldRun`: Run once the clock passes today's configured hour, unless the previous
day already has a report. No same-day memory needed: writing the report
flips `hasReportForPreviousDay` durably.

#### Dream waits for AC power but not user idleness
`DreamScheduler.powerAllowsDreaming`: Dreaming waits for AC power — an unattended model pass must never be
the thing that drains the battery. It does not wait for the user to be
idle: a missed run catches up as soon as LokalBot itself is quiet.

### `LokalBot/Services/Dreaming/DreamService.swift`

#### Evidence-only fallback when no model; generation follows Main LLM privacy boundary
`DreamService`: One night's dream, end to end: compile the previous day's evidence, ask
the Main LLM engine for the retrospective + memory update, merge and
persist. When no model is reachable the deterministic evidence-only brief
is written instead — the morning surface is never empty, and the report
itself says which kind it is. Evidence comes from the local library;
generation follows the configured Main LLM privacy boundary (on-device or
an explicitly approved remote origin), and artifacts land inside the
storage root.

#### Engine resolved per dream so backend changes apply next night
`DreamService.makeEngine`: Resolved per-dream so backend/model changes apply to the next night;
same seam as chat/dictation (`ThinkExecution.makeTextEngine`).

#### Read evidence revision before compilation to detect source mutation
`DreamService.dream`: Read before the detached compilation: cancellation alone cannot
detect a source mutation while the library snapshot is being read.

#### Evidence compilation runs detached, off the main actor
`DreamService.dream`: Evidence compilation walks the whole meeting library; keep that off
the main actor (the scheduler calls this from a MainActor task).

#### Regenerated old reports never replay older synthesis over newer memory
`DreamService.dream`: A missing/corrupt historical report may need regeneration after
later days have already advanced durable memory. Rebuild that report
from its own evidence, but never replay an older synthesis over newer
project/goal/pattern state.

#### Empty day writes deterministic stub without waking a model
`DreamService.dream`: Nothing happened that day. Don't wake a model to say so — write
the deterministic stub through the same save path so the day is
durably marked dreamed and catch-up moves on. Memory carries
forward untouched.

#### Transient errors leave day undreamed so scheduler retries after backoff
`DreamService.dream`: A rate limit or dropped connection is not a broken backend.
Leave the day undreamed so the scheduler retries after its
backoff instead of keeping an evidence-only brief for good.

#### Engine failure writes evidence-only brief and marks day done
`DreamService.dream`: Engine unavailable (no model prepared, server down, remote origin
unapproved…) or still failing after retries. Still deliver the
morning surface — evidence only, memory untouched — and mark the
day done so the scheduler doesn't hammer a broken backend all
night. "Dream now" can redo the day.

#### Output cap prevents reasoning models spending thousands of hidden tokens
`DreamService.maxOutputTokens`: Output allowance for the retrospective plus memory update. Visible
replies run about 1–2K tokens; without a cap a reasoning model on a
remote server spent 4–27K hidden tokens and up to eight minutes per day.

#### On truncation retry once with thinking off and more room
`DreamService.truncationRetryOutputTokens`: The model ran out of room: retry once with thinking off and more room
for the visible JSON, as the day digest does.

#### Transient failure retried quietly; day stays undreamed
`DreamService.Deferred`: A transient failure the scheduler retries after its backoff, quietly:
it is not a user-facing error and the day stays undreamed.

### `LokalBot/Services/Dreaming/DreamStore.swift`

#### Entries keyed by same case-insensitive keys as nightly merge
`DreamMemoryEntry`: A user-manageable item in the durable work memory. Values identify entries
by the same case-insensitive keys the nightly merge uses.

#### Dream artifacts live in private storage root; report JSON is completion marker
`DreamStore`: Persistence for dreaming artifacts, entirely inside the private storage
root (never a user-chosen folder, unlike routines/exports — so plain
overwrite is safe and no ownership sidecars are needed):

  dreams/\<yyyy-MM-dd>.json   # structured report, source of truth
  dreams/\<yyyy-MM-dd>.md     # human-readable rendering of the same report
  memory/memory.json         # structured work memory, source of truth
  memory/memory.md           # human-readable rendering

A valid report whose embedded day matches its filename doubles as the
durable "this day was dreamed" marker the scheduler consults, so a crash
between runs never double-dreams and a missed night is retried at launch.

#### Serialize revision check and writes across all store instances
`DreamStore.mutationLock`: Store values are created by several services. Serialize the revision
check and writes across all instances, not only one scheduler task.

#### Activity-only invalidation days; absent in older intents
`DreamStore.PendingInvalidation.activityDays`: Days whose screen, activity, coding-agent, or digest evidence
changed without touching a meeting. Absent in older intents.

#### Activity-only changes tracked separately from meeting invalidation
`DreamStore.EvidenceState.invalidatedActivityDays`: Activity-only changes; see `DreamEvidenceProvenance.isInvalidated`.

#### Dream begun before memory clear cannot write snapshot back
`DreamStore.EvidenceState.memoryClearedRevision`: Revision at which Settings cleared the memory. A dream that began
before it cannot write its snapshot back.

#### Revocation intent kept outside memory/ and blocks all processes until cleanup
`DreamStore.pendingInvalidationURL`: Kept outside memory/ so revocation remains durable if that directory
becomes unwritable. Its presence blocks every process until cleanup.

#### Capture revision before compiling evidence, require it at commit
`DreamStore.evidenceRevision`: Capture this before compiling evidence, then require it when committing.

#### Prepared intents recovered only if lock-protected or owner process exited
`DreamStore.evidenceRevision`: Acquiring this file lock proves a lock-protected mutation is
no longer running. Standalone preflights may still be waiting
for their source write, so only recover them after owner exit.

#### Failed revocation never silently dropped; retried when storage writable
`DreamStore.evidenceRevision`: "Dream now" and the scheduler's normal retry can recover
after storage becomes writable; never silently drop a failed
revocation just because the next changed source is different.

#### Recovery treats activity-only days as day-wide, conservatively
`DreamStore.evidenceRevision`: Recovery treats activity-only days as day-wide: conservative.

#### Day keys sort chronologically, so decode newest-first
`DreamStore.latestReport`: Newest valid report by analyzed day. Day keys sort lexicographically in
chronological order, so candidates are decoded newest-first.

#### Markdown must be durable before the report JSON completion marker
`DreamStore.save(_:)`: The report JSON is the scheduler's durable completion marker, so its
Markdown sibling must be durable before the marker appears.

#### Direct callers also cannot restore a revoked report
`DreamStore.save(_:)`: Direct callers must not restore a previously revoked report either.

#### Remove completion marker first so scheduler rebuilds day with fresh artifacts
`DreamStore.invalidateReport`: Processing can finish after a brief was generated (for example after a
parked crash-recovery job is retried). Remove the generated completion
marker first so the scheduler will rebuild that day with fresh artifacts.

#### Week and month rollups covering the day are removed with it
`DreamStore.invalidateReport`: Week and month lines drawn from this day go with it.

#### Persist revocation before cleanup; reads filter revoked content on failure
`DreamStore.invalidateEvidence`: Persist revocation before cleanup. If a later disk write fails, reads
still filter revoked content and an in-flight synthesis cannot commit.
Legacy items/reports have unknown dependencies and are removed on the
first mutation; pins affect retention, never source revocation.

#### Successful retry reopens root; readers excluded until cleanup succeeds
`DreamStore.invalidateEvidence`: A successful retry may reopen this root. Keep other readers
excluded until cleanup has succeeded or the catch blocks it.

#### Durable intent written before memory journal
`DreamStore.invalidateEvidence`: Durable intent precedes the memory journal. A fresh process
must not mistake a journal permission failure for no change.

#### Journal write failure blocks root from reads and inference
`DreamStore.invalidateEvidence`: Source mutation precedes this call. If even the journal cannot
be written, do not let another store instance read old facts or
start inference in this process. The caller surfaces the error.

#### Autocomplete fails closed with try-lock, never waiting in keyboard callback
`DreamStore.autocompleteEvidenceIsAvailable`: Autocomplete must fail closed during a source mutation without waiting
on a store/file lock inside the keyboard acceptance callback.

#### Prepared barrier before source write; never consumed by inference retry
`DreamStore.prepareEvidenceInvalidation`: Call before a source write. Failure aborts that write; success leaves a
durable barrier until the matching post-write invalidateEvidence call.
A prepared intent is never consumed by a background inference retry.

#### Retract before source change; later Dream errors must not fail successful mutation
`DreamStore.withEvidenceMutation`: Fully retract before changing a source, under the shared app/headless
lock. A cleanup failure leaves the source untouched; a successful source
mutation must not be reported as failed by a later Dream storage error.

#### Advanced revision rejects older generations until lock releases
`DreamStore.withEvidenceMutation`: The advanced revision rejects older generations. No new one can
acquire its revision until this lock releases after the source
write, including nested mutations and partial source failures.

#### Reload before pin change so Settings cannot overwrite newer memory
`DreamStore.setPinned`: Reload before changing a pin so a Settings view cannot overwrite memory
written by a dream since the view appeared. Returns nil when the memory
or selected entry no longer exists.

#### Commit order memory, rendering, then marker, so failures retry safely
`DreamStore.save(report:memory:)`: Persist one complete dream. Memory is committed first, followed by the
report rendering, and the report JSON marker last. Any earlier failure
therefore leaves `hasReport` false so the scheduler can retry safely.

#### Atomic staleness check and commit; only read sources decide staleness
`DreamStore.saveGenerated`: No await can occur between the staleness check and the complete commit.
Even a model or headless caller that ignores task cancellation cannot
put a snapshot taken before source revocation back into the store.

Only the sources this dream read decide whether it is stale: a change
to another day's evidence while the model ran no longer discards the
run. Memory written here is retracted against the current state, so a
revocation committed during generation still removes its facts. A
report without provenance falls back to the store-wide revision.

#### Retention never removes reports or memory; only Clear and source deletion do
`DreamStore.clearAll`: Settings' "Clear work memory": deletes every report and the work
memory. Scheduled retention never removes them (they outlive the screen
window), so this and source deletion are how they go away.

#### Nil during pending revocation so callers withhold evidence-backed data
`DreamStore.evidenceCheck`: For evidence-backed data kept outside this store (learned personal
claims): a check that is true when a later deletion or correction of a
source invalidated the provenance. Nil while a revocation is pending or
the state can't be read, so callers withhold that data until cleanup.

#### Advisory file lock makes revision check and commit atomic across processes
`DreamStore.withLock`: The headless runner and app can share a library. An advisory file
lock makes revision-check + commit atomic across those processes too.

### `LokalBotTests/Services/Dreaming/DreamLoopTests.swift`

#### 2026-10-01 Dream re-dreamed seven days eight times and never kept memory
`DreamLoopTests`: The overnight Dream re-dreamed the same seven days about eight times on
2026-10-01 and never kept a memory: every retention pass, digest refresh,
and unrelated meeting edit discarded or revoked reports, and a rate limit
was recorded as a finished evidence-only day.

#### Recent report comparing a later meeting survives expiry of earlier captures
`testScreenDeletionKeepsRecentReportsAndMeetingDerivedMemory`: A recent report whose comparison window reaches a meeting held the
day after the captures that are now expiring.

#### A meeting finishing while yesterday is dreamed must not discard the dream
`testUnrelatedChangeWhileTheModelRunsDoesNotDiscardTheDream`: Tonight's meeting finished processing while yesterday was dreamed.

#### A blank advice bullet once discarded the 19:07 dream
`testBlankAdviceBulletDoesNotDiscardTheNight`: The 19:07 dream was thrown away because one advice bullet was blank.

### `LokalBotTests/Services/Dreaming/DreamMemoryRetractionTests.swift`

#### Full UUID provenance matches even when time zones change the day key
`testMeetingIdentityRetractsEvidenceAfterCalendarDayChanges`: A different time zone can put the same meeting on another local day.
Full UUID provenance must still match even if day keys no longer do.

#### A reopened store models a generation that missed cancellation, even after restart
`testPersistedRevisionRejectsUncancelledGenerationFromBeforeDeletion`: A new instance models a separate generation completion which did not
observe scheduler cancellation, including one resumed after restart.

#### Interrupted-retraction state is recreated by writing files, not permission failures
`testMemoryAndReportReadsFailClosedAfterInterruptedRetraction`: Recreate the on-disk state after revision persistence but before
cleanup, without relying on permission failures when tests run root.

#### Copying persisted files to a fresh root reproduces a reader in a new process
`testDurableIntentBlocksAStoreWithNoInMemoryFailureState`: Copy the actual persisted files to an unseen root. No static block
exists for that root, reproducing a reader in a fresh process.

#### A missing failing journal on restart must not restore unchanged old memory
`testDurableIntentBlocksAStoreWithNoInMemoryFailureState`: The failing journal is gone on restart, but its absence must not
restore the unchanged old memory file.

#### If the revision journal can't be written, the source must stay unchanged
`testRevisionJournalFailurePreventsTheSourceMutation`: Intent creation still succeeds, but the subsequent revision journal
cannot be decoded or replaced. The source must remain unchanged.

#### A directory at the journal path simulates storage failing even on privileged runners
`testRevisionJournalFailureAfterSourceSuccess`: Simulate Dream storage becoming unavailable after source success.
A directory at the journal path fails even on privileged runners.

#### A successful model reply after mutation, uncancelled, must still be rejected
`testStaleSynthesisIsRejected`: Deliberately return a successful model reply after the mutation,
without cancelling this task. The store must still reject it.

### `LokalBotTests/Services/Dreaming/DreamingTests.swift`

#### Dream hour is clamped: 99 behaves as 23, not always due
`DreamScheduler.shouldRun`: Defensive hour clamp: 99 behaves as 23, not as "always due".

#### Report marker is written only after memory persists; blocked memory dir forces failure
`testCombinedSaveWritesReportMarkerOnlyAfterMemorySucceeds`: A regular file where the memory directory belongs forces the first
persistence phase to fail. The scheduler marker must remain absent.

#### Catch-up dreams cover older days, so the narrative names no relative day
`DreamPrompts.system`: Catch-up dreams cover older days, and the brief is read later, so
the narrative names no relative day.

#### Dream prompt avoids 'Mac' because the pass may run on an approved remote model
`DreamPrompts.system`: The pass may run on an approved remote model.

#### Fallback leads with the user's own commitment and never infers analysis sections
`DreamCompiler.fallbackReport`: The user's own commitment leads; analysis sections stay empty
because the fallback never infers.

#### A project proposed identically is not activity; its stamp must not refresh
`DreamMemory.merging`: Proposed identically → not "activity"; the stamp must not refresh.

#### Model returns full replacement lists, so an empty list intentionally clears
`DreamMemory.merging`: The model returns a full replacement list, so [] intentionally clears.

#### A brief wake to glance at something still counts as an empty day
`DreamEvidence.isSubstantivelyEmpty`: A brief wake to glance at something is still an empty day…

#### The comparison window alone never makes a day substantive
`DreamEvidence.isSubstantivelyEmpty`: The comparison window alone never makes a day substantive.

#### Empty-day stub advances the memory watermark so catch-up moves past the day
`DreamService empty day`: …and advances the memory watermark so catch-up moves past the day.

#### Beyond the lookback the card goes quiet instead of resurrecting stale briefs
`TodayDreamSelection.report`: Beyond the lookback the card goes quiet instead of resurrecting
stale briefs.

#### A stale brief must carry its own day, never 'for today'
`TodayDreamSelection.prioritiesHeading`: A Thursday brief surfacing on Sunday must carry its own day —
never "for today".

#### Beyond a week a bare weekday is ambiguous, so use the date
`TodayDreamSelection.prioritiesHeading`: Beyond a week, a bare weekday would be ambiguous — use the date.

#### Yesterday panel label is the same rule, as a value localized by the page
`testPrioritiesSourceIsTodayOnlyForYesterdaysBrief`: The Yesterday panel's label is the same rule, as a value the page
can show in the app's language.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
