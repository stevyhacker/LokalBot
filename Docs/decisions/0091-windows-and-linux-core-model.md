# 0091. Windows and Linux: core — model

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-core/src/model/`.

## Decisions

### `LinuxWindows/crates/lokalbot-core/src/model/activity.rs`

#### Day memory models mirror ActivityTracker, TimelineWorkSession and ScreenshotService Swift types
Day memory: activity blocks, screen moments and work sessions
(`ActivityTracker.swift`, `TimelineWorkSession.swift`, `ScreenshotService.swift`).

#### Title cleared after retention; Private with empty title for excluded apps
`ActivityBlock.title`: Cleared after the retention window; `Private` app with an empty title
for excluded apps and sites.

#### app_id is executable or desktop-file id used for exclusion rules
`ActivitySample.app_id`: Executable or desktop-file id, used for exclusion rules.

#### Kept pixels are encrypted on disk and never leave the app
`ScreenMoment`: A retained screen context moment (`screenshots` row). Pixels, when kept,
are encrypted on disk and never leave the app.

#### Path is empty when only text was kept or pixels expired
`ScreenMoment.path`: Empty when only text was kept or after pixels expired.

#### Adjacent captures in one group look alike; 0 means no group
`ScreenMoment.similarity_group`: Adjacent captures in one group look alike; 0 is no group.

#### Sessions are computed on the fly from blocks, or a meeting on the timeline
`WorkSession`: Work sessions computed on the fly from activity blocks
(`TimelineWorkSession.sessions`), or a recorded meeting on the timeline.

#### Session id format is work-\<first block id> or meeting-\<UUID>
`WorkSession.id`: `work-<first block id>` or `meeting-<UUID>`.

#### Title is up to two window titles, else the session's apps
`WorkSession.title`: Up to two representative window titles joined by " · ", or the
session's apps ("AppA, AppB +2") when no title covered enough of it.

#### True when no window title named the session
`WorkSession.title_names_apps`: True when `title` lists apps because no window title named the session.

#### Active seconds are the union of block intervals
`WorkSession.active_seconds`: Union of block intervals, in seconds.

#### Titles ordered by time spent, most first
`WorkSession.notable_titles`: Observed window titles, most time first.

#### Set when session is a recorded meeting rather than app activity
`WorkSession.meeting_id`: Set when the session is a recorded meeting rather than app activity.

#### Project shares are empty without coding-agent evidence for the day
`WorkSession.project_shares`: Tracked time per project, busiest first. Empty without coding-agent
evidence for the day.

#### Each burst belongs to the one session it overlaps most, counted once
`WorkSession.agent_bursts`: The agent bursts listed under this session. Each belongs to the one
session it overlaps most, so its outcomes are counted once.

#### Title names the project and agents' task instead of window or apps
`WorkSession.title_names_project`: The title names the session's project and its agents' task, instead of
a window or its apps.

#### Includes the day's stored agent work, scheduled runs included
`DayActivity.agent_bursts`: The day's stored coding-agent work, scheduled runs included.

#### Enum mirrors Mac screenContextCaptureMode setting
`ScreenContextMode`: How much screen context day memory keeps (`screenContextCaptureMode`).

### `LinuxWindows/crates/lokalbot-core/src/model/ask_scope.rs`

#### Narrower questions exclude earlier wider answers; reopened conversations never widen
What one Ask question may draw on, as saved with its turns (`AskSourceScope`,
`AskDateScope`, `ChatViewModel.QuestionScope`), and what that means for the
turns around it: earlier, wider answers stay out of a narrower question's
model context, and a reopened conversation never widens.

#### Raw values match the Mac; Today is the Activity source kept for decoding
`AskSourceScope`: A source a question may read. The raw values are the Mac's; `Today` is the
Activity source, a name kept so saved conversations still decode.

#### Agent notes offered only while Read coding agent notes is on
`AskSourceScope::AgentNotes`: Notes the person's coding agents saved for themselves. Offered only
while Read coding agent notes is on.

#### Order is the order questions save sources
`AskSourceScope::ALL`: In the order questions save them.

#### Files and Agent notes always in All sources so toggling never narrows history
`AskSourceScope::defaults`: Every source. Files and Agent notes are part of "All sources" whether or
not they are on, so turning one on or off never makes an earlier question
look narrowed.

#### Civil day key so a time zone change cannot move it
`day_key`: `AskDayScope.key`: a civil day, so a change of time zone can't move it.

#### Storage key format: single day or inclusive range with three dots
`AskDateScope`: `AskDateScope`: one civil-day range shared by search, answers and saved
questions. Single days are `YYYY-MM-DD`; ranges include both ends and are
`YYYY-MM-DD...YYYY-MM-DD`.

#### Saved on both turns of a question, plus attached screen days
`QuestionScope`: `ChatViewModel.QuestionScope`, plus the days of its attached screens: what is
saved on both turns of a question.

#### Sources kept in AskSourceScope::ALL order
`QuestionScope.sources`: In `AskSourceScope::ALL` order.

#### Port's screen-app filter limits screen search so it is a boundary; Mac ignores it
`QuestionScope.screen_app`: Here the screen-app filter also limits the model's screen search, so it
is part of the boundary. The Mac ignores the key.

#### No named sources means all sources
`QuestionScope::allowed_sources`: The sources as a question sends them: all of them when none were named.

#### Current scope is latest question's; no question means none
`QuestionScope::current`: `ChatViewModel.currentQuestionScope`: what the latest question asked
within. A conversation with no question has none.

#### Pairs reaching beyond scope, failed, stopped or Remember-only stay out of model
`finalized_history`: `ChatViewModel.finalizedHistoryForKey` with its evidence filter: the
question/answer pairs that may reach the model for a question within `scope`.
A pair whose question reached further than `scope` stays out, as does one
that failed, was stopped, or only saved a "Remember …" statement.

#### App-limited screen question ignores other apps' answers
`within_screen_app`: A question limited to one app's screens doesn't hear answers from others'.

#### Only failed last turn retries; attached screens need live in-memory ids
`can_retry`: `ChatViewModel.canRetry`. Only the failed last turn can be asked again, and a
question with attached screens only while their ids are still in memory
(`has_live_attachments`): the captured text never reaches disk.

#### Retry uses original scope; all sources only for legacy turns with none
`retry_question`: `ChatViewModel.retry`: the question behind a failed turn, and the scope it
was asked within. Sources default to all only for a legacy turn with none.

#### Remove failed turn and question so retry doesn't duplicate them
`remove_failed_turn`: Takes a failed turn and its question out of the conversation, so asking it
again doesn't repeat them. `false` if it isn't the failed last turn.

#### Test fixture mirrors JSONEncoder output for a current Mac turn
`mac_conversation`: What `JSONEncoder` writes for a current Mac turn, with sorted keys.

#### Test: version-1 turns can't be retried because real scope unknown
`version_one_turns_are_never_reused_under_a_narrower_question`: Nor retried: its real scope is unknown.

#### Test: wider question still sees narrower answers
`earlier_wider_answers_stay_out_of_a_narrower_question`: Wider still sees narrower answers.

#### Unscoped question may reuse dated answers, matching the Mac
`a_date_scoped_question_reads_only_that_range`: An unscoped question may reuse dated answers, as on the Mac.

#### Test: attachments are per question, boundary persists without them
`the_current_scope_is_the_latest_questions`: Attachments are for one question; the boundary carries on without them.

### `LinuxWindows/crates/lokalbot-core/src/model/chat.rs`

#### Conversations stored encrypted in chats/\<UUID>.json.enc
Ask conversations (`chats/<UUID>.json.enc`, see `crate::chats`).

#### Every field may be missing; pre-scope turns are migrated on read
`RawConversation`: What `Conversation.init(from:)` reads: every field may be missing, and turns
saved before question scopes existed are migrated here.

#### Mac key names kept so conversations open on either computer
`ChatMessage`: One turn, stored under the Mac's key names (`ChatMessage` in
`ChatViewModel.swift`) so a conversation opens on either computer.

#### Assistant text stores inline citation markers; UI renders them as [n]
`ChatMessage.text`: Assistant text keeps citations inline as `[meeting:<UUID>@m:ss]`,
`[meeting:<UUID>]` or `[screen:<id>]`; the UI renders them as `[n]`.

#### Older turns dated from conversation; UI shows no time
`ChatMessage.created_at_is_estimated`: An older turn dated from its conversation: the UI shows no time for it.

#### Empty source scopes mean a legacy turn
`ChatMessage.source_scopes`: Sources enabled for this question. Empty on legacy turns.

#### Date filter stored apart from sources so it never grants one
`ChatMessage.day_scope_key`: The civil day or range this question was limited to: `YYYY-MM-DD` or
`YYYY-MM-DD...YYYY-MM-DD` (`AskDateScope.storageKey`). Kept apart from the
sources so a date filter never grants one.

#### Captured text stays out of conversation; only attached screen days saved
`ChatMessage.attached_screen_day_keys`: Civil days of screens attached to the question. The captured text itself
stays out of the conversation; these preserve where it came from.

#### Some with no meetings is still a boundary
`ChatMessage.meeting_ids`: Meetings the question was bound to. `Some` with none is still a boundary.

#### Always written as current version, as on the Mac
`ChatMessage.source_scope_schema_version`: Always written as the current version, as on the Mac.

#### Version-1 turns not reusable or retriable under narrower question
`ChatMessage.legacy_scope_is_ambiguous`: Version-1 turns didn't save enough to be reused or retried under a
narrower question.

#### Failed or stopped turn shown as error with Retry
`ChatMessage.is_error`: The turn failed or was stopped: shown as an error, with Retry.

#### Day scope read raw so a dropped old value can mark the turn ambiguous
`RawChatMessage.day_scope`: A string on current turns; older builds saved an instant, or a key that
no longer parses. Kept raw so a dropped value can mark the turn ambiguous.

#### Distinguish present null from missing key when deserializing
`present_value`: Tells a present `null` from a missing key.

#### Old absolute-date scope dropped; marked ambiguous so retry cannot widen it
`ChatMessage::from`: An absolute date from an older build: its time zone was never saved,
so turning it into a civil day could move the boundary. Drop the day
and keep a retry from silently widening the old request.

#### Undated turns take conversation date estimated; v1 scopes never trusted
`ChatMessage::migrated`: `Conversation.init(from:)`: a turn with no date takes its conversation's,
marked estimated, and version-1 scopes are never trusted for reuse.

#### Version 1 lacked pinned-screen provenance so even Meetings-only could leak text
`ChatMessage::migrated`: Version 1 also omitted pinned-screen provenance, so even a
Meetings-only label could have hidden captured text in its prompt.

#### Version 1 overloaded Today; restore sources without inventing a civil day
`ChatMessage::migrated`: Version 1 overloaded Today as a source and, selected alone, as a
one-day grant to every source. Restore source types without
inventing a civil day; the old answer stays history for full scope.

#### claim_id is None when the Remember statement was refused
`RememberReceipt.claim_id`: The saved claim, or `None` when the statement was refused.

#### Citations in order of appearance, keeping first occurrence of each
`Citation::parse_all`: Parses every `[meeting:…]`/`[screen:…]` marker in order of appearance,
keeping the first occurrence of each.

### `LinuxWindows/crates/lokalbot-core/src/model/digest.rs`

#### Digest file layout journal/YYYY-MM-DD.md plus .meta.json mirrors Swift writer
Day Digest: `journal/YYYY-MM-DD.md` plus its `.meta.json` sidecar
(`DayDigestJournalWriter.swift`, `DayDigestPresentation.swift`).

#### Dates use Swift seconds since 2001 because macOS decoder requires it
`DigestMeta`: `journal/YYYY-MM-DD.meta.json` (v2, `DayDigestGenerationMetadata`).
Dates use Swift's default encoding (seconds since 2001-01-01), which the
macOS decoder requires; ISO strings are accepted when reading.

#### Filled by Library::save_digest when None
`DigestMeta.journal_modified_at`: Modification time of the journal when the sidecar was written;
filled in by `Library::save_digest` when `None`.

#### Repeated degraded writes for unchanged evidence capped at three
`DigestMeta.degraded_attempt_count`: Repeated degraded writes for unchanged evidence (at most 3).

#### Hash mismatch means user edited journal; never overwritten
`DigestMeta.journal_digest`: SHA-256 of the journal Markdown. A journal whose digest no longer
matches was edited by the user and is never overwritten. Filled in by
`Library::save_digest` when empty.

#### Coverage is evidence active seconds over tracked seconds
`DigestCoverage`: Active seconds of evidence that reached the digest over all tracked seconds.

#### No status lead; shown under Other work
`TaskStatus::Unknown`: No status lead; shown under "Other work".

#### Item without bold heading becomes title with empty summary
`DigestTask.title`: The bold heading, or the whole item when it has none (then
`has_heading` is false and `summary` is empty).

#### Time range comes from older time-topic headings
`DigestTask.time_range`: `09:00–10:30` from older `**time · topic**` headings.

#### Filled by Library::day_digest; None means moment no longer kept
`DigestTask.source_moments`: Those sources as they are now, filled by `Library::day_digest`; `None`
is a moment no longer kept.

#### Detail kept as written, e.g. 2h 5m or \<1m
`DigestTimeAllocation.detail`: As written ("2h 5m", "\<1m").

#### Hour is two digits or Other
`DigestActivityGroup.hour`: Two-digit hour ("09"), or "Other".

#### At most three bullets, or the paragraph(s)
`DayDigest.at_a_glance_markdown`: The concise overview: at most three bullets, or the paragraph(s).

#### Highlights are At a glance items, at most 3
`DayDigest.highlights`: "At a glance" items, shown as Highlights (at most 3).

#### Tasks kept in written order; grouped by status title
`DayDigest.tasks`: Ordered as written; group them with `TaskStatus::group_title`
(Blocked, In progress, Other work, Done).

#### Follow-ups exclude decisions, blockers and task next steps
`DayDigest.follow_ups`: Follow-ups that are neither decisions, blockers nor a task's next step.

#### Same follow-ups as rows with optional next step
`DayDigest.follow_up_tasks`: The same follow-ups as rows (title plus optional next step).

#### Stale means newer evidence exists than the digest covers
`DayDigest.is_stale`: Newer evidence exists than what the digest covers.

### `LinuxWindows/crates/lokalbot-core/src/model/follow_up.rs`

#### Follow-up draft is reviewed and sent by the user; LokalBot never sends it
`follow-up-draft.json` in a meeting folder (`FollowUpDraft` in
`MeetingOutcomeState.swift`): the follow-up the user reviews, copies and
sends themselves. LokalBot never sends it.

#### seeded means still the unedited outline from outcomes
`FollowUpDraft.seeded`: Still the outline built from the outcomes, not edited or saved.

#### Seed outline is up to three decisions and five next steps
`FollowUpDraft::seeded`: The outline macOS starts from (`FollowUpDraft.seeded`): up to three
decisions and five next steps with their owners and due dates.

### `LinuxWindows/crates/lokalbot-core/src/model/meeting.rs`

#### Path is relative to library root
`Meeting.relative_path`: Path relative to the library root, e.g. `meetings/2026/10/15-customer-call`.

#### Duration is longest recorded track in seconds
`Meeting.recorded_duration`: Longest recorded track, in seconds.

#### Sample meeting is synthetic: visible to Ask and search but excluded from personal memory
`Meeting.sample_id`: Set on the bundled sample meeting ("orders-api/en"): a made-up call
with synthetic voices. Ask, search and agents still see it; personal
memory (digests, the day, people, projects, actions) leaves it out.

#### Unknown keys preserved so saving meta.json never drops them
`Meeting.extra`: Keys this build doesn't know, written by macOS or a newer release. Kept
as they are so saving `meta.json` here never drops them.

#### Email stays in local metadata; never shown, indexed, exported or prompted
`CalendarParticipantIdentity.email_address`: Kept in local metadata only; never shown, indexed, exported or prompted.

#### Keeps whole segments only; crossing ones need re-transcription to cut audio
`ContentRange::apply`: Keeps segments wholly inside the range (`ContentRange.applying`). A
segment crossing a boundary can't be clipped as text; transcribing
again cuts the audio there instead.

#### Own work excludes merged sources and the made-up sample
`Meeting::is_own_work`: Whether this meeting is the user's own work: what digests, the day,
people, projects, action lists and briefings are built from. Merged
sources live on in their merged meeting, and the sample is made up.

#### Audio saved past the reviewed end
`Meeting::additional_saved_audio_duration`: The reviewed range, when it is usable.
Audio saved past the reviewed end (`additionalSavedAudioDuration`).

#### Unrepresentable length returns start because chrono addition panics
`Meeting::started_plus`: The time `seconds` after the start. A length the calendar cannot hold
(a damaged `meta.json`) gives the start itself: chrono's `+` panics.

#### Wall-clock span unless recorded duration is known
`Meeting::duration_seconds`: Wall-clock span, or the recorded duration when known.

#### Generic titles fall back to calendar title, then App at time
`Meeting::display_title`: Generic titles fall back to the calendar title, then "\<App> at \<time>".

### `LinuxWindows/crates/lokalbot-core/src/model/mod.rs`

#### Field names follow macOS JSON so files round-trip
Serializable records of the library. Field names follow the macOS JSON so
files round-trip between both apps.

### `LinuxWindows/crates/lokalbot-core/src/model/outcomes.rs`

#### Decoding normalizes ownership, first-person phrasing and FNV IDs like Swift
`outcomes.json` and `outcome-state.json` (`LokalBot/Models/Meetings/MeetingOutcomes.swift`,
`MeetingOutcomeState.swift`).

Decoding normalizes records exactly as the Swift decoders do: ownership
is reconciled with the stored attribution, the user's items are owned by
`Me` and phrased in first person, and missing IDs get their stable FNV ID.

#### Port cannot reproduce Swift JSON bytes so revision is not checked
`MeetingOutcomes.transcript_revision`: Matches `Transcript` evidence revision; a mismatch makes outcomes stale.
This port cannot reproduce Swift's JSON bytes, so it does not check
it (see `Library::outcomes` and `Library::save_new_transcript`).

#### Schema v1 stored decisions as plain strings
`decisions_compat`: v1 stored decisions as plain strings.

#### User work first, then mic-spoken unclear, then by importance; nothing dropped
`MeetingOutcomes::prioritized`: The user's work first, then unclear-owner actions spoken on this
computer's microphone, then everything else by importance
(`prioritizingActionItems`). Nothing is dropped.

#### Microphone speaker keys include me, local, local N, merged prefixed
`MeetingOutcomes::is_microphone_speaker`: Microphone speaker keys ("me", "local", "local 2", merged "source1:local 2").

#### FNV-1a over normalized kind, text, owner, due, citations
`MeetingOutcomes::stable_id`: FNV-1a over the normalized `kind|text|owner|due|citations…` fields.

#### Owner as named; Me for user; None when unresolved
`ActionItem.owner`: As named; `Me` for the user's own items; `None` when unresolved.

#### Due phrase kept as spoken, not normalized
`ActionItem.due`: The due phrase as spoken ("by Friday"), not normalized.

#### Unclear owner with mic-spoken evidence is likely the user's
`ActionItem::is_likely_user_action`: Unclear ownership whose evidence was spoken on the microphone: most
likely the user's own work.

#### First person for the user, Requested: prefix for requests
`ActionItem::display_text`: The text as shown: first person for the user, "Requested: " for requests.

#### Attribution disagreeing with stored isForUser becomes unresolved
`ActionAttribution::consistent_with`: A stored attribution that disagrees with the stored `isForUser` flag
becomes unresolved (`OutcomeAttribution.consistent(with:)`).

#### Legacy records freeze per-field correction dates at updatedAt
`ActionState::from`: Legacy records without per-field correction dates freeze them at
`updatedAt`, before a later status write advances it.

#### Timestamps persisted at millisecond precision
`millis`: Millisecond precision, as persisted (`outcomePersistedTimestamp`).

#### id format is MEETING-UUID:actionID; joins corrections to meeting
`ActionReference`: An action item with the user's corrections applied, joined to its meeting
(`OutcomeActionReference`). `id` is `"<MEETING-UUID>:<actionID>"`.

#### Extracted action normalized but without corrections
`ActionReference.action`: The extracted action, normalized but without corrections.

#### Last user edit, or meeting start when never edited
`ActionReference.state_updated_at`: When the user last edited it, or the meeting start when never edited.

#### Open or deferred work with resolved due day before today
`ActionReference::is_overdue`: Open (or deferred) work whose resolved due day is before `today`.

#### Corrected due phrase resolves from typing day; extracted from meeting day
`ActionReference::due_reference_date`: A corrected due phrase is read from the day the user typed it; an
extracted one from the day of the meeting.

#### Thread id is thread-%016llx of sorted reference IDs
`ActionThread.id`: `thread-%016llx` of the sorted reference IDs.

#### Clustering key of newest member; empty when too few significant words
`ActionThread.canonical_text`: The folded clustering key of the newest member (empty when the
thread could not be clustered, e.g. too few significant words).

#### References ordered newest meeting first
`ActionThread.references`: Newest meeting first.

#### Shown text is latest correction, else most descriptive
`ActionThread.text`: The text to show: the latest correction, else the most descriptive.

#### Open undated work is stale after 21 days since last mention
`ActionThread::STALE_AFTER_DAYS`: Days after the last mention when open, undated work counts as stale.

#### Open if any open, else deferred if any, else done
`ActionThread::status`: Open if any member is open, else deferred if any, else done.

#### Newest owner correction decides; else all members must be the user's
`ActionThread::is_for_user`: The newest owner correction decides; otherwise every member must be the user's.

#### Stale: open, unmentioned for weeks, not due ahead
`ActionThread::is_stale`: Open work nobody mentioned for weeks and that is not due ahead.

### `LinuxWindows/crates/lokalbot-core/src/model/people.rs`

#### Speaker is set only for someone other than the person; None for own or unnamed
`NotePoint.speaker`: Who said it when that is someone other than the person: "You" or a
named speaker. `None` for the person's own lines and unnamed ones.

#### Call recorded in parts has notes for each part
`NotePoint.meeting_id`: The recording the line is from; a call recorded in parts has notes
for each part.

#### Parts of one call recorded separately share the event id
`MeetingRef.calendar_event_id`: Parts of one call recorded separately share it.

#### Counts named people other than the user
`MeetingRef.participant_count`: Named people in the meeting other than the user.

#### Person id is person-%016llx of the join key
`PersonProfile.id`: `person-%016llx` of the join key.

#### Folded person IDs, own first, so earlier curation still applies
`PersonProfile.member_ids`: Every person ID folded into this one, its own first; curation saved
under an earlier ID still applies.

#### Newest first; every recording including parts of one call
`PersonProfile.meetings`: Newest first; every recording, including parts of one call.

#### Open or deferred work the person owns, attention order
`PersonProfile.their_actions`: Open or deferred work the person owns, attention order.

#### User's open work naming the person or from a small meeting
`PersonProfile.my_actions`: The user's open work that names the person or came from a small
meeting with them, attention order.

#### Decisions newest first, capped at 8
`PersonProfile.decisions`: Newest first, at most 8.

#### Up to three lines from newest meeting notes
`PersonProfile.recent_notes`: Up to three lines from the newest meeting notes about the person.

#### Latest-meeting notes labelled Last Time rather than Last Mentioned
`PersonProfile.notes_is_latest_meeting`: `recent_notes` come from the newest meeting with the person: "Last
Time" rather than "Last Mentioned".

#### Meetings counted as occasions; call recorded in parts counts once
`PersonProfile::meeting_count`: Meetings as occasions: a call recorded in parts counts once.

### `LinuxWindows/crates/lokalbot-core/src/model/projects.rs`

#### Normalized names dismissed as Not a Project
`ProjectCuration.hidden_names`: Normalized names the user dismissed as "Not a Project".

#### Source names become target's other names; caller drops source note
`ProjectCuration::merge`: Folds one tracked project into another: its names become the target's
other names (`ProjectStore.merge`). Returns whether anything changed;
the caller drops the source's note.

#### Other names are single-spaced without blanks, repeats or own name
`clean_other_names`: Single-spaced, without blanks, repeats or the project's own name
(`ProjectStore.cleanOtherNames`).

#### Location is on this PC or the remote host that wrote it
`ProjectSummary.location`: "on this PC" or the remote host that wrote it.

#### Suggested when a capitalized term appears in three or more meetings
`ProjectKind::Suggested`: A capitalized term seen in three or more meetings.

#### Overnight review names work no tracked project covers
`ProjectKind::SuggestedReview`: Work the overnight review named that no tracked project covers.

#### Window time covers the last 7 days
`ProjectWindowTime`: Tracked window time for a project in the last 7 days.

#### Id formats tracked:UUID, topic:name or review:name
`ProjectProfile.id`: `tracked:<UUID>`, `topic:<normalized name>` or `review:<normalized name>`.

#### Up to three lines per meeting naming the project
`ProjectProfile.mentions`: Up to three lines per meeting naming the project.

#### Others' open work mentioned in last 14 days or due ahead
`ProjectProfile.others_actions`: Other people's open work mentioned in the last 14 days or due ahead.

#### Decisions newest first, capped at 8
`ProjectProfile.decisions`: Newest first, at most 8.

#### Up to eight people from the project's meetings
`ProjectProfile.people`: Up to eight people from the project's meetings.

#### Tracked window time over last 7 days
`ProjectProfile.week_seconds`: Tracked window time naming the project in the last 7 days.

#### Days as YYYY-MM-DD with seconds, newest first
`ProjectProfile.days`: `(YYYY-MM-DD, seconds)`, newest day first.

#### Windows list is the longest, at most six
`ProjectProfile.windows`: The longest windows, at most six.

#### Counts every window with tracked time; windows lists only longest
`ProjectProfile.window_count`: Every window with tracked time in those days; `windows` lists only
the longest (`ProjectProfile.windowCount`).

#### Test fixture is tracked.json as ProjectStore writes it
`curation_reads_and_writes_the_mac_format`: `projects/tracked.json` as `ProjectStore` writes it.

### `LinuxWindows/crates/lokalbot-core/src/model/transcript.rs`

#### Alias keys are canonical trimmed lowercase speaker keys
`Transcript.speaker_aliases`: Canonical speaker key (trimmed, lowercase) to the name the user gave it.

#### Segment times are seconds from recording start
`Segment.start`: Seconds from the start of the recording.

#### Speaker labels: me/them legacy, local/them, diarized with numbers
`Segment.speaker`: `me`/`them` (legacy), `local`/`them`, or diarized `local N`/`them N`.

#### Process-wide my-microphone-is-me setting so all views label speech alike
`MICROPHONE_IS_USER`: Settings → "My microphone is me" (`SpeakerAttribution.microphoneIsUser`).
One value for the whole process, as on macOS, so the meeting view,
`transcript.md`, search and Ask all label microphone speech the same way.

#### Default on: personal microphone belongs to this computer's user
`SpeakerAttribution::microphone_is_user`: On by default: the personal microphone belongs to this computer's user.

#### Shared-room recordings turn it off so voices stay unidentified
`SpeakerAttribution::set_microphone_is_user`: Shared-room recordings turn it off, so unconfirmed microphone voices
stay unidentified instead of being labelled as the user.

#### Default names: Them, Me, Local speaker, Speaker unclear, else capitalized
`Transcript::default_speaker_name`: Default names when no alias exists (`Transcript.defaultSpeakerName`):
Them, Me, Local speaker, Speaker unclear; anything else capitalized
("them 2" → "Them 2").

#### Legacy attribution implied by label with my-microphone default applied
`Transcript::resolved_attribution`: A segment's attribution, or the legacy one implied by its label, with
the "my microphone is me" default applied (`resolvedAttribution`).

#### One identity per key else unresolved; overlap and echo never decide
`Transcript::speaker_identity`: One identity for every segment of a speaker key, else unresolved;
overlapping speech and suspected echo never decide it.

#### Display name: alias, Me for user's voice, else default
`Transcript::speaker_name`: Display name for a speaker: the user's alias, "Me" for the user's own
voice, else the default name (`displaySpeaker(for:)`).

#### Mixed voices and suspected echo can never be confirmed
`Transcript::can_confirm_speaker`: Whether every turn of a speaker may be confirmed as one person
(`canConfirmSpeaker`): mixed voices and suspected echo never can.

#### None withdraws confirmation, returning to diarization identity
`Transcript::confirm_speaker`: Records who a speaker is (`confirmSpeaker`). `None` withdraws a
confirmation and returns the speaker to its diarization identity.

#### Name equal to the default counts as no name
`Transcript::set_speaker_alias`: Sets or clears a speaker's name (`setSpeakerAlias`). A name equal to
the speaker's default is no name.

#### Names follow voice by time: 80% overlap with one named speaker, same track
`Transcript::carry_speaker_names_from`: Carries the names the user gave speakers in `previous`, an earlier
transcription of the same audio, onto this one
(`SpeakerIdentityResolver.remap`). Diarization labels can change
between runs, so a speaker takes a name by time, not by label: at
least 80% of its speech must overlap one named speaker on the same
track, and no other named speaker. Ambiguous and unnamed speakers keep
their defaults, so a name the user removed stays removed.

#### Segment id format segment-%04d-%010lld-%010lld index, start ms, end ms
`Transcript::segment_id`: `segment-%04d-%010lld-%010lld`: index, start ms, end ms.

#### transcript.md entry format and blank-line separation
`Transcript::markdown`: `transcript.md`: `**[HH:MM:SS] Name:** text`, blank-line separated.

#### Test: diarization swapped labels and found a partly overlapping short speaker
`speaker_names_follow_the_voice_not_the_label`: Diarization swapped the labels and found a short speaker that only
partly overlaps Ana.

#### Test: half of this speaker's time is new speech
`names_need_most_of_the_speech_and_the_same_track`: Half of this speaker's time is new speech.

#### Test: same time range but on the microphone track
`names_need_most_of_the_speech_and_the_same_track`: Same time, but the microphone track.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
