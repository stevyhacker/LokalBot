# 0009. Timeline, Today and the Dream review

- Status: Accepted
- Date: 2026-11-20

## Context

This feature covers the activity timeline and its sampler, the Today page, the day digest (the daily journal written from a day's activity, screen text, meetings and coding-agent work), the optional daily Markdown note, memory routines, and the overnight Dream review that turns past days into reports, work memory and week and month rollups. The Mac app implements it in Swift, and the Windows and Linux app in Rust, mostly in `lokalbot-ai`, `lokalbot-core` and `lokalbot-engine`. These decisions were moved here from code comments when the code stopped carrying comments ([ADR 0001](0001-code-carries-no-comments.md)).

## Day digest generation

### The journal's facts are rendered from evidence, and the model only groups work

A day's evidence (activity blocks, screen text, finished meetings) is cut into gap-aware segments. A first model pass per segment extracts work candidates, and a second pass groups them into tasks. The journal's meetings, time allocation and full activity log are rendered from the evidence itself, so a weak or failed model never loses activity.

Where: `LinuxWindows/crates/lokalbot-ai/src/digest.rs` (file), `LokalBot/Services/Timeline/DayDigestEvidence.swift`, `LokalBot/Services/Timeline/DailyDigestEvidence.swift`.

### Coding-agent sessions are stated from recorded facts and added after aggregation

The agent-sessions section holds recorded facts only, one entry per session. The agent's own report is a claim for the model to corroborate, so it stays out of that section. Segment extraction keeps at most three items per segment and a small model rarely fills them all, so parallel sessions could vanish: sessions that recorded an outcome are stated from their actions and added after aggregation, because a small model asked to merge them blends unrelated sessions.

Where: `LinuxWindows/crates/lokalbot-ai/src/digest.rs` (`agent_sessions_section`), `LokalBot/Services/Timeline/DayDigestEvidence.swift` (`DayDigestOverviewGenerator.generateResult`).

### Segment answers are cached in memory by exact prompt

A digest is regenerated whenever a meeting finishes or evidence settles, and without a cache every run re-asked the model about every segment, including morning segments whose evidence had not changed (16 full runs on 2026-10-01). Answers to prompts already asked today are kept by exact prompt, in memory only and bounded, and are purged with the day's journal when evidence is deleted or corrected, so no derived text outlives its source.

Where: `LokalBot/Services/Timeline/DayDigestEvidence.swift` (`DayDigestSegmentCache`).

### Coding-agent evidence joins a day's signature only when present

Agent evidence is appended to the day's content signature only when there is some, so days without agent work keep matching the signatures their journals and cached artifacts were generated with.

Where: `LinuxWindows/crates/lokalbot-ai/src/digest.rs` (`content_signature`), `LokalBot/Services/Timeline/DailyEvidenceSnapshot.swift` (`DailyEvidenceSnapshot.signature`).

### The latest evidence time is gathered one source at a time

A single chained sum of the six evidence arrays exceeds the type checker's time limit on slower build machines, so the sources are appended one at a time.

Where: `LokalBot/Services/Timeline/DailyEvidenceSnapshot.swift` (`DailyEvidenceSnapshot.latestEvidenceAt`).

### A failing model gets a durable repair budget and keeps its backoff

Repeated degraded writes for unchanged evidence increment a durable budget that records whether the journal still needs a model-backed repair, so a persistently crashing model cannot be relaunched forever. When primary evidence changes while the scheduler may be awaiting a model, that snapshot-bound run is cancelled and policy picks a fresh one, but a recent model failure keeps its backoff: on 2026-10-01 every finished meeting cleared it, so a rate-limited provider was asked again at once.

Where: `LokalBot/Services/Timeline/DayDigestEvidence.swift` (`DayDigestGenerationMetadataStore.record`), `LokalBot/Services/Timeline/DayDigestScheduler.swift` (`DayDigestScheduler.reconsiderEvidence`).

### Daily reports follow the note language, and saved evidence stays as recorded

A day has no single transcript to match, so the day digest and the overnight review write their prose in the explicit note language, and with Match Transcript in the resolved interface language. Every model pass, its retry after an output limit, and the segment cache key carry that rule, so changing the language never reuses another language's answers. Model-free fallbacks use the note language's interface catalog when one exists and the interface catalog otherwise (custom languages included). JSON keys, status values, IDs, parser-required headings such as `### Tasks`, and the internal `Pull requests:` prefix used for matching stay canonical; recorded actions, quoted sources and source titles are never translated. Existing reports are not rewritten when the setting changes. A model-free brief formats tracked time with the note language's units ("4 ч", not "4h"). The Dream report and work-memory Markdown files keep canonical English headings and provenance, because the memory file is fed back into prompts and both are library artifacts rather than interface; the provenance line on the Today card is interface text and follows the interface language on both platforms.

Where: `LokalBot/Models/Meetings/SummaryLanguage.swift` (`DailySummaryLanguage`), `LokalBot/Services/Timeline/DayDigestEvidence.swift` (`DayDigestOverviewGenerator`, `displayedOutcome`), `LokalBot/Services/Dreaming/DreamCompiler.swift` (`fallbackReport`), `LinuxWindows/crates/lokalbot-ai/src/language.rs` (`DailySummaryLanguage`), `LinuxWindows/crates/lokalbot-ai/src/digest.rs`, `LinuxWindows/crates/lokalbot-ai/src/dream.rs`.

## Digest schedule and ownership

### The digest is written once a day after `dayDigestHour`, and past days are finalized once

The digest is written automatically after `dayDigestHour`, or on request. The journal file's mtime is the durable once-per-day marker: a journal written at or after today's target hour, by the scheduler or a manual regenerate, means done, across an app relaunch too. After the local date changes, past days are finalized once, oldest first and at most seven days back, and that rewrite is their durable marker, so late work after the evening preview is included. A degraded journal isn't final, a changed source reopens a day whose signature no longer matches, and a past day's new digest reopens that day's overnight review.

Where: `LinuxWindows/crates/lokalbot-engine/src/digest.rs` (file, `past_day`), `LokalBot/Services/Timeline/DayDigestScheduler.swift`, `LokalBotTests/Services/Timeline/DayDigestSchedulerTests.swift` (`testDigestWrittenAfterTargetHourSuppressesTheRun`).

### A journal the person edited is never overwritten

The SHA-256 of the journal Markdown is kept in `DigestMeta.journal_digest`, filled in by `Library::save_digest` when empty. A journal that no longer matches it was edited by the person and is never replaced. The writer captures the journal revision before awaiting a model and checks it again immediately before committing, so a user edit or a newer generation wins.

Where: `LinuxWindows/crates/lokalbot-core/src/model/digest.rs` (`DigestMeta.journal_digest`), `LinuxWindows/crates/lokalbot-engine/src/digest.rs` (`past_day`), `LokalBot/Services/Timeline/DayDigestJournalWriter.swift` (`DayDigestJournalWriter`).

### An interrupted journal commit is finished from a pending-write record

The filesystem can't make the two-file journal commit atomic, so enough intent is kept beside it to finish the ownership sidecar after a crash. Readers recognize the intended digest while the record exists, so a generated journal never becomes user-owned just because the sidecar write was interrupted.

Where: `LokalBot/Services/Timeline/DayDigestJournalWriter.swift` (`DayDigestJournalWriter.PendingWrite`).

### A digest is rewritten only when the person asks

The day's menu item names what choosing it will do: write the first digest, update one that has newer activity, or rewrite a current one. Each is an explicit action, and nothing rewrites a digest unasked.

Where: `LokalBot/Models/Timeline/TimelineDayStrip.swift` (`TimelineDigestPreview.menuTitle`), `LinuxWindows/crates/lokalbot-app/src/pages/timeline/day_list.rs` (`digest_menu_title`).

### Callers use a generated digest only while it matches the day's evidence

The day's unedited generated digest comes with whether it still matches the evidence (`DailyEvidenceArtifacts.generatedDigest`), and callers use only a current one, because a stale digest could disagree with newer corrections or evidence.

Where: `LinuxWindows/crates/lokalbot-ai/src/digest.rs` (`generated_digest`).

### Screen Memory reads activity blocks after the digest is generated

Generation can take a minute, and blocks read before the model ran replaced newer ones, so the blocks are read once it finishes.

Where: `LokalBot/Views/ScreenMemory/CaptureView.swift` (`CaptureModel.generateDigest`).

## Evidence changes and retention

### Every source change takes one route, and only meeting changes reach later days

All source changes go through `primaryEvidenceDidChange`, so exports, routines and reused digest answers can't diverge from what changed. Meetings feed later days' comparison windows, while screen, activity and coding-agent evidence is read only for its own day. Treating a screen change as a meeting change made every retention pass discard two weeks of Dream reports.

Where: `LokalBot/AppState.swift` (`AppState.primaryEvidenceDidChange`), `LinuxWindows/crates/lokalbot-engine/src/lib.rs` (`Shared::evidence_changed`).

### Revising or expiring sources keeps the digest; only deleting them withdraws it

On 2026-10-07 a summary rerun started 17 s after a manual digest and removed it before any new notes existed. Reprocessing revises a meeting rather than deleting it, and saved moments are evidence too, so such changes leave the digest in place, marked out of date until it is regenerated. Only deleting a day's sources withdraws its digest.

Where: `LokalBot/AppState.swift` (`AppState.meetingArtifactsWillChange`), `LinuxWindows/crates/lokalbot-core/src/timeline.rs` (`Library.with_moment_revision`), `LokalBotTests/Integration/DailyEvidenceIntegrationTests.swift` (`testOnlyDeletingSourcesWithdrawsTheDayDigest`).

### Past the retention window, a fingerprint mismatch is expiry, not new work

Scheduled retention clears a day's titles and screen text after its digest was written, and the digest outlives them (PRIVACY.md). Past the window a fingerprint mismatch therefore neither marks the digest out of date nor invites a rewrite from what is left.

Where: `LokalBot/Services/Timeline/DayDigestLifecycle.swift` (`DayDigestLifecycle.evidenceHasExpired`), `LokalBotTests/Services/Timeline/DayDigestLifecycleTests.swift` (`testExpiredEvidenceDoesNotMarkTheDigestOutOfDate`).

### A finished day keeps its coding-agent bursts until that work changes

A finished day keeps the bursts its digest and Dream review were written with until a session's work there changes or the session is gone. On 2026-10-20 and 21, sessions that moved to another branch relabeled earlier days' bursts, and each relabel rebuilt those days' digests, several times a day.

Where: `LokalBot/Services/CodingAgents/CodingAgentEvidenceIngestor.swift` (`CodingAgentEvidenceIngestor.apply`).

### The day-in-the-life test writes the digest after the boundary review

A boundary review revokes the day's derived evidence, its digest included, so the digest is written after it, as the day's last derived artifact.

Where: `Scripts/test/day-in-the-life.sh`.

## Overnight review schedule

### The review runs when LokalBot is quiet and on mains power, and reaches back at most seven days

A minute tick drives the schedule, correct across sleep and clock changes, and the report itself is the durable marker, so a night the computer slept through is caught up at the next launch or wake. A review waits until LokalBot is quiet and the computer is on mains power, because an unattended model pass must never be what drains the battery; it does not wait for the user to be idle. It never starts a model download and never reaches further back than seven days or the start of the enabled period.

Where: `LinuxWindows/crates/lokalbot-engine/src/dreaming.rs` (file), `LokalBot/Services/Dreaming/DreamScheduler.swift` (`DreamScheduler.powerAllowsDreaming`).

### Each opt-in period starts at yesterday, and the start is persisted

Turning the review on sets the period's first eligible day to yesterday and persists it; turning it off clears it. Catch-up then never treats a first launch or an opt-in as permission to backfill every historical workday, and a multi-day sleep can't silently skip the last workday. An update to a version that has this boundary gives each enabled period a start, so it doesn't review older days.

Where: `LokalBot/AppState.swift` (`AppState.applyDreamingSetting`), `LokalBot/Models/Settings/AppSettings.swift` (`AppSettings.dreamingFirstEligibleDayKey`), `LinuxWindows/crates/lokalbot-core/src/settings.rs` (`Settings.normalize_dreaming_boundary`), `LinuxWindows/crates/lokalbot-app/src/state.rs` (`AppData::new`).

### Clearing work memory restarts reviews from today

Settings' "Clear work memory" stops a review in progress, deletes every report and the work memory, and moves the enabled period's start to today, so the week before the clear isn't reviewed straight back into memory.

Where: `LokalBot/AppState.swift` (`AppState.clearDreamMemory`), `LinuxWindows/crates/lokalbot-engine/src/dreaming.rs` (`clear_work_memory`), `LinuxWindows/crates/lokalbot-app/src/pages/settings/overnight_review.rs` (`SettingsPage.clear_work_memory`).

### The CLI accepts only a canonical past day as a review target

A current or future day would advance the durable memory watermark past days that haven't happened yet. Requiring the canonical day key also rejects normalized dates such as 2026-02-30 and ambiguous shorthand such as 2026-7-2.

Where: `LokalBot/HeadlessCommands.swift` (`HeadlessCommand.validatedDreamTarget`).

### An empty day gets a stub without waking a model

When nothing happened, a stub marks the day reviewed so catch-up moves on, and memory carries forward.

Where: `LinuxWindows/crates/lokalbot-ai/src/dream.rs` (`dream`).

### Without a model the review writes an evidence-only brief; transient failures retry

When no model is prepared, the server is down, the remote origin is unapproved, or generation keeps failing, a deterministic evidence-only brief is delivered as the morning surface, memory is left untouched, the day is marked done, and the report says which kind it is; "Review now" can redo it. A rate limit or dropped connection is not a broken backend, so the day is left unreviewed and the scheduler retries after its backoff instead of keeping an evidence-only brief for good.

Where: `LinuxWindows/crates/lokalbot-ai/src/dream.rs` (file, `dream`), `LokalBot/Services/Dreaming/DreamService.swift` (`DreamService.dream`).

## Overnight review results and memory

### The model answers against a strict schema, and memory lists are parsed strictly

The JSON schema matches the system prompt for grammar-constrained backends. Strict structured outputs need every declared property, so `expired` is required and the prompt says to return false for an active goal. Parsing extracts the JSON object tolerantly, then decodes it strictly: report sections drop blank bullets, but memory lists stay strict because they replace stored entries, and a parse failure sends the service to the fallback brief.

Where: `LinuxWindows/crates/lokalbot-ai/src/dream.rs` (`schema`, `parse`), `LokalBot/Services/Dreaming/DreamPrompts.swift` (`DreamPrompts.parse`).

### Memory merges deterministically, and freshness follows the day's evidence

Each night's proposed update is merged deterministically, with freshness following the day's evidence rather than the model's wording: a paraphrase mustn't keep a dead project alive, and an active project repeated verbatim mustn't age out. Projects update or insert by case-insensitive name, their day stamp refreshing when the model marks them active today (or, when it omits the flag, when the entry is new or its text changed), and a project marked inactive is never inserted; goals refresh or insert only when the model ties them to evidence from the analyzed day, and a goal marked expired is removed and never inserted, the one sanctioned removal besides age-out, because it needs day evidence rather than absence. Entries the model didn't mention are kept, since a small model forgetting a project must not erase it, but age out after the retention window; pinned entries sort first and skip the freshness filter, so retention, cap eviction and expiry can't remove them. Patterns are a full replacement list, an explicit empty list included, and everything is capped so memory can never grow unbounded.

Where: `LokalBot/Services/Dreaming/DreamModels.swift` (`DreamMemory.merging`), `LinuxWindows/crates/lokalbot-core/src/dream/mod.rs` (`DreamMemory::merging`).

### A missing past report is rebuilt from its own evidence without touching newer memory

A missing or corrupt historical report may need regenerating after later days have already advanced durable memory. It is rebuilt from its own evidence, but an older synthesis is never replayed over newer project, goal or pattern state.

Where: `LokalBot/Services/Dreaming/DreamService.swift` (`DreamService.dream`), `LinuxWindows/crates/lokalbot-ai/src/dream.rs` (`dream`).

### A review is saved memory first and report JSON last

The report JSON is the scheduler's completion marker, so memory is committed first, the Markdown rendering is made durable next, and the JSON is written last. Any earlier failure leaves `hasReport` false, so the scheduler can retry safely.

Where: `LokalBot/Services/Dreaming/DreamStore.swift` (`DreamStore.save(report:memory:)`), `LinuxWindows/crates/lokalbot-core/src/dream/store.rs` (`DreamStore::write_report_locked`).

### The journal's share of the evidence pack is capped

A journal's raw activity log can run to hundreds of KB. Unbounded, it pushed app totals, saved moments, the comparison window and action handles past `evidenceCharacterLimit`, so `digestCharacterLimit` bounds it.

Where: `LokalBot/Services/Dreaming/DreamCompiler.swift` (`DreamCompiler.digestCharacterLimit`).

### Week and month rollups are caches stamped with the reviews they came from

After the overnight review, each recent finished week and month gets one line condensed from its daily reviews, so the agent briefing can show older time at lower detail; the app writes the lines and the CLI reads them. A rollup records a stamp of its source reviews and every reader recomputes it, so a deleted, retracted or regenerated review makes the line stale at once; stale lines are never shown, are removed, and are rebuilt the next night. Clear work memory removes them with the reviews, since they live in `dreams/rollups`.

Where: `LokalBot/CLISupport/DreamRollupFormat.swift` (`DreamRollupFormat`), `LokalBot/Services/Dreaming/DreamRollupService.swift`, `LinuxWindows/crates/lokalbot-core/src/dream/rollup.rs` (file), `LinuxWindows/crates/lokalbot-ai/src/dream_rollup.rs` (file).

### New rollups are written only while agents may read all screen history

Stale lines are always removed, but each new one costs a model call (at most a few a night, newest periods first), so new lines are written only while agents may read all retained screen history, which the briefing's older timeline needs.

Where: `LinuxWindows/crates/lokalbot-engine/src/dreaming.rs` (`roll_up_reviews`), `LinuxWindows/crates/lokalbot-ai/src/dream_rollup.rs` (file), `LokalBot/AppState.swift` (`rollUpReviews`).

## Revocation, privacy and concurrency

### The source revision is read before compiling and checked atomically at commit

The review reads source state before compiling, because a source change while the library is being read can't be noticed any other way. No await can occur between the staleness check and the complete commit, so even a model or headless caller that ignores task cancellation can't put a snapshot taken before a source revocation back into the store. The headless runner and the app can share a library, so an advisory file lock makes the check and commit atomic across those processes too.

Where: `LinuxWindows/crates/lokalbot-ai/src/dream.rs` (`dream`), `LokalBot/Services/Dreaming/DreamStore.swift` (`DreamStore.saveGenerated`, `DreamStore.withLock`).

### Only the sources a review read decide whether it is stale

On 2026-10-01 the review re-dreamed the same seven days about eight times and never kept a memory: every retention pass, digest refresh and unrelated meeting edit discarded or revoked reports, and a rate limit was recorded as a finished evidence-only day. A change to another day's evidence while the model ran no longer discards the run, and a report without provenance falls back to the store-wide revision. Memory written at commit is retracted against the current state, so a revocation committed during generation still removes its facts.

Where: `LokalBot/Services/Dreaming/DreamStore.swift` (`DreamStore.saveGenerated`), `LokalBotTests/Services/Dreaming/DreamLoopTests.swift` (`DreamLoopTests`).

### Revocation is persisted before cleanup, fails closed and overrides pins

Revocation is persisted before cleanup, so if a later disk write fails, reads still filter revoked content and an in-flight synthesis can't commit; the persisted intent blocks reads even in a fresh process with no in-memory failure state. Source revocation overrides pinning, since pins affect retention only. Legacy items and reports have no provenance and can't safely be attributed to an unaffected source, so the first evidence mutation removes them instead of guessing from their display text.

Where: `LokalBot/Services/Dreaming/DreamStore.swift` (`DreamStore.invalidateEvidence`), `LokalBot/Services/Dreaming/DreamModels.swift` (`DreamMemory.retractingEvidence`), `LokalBotTests/Services/Dreaming/DreamMemoryRetractionTests.swift` (`testDurableIntentBlocksAStoreWithNoInMemoryFailureState`).

### Day-keyed revocation also covers the adjacent UTC dates

Provenance in older artifacts uses civil dates, so revocation covers the adjacent UTC dates and changing the Mac's timezone can't hide a screen dependency. This may retract a neighboring day's facts, which can be regenerated.

Where: `LokalBot/Services/Dreaming/DreamEvidenceMutation.swift` (`DreamEvidenceInvalidation.sourceDayKeys`).

### Reviews stay in the library and record only the approved inference origin

Evidence comes from the local library, generation follows the Think model's privacy boundary, and artifacts stay inside the library. Provenance records only the canonical scheme, host and port of the approved remote origin where the Think model processed a review; paths, query strings, credentials and API keys are never stored.

Where: `LinuxWindows/crates/lokalbot-ai/src/dream.rs` (file), `LokalBot/Services/Dreaming/DreamModels.swift` (`DreamInferenceProvenance.origin`), `LinuxWindows/crates/lokalbot-core/src/dream/mod.rs` (`InferenceProvenance`).

### Reports are scrubbed of credentials before they are saved

Reports derive from screen text and transcripts, so the same deterministic credential scrubbing applied to exports runs before anything is saved.

Where: `LokalBot/Services/Dreaming/DreamModels.swift` (`DreamReport.redacted`), `LinuxWindows/crates/lokalbot-core/src/dream/mod.rs` (`DreamReport::redacted`).

### The day's dictation is read once and not kept

The pass that learns about the person reads the day's dictation once, and it is never kept past that pass.

Where: `LinuxWindows/crates/lokalbot-engine/src/dreaming.rs` (`learn_about_person`).

## Timeline and Today

### The rail's away gaps start at the latest end seen so far

The rail shows an away row wherever nothing was recorded for at least `minimum_gap_seconds`. Sessions overlap, as when a meeting runs over the work beside it, so with sessions ordered by start as `work_sessions` returns them, a gap starts at the latest end seen so far.

Where: `LinuxWindows/crates/lokalbot-core/src/timeline.rs` (`rail_rows`).

### Meetings match activity apps by name containment

The sampler stores an app's own name ("zoom.us", "Microsoft Teams") and a meeting stores the name LokalBot gives its call app ("Zoom", "Teams"), so either name may contain the other.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/timeline/day_list.rs` (`is_same_app`).

### Saved moments are exempt from retention

Saving a moment again re-notes it and keeps its creation time.

Where: `LinuxWindows/crates/lokalbot-core/src/timeline.rs` (`Library.save_moment`).

### A hung app can't block window-title reads

On Windows the sampler reads another process's caption into a buffer of the reported length without sending `WM_GETTEXT`. On the Mac, cross-process Accessibility title reads run off the main actor with bounded queue growth and caller latency: one resolver is active at a time, callers for the same PID share it, and a different PID fails closed instead of queuing behind a wedged process.

Where: `LinuxWindows/crates/lokalbot-platform/src/activity/win32.rs` (`window_title`), `LokalBot/Services/Timeline/ActivityTracker.swift` (`FocusedWindowTitleLookup`).

### Store apps are resolved through their child window

Store apps draw inside ApplicationFrameHost, while their own process owns a child window, so the sampler resolves the app from that window.

Where: `LinuxWindows/crates/lokalbot-platform/src/activity/win32.rs` (`WindowsSource::sample`).

### Only an excluded site is recorded anonymously

An unreadable address under site rules and a timed-out read keep the app without a title, and an unknown secure-field state keeps the window title.

Where: `LokalBotTests/Services/Timeline/ActivityStoreTests.swift` (`ActivitySampler`).

### Today reloads before changing pins

Changing a pin reloads first, so the page can't overwrite what a review wrote since.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/today/brief.rs` (`set_pinned`).

## Daily note and routines

### The daily note records a hash of what LokalBot wrote and never overwrites an edit

The optional daily Markdown note is one deterministic file per day with the digest, meeting links, app time and saved moments. A hidden sidecar records the hash of the exact bytes LokalBot wrote, so a person's edit is never overwritten.

Where: `LinuxWindows/crates/lokalbot-engine/src/exports/daily.rs` (file), `LokalBot/Services/Timeline/DailyMemoryExportService.swift`.

### A past day's note gets a new digest only while the whole day is retained

When a digest finishes or is rebuilt after its note was written, today's note refreshes as for any evidence change. A past day's note within the catch-up window is rewritten with the finished digest only while all of that day is still retained, because a digest rebuilt from what retention left would replace a fuller note.

Where: `LinuxWindows/crates/lokalbot-engine/src/exports/mod.rs` (`Exports::digest_did_change`).

### A scheduled routine runs once per token, but a crashed run is retried

Every routine attempt is recorded. A scheduled token is terminal after either success or failure, so a bad destination or malformed source never becomes a tight retry loop, while manual runs use unique tokens and stay available. A `running` row left by a crash is deliberately neither success nor terminal, so the scheduler retries it after the next launch instead of silently losing a due output.

Where: `LinuxWindows/crates/lokalbot-core/src/routines.rs` (file, `Library::routine_has_finished`), `LokalBot/Services/Timeline/MemoryRoutines.swift` (`MemoryRoutineRunStore`).

### Routine suppression looks only at the latest revision

A correction can be reverted (A -> B -> A), so an older success for A must not suppress the run; only the latest revision in the scope is reused.

Where: `LinuxWindows/crates/lokalbot-core/src/routines.rs` (`Library::routine_revision_token`).

## Consequences

- An edited journal or daily note belongs to the person. Generated output never replaces it, and any write that awaited a model checks ownership and revision again just before committing.
- Source changes keep derived content and mark it out of date; only deletion withdraws a digest or review, and staleness is decided by the sources an artifact actually read. A new kind of evidence goes through `primaryEvidenceDidChange` (`Shared::evidence_changed`), with a decision on whether it feeds later days.
- Completion markers (the journal's mtime, the report JSON, a routine's token) are written last, and the overnight review stays bounded: an opt-in start, seven days back, mains power, quiet, and no model downloads.
