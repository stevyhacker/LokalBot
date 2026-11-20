# 0013. Mac app: Calendar

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Services/Calendar/`, `LokalBotTests/Services/Calendar/`.

## Decisions

### `LokalBot/Services/Calendar/CalendarEventFilter.swift`

#### EventKit-free snapshot keeps filter rules unit-testable without a calendar store
`RawCalendarEvent`: EventKit-independent snapshot of the handful of fields meeting-filtering
needs, so the filter rules are unit-testable without a real calendar store.

#### Focus and hold blocks usually carry free availability
`RawCalendarEvent.availabilityFree`: `availability == .free` — focus/hold blocks usually carry this.

#### Exclude all-day, cancelled, declined, out-of-office and solo free focus blocks
`CalendarEventFilter.isRecordableMeeting`: A recordable meeting: a real title, and not one of the non-meeting shapes
— all-day, cancelled, declined, out-of-office, or a solo focus/hold block
(free time with no attendees and no conferencing link).

### `LokalBot/Services/Calendar/CalendarEventProviding.swift`

#### Map EKAuthorizationStatus so callers never import EventKit
`CalendarAuthorizationStatus`: Calendar permission state, mapped off `EKAuthorizationStatus` so callers
(the detector, settings UI, tests) never import `EventKit`.

#### Read-only seam for matching layer and tests; production uses EventKit provider
`CalendarEventProviding`: Read-only window into the user's calendar, narrowed to "which meeting is
happening around now". The seam the matching layer and its tests depend on;
production wires up ``EventKitCalendarEventProvider``.

#### Reason request failed before macOS could grant or deny; nil for normal flow
`CalendarEventProviding.accessRequestError`: User-facing reason the latest access request failed before macOS could
grant or deny it. Nil for a normal grant/denial flow.

#### Requests full read access; completion delivered on main thread
`CalendarEventProviding.requestAccess`: Requests full read access; completion delivered on the main thread.

#### Recordable meetings overlapping look-around window sorted by start; empty without access
`CalendarEventProviding.meetingCandidates`: Recordable meetings overlapping the look-around window, sorted by start.
Empty unless access has been granted.

### `LokalBot/Services/Calendar/CalendarMeetingCandidate.swift`

#### Filtered, EventKit-free candidate so matching layer and tests avoid EventKit
`CalendarMeetingCandidate`: A calendar event that could line up with a recording: already filtered down
to a real, recordable meeting (see ``CalendarEventFilter``) and stripped of
EventKit so the matching layer and its tests never import `EventKit`.

#### Provider tag such as eventkit, persisted on the Meeting
`CalendarMeetingCandidate.provider`: Source provider tag, e.g. "eventkit". Persisted on the `Meeting`.

#### Per-occurrence ID keys the repeat-suppression cooldown on this instance
`CalendarMeetingCandidate.externalID`: Stable per-occurrence identifier (event id + occurrence start) so the
repeat-suppression cooldown is keyed on this exact meeting instance.

#### Conferencing link lets browser audio count as meeting without title match
`CalendarMeetingCandidate.meetingURL`: Conferencing link found on the event (Meet/Zoom/Teams/…), if any. The
signal that lets a browser's audio count as a meeting without a window
title match.

#### Sanitized agenda held in memory; recording keeps it only when agenda use enabled
`CalendarMeetingCandidate.agenda`: Sanitized invitation agenda, held in memory. A recording keeps it
only when agenda use is enabled.

#### Prefer structured identities, else project legacy name-only roster
`CalendarMeetingCandidate.resolvedParticipantIdentities`: Structured identities when the provider supplies them, otherwise a
backwards-compatible projection of the legacy name-only roster.

#### Grace is 60 s; generous values made auto-record fire minutes early
`CalendarMeetingCandidate.earlyJoinGrace`: Grace before an event's scheduled start during which it already counts
as active — a *beat* early (people click Join ~a minute ahead), not a
long pre-roll. A generous value here is what made auto-record fire whole
minutes before a meeting actually began.

#### Start-biased: calendar end never stops a recording, only audio does
`CalendarMeetingCandidate.isActive`: Is this event happening at `now`? In progress, or within `earlyJoin`
before its start. Calendar end never *stops* a recording — only audio
does — so this is deliberately start-biased.

#### Latest-started in-progress event wins, else soonest upcoming
`Array<CalendarMeetingCandidate>.activeCandidate`: The single event that best represents "what is happening now": an
in-progress event (most recently started) beats one about to start; with
none in progress, the soonest upcoming wins. Nil when none is active.

### `LokalBot/Services/Calendar/ConferenceURLDetector.swift`

#### Detect conferencing links in free text to flag online meetings and verify the room
`ConferenceURLDetector`: Recognizes video-conferencing links inside free text (calendar notes,
location, the event URL). This flags an event as an online meeting and
provides its URL so the detector can verify the right room.

#### Hosts are base domains; subdomains match by suffix
`ConferenceURLDetector.hosts`: Known conferencing hosts (base domains; subdomains match via suffix).

#### Build detector once because calendar reads query every event's fields
`ConferenceURLDetector.linkDetector`: Built once: calendar reads ask about every event's URL, location and notes.

### `LokalBot/Services/Calendar/EventKitCalendarEventProvider.swift`

#### Read-only EventKit access; synced Google/Exchange/iCloud calendars visible; non-isolated reads for detector
`EventKitCalendarEventProvider`: `CalendarEventProviding` backed by the system calendar via EventKit. Reads
only — no Google/Microsoft OAuth (v1): anything synced into Apple Calendar
(Google, Exchange, iCloud) is visible here all the same.

`ObservableObject` so the settings UI reflects permission changes; the data
methods stay non-isolated so the (non-`@MainActor`) detector can read them
straight from its tick on the main thread.

#### Window of 15 min behind and 90 min ahead for late-join and early detection
`EventKitCalendarEventProvider.lookBehind/lookAhead`: Look-around window: a meeting you joined up to 15 min late still matches,
and one starting within 90 min is visible for early detection.

#### Cache EventKit fetches 30 s so ticks do not hammer the store
`EventKitCalendarEventProvider.cacheTTL`: Re-fetch at most this often — EventKit ticks (mic toggles, audio blips)
shouldn't hammer the store; meetings don't change on a 30 s scale.

#### Re-read TCC state because Settings changes send no notification
`EventKitCalendarEventProvider.refreshAuthorizationStatus`: Re-reads the TCC state (it can change in System Settings with no
notification) and republishes only on a real change.

#### Detector keeps narrow window; Today uses separate day query
`EventKitCalendarEventProvider.meetingCandidates(now:)`: The detector intentionally keeps its narrow look-around window. Today
uses ``meetingCandidates(on:calendar:)`` instead so a distant afternoon
meeting cannot disappear from the day's schedule.

#### Day cache independent of detector so Today does not widen auto-recording window
`EventKitCalendarEventProvider.meetingCandidates(on:calendar:)`: Every recordable meeting overlapping the supplied local calendar day.
This cache is independent from detector polling so widening Today does
not widen automatic recording's confidence window.

#### People's Coming up uses a longer window with its own cache
`EventKitCalendarEventProvider.meetingCandidates(from:days:calendar:)`: Recordable meetings from `now` through the next `days` days, for
People's "Coming up". The same events Today reads, over a longer
window, with a cache of its own so the detector and Today keep theirs.

#### Attendee addresses decide which email threads involve people the user meets
`EventKitCalendarEventProvider.attendeeAddresses`: Attendee addresses of meetings between `start` and `end`, for
deciding which email threads involve people the user meets.

#### Non-meetings (all-day, cancelled, declined, OOO, focus, untitled) map to nil
`EventKitCalendarEventProvider.candidate(from:)`: Map an `EKEvent` to a recordable candidate, applying ``CalendarEventFilter``.
Nil for non-meetings (all-day, cancelled, declined, OOO, focus blocks,
untitled) or events missing a start/end.

#### Fold occurrence start into id because recurring series share an event id
`EventKitCalendarEventProvider.occurrenceID`: Per-occurrence id: the event id alone is shared across a recurring
series, so fold in the occurrence start to keep occurrences distinct.

### `LokalBot/Services/Calendar/MeetingMatcher.swift`

#### Automatic detection needs app/audio signal; explicit user action may start mic-only with event
`MeetingDetectionContext`: What the detector concluded about the current moment: the app/browser that
will be captured, the calendar event it lines up with (if any), how sure we
are, and why. Automatic detection always requires an app/audio signal; an
explicit user action may carry a calendar event and start mic-only.

#### An end event only governs the recording from its own detector lifecycle
`MeetingDetectionEnd`: An end event has authority over only the recording that joined this exact
detector lifecycle.

#### Unconfident when a browser call merely stopped being observable
`MeetingDetectionEnd.confident`: False when a browser call merely stopped being observable.

#### Uncertainty never stops a recording; confident end allows immediate rejoin recording
`MeetingDetectionEnd.action`: Neither automatic nor explicit recordings can be stopped by uncertainty.
A confident end means the call is over, so rejoining the same calendar
event is a new call and records at once. The repeat cooldown is for a
recording the user stopped.

#### Matching policy kept pure, with no EventKit, AppKit or Core Audio
`MeetingMatcher`: The matching layer between detection and recording. Pure policy — no
EventKit, AppKit, or Core Audio — so every rule here is unit-testable.

#### Calendar, titles and output are metadata; caller must verify in-call document state
`MeetingMatcher.browserCountsAsMeeting`: Calendar, titles and output are supporting metadata, never proof of a
call. The caller must verify the actual meeting document's in-call state.

#### Sustained-audio boundary is inclusive; nil firstSeenAt means no audio observed
`MeetingMatcher.sustainedAudioConfirmed`: Whether a start candidate has produced audio for at least the required
duration. The boundary is inclusive: exactly `minimumDuration` confirms
the start, anything shorter does not. `firstSeenAt == nil` means no audio
has been observed yet.

#### Generation identifies window so queued rechecks cannot act on a newer candidate
`MeetingMatcher.StartConfirmationState`: The live state for one sustained-audio confirmation window. A generation
identifies the exact window so a queued recheck cannot act on a newer
candidate after the old window has been reset.

#### Audio after an expired gap starts a new window even for same bundle
`MeetingMatcher.StartConfirmationState.observeAudio`: Records fresh audio and answers whether it began a new window. Audio
after an expired gap is a new candidate even when the bundle id is
unchanged; otherwise the abandoned window could confirm immediately.

#### Silence abandons candidate only after gap passes tolerance, since listening pauses are normal
`MeetingMatcher.StartConfirmationGapOutcome`: What a start candidate's silence means when it has no fresh audio
evidence on this particular tick.

Detection asks "is the app making sound right now", so a candidate mid
confirmation loses that signal every time the remote side stops talking
to listen — an ordinary conversational rhythm, not evidence the call
ended. `abandoned` only once the *gap itself* has run past tolerance,
not the instant evidence is briefly missing.

#### Tolerated silence keeps the candidate but cannot supply fresh audio to confirm
`MeetingMatcher.startConfirmationGapOutcome`: A tolerated silence preserves the candidate, but cannot provide the
fresh audio observation required to complete its confirmation gate.

#### Recording may bridge confirmation for one replacement meeting app, never from global audio
`MeetingMatcher.shouldKeepActiveSessionForPendingHandoff`: A live recording may bridge the confirmation gate for one replacement
native meeting app. The candidate must still be a running known meeting
bundle and its own last audio observation must remain inside the bounded
gap. This never turns arbitrary or global audio into continuation proof.

#### Cooldown only after user-stopped recordings; self-ended calls never block rejoin
`MeetingMatcher.shouldSuppressRepeat`: Suppress an auto-start that would re-record the same calendar event right
after the user stopped its recording, such as a detector tick racing a
manual stop. A call that ended on its own never starts the cooldown: the
detector only announces a call once, so a refused rejoin would go
unrecorded to its end. A genuinely new occurrence has a different
`externalID`, so it is never blocked.

#### Split immediately on calendar event change so back-to-back meetings are not merged
`MeetingMatcher.shouldSplitForCalendarHandoff`: A live recording backed by one calendar event should split immediately
when the active calendar event changes. This prevents back-to-back
meetings from being merged during the stop debounce.

#### Owning recording splits; idle calendar handoff starts; unowned recording is left alone
`MeetingMatcher.switchAction`: What automatic recording does when the detector moves to another app or
calendar event within one session. The recording that owns the session
splits. With nothing recording (the user stopped the previous event),
the next calendar event is a new meeting and records; a recording the
session does not own is left alone.

#### Use the meeting app's own audio I/O, not the global mic-in-use flag
`MeetingMatcher.isMeetingOngoing`: Whether the detector should treat a meeting as in progress this tick.

`appAudioActive` is the *meeting app's own* audio I/O (input or output).
It deliberately replaces the global "mic in use" flag: once we start
recording, our own mic capture keeps the default input device "running
somewhere", and before recording a global mic check can belong to a
different app entirely. Start and continue both key off the selected app's
own audio signal; calendar-backed browsers may also start from output
audio found in their helper process.

### `LokalBot/Services/Calendar/UpcomingMeetingPreparation.swift`

#### Decisions and commitments keep their meeting id so Today can cite the source
`UpcomingMeetingReference`: A source-backed note shown while preparing for an upcoming meeting. Every
decision and commitment retains its meeting id so Today can jump back to
the exact source instead of presenting an uncited AI assertion.

#### Code selects all evidence; the LLM only rewrites the bounded packet
`UpcomingMeetingEvidence`: The complete, bounded evidence packet behind one pre-meeting card. The LLM
only rewrites this packet; code selects the event, source meetings, project
context, decisions, and commitments.

#### Agenda is sanitized and present only when agenda use is enabled
`UpcomingMeetingEvidence.agenda`: Sanitized invitation agenda, present only when agenda use is enabled.

#### Email threads come from downloaded conversations when an account is connected
`UpcomingMeetingEvidence.emailThreads`: Downloaded conversations with the attendees, when an email account is
connected (`EmailMeetingContext`).

#### Signature includes extracted content so new summaries invalidate in-memory briefs
`UpcomingMeetingEvidence.signature`: Stable within one process and deliberately includes extracted content,
so a newly-written summary/outcomes file invalidates the in-memory brief.

#### Model-free brief restates evidence only, never infers completion or ownership
`UpcomingMeetingEvidence.fallbackBrief`: An immediate, model-free brief keeps the card useful while the local
model starts (or when none is available). It only restates selected
evidence and never infers completion or ownership.

#### Prior summaries placed first and cut at end so decisions and commitments survive cap
`UpcomingMeetingEvidence.promptContext`: Decisions, commitments, and project context are what the brief is for.
Prior meeting summaries share the room those leave: placed first and cut
at the end, six long summaries used to push them past the cap.

#### Meeting means other people or conferencing link, recordable
`UpcomingMeetingSelector.Kind.meeting`: Other people or a conferencing link: a call LokalBot can record.

#### Solo events with meeting-like titles are listed without Join or Record
`UpcomingMeetingSelector.Kind.soloMeeting`: Only the user is invited, but the title names a meeting (a standup
joined from elsewhere). Listed, without Join or Record.

#### Solo non-meeting titles are never listed as meetings
`UpcomingMeetingSelector.Kind.personal`: Only the user, with a non-meeting title (a dentist or doctor visit,
an errand). Never listed as a meeting.

#### English and Serbian meeting words distinguish private-calendar meetings from appointments
`UpcomingMeetingSelector.looksLikeMeeting`: Meeting words in English and Serbian. A personal appointment title
rarely uses them; a meeting kept on a private calendar usually does.

#### Keep all meetings overlapping the day; exclude personal appointments
`UpcomingMeetingSelector.schedule`: Keep every meeting overlapping the requested local day, including
meetings which have ended and meetings many hours away. Personal
appointments are left out so they cannot take a meeting's place.

#### Primary is in-progress else next today, skipping the event being recorded
`UpcomingMeetingSelector.primary`: Pick the meeting whose preparation deserves emphasis: an in-progress
event first, otherwise the next event at any later time today. The event
already being recorded is skipped because Today has a dedicated live card.

#### Deterministic local retrieval: participants outweigh titles, recency breaks ties, no LLM search
`UpcomingMeetingPreparationCompiler`: Deterministic local retrieval for pre-meeting evidence. Participant matches
dominate recurring-title matches; recency breaks ties. This avoids asking an
LLM to search the entire private library or decide which sources are relevant.

#### Match participants by email address even when display names differ
`UpcomingMeetingPreparationCompiler`: An address is the same person even when a display name differs.

#### Automatic preparation never triggers a surprise multi-gigabyte model download
`UpcomingMeetingLocalGenerationPolicy.shouldGenerateAutomatically`: Automatic preparation must never trigger a surprise multi-gigabyte
download. A user can still explicitly request generation from the card.

#### Shared Today schedule read; no meetings without Calendar setting and macOS access
`UpcomingMeetingSchedule`: Today's calendar meetings, read once for whoever shows them: the Today
page (`UpcomingMeetingPreparationModel`) and the menu bar's status block.
Without the Calendar setting and macOS access there are no meetings.

#### Meetings in time order with personal appointments excluded
`UpcomingMeetingSchedule.Reading.meetings`: The day's meetings in time order; personal appointments left out.

#### Next-week meetings for People; nil when off or no access; never asks for access
`UpcomingMeetingSchedule.readAhead`: Meetings from now through the next week, for People's "Coming up" and
a person's next-meeting card. Nil while Calendar use is off or access
is missing; People never asks for access.

#### Deterministic non-EventKit seam for screenshots and XCUITest
`UpcomingMeetingSchedule.demoSchedule`: A deterministic, non-EventKit seam for screenshots and XCUITest. It
exercises the real schedule, evidence compiler, Join/Record actions,
and accessibility tree without reading the developer's calendar.

#### Retain all meetings; only active/next gets history lookup and brief; briefs cached across refreshes
`UpcomingMeetingPreparationModel`: Today-owned state for the full calendar day. Every meeting is retained for
the schedule, but only the active/next meeting gets the heavier history
lookup and optional local-LLM brief. Generated briefs stay cached across
30-second refreshes.

#### Cache email threads so 30 s refresh does not decrypt the mailbox
`UpcomingMeetingPreparationModel.emailCacheKey`: Email threads for the primary event, reused until the event or the
downloaded mail changes, so the 30-second refresh doesn't decrypt the
mailbox each time.

#### Already-recorded events are excluded from coming up; Today lists them as recordings
`UpcomingMeetingPreparationModel.refresh`: An event a recording already covers, the one being recorded
included, is not coming up again. Today lists it as that recording.

#### Explicit generation may download the model; only automatic refresh is forbidden to
`UpcomingMeetingPreparationModel.generate`: Explicit generation may prepare/download the user's selected local
model; unlike automatic refresh, that potentially expensive action is
always initiated by the Generate brief button.

#### Evict an arbitrary entry other than the just-written brief
`UpcomingMeetingPreparationModel.generate`: Dictionary order is arbitrary, so this drops some other entry,
never the brief just written: without it the card would fall
back to the template and the next refresh would generate again.

### `LokalBotTests/Services/Calendar/CalendarDetectionTests.swift`

#### Test bundle entitlements are a copy of LokalBot/LokalBot.entitlements; see project.yml
`CalendarDetectionTests.testCalendarCapabilityIsConfiguredForGeneratedBuilds`: A copy of LokalBot/LokalBot.entitlements; see project.yml.

#### Other Feishu and DingTalk pages are documents and downloads, not calls
`ConferenceURLDetector.isMeetingURL`: Other Feishu and DingTalk pages are documents and downloads, not calls.

#### Events are active one minute before start (early-join grace)
`CalendarMeetingCandidate.isActive`: Within the 1-minute early-join grace before start (a beat early).

#### Events beyond the grace must not auto-record minutes ahead of start
`CalendarMeetingCandidate.isActive`: Beyond the grace — must NOT auto-record minutes ahead of the start.

#### A tab title cannot establish that the user joined the call
`MeetingMatcher.browserCountsAsMeeting`: A tab title cannot establish that the user joined the call.

#### No title and no calendar is not a meeting; random browser tabs are never recorded
`MeetingMatcher.browserCountsAsMeeting`: No title and no calendar → not a meeting (the pre-calendar fallback, and
why a random browser tab is never recorded).

#### Calendar plus unrelated video output must never establish a call
`MeetingMatcher.browserCountsAsMeeting`: Calendar plus unrelated video output must never establish a call.

#### A calendar event alone, without browser audio, never starts a recording
`MeetingMatcher.browserCountsAsMeeting`: Calendar event alone, with no browser audio, never starts a recording.

#### Own mic recorder keeps global mic flag true; continue decision must key off the app's own audio
`MeetingMatcher.isMeetingOngoing`: Regression: once recording starts, our own mic recorder keeps the global
"mic in use" flag true. The continue decision must ignore it and key off
the meeting app's OWN audio — otherwise the meeting never reads as ended
and recording never stops.

#### Browsers carry their own title and calendar gate and never wait for sustained audio
`MeetingDetector.requiresSustainedAudioForStart`: Browsers carry their own title/calendar gate and never wait here.

#### A short remote pause is conversational rhythm and must not restart the confirmation window
`MeetingMatcher.startConfirmationGapOutcome`: `detectRunningMeetingApp` requires fresh output audio, so a candidate
lost that signal entirely — not just its elapsed time — every time the
remote side paused to listen rather than talk. Real log, 2026-08-26: six
consecutive attempts on a live Teams call each failed after 4.2-12.7 s,
two of them past the 12 s window itself. A gap this short is
conversational rhythm, not the call ending, and must not restart the
window.

#### Silence past the gap tolerance abandons a candidate that never recurs
`MeetingMatcher.startConfirmationGapOutcome`: Silence past the gap tolerance is what `nativeAudioMinimumConfirmationDuration`
itself already guards against for a single blip — a candidate that never
recurs must still be abandoned, gap-tolerant or not.

#### A short sound cannot coast past the minimum duration during silence
`MeetingMatcher.startConfirmationGapOutcome`: A short sound cannot coast past the minimum duration during silence.

#### Gap tolerance bridges existing evidence only; an isolated blip must still be abandoned
`MeetingMatcher.startConfirmationGapOutcome`: The tolerance only ever bridges a gap in evidence that already exists;
it cannot manufacture evidence on its own. A single blip (a
notification ding) followed by real silence for the rest of the window
must still be abandoned — the exact case
`nativeAudioMinimumConfirmationDuration` was introduced to guard
against, and this tolerance must not reopen it.

#### The gap boundary is inclusive, matching sustainedAudioConfirmed
`MeetingMatcher.startConfirmationGapOutcome`: The gap boundary is inclusive, matching `sustainedAudioConfirmed`'s own
inclusive boundary.

#### Fresh audio after an expired gap starts a new window instead of confirming on total span
`MeetingMatcher.StartConfirmationState.observeAudio`: A fresh tick cannot revive a window whose last evidence is already past
tolerance. At this timestamp the old implementation saw a 12-second
total span and confirmed immediately instead of starting over.

#### Canceling a DispatchWorkItem is no identity check; stale callbacks are rejected by generation
`MeetingMatcher.StartConfirmationState`: Canceling a submitted DispatchWorkItem is not the identity check: if an
obsolete callback is already queued, its captured generation must no
longer match the restarted window.

#### Tencent Meeting and VooV start like Zoom; Feishu, Lark, DingTalk, WeCom wait like Teams
`MeetingDetector.requiresSustainedAudioForStart`: Tencent Meeting and VooV are dedicated conferencing apps, like Zoom.
Feishu, Lark, DingTalk and WeCom also carry chat and voice messages, so
they wait out the same sustained-audio gate as Teams and Slack.

#### A meta.json written before calendar support still decodes with nil calendar fields
`Meeting.init(from:)`: A meta.json written before calendar support still decodes (calendar
fields default to nil).

#### Calendar provenance round-trips through the same ISO-8601 codec StorageManager uses
`Meeting`: Calendar provenance round-trips through the same ISO-8601 codec
StorageManager uses for meta.json.

#### Manual recordings keep calendar-free JSON; nil optionals are omitted, never null
`Meeting.encode(to:)`: Manual recordings (no calendar) keep their old, calendar-free JSON shape:
nil optionals are omitted, never written as null keys.

#### Idle Teams modulehost reported output and input true in 20/20 samples; not call evidence
`MeetingDetector.carriesMeetingSignal`: Measured with Teams launched and idle, 20 samples over 20 s: modulehost
reported isRunningOutput and isRunningInput true in 20/20 while every
helper reported false. A process in that state cannot be evidence of a
call, so the start decision must not read it.

#### An unknown process is judged by the other rules, not dropped here
`MeetingDetector.carriesMeetingSignal`: An unknown process is judged by the rest of the rules, not silently
dropped here.

#### An always-open stream is not meeting evidence but stays a valid capture target
`MeetingDetector.bestCaptureAudioProcess`: An always-open stream is not evidence that a meeting is running, but it
remains a valid capture target once another signal starts the recording.

#### Observed false starts fall below the inclusive 12 s confirmation boundary
`MeetingDetector.nativeAudioMinimumConfirmationDuration`: Every measured short false start is below the inclusive confirmation
boundary; a real candidate confirms exactly at that boundary.

### `LokalBotTests/Services/Calendar/UpcomingMeetingPreparationTests.swift`

#### Today's list words the status; the model only says where it stands
`testPresentationLabelsPastMeetingAsEnded`: Today's list words the status; the model only says where it stands.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
