# 0089. Windows and Linux: core — dream

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-core/src/dream/`.

## Decisions

### `LinuxWindows/crates/lokalbot-core/src/dream/mod.rs`

#### Dream artifact formats match Mac so either app reads the library
The overnight review's artifacts (`Services/Dreaming/DreamModels.swift`):
one report per reviewed day and the durable work memory of active projects,
goals and patterns. The formats match the Mac's, so a library written by
either app is read by the other.

#### Retrospective looks back at most 14 days including reviewed day
`COMPARISON_WINDOW_DAYS`: The retrospective looks back at most this many days, the reviewed day
included (`DreamCompiler.comparisonWindowDays`).

#### Catch-up covers yesterday plus six prior days, as DreamScheduler
`CATCH_UP_DAYS`: `DreamScheduler.catchUpDays`: yesterday plus the six days before it.

#### Day keys are local calendar days yyyy-MM-dd, sorting by date
`day_key`: `DreamDay.key`: local calendar days as `yyyy-MM-dd`, which sort by date.

#### Canonical key equals its own parse round trip
`is_canonical_day_key`: A canonical key: the same text it parses back to.

#### Source feeds its own day and following windows; unreported days included to cancel work
`report_day_keys`: `DreamEvidenceInvalidation.dayKeys`: a source feeds its own day and the
comparison windows that follow it. Days without a report are included so
work already in flight is cancelled.

#### Store only approved origin, never paths, queries, credentials or keys
`InferenceProvenance`: Where the Think model processed a review. Paths, queries, credentials and
keys are never stored, only the approved origin.

#### Valid report matching its filename is the reviewed marker; no engine means evidence-only
`DreamReport`: One overnight retrospective, `dreams/<day>.json`. A valid report whose day
matches its file name doubles as the "this day was reviewed" marker. No
`engine_name` marks an evidence-only brief.

#### Day is the reviewed local day, not display day
`DreamReport.day`: The reviewed local day, not the day the report is shown.

#### Thread ids align by index with top actions
`DreamReport.top_action_thread_ids`: The action thread behind each top action, aligned by index.

#### Page and Markdown must tell same truth about where model ran
`DreamReport::provenance_description`: Today and the Markdown copy tell the same truth about where the model
ran and why a brief is evidence-only. Written for the file; `tr` keys
are used by the page when it shows this.

#### Reports derive from screen and transcripts, so credentials are scrubbed before saving
`DreamReport::redacted`: Reports derive from screen text and transcripts, so the same credential
scrubbing applied to exports runs before anything is saved.

#### Model proposes full lists; merge keeps stamps, retention and caps in app code
`MemoryUpdate`: What one night proposes: full updated lists, merged by [`DreamMemory::merging`]
so day stamps, retention and caps stay app code rather than model behaviour.

#### None keeps older text-change rule when backend omits it
`ProposedProject.active_today`: True only when the day's evidence shows work on it; `None` when a
backend left it out, which keeps the older text-change rule.

#### memory.json is fed back into next night's review
`DreamMemory`: `memory/memory.json`, fed back into the next night's review.

#### Missing entries are unattributed legacy data
`DreamMemory.pattern_provenance`: Missing entries are unattributed legacy data.

#### Pinned items skip age-out and cap; review updates but never removes
`MemoryProject.pinned`: Exempt from age-out and the cap. A review can update it, never remove it.

#### Horizon kept as stated, never normalized to a date
`MemoryGoal.horizon`: As stated or inferred ("this week", "Q3"), never a normalized date.

#### Merge rules: case-insensitive names, evidence-tied goals, expiry, pins, replacement patterns
`DreamMemory::merging`: `DreamMemory.merging`: projects update or insert by case-insensitive
name; goals refresh or insert only when tied to the day's evidence; a
goal marked expired goes unless pinned; what the model didn't mention
stays until it ages out; pins skip age-out and the cap; patterns are a
full replacement list.

#### Project freshness follows day's evidence, not wording
`DreamMemory::merging`: Freshness follows the day's evidence, not wording: a
paraphrase mustn't keep a dead project alive, and an active
project repeated verbatim mustn't age out.

#### Unchanged pattern keeps provenance; new or reworded depends on all sources
`DreamMemory::merging`: An unchanged pattern keeps its dependencies; a reworded or new
one depends on everything the synthesis could read.

#### Synthesis depends on all memory items plus its sources
`DreamMemory::provenance_adding`: A synthesis can use any memory item in its context, so its dependencies
are everything memory depends on as well as `sources`.

#### Redaction can collapse two patterns; merge both provenance sources
`DreamMemory::redacted`: Redaction can collapse two strings; keep both's sources.

#### Unparseable day stamp counts stale so corrupted entries age out
`is_fresh`: An unparseable stamp counts as stale: a corrupted entry ages out.

### `LinuxWindows/crates/lokalbot-core/src/dream/presentation.rs`

#### Resolve citations at display time without rewriting saved brief; missing ids read unavailable
Resolves a brief's citations against the current library without rewriting
what was saved (`DreamBriefPresentation`). An id the library no longer has
reads as unavailable rather than a raw handle.

#### Older briefs with title plus id link the existing title instead of repeating
`brief_pieces`: The text with each cited id as a meeting. Older briefs sometimes say "Demo Day
`12345678`": the title already there becomes the link instead of repeating.

### `LinuxWindows/crates/lokalbot-core/src/dream/rollup.rs`

#### Rollups are caches stamped by source reviews; stale lines never shown
One line per past week and month, condensed from the overnight reviews
(`DreamRollupFormat.swift`, the deterministic half of `DreamRollupService`).
A rollup is a cache over the daily reviews: it records a stamp of the reviews
it was made from, and anyone reading it recomputes that stamp, so a deleted,
retracted or regenerated review makes it stale at once. Stale lines are never
shown. Clear work memory removes them with the reviews (`dreams/rollups`).

#### Rollups written at most every 20 hours since rebuild nights call it repeatedly
`MINIMUM_GENERATION_INTERVAL_SECONDS`: New lines are written at most this often: a night that rebuilds several
reviews runs this after each one.

#### Key formats are 2026-W41 for weeks and 2026-09 for months
`Rollup.key`: "2026-W41" or "2026-09".

#### Reviews whose day mismatches file name are ignored, as the store does
`rollup::reviews`: Every readable review, by day. One whose day doesn't match its name is
ignored, as the store does.

#### Stamp changes when a review appears, disappears or is regenerated
`rollup::stamp`: Changes whenever a review in the period appears, disappears or is regenerated.

#### Only finished weeks and months, newest first
`rollup::periods`: The finished weeks and months the briefing can show, newest first.

### `LinuxWindows/crates/lokalbot-core/src/dream/store.rs`

#### Dream store layout, shared advisory lock with Mac, revocation-pending blocks memory reads
Persistence for the overnight review (`DreamStore.swift`), inside the
library:

  dreams/\<yyyy-MM-dd>.json    the report; its presence marks the day reviewed
  dreams/\<yyyy-MM-dd>.md      the same report, readable
  memory/memory.json          work memory
  memory/memory.md            the same memory, readable

Every check-then-write runs under the advisory `.dream-store.lock`, which the
Mac takes too. Withdrawing changed evidence first records its intent in
`.dream-revocation-pending.json`: while that file exists nothing may read
overnight memory, so a failed cleanup can't leave old facts in use.

#### Review whose inputs changed while running must not be saved
`StoreError::Cancelled`: What this review read changed while it ran, so it must not be saved.

#### Pinnable items keyed by merge's case-insensitive keys
`MemoryEntry`: A work-memory item the person can pin, by the merge's case-insensitive keys.

#### Same durable revocation intent record the Mac writes
`PendingInvalidation`: One revocation's durable intent, as the Mac writes it.

#### Days where non-meeting evidence changed without touching a meeting
`PendingInvalidation.activity_days`: Days whose screen, activity, coding-agent or digest evidence changed
without touching a meeting.

#### Unfinished revocations block overnight memory reads even if record unwritten
`BLOCKED`: Revocations this process couldn't finish. Nothing reads overnight memory for
these roots until a retry succeeds, even if the record itself couldn't be
written (`blockedRoots`, `pendingInvalidations`).

#### Capture revision before compiling evidence, require at commit; finish unfinished revocation
`DreamStore::evidence_revision`: Capture this before compiling evidence, and require it when committing.
A revocation left unfinished is finished first.

#### Lock held proves protected mutation ended; unprotected own-process intent is incomplete
`DreamStore::evidence_revision`: Holding the lock proves a lock-protected mutation is over. This
app only writes those, so an unprotected one is from a Mac run
that isn't this process, and its write can't be coming here.

#### Recovery treats activity-only days as day-wide, conservatively
`DreamStore::evidence_revision`: Recovery treats activity-only days as day-wide: conservative.

#### None during pending revocation so callers withhold evidence-backed data
`DreamStore::evidence_check`: For evidence-backed data kept elsewhere (learned personal items): the
current state, or `None` while a revocation is pending or the state
can't be read, so callers withhold that data meanwhile.

#### Markdown written durably before JSON completion marker
`DreamStore::write_report_locked`: The JSON is the scheduler's completion marker, so its Markdown sibling is
durable before the marker appears.

#### Reload before pinning so stale page cannot overwrite newer memory
`DreamStore::set_pinned`: Reloads before changing a pin, so a page can't overwrite memory a review
wrote since it appeared. `None` when the entry no longer exists.

#### Staleness judged by read sources only; memory then report, JSON marker last
`DreamStore::save_generated`: One whole review. Only the sources it read decide whether it is stale, so
a change to another day's evidence doesn't discard the run. Memory is
retracted against the current state as it is written, then the report,
with its JSON marker last: an earlier failure leaves the day to retry.

#### Clear removes reports, memory and pins; retention never does
`DreamStore::clear_all`: Clear work memory: every report and the memory, pins included. Scheduled
retention never removes them, so this and source deletion are how they go.

#### Intent durable before state advances; pins never affect source revocation
`DreamStore::invalidate_evidence`: `DreamStore.invalidateEvidence`: the intent is durable before the state
advances, and memory and reports are cleaned up after it. Returns the
report days removed. Pins affect retention, never source revocation.

#### Caller must hold the store lock
`DreamStore::revoke_locked`: With the store lock held.

#### On failure block other stores from reading old facts or starting review
`DreamStore::revoke_locked`: Don't let another store read old facts or start a review.

#### Write intent before state so failed state write isn't mistaken for no change
`DreamStore::commit_revocation`: The intent precedes the state: a fresh process mustn't mistake a
failed state write for no change.

#### Undecodable memory file is left alone, filtered by state, must not block deletion
`DreamStore::commit_revocation`: A file this version can't decode stays as it is: every reader filters
it by the state just written, and it mustn't stop a deletion.

#### Revocation overrides pinning; items without provenance go with first change
`retracting`: `DreamMemory.retractingEvidence`. Source revocation overrides pinning, and an
item without provenance goes with the first change rather than guessing.

### `LinuxWindows/crates/lokalbot-core/src/dream/tests.rs`

#### Fixture mirrors Mac JSON: pretty, sorted, ISO dates, omitted optionals
`MAC_REPORT`: `dreams/<day>.json` as the Mac writes it: pretty, sorted, ISO dates, and
optional fields left out rather than null.

#### Fixture mirrors Mac memory.json output
`MAC_MEMORY`: `memory/memory.json` as the Mac writes it.

#### File whose day mismatches its name is not a marker
`a_saved_report_is_the_days_completion_marker_with_a_markdown_copy`: A file whose day doesn't match its name is not a marker.

#### Goal without provenance is taken by first change
`source_deletion_retracts_even_pinned_items_and_their_reports`: The goal has no provenance, so the first change takes it too.

#### Rewritten memory file no longer contains retracted items
`source_deletion_retracts_even_pinned_items_and_their_reports`: The rewritten memory no longer holds them for anyone reading the file.

#### Setup simulates Mac crash after writing intent
`an_unfinished_revocation_blocks_use_until_it_is_recovered`: The Mac crashed after writing its intent.

#### Scheduler's next revision read finishes cleanup
`an_unfinished_revocation_blocks_use_until_it_is_recovered`: The scheduler's next revision read finishes the cleanup.

#### Pinned project sorts first; inactive projects never inserted
`the_merge_follows_the_days_evidence_and_keeps_what_the_model_forgot`: A pinned project sorts first; an inactive one is never inserted.

#### Explicit empty pattern list clears patterns
`the_merge_follows_the_days_evidence_and_keeps_what_the_model_forgot`: An explicit empty list clears the patterns.

#### Written rollup JSON must be readable by the Mac
`deleting_a_report_removes_the_lines_covering_it`: A Mac can read what is written here.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
