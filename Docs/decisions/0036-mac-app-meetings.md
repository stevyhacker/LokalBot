# 0036. Mac app: Meetings

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Models/Meetings/`, `LokalBot/Services/Meetings/`, `LokalBot/Views/Meetings/`, `LokalBotTests/Models/Meetings/`, `LokalBotTests/Services/Meetings/`.

## Decisions

### `LokalBot/Models/Meetings/CalendarParticipantIdentity.swift`

#### Email stays in local metadata; transcript aliases persist opaque id only
`CalendarParticipantIdentity`: One remote attendee from the calendar event matched to a meeting.

The email address is retained only in local meeting metadata so the rename
UI can distinguish attendees with the same display name. Transcript aliases
persist the opaque `id`, never the email address.

#### Email-derived name is an editable suggestion, never automatic identity
`CalendarParticipantIdentity.suggestedSpeakerName`: An editable picker suggestion, never an automatic speaker identity.
EventKit often supplies an address without a display name. Keep that
absence in metadata so automatic naming cannot treat this guess as fact.

#### Accept only mailto participant URLs so opaque ids are not emails
`CalendarParticipantIdentity.emailAddress`: EventKit represents attendee addresses as participant URLs. Accept only
`mailto:` so opaque calendar/provider identifiers are never mistaken for
email addresses.

#### Dedupe by email first, name only without email
`CalendarParticipantIdentity.normalized`: Deduplicates identities by email first and by name only when an email is
unavailable. A same-name/different-email pair remains distinct.

### `LokalBot/Models/Meetings/ConferenceRoom.swift`

#### Meet shows the same room under /meet/ too (#372)
`ConferenceRoom.init`: Meet also shows the same room under /meet/ (#372).

#### MTS Link invitations may have /j/; active call adds /stream-new/id
`ConferenceRoom.init`: Invitations may have /j/; the active call adds /stream-new/\<id>.

#### Telemost controls only from same-room iframe, never unrelated frames
`ConferenceRoom.acceptsFrame`: Telemost embeds its call controls in a same-room iframe. Never borrow
controls from an unrelated frame, even on the same service.

#### Post-call pages only end a verified call in its own window
`ConferenceRoom.isPostCallPage`: These pages can only end a previously verified call in its own window.

### `LokalBot/Models/Meetings/Meeting.swift`

#### Meeting persisted as meta.json in meetings/YYYY/MM/dd-slug folder
`Meeting`: One recorded meeting. Persisted as `meta.json` inside its own folder:
`meetings/YYYY/MM/dd-slug/{mic.m4a, system.m4a, meta.json}`.

#### Calendar fields optional so old meta.json decodes and manual shape stays
`Meeting.calendarProvider`: MARK: Calendar provenance (optional)

Populated only when a recording was matched to a calendar event. All
optional so `meta.json` written before calendar support still decodes
(synthesized `Codable` decodes missing keys to nil and omits nil keys on
encode, so manual recordings keep their old, calendar-free shape).

#### Optional so older meta.json still decodes
`Meeting.participantNameHints`: Calendar attendee / roster names that can seed speaker rename
suggestions. Optional so older `meta.json` files still decode.

#### Emails stay in local metadata; transcript aliases keep opaque ids
`Meeting.calendarParticipantIdentities`: Structured calendar attendees. Email addresses remain in this local
metadata only; transcript aliases retain opaque participant IDs.

#### Agenda saved stripped of join details, only when agenda use is enabled
`Meeting.calendarAgenda`: The invitation's agenda with joining details, links, phone numbers,
and addresses removed. Saved only when the user enables agenda use.

#### Merge is non-destructive; speaker labels stay scoped to source meeting
`Meeting.mergedSourceMeetingIDs`: IDs of the source meetings when this record was created by the
non-destructive merge flow. Source folders are never removed or
rewritten, and speaker labels in the merged transcript stay scoped to
their source meeting so identities cannot silently bleed across calls.

#### Source metadata hides old row across launches without deleting evidence
`Meeting.mergedIntoMeetingID`: The merged meeting that folded this source out of the main library.
Keeping this relationship in the source metadata lets the app hide the
old row across launches without deleting its original evidence.

#### Imported meetings take no screen context; merge keeps imported status
`Meeting.importedFileNames`: The original file names when this meeting came from audio or video
files the user imported rather than recordings made on this Mac. The
screen during their time span shows what the user was doing then, not
this meeting, so imported meetings take no screen context. A merge
keeps every imported source's names, so it stays imported.

#### Import source lets re-importing the same export skip duplicates
`Meeting.importSource`: Set on a meeting brought in from another app's notes or transcript
(`ExternalMeetingWriter`): which app and the meeting's id there, so
importing the same export again skips it instead of adding a copy.

#### Sample meeting is visible to Ask and agents but excluded from personal memory
`Meeting.sampleID`: Set on LokalBot's bundled sample meeting ("orders-api/en"): a made-up
call with synthetic voices (`SampleMeeting`). Ask, search and agents
still see it; personal memory (the day, digests, people, projects,
action lists, Personal Context) leaves it out.

#### Own work excludes merged sources and the sample for memory features
`Meeting.isOwnWork`: The user's own work: what memory, digests, people, projects, action
lists and briefings are built from. Merged sources live on in their
merged meeting, and the sample is made up.

#### Parent manifests cover interrupted marker writes; missing parents reveal originals
`Meeting.resolvingMergeRelationships`: Shared, read-only library projection for the app and CLI/MCP. Parent
manifests cover interrupted source-marker writes; missing parents make
their originals visible again. StorageManager persists these repairs.

#### Recorded audio length measured at finalize can be less than wall-clock span
`Meeting.recordedDuration`: Length of the actual recorded audio (longest track), measured at
finalize. The wall-clock span (`duration`) can exceed what was captured
— an audio-device disruption can truncate the tracks while a
calendar-backed session stays live — so this is the playable length and
what `durationLabel` reports. Optional so older `meta.json` still decodes.

#### Content range in original audio seconds; raw tracks stay intact
`Meeting.contentRange`: Seconds on the original audio timeline. Raw tracks stay intact; all
derived meeting evidence is limited to this reviewable range.

#### Nil on legacy recordings because saved range may be a user edit
`Meeting.contentRangeSource`: Nil on legacy recordings: a saved range may have been a user edit.

#### Intent retained across detector visibility gaps and late attachment
`Meeting.captureIntent`: Retained across detector visibility gaps and late attachment attempts.

#### Crossing segments dropped without word alignment; retranscription partitions at boundary
`Meeting.ContentRange.applying`: Without word alignment, a crossing segment cannot be safely
clipped as text. Retranscription partitions audio at the boundary.

#### Title hierarchy: calendar provenance beats generic labels, else app and time
`Meeting.displayTitle`: Human title hierarchy shared by list, preview, Today, Timeline, Ask,
and Agent surfaces. Calendar provenance beats generic recorder labels;
otherwise preserve the original title and fall back to app + time.

#### Old merge titles cleaned for display while stored title stays intact
`Meeting.displayTitle`: Older merges embedded bookkeeping in the title. Keep the stored
title intact while presenting the meeting by its actual name.

### `LokalBot/Models/Meetings/MeetingAttributionArtifactFiles.swift`

#### Stale-attribution markers shared by CLI and MCP readers
`MeetingAttributionArtifacts`: Stale-attribution markers written beside a meeting's outcomes. Read-only
helpers live here so file-backed readers (CLI, MCP) share one definition.

### `LokalBot/Models/Meetings/MeetingDetailPresentation.swift`

#### Compact reading time; fixed-width stamp stays for exports and files
`Transcript.shortStamp`: "0:12", "37:05", "1:02:09": the compact time people read beside a
line. `stamp` keeps the fixed-width form for exports and files.

#### Display-only values; never stored, sent to a model, or identity decisions
`MeetingDetailPresentation`: Display-only values for a saved meeting's page: who spoke, how long, what
is being said at the playhead, and whose each action is. Nothing here is
stored, sent to a model, or treated as an identity decision.

#### Date reads Today/Yesterday at time, then medium date and time
`MeetingDetailPresentation.dateText`: "Today at 1:00 PM", "Yesterday at 3:10 PM", then "Nov 6, 2026 at 3:00 PM".

#### Speaker id is the transcript's canonical speaker key
`MeetingDetailPresentation.Speaker.id`: The transcript's canonical speaker key ("me", "them 2").

#### needsName marks a call voice nobody has named
`MeetingDetailPresentation.Speaker.needsName`: A call voice nobody has named yet.

#### Speakers listed you first, then by first speaking
`MeetingDetailPresentation.speakers`: Everyone who spoke, you first, then in order of first speaking.

#### Unnamed call voices ordered by first speaking
`MeetingDetailPresentation.unnamedSpeakerKeys`: Call voices without a saved name, in order of first speaking.

#### Speech minutes round to whole minutes, minimum one
`MeetingDetailPresentation.speechMinutes`: Whole minutes for "12 min of speech"; any speech at all reads as one.

#### Index built once per transcript so player can query every tick
`MeetingDetailPresentation.PlayheadIndex`: Finds the line being said at a time. Built once per transcript so the
player can ask on every clock tick.

#### Caption is latest started line; before speech, the first
`MeetingDetailPresentation.PlayheadIndex.caption`: The latest line that has started; before any speech, the first.

#### One header count; both bands show whenever actions exist, empty side says so
`MeetingDetailPresentation.ActionsPanel`: What the Actions panel says about itself: one count in its header,
then a band for your actions and one for everyone else's. Both bands
show whenever the meeting has actions, so a side with none says so
instead of leaving a gap.

#### No actions gives one line and no bands
`MeetingDetailPresentation.ActionsPanel.Line.noActions`: The meeting produced no actions: one line, no bands.

#### Header pill count is nil when meeting has no actions
`MeetingDetailPresentation.ActionsPanel.count`: The header's pill. A meeting without actions has no count.

#### Actions link needs your action in saved outcomes of a real meeting
`MeetingDetailPresentation.ActionsPanel.showsActionsLink`: "Also in Actions" leads to your open work, so it needs an action
of yours that the Actions list holds: saved outcomes of a real
meeting, not a sample or notes that are still being written.

#### Others' actions with missing or placeholder owner ask for a real owner
`MeetingDetailPresentation.ownerNeedsAttention`: Someone else's action whose owner is missing or only a placeholder
voice ("Speaker 2"): the row asks for a real owner.

#### Open work past due day is overdue; within attention window is soon
`MeetingDetailPresentation.dueUrgency`: The Actions list's rule for one action: open work past its due day is
overdue, due within the attention window is soon, the rest is later.

#### value is the saved owner; empty clears it
`MeetingDetailPresentation.OwnerOption.value`: What is saved as the owner; empty clears it.

#### Owner choices: you, other speakers, uninvolved invitees, none
`MeetingDetailPresentation.ownerOptions`: Owner choices for one action: you, this meeting's other speakers,
invited people who are not already among them, and no owner.

#### Owner selection matches by name, not voice, until someone says so
`MeetingDetailPresentation.ownerOptions`: By name, not by voice: "Them" on an action is not the person
that voice was named as afterwards, until someone says so.

#### New owner keeps corrected text and due; nil when owner unchanged
`MeetingDetailPresentation.ownerCorrection`: Saving a new owner from the row's menu keeps a corrected wording and a
corrected or cleared due date exactly as they are. Nil when the choice
is already the action's owner.

#### Owner is saved as the transcript's own speaker name
`MeetingDetailPresentation.storedSpeakerNames`: The name the transcript itself uses for each speaker ("Them 2", or a
saved alias): what an owner is saved as, whatever the page shows.

#### Row subtitle order: time, duration, then source
`MeetingDetailPresentation.rowSubtitle`: "1:00 PM · 50 min · Zoom": when, how long, then where it happened.

#### Widths in points at default text size; page fills pane, only prose has measure
`MeetingDetailLayout`: Widths of a saved meeting's page, in points at the default text size.
The page fills the detail pane; only prose keeps a reading measure.

#### Ultra-wide panes centre the column to keep play times near text
`MeetingDetailLayout.columnMaximumWidth`: The page's widest. Past this a row's text and its play time at the
trailing edge drift too far apart, so an ultra-wide pane centres the
column instead of stretching it.

#### Text-bound widths scale relative to default text size
`MeetingDetailLayout.factor`: How much wider than at the default text size a text-bound width is.

#### Pinned header copies scroller inset only for 1-40 pt differences
`MeetingDetailLayout.pinnedTrailingInset`: The title and the player are pinned above the scrolling panels. With
scroll bars set to always show, the scrolling column is narrower than
the pane by the scroller, so the pinned part takes the same inset and
both keep one trailing edge. Overlay scroll bars leave no difference.
A difference too large to be a scroller is a layout in flight, not an
inset to copy.

#### Whole-meeting search is pinned because matches move between tabs
`MeetingDetailLayout.FindPlacement.pinnedBar`: Command-F's search of the whole meeting, pinned under the player
because its matches move between tabs.

### `LokalBot/Models/Meetings/MeetingGenerationContext.swift`

#### Agenda stripped of joining info, links and contacts; persisted only if enabled
`CalendarAgenda`: The agenda part of a calendar invitation, with joining instructions,
links, phone numbers, email addresses, and markup removed. Only kept
when the user turns on agenda use; otherwise it is never persisted.

#### Calendar and screen context is secondary; transcript is the only evidence
`MeetingGenerationContext`: Secondary, source-labeled context for meeting notes: the calendar title,
invited participants by name, the optional agenda, and titles of
documents on screen during the call. The transcript stays the only
evidence for claims, decisions, actions, and ownership.

### `LokalBot/Models/Meetings/MeetingNotes.swift`

#### User notes.md folded into prompts as high-signal context the model trusts
`MeetingNotes`: The user's own quick notes taken during a meeting — a plain `notes.md`
beside the audio in the meeting folder. Written live by the recording
panel and folded into the summary + outcomes prompts as high-signal
context (the user typed it; the model should trust it over its own
paraphrase of the transcript).

#### Clearing text removes the file so empty notes never reach prompts
`MeetingNotes.write`: Best-effort save; clearing the text removes the file so empty notes
never haunt the summary prompt.

### `LokalBot/Models/Meetings/MeetingOutcomeProjection.swift`

#### Shared file-backed outcome read model merges extraction with user state
`MeetingOutcomeProjection`: File-backed outcome read model shared by the app, CLI, and MCP server. It
merges immutable extracted outcomes with the user's saved workflow state.

#### Single loader prevents exports falling back to unedited extraction
`MeetingOutcomeProjection.load`: One loader for UI surfaces and background routines. Keeping the merge
here prevents exports from silently falling back to immutable extraction
after the user has completed or corrected an action in the app.

#### Corrected due phrase resolves from correction day; extracted from meeting day
`OutcomeActionReference.dueReferenceDate`: A corrected due phrase is interpreted from the day the user typed it;
an extracted phrase from the day of the meeting.

### `LokalBot/Models/Meetings/MeetingOutcomeState.swift`

#### User workflow state layered over immutable extracted outcomes
`MeetingOutcomeState`: User-owned workflow state layered over immutable extracted outcomes.

#### Cleared flags distinguish explicit clear from absent override; legacy inherits
`MeetingOutcomeState.ActionState.ownerWasCleared`: Distinguish an explicit user clear from the absence of an override.
Nil overrides continue to inherit extracted values for legacy state.

#### Legacy correction dates frozen before status writes advance updatedAt
`MeetingOutcomeState.ActionState.init(from:)`: Freeze legacy correction dates before a subsequent status write
advances updatedAt. New records preserve each field independently.

#### No sending integration; approved workflow is review, copy or export only
`FollowUpDraft`: Editable follow-up content. No sending integration is attached to this
model: the approved workflow is review, copy, or export only.

#### Timestamps rounded to milliseconds to match ISO-8601 persistence
`Date.outcomePersistedTimestamp`: ISO-8601 persistence uses millisecond precision. Normalize mutation
timestamps at creation so in-memory and reloaded workflow state agree.

### `LokalBot/Models/Meetings/MeetingOutcomes.swift`

#### Citation is a durable pointer plus excerpt; transcript stays immutable
`OutcomeSourceCitation`: A transcript-backed source reference stored with an extracted outcome.
The transcript stays immutable; this record is only a durable pointer into
it, plus a short excerpt so older outcomes remain understandable if a
transcript is later repaired.

#### meetingID persisted so exported citations identify themselves outside folder
`OutcomeSourceCitation.meetingID`: Redundant with the per-meeting folder for new records, but persisted so
exported/indexed citations remain self-identifying outside that folder.

#### Extracted outcomes immutable; corrections and status live in MeetingOutcomeState
`MeetingOutcomes`: Structured outcomes extracted from a meeting after summarization. The
extracted text and evidence are immutable source data; user corrections and
workflow status live separately in `MeetingOutcomeState`.

#### Owner as named in meeting; nil when unstated, never guessed
`MeetingOutcomes.ActionItem.owner`: Who it is on, exactly as named in the meeting ("Me", "Ana"). Nil
when no owner was stated -- never guessed.

#### Due is stored as spoken, not normalized
`MeetingOutcomes.ActionItem.due`: Due date/time as spoken ("Friday", "by end of Q3"), not normalized.

#### Stored extraction judgment; legacy records derive it from owner
`MeetingOutcomes.ActionItem.isForUser`: Stored extraction judgment. Legacy records derive it from owner.

#### Unclear owner spoken on this Mac's microphone is likely the user's
`MeetingOutcomes.ActionItem.isLikelyUserAction`: Unclear ownership whose evidence was spoken on this Mac's
microphone: most likely the user's own work.

#### Importance ranks others' and unclear actions; user-owned all retained
`MeetingOutcomes.ActionItem.importance`: Relative meeting importance assigned by the grounded extraction
pass. This ranks other participants' actions and actions with unclear
ownership together; every user-owned action is retained.

#### Decision decodes both plain string (schema v1) and object
`MeetingOutcomes.Decision.init(from:)`: A decision was a plain string in schema v1. Decode both shapes.

#### String decisions kept for routines and chat; UI reads decisionRecords
`MeetingOutcomes.decisions`: Compatibility surface used by routines and chat formatting. New UI
reads `decisionRecords` so it can render evidence citations.

#### Priority order user, likely-user, others; nothing dropped, views cap own lists
`MeetingOutcomes.prioritizingActionItems`: Orders the user's work first, then unclear-owner actions spoken on this
Mac's microphone, then every other or unclear-owner action, ranked
together by importance. Nothing is dropped: stored outcomes, search,
CLI/MCP, follow-ups, and briefs keep every validated action, and views
that show a short list cap their own presentation.

#### Microphone speaker keys include me, local and merged source forms
`MeetingOutcomes.isMicrophoneSpeaker`: Microphone speaker keys ("me", "local", "local 2", including merged
"source1:local 2") as written by the attributed track transcriber.

#### FNV-1a gives persistable identity because Swift Hasher is randomized
`MeetingOutcomes.stableID`: FNV-1a keeps identity stable across app launches and re-extractions.
Swift's `Hasher` is intentionally randomized and cannot be persisted.

### `LokalBot/Models/Meetings/MeetingScreenContext.swift`

#### Built only from retained screen-memory rows; no pixels or text; can shrink
`MeetingScreenContext`: What was on screen while a meeting recorded, aligned to the meeting's
audio timeline. Built only from retained screen-memory rows (titles,
document names, URLs, and timestamps); pixels and captured text are not
read here. Captures expire with screen retention, so this can shrink.

#### Offset is seconds from start of meeting audio
`MeetingScreenContext.Moment.offset`: Seconds from the start of the meeting's audio.

#### End is when next stretch began or recording ended
`MeetingScreenContext.Moment.endOffset`: When the next stretch began, or the end of the recording.

#### Site is tab-title site name, else web page host
`MeetingScreenContext.Material.site`: The site name from the tab title, else a web page's host.

#### Time on screen is approximate: capture to next change
`MeetingScreenContext.Material.secondsOnScreen`: Approximate time in front, from capture to the next change.

#### Link only when stored URL can reopen the page
`MeetingScreenContext.Material.pageURL`: A web address that reopens this page, when the stored one can.

#### Only titles used as secondary context, never captured text
`MeetingScreenContext.materialTitles`: Window and document titles for use as secondary context, never the
captured text itself.

#### Cap materials by longest on screen, keep first-appearance order
`MeetingScreenContext.build`: A long call can touch dozens of windows; keep the ones that stayed
in front longest, still listed in the order they first appeared.

#### Browser document name is URL fragment, so ignored for titles
`MeetingScreenContext.page(for:)`: A browser's document name is the last piece of the page's URL
("#inbox", a message id), not something the user would recognize.

#### Account addresses and unread counts dropped so revisits group
`MeetingScreenContext.splittingSite`: "Weekly sync - you@example.com - Gmail" reads as the page "Weekly
sync" on "Gmail". Account addresses and unread counts are dropped so
revisits of one page group together.

#### Stored URLs lack query and fragment, so such pages get no link
`MeetingScreenContext.reopenableURL`: Stored addresses drop their query and fragment, so a page chosen by
either (a Gmail message, a YouTube video, a search) gets no link
rather than one that opens the wrong page.

#### The call's own window or tab is not referenced material
`MeetingScreenContext.isCallWindow`: The call itself (the meeting app's window or a conference tab) is not
material the user referenced.

#### Captures may lack URL; camera/microphone tab or Meet tab is the call
`MeetingScreenContext.isCallWindow`: Captures can lack the tab's URL. A tab using the camera or
microphone during the meeting is the call, and so is a Meet tab.

#### Material keyed by title not URL; paths shared and URL may be missing
`MeetingScreenContext.materialKey`: Keyed by the readable title, not the URL: many pages share a path
(every Gmail message, every YouTube video), and captures can lack
the URL altogether.

### `LokalBot/Models/Meetings/NoteTemplate.swift`

#### Adapted from Seminarly; Markdown output so JSON schema not ported
`NoteTemplate`: Shape of the notes the LLM should produce. Adapted from Seminarly's
`NoteTemplate` — LokalBot keeps summarisation output as Markdown rather
than structured JSON, so the JSON section schema isn't ported, just the
enum that drives prompt selection.

### `LokalBot/Models/Meetings/SampleMeeting.swift`

#### Bundled synthetic call through ordinary import; Ask sees it, memory excludes; mirrors Rust and sample_meeting.py
`SampleMeeting`: LokalBot's sample meeting (`Resources/SampleMeeting`): a made-up call
between two synthetic voices, bundled so a new library can show a cited
answer before anything is recorded. It goes through the ordinary import
and carries `Meeting.sampleID`, so Ask, search and agents see it while
personal memory leaves it out. The Windows and Linux app embeds the same
recording (`lokalbot_engine::sample`).

`Scripts/dev/sample_meeting.py` builds the audio and its reference transcript,
and scores a transcript of it.

#### Recording id stored as sampleID: script then language
`SampleMeeting.Recording.id`: Stored as the meeting's `sampleID`: the script, then its language.

#### Suggested Ask question in interface language; answer in expected.\<language>.json
`SampleMeeting.question`: The question the sample suggests for Ask, shown in the interface
language. Its answer is in the passage where the decision changes
(`SampleMeeting/expected.<language>.json`).

#### Pick sample by interface language, fall back to English
`SampleMeeting.recording(for:)`: The sample spoken in `language` (an interface language such as "de" or
"sr-Latn"), else the English one.

### `LokalBot/Models/Meetings/SummaryLanguage.swift`

#### Summary language is distinct from transcription language; default matches transcript
`SummaryLanguage`: Target language for AI-generated summary notes. Distinct from
`TranscriptionLanguage`: that controls what WhisperKit/Parakeet listens
for, this controls what the LLM writes notes in. Default `.matchTranscript`
resolves the transcript text to a concrete language before prompt
construction. Ported from Seminarly's `SummaryLanguage`.

#### Presets exclude matchTranscript and custom, for pickers
`SummaryLanguage.presets`: Stable preset cases (excludes `.matchTranscript` and `.custom`) - used
to drive Pickers without exposing two-mode logic.

#### Nil for matchTranscript means no language directive in prompt
`SummaryLanguage.promptLanguageName`: Name to drop into the LLM prompt (e.g. "Korean", "Klingon"). Returns
nil for `.matchTranscript`, signalling the caller to inject no directive.

#### Detect per passage and vote; a single prefix must not decide
`SummaryLanguage.detectTranscriptLanguage`: Detect each bounded passage independently, then choose the language
with the most material support. `NLLanguageRecognizer` can lock onto a
foreign-language opening even when the rest of a long string is in a
different language, so a single prefix must never decide a meeting.

#### Sampled across meeting; non-preset languages count as themselves
`SummaryLanguage.isMostlyEnglish`: Whether most of a transcript is English, sampled across the meeting
for the same reason as above. Languages outside the summary presets
count as themselves here instead of falling back to English.

#### Chinese variant chosen by character set; bopomofo means Cantonese
`SummaryLanguage.chineseScriptLanguage`: MARK: - Chinese script detection

Simplified vs Traditional vs Cantonese is script, not language code - we
look at the character set to pick the right Mandarin variant (or
Cantonese when bopomofo appears).

### `LokalBot/Services/Meetings/AppState+MeetingImport.swift`

#### Plan JSON carries paths and counts only, never meeting contents
`ExternalImportPlan.json`: The plan as the socket and the approval card report it. Paths and
counts only, never a meeting's contents.

#### Message is nil when import simply worked
`ExternalImportSummary.message`: What the person sees when the import ends, or nil when it simply
worked and the new meetings speak for themselves.

#### Chosen or approved files import without asking, serialized after recording imports
`AppState.importExternalMeetings`: Imports every meeting in `urls` that isn't in the library yet. The
person chose the files, or approved the request, so nothing asks
again. Imports run one after another, after any recording imports.

#### Import log holds counts only, no titles or paths
`AppState.runExternalImport`: Counts only: titles and paths stay out of the log.

### `LokalBot/Services/Meetings/ExternalMeetingWriter.swift`

#### Import file mapping; sources read-only; meta.json last so no half-made meetings
`ExternalMeetingWriter`: Stores a meeting read from another app (`ExternalMeeting`) as a LokalBot
meeting. The source's transcript becomes `transcript.json`, its notes
`summary.md` (with an untouched copy in `imported-notes.md`), and a
recording that came with it goes through `MeetingImportService`. The
source files are only read. `meta.json` is written last, so the library
never lists a half-made meeting.

#### Source notes kept unchanged so later LokalBot notes never lose them
`ExternalMeetingWriter.importedNotesFileName`: Where the source's own notes are kept unchanged, so writing LokalBot
notes for the meeting later never loses them.

#### Deterministic id lets interrupted imports be recognized
`ExternalMeetingWriter.meetingID`: The same source meeting always gets the same LokalBot id, so an
import interrupted after its audio was saved is still recognized.

#### Failed text-only imports are removed; recording meetings are kept as imported
`ExternalMeetingWriter.write`: A text-only meeting isn't listed until meta.json exists, so
nothing half-made stays behind. A recording's meeting is kept:
its audio is safe and its id still marks it imported.

#### Voice Memos use the mic track; other sources' recordings are calls
`ExternalMeetingWriter.recordingTrack`: Voice Memos are recorded on the person's own microphone, so "My
microphone is me" applies to them; other sources' recordings are calls.

#### Missing start falls back to file modification date, never future
`ExternalMeetingWriter.fallbackStart`: When the source kept no start: the file's modification date, which an
export usually leaves at the meeting's day or later, never the future.

#### Stable them-N labels with names as aliases; untimed lines laid out at speaking pace
`ExternalMeetingWriter.transcript`: The source's lines as a LokalBot transcript. Each named speaker gets a
stable label ("them 1", "them 2", …) with their name as its alias; the
person's own microphone lines are "me". Lines the source kept without
times are laid out one after another at speaking pace, marked coarse.

#### Action items appended only when notes don't already state them
`ExternalMeetingWriter.notesMarkdown`: The source's notes, with its action items listed after them unless
the notes already say them.

### `LokalBot/Services/Meetings/MeetingActionHandoff.swift`

#### One Agent Mode task per own open action, with notes attached
`MeetingActionHandoff`: Hands a meeting's open actions that are the person's to Agent Mode: one
task per action, with its prompt in the composer and the meeting's notes
attached, so an agent can work on each one on its own.

#### More than eight actions suggests noisy extraction, so cap
`MeetingActionHandoff.maximumActions`: More actions than this from one meeting is more likely a noisy
extraction than a list worth a task each.

#### Automatic handoffs only for last-day meetings so reprocessing never floods Agent Mode
`MeetingActionHandoff.automaticWindow`: Automatic handoffs only follow meetings from the last day, so
importing or summarizing old recordings again never fills Agent Mode.

#### Notes travel as an attachment that Agent Mode rereads on send
`MeetingActionHandoff.prompt`: The task's composer text. The meeting's notes travel as an attachment
that Agent Mode reads again when the prompt is sent.

#### Only a lone lookup runs without a card, matching AgentApprovalPolicy.isLibraryLookup
`MeetingActionHandoff.prompt`: Only a lone lookup runs without a card (AgentApprovalPolicy.isLibraryLookup).

#### Handoff folder layout relative to the workspace
`MeetingActionHandoff.folder`: `handoffs/<day>-<meeting>/<number>-<action>`, relative to the workspace.

#### Automatic setting starts tasks; manual request recreates archived tasks
`AppState.handOffActions`: Gives each open action of the person's from `meeting` its own Agent
Mode task. With "Start handoffs automatically" on, the tasks run as
agents free up; otherwise each prompt waits in its composer. Asked
for by hand, an action whose task was archived gets a new one.
Returns the new tasks' IDs, empty when every action already has a task.

### `LokalBot/Services/Meetings/MeetingAttributionArtifacts.swift`

#### Writers live here for checkpoints; names and readers shared with CLI in Models
`MeetingAttributionArtifacts`: Writers live here because they reach generation checkpoints; the file
names and read-only helpers are shared with the CLI in Models.

### `LokalBot/Services/Meetings/MeetingAudioAsset.swift`

#### Player and export share sources and gains so playback matches export
`MeetingAudioAsset.playbackSources`: The meeting's source files paired with the gain each should play at.
Shared by the live `MeetingPlayer` (which renders them as independent
players) and the offline export (which folds the same set into one
composition), so what you hear matches what you export.

#### Mic bleed: system track dominant at 0.85, mic 0.55
`MeetingAudioAsset.existingSources`: The mic track can contain speaker bleed; keep the clean system
track dominant and leave enough local voice to understand replies.

### `LokalBot/Services/Meetings/MeetingAudioFiles.swift`

#### AAC tracks, crash-safe CAF tees and Windows/Linux WAV fallback order
`MeetingAudioFiles`: Resolves the durable AAC tracks and the crash-safe PCM preview tees for one
meeting. A process crash can leave `mic.m4a` / `system.m4a` unreadable
because their MP4 containers were never finalized; the append-only CAF tees
remain readable and must stay available for transcription and playback.
Meetings recorded, imported or merged by the Windows and Linux app keep
16 kHz `mic.wav` / `system.wav` tracks instead; they are read only when a
folder has neither an AAC track nor a recovery tee.

#### Gap beyond 0.1 s means truncated primary; CAF is more complete
`MeetingAudioFiles.completenessTolerance`: Container finalization and the PCM tee can differ by a small encoder
tail. A larger gap means the primary track was truncated and the CAF is
the more complete recording.

#### WAV tracks come from the Windows and Linux app, which has no AAC encoder
`MeetingAudioFiles.Track.portableFileName`: Written by the Windows and Linux app, which has no AAC encoder.

#### Prefer AAC; fall back to CAF if undecodable or materially shorter
`MeetingAudioFiles.readableURL`: Prefer the compact AAC track, falling back to the crash-safe CAF only
when AAC cannot be decoded or is materially shorter. The latter covers
a crash that leaves a technically readable but truncated MP4 container.

#### Keep CAF unless primary is readable; it may be the only recording
`MeetingAudioFiles.removeRedundantRecoveryFiles`: A normal stop leaves a finalized primary track, so its duplicate CAF can
be removed. If the primary is unreadable, preserving the CAF is a hard
data-safety rule: it may be the user's only recoverable recording.

#### Keep checkpoints if reconstruction failed; may be only surviving copies
`MeetingAudioFiles.removeRedundantRecoveryFiles`: Keep checkpoints if reconstruction failed: they may be the only
surviving copies of intervals not described by the AAC header.

#### Readable AAC header does not prove intact payload; decode fully when CAF exists
`MeetingAudioFiles.preferredURL`: A readable AAC header alone cannot prove its payload is intact.

### `LokalBot/Services/Meetings/MeetingAudioRecovery.swift`

#### Fast retry burst then slow wait, never permanent mic-only failure
`MeetingAudioRecovery`: One session-owned attachment loop. A bounded fast retry burst becomes a
low-frequency wait, never a permanent microphone-only failure.

#### Detector events can wake recovery anytime; stale or different calls can't attach
`MeetingAudioRecovery.offer`: Detector/device events can wake recovery immediately, including after
the initial burst. A stale generation or a different call cannot attach.

#### Fewer than five dropped buffers are inaudible; one flagged a 33-minute recording
`RecordingHealthReport.noticeableDroppedBuffers`: Drops below this are isolated callbacks (about 10–90 ms each) that no
listener would notice. A single one flagged a complete 33-minute
recording as "interrupted" on 2026-10-01.

#### Incident history capped at 1000 events, preserving the first failure
`RecordingHealthReport.observe`: Keep the incident history bounded, preserving the first failure.

#### Notify only for sustained conditions; notifications interrupt the call
`CaptureWarningNotifications`: When a live capture warning also becomes a macOS notification. The meeting
view shows every warning as it happens; a notification interrupts the call
itself, so it is kept for conditions that lasted long enough to matter.
On 2026-10-01 a 1.9-second accessibility hiccup and one dropped buffer each
raised "Recording needs attention" mid-meeting.

#### Stopped audio must persist 15 s before notifying
`CaptureWarningNotifications.sustainedAudioWarningDelay`: Audio that stops arriving must persist this long before it notifies.

#### Call-status warning waits the detector's own browser observation grace
`CaptureWarningNotifications.delay`: The detector itself waits this long before it treats a lost call
as anything but a hiccup.

#### Each warning notifies at most once per recording
`CaptureWarningNotifications.due`: Warnings due for a notification now, each at most once per recording.

### `LokalBot/Services/Meetings/MeetingDocumentSnapshot.swift`

#### Snapshot published after cancellation check so older documents can't install
`MeetingDocumentSnapshot`: Value-only result of file validation. The view publishes this after checking
task cancellation, so a pipeline update cannot install an older document.

### `LokalBot/Services/Meetings/MeetingImportService.swift`

#### Imported audio is the system track, never enrolled in voice profiles; phone recordings use mic
`MeetingImportService`: Turns an audio or video file the user brings in into a meeting. The file's
audio becomes the meeting's system track, so it is diarized like call audio
and, like any remote participant's, its voices are never enrolled or matched
against voice profiles. The original file is only read; the meeting keeps
its own AAC copy, and the normal processing pipeline does the rest. A
recording from a paired phone or tablet takes the same path, except that it
becomes the microphone track: see `importDeviceRecording`.

#### Drops accept same kinds; AVFoundation decides actual readability
`MeetingImportService.contentTypes`: What the import panel offers. A drop accepts the same kinds of file;
AVFoundation decides whether it can actually read the audio.

#### Device-chosen id is kept so resends find the meeting
`MeetingImportService.DeviceOrigin.id`: The device chose it, so the meeting keeps it and a resend finds it.

#### Device clock decides start, but meeting never ends in the future
`MeetingImportService.DeviceOrigin.startedAt`: When the device started recording. The device's clock decides, but
the meeting never ends in the future.

#### Sample marks the sample meeting: localized title, dated now, carries its id
`MeetingImportService.importRecording`: `sample` marks the import as LokalBot's sample meeting: it is titled in
its own language, dated now, and carries its id.

#### External recordings keep source id, title, start; own-device mic goes on mic track
`MeetingImportService.importExternalRecording`: A recording that came with a meeting from another app (Zoom, Voice
Memos, MacWhisper): its id, title, and start come from that app. Call
audio goes on the system track like any imported file; a recording the
person made on their own device's microphone, as Voice Memos are, goes
on the microphone track like a paired phone's.

#### Device audio is the person's mic track and takes no screen context
`MeetingImportService.importDeviceRecording`: Makes a meeting of a recording from a paired device. It is the device's
microphone, the person's own, so it becomes the microphone track: their
speech counts as theirs under "My microphone is me", and other voices
in the room are treated as the Mac's microphone treats them, not as call
participants. Like any import it takes no screen context, because the
person wasn't at this Mac.

#### ADTS duration counts frames at 1024 samples; stops at damage, never overstates
`MeetingImportService.adtsDuration`: How long an ADTS stream really is: its frames counted, 1024 samples each.
Stops at a frame cut short or damage, so it never overstates. Nil when
it doesn't start with a frame.

#### Each ADTS frame holds one to four 1024-sample blocks
`MeetingImportService.adtsDuration`: Each ADTS frame holds 1 to 4 raw blocks of 1024 samples.

#### Stated start outranks the file's own start date
`MeetingImportService.Plan.statedStart`: Outranks what the file itself says about when it began.

#### Known duration is what the conversion must keep
`MeetingImportService.Plan.wholeDuration`: What the conversion must keep, when that can be known.

#### Sender deletes its file on return, so meeting must be on disk
`MeetingImportService.Plan.isOnlyCopy`: The sender deletes its file once this returns, so the meeting has to
be on the disk by then rather than in its cache.

#### Precise timing avoids truncated exports of indexless files; 27 minutes became 3.5
`MeetingImportService.makeMeeting`: Without precise timing AVFoundation guesses the length of a file with
no index (ADTS, some MP3s) from its first frames, and the export stops
there: 27 minutes that started loud and went quiet came out as 3.5.

#### Convert beside the library to avoid cross-volume copy and half-made meetings
`MeetingImportService.makeMeeting`: Convert beside the library so the finished file moves into the
meeting folder without a cross-volume copy, and a failed conversion
never leaves a half-made meeting in the library.

#### Metadata written last so library scans never see half-made meetings
`MeetingImportService.makeMeeting`: The meeting appears in the library only once its metadata is
written, which is last, so a library scan never sees it half-made.

#### Start heuristics: metadata date, else earlier file date, capped, pre-2001 ignored
`MeetingImportService.recordingStart`: Best guess at when the recording began, never so late that it would
end in the future. A recorder's own creation date names the start. File
dates are weaker: modification usually marks when recording stopped and
survives a copy, while a copy's creation date is when it was copied, so
the earlier of the two readings wins. Dates before 2001 are unset
container fields, not real recordings.

#### Mix every enabled audio track to AAC and drop video
`MeetingImportService.exportAudio`: Every enabled audio track, mixed to AAC. A video's picture is dropped;
a screen recording's separate microphone and system tracks are mixed.

### `LokalBot/Services/Meetings/MeetingMergeService.swift`

#### Merge never deletes sources; speakers namespaced; sources folded into the merged row
`MeetingMergeService`: Builds a new meeting from completed source meetings without deleting any
source folder. The merged timeline is the selected source ranges laid
end-to-end; transcript speakers are namespaced by source so a label such as
"Me" in one recording can never silently claim a voice in another recording.
Source records are marked as folded into the new meeting so the normal
library view shows one merged row instead of duplicates.

#### Incomplete coverage means a requested summary must transcribe merged audio first
`MeetingMergeService.Result.transcriptCoverageComplete`: False when any selected source range contributed no transcript
segment. A requested summary must first transcribe the merged audio.

#### Version-2 fields optional so old manifests don't claim coverage
`MeetingMergeService.Manifest.Source`: Version-2 fields. Optional decoding keeps older manifests
readable without claiming coverage they never recorded.

#### Merge stays imported if sources are, since screen context would be unrelated
`MeetingMergeService.merge`: Screen context reads this marker. An imported source's span
shows unrelated screen activity, so the merge stays imported.

#### Source-scoped speaker names keep confirmed aliases and show provenance
`MeetingMergeService.makeTranscript`: Every visible speaker receives a source-scoped display name.
This preserves a confirmed source alias while making the
provenance obvious in a merged transcript.

#### Preserve leading silence so audio shares the transcript's rangeStart base
`MeetingMergeService.composition`: Preserve silence at the beginning of a selected range
when a source track starts late. Transcript offsets are
relative to `rangeStart`, so audio must share that base.

#### Advance cursor over full range when a track is missing to keep alignment
`MeetingMergeService.composition`: Advance over the source's complete selected range even when one
track is missing, keeping mic/system/transcript time aligned.

#### Keep merged transcript for text-only sources when full ASR retry runs
`MeetingMergeService.preservingTranscriptOnlySources`: Full-ASR retry covers every source that contributed audio. Preserve the
already merged transcript in source intervals that had text but no
audio; otherwise silence in the concatenated asset erases that source.

### `LokalBot/Services/Meetings/MeetingNoteExportScheduler.swift`

#### Passes run at most once a minute, only when idle, re-rendering changed meetings
`MeetingNoteExportScheduler`: Runs the optional meeting note export. A pass starts when the export is
configured and after meeting evidence, People, or Projects change, at most
once a minute and never while `canRun` says processing is busy. Each pass
re-renders only the meetings whose sources changed since the last one, so
following corrections does not reread the whole library.

#### Changing folder, format or transcript choice re-exports every meeting
`MeetingNoteExportScheduler.Configuration.destinationID`: Folder, format, and transcript choice. Changing any of them
exports every meeting again into the chosen folder.

#### Failed passes wait 15 minutes so removable volumes can return
`MeetingNoteExportScheduler.retryInterval`: A failed pass waits this long before it is tried again, which gives a
removable or network volume time to return.

#### Cancelled passes may leave notes, so the next start redoes them
`MeetingNoteExportScheduler.cancel`: A cancelled pass may have left notes behind; the next start redoes it.

#### Structured utility child so cancelling reaches the filesystem worker
`MeetingNoteExportScheduler.run`: A structured utility-priority child, so cancelling the pass reaches
the filesystem worker itself.

### `LokalBot/Services/Meetings/MeetingNoteExportService.swift`

#### Fingerprints cover sources so next pass renders only possibly changed meetings
`MeetingNoteExportReport`: What one pass did. Fingerprints are of each meeting's sources, so the next
pass renders only the meetings whose notes could have changed.

#### Notes keep first name, refresh only while unedited, and are left alone if edited or deleted
`MeetingNoteExportService`: Optional one-note-per-meeting export to a folder the person picks, such as
an Obsidian vault or a Logseq OG graph's `pages` folder: the summary with
the action list as LokalBot shows it, people and tracked projects as links,
and optionally the transcript.

A note is named when it is first written and keeps that name, so links to
it from other notes survive a renamed meeting. It is refreshed only while
it still holds the bytes LokalBot wrote (the same hash sidecar as the daily
export). A note the person edited, deleted, or moved is theirs: LokalBot
leaves it alone and does not write that meeting again. Deleting a meeting
in LokalBot leaves its note in place, like every other export.

#### Render version is in every fingerprint so format changes refresh all notes
`MeetingNoteExportService.renderVersion`: Part of every fingerprint: changing how notes look refreshes them all.

#### Left means edited, deleted, moved, or name held by a foreign file
`MeetingNoteExportService.Outcome.left`: Edited, deleted, or moved by the person, or a file LokalBot did
not write holds the name.

#### Matching fingerprints skip a meeting without reading it
`MeetingNoteExportService.export`: Writes or refreshes the note of every finished meeting with a summary,
or a transcript when transcripts are included. A meeting whose
fingerprint matches `previous` is skipped without being read.

#### Sample meeting is fake so it is never exported
`MeetingNoteExportService.export`: The sample meeting is made up, so it never lands in the user's notes.

#### Stamp sources before reading so later changes alter the next stamp
`MeetingNoteExportService.export`: Sources are stamped before anything is read from them: a file that
changes after its stamp is taken changes the next pass's stamp too.

#### Actions grouped like summary.md with corrections applied and completed checked
`MeetingNoteExportService.actionLines`: The action list as LokalBot shows it, grouped like `summary.md`, with
the person's corrections applied and completed actions checked off.

#### File name has date, title and short id so notes sort and survive renames
`MeetingNoteExportService.fileName`: "2026-09-29 Atlas release sync (4f7c2a91).md": the date sorts notes,
the title reads well in a vault, and the meeting's short id finds the
note again after the meeting is renamed.

#### Stamp is file names, sizes and mtimes, which processing and edits change
`MeetingNoteExportService.sourceStamp`: Names, sizes, and modification dates of the files in a meeting folder.
Processing, a correction, a completed action, and a renamed speaker or
meeting each rewrite one of them.

#### Double-quoted YAML so colons and quotes in titles stay text
`MeetingNoteExportService.yamlString`: A double-quoted YAML scalar, so titles with colons or quotes stay text.

#### Notes with remaining sidecar but missing file mean the person deleted or moved them
`MeetingNoteExportService.ExistingNotes`: The export folder's notes by meeting short id, and the meetings whose
note is gone while its ownership sidecar remains: the person deleted
the note or moved it elsewhere in the vault.

#### With duplicate notes for a meeting prefer the one LokalBot wrote
`MeetingNoteExportService.ExistingNotes`: Two notes for one meeting: keep to the one LokalBot wrote.

#### People and projects joined by People and Projects page rules, once per pass
`MeetingNoteExportService.Connections`: People and tracked projects per meeting, joined with the same rules as
the People and Projects pages, once per pass.

#### Key changes when tracked projects change, re-checking all project links
`MeetingNoteExportService.Connections.projectsKey`: Changes when a project is tracked, renamed, or dropped, so every
note's project links are looked at again.

### `LokalBot/Services/Meetings/MeetingPlayer.swift`

#### Separate clock so only audio bar and highlights subscribe to ticks
`MeetingPlaybackClock`: Only the audio bar and lightweight row highlights subscribe to timer ticks.
Keeping this separate avoids invalidating the entire meeting workspace.

#### Independent AVAudioPlayers resample mismatched tracks; a single composition garbles playback
`MeetingPlayer`: Plays a meeting's two source files (mic.m4a + system.m4a) together. They
were recorded simultaneously, so playing both from the same offset
reproduces the meeting; click-to-seek from the transcript lands here.

Each track gets its own `AVAudioPlayer` and the OS mixes them at the output
device. This is deliberate: the mic and system files routinely differ in
sample rate (device-native vs. the 48 kHz tap) and channel count (mono vs.
stereo mixdown). Folding both into one `AVMutableComposition` + `AVAudioMix`
and rendering through `AVPlayer` garbles the mismatched track during
real-time playback — independent players resample each cleanly. (Offline
export can still use the composition; see `MeetingAudioAsset`.)

#### AVAudioPlayer enableRate and rate change speed preserving pitch
`MeetingPlayer.speed`: Playback rate (1.0 = normal). `AVAudioPlayer` honors `enableRate` + `rate`
and preserves pitch while the rate changes.

#### Waveform uses exactly the tracks and gains that loaded
`MeetingPlayer.waveformSources`: Use exactly the tracks and gains that loaded successfully for playback.

#### Longest source owns the timeline; first player freezes scrubber when shorter ends
`MeetingPlayer.timelinePlayer`: The longest source owns the meeting timeline. The system track can end
before the mic (or vice versa); clocking from `players.first` freezes or
jumps the scrubber as soon as that shorter player finishes.

#### Playback shares file and gain policy with export
`MeetingPlayer.load`: Share the file + gain policy with the offline export so what you hear
matches what you export.

#### Worker owns players until return; main actor takes them after generation check
`MeetingPlayer.PreparedPlayers`: The worker exclusively owns these players until it returns. Main-actor
playback takes ownership only after the generation/cancellation check.

#### Schedule tracks against a shared device-time anchor to stay in sync
`MeetingPlayer.play`: Schedule against a shared device-time anchor so both tracks stay in sync.

#### Clamp seek to each track's length so shorter tracks don't reject it
`MeetingPlayer.setPlayheads`: Position every track at `time`, clamped to that track's own length so a
shorter track doesn't reject the seek.

### `LokalBot/Services/Meetings/MeetingRecapExporter.swift`

#### Recaps need no servers: plain text and self-contained offline HTML
`MeetingRecapExporter`: Pure formatters for sharing a meeting outside LokalBot with zero servers:
a clean plain-text recap for Slack or email, and a self-contained single-file
HTML recap (auto light/dark, zero external assets, collapsible transcript).

#### HTML recap is offline-first with zero external requests
`MeetingRecapExporter.staticHTML`: Single-file, offline-first HTML recap with zero external network requests.

### `LokalBot/Services/Meetings/MissingTranscription.swift`

#### Finds pre-durable-intent recordings and merges with empty source spans
`MissingTranscription`: Finds finished recordings whose transcript is missing or incomplete, so the
pipeline can queue them once. Recordings from before processing intent was
durable can have audio but no transcript and no job; merges made before a
merge re-transcribed untranscribed sources can leave a whole source's span
of the merged transcript empty.

#### Marker written before repair so silent gaps aren't retried every launch
`MissingTranscription.gapRepairMarkerFileName`: Written before a merged-gap repair is queued, so a span that stays
empty (for example, silence) is not re-transcribed on every launch.

#### Recordings under 5 s hold no speech worth a model run
`MissingTranscription.minimumRecordingSeconds`: Shorter recordings hold no speech worth a model run.

#### Merged sources under 30 s may legitimately have no segments
`MissingTranscription.minimumGapSeconds`: A merged source shorter than this may legitimately have no segments.

### `LokalBot/Services/Meetings/PipelineJobStore.swift`

#### Durable queue; attempts count starts so poison-pill meetings can't crash-loop
`PipelineJobStore`: Persists the post-meeting processing queue in lokalbotv3.sqlite so a crash,
force-quit, or reboot mid-transcription doesn't silently drop the job — the
in-memory queue in `ProcessingPipeline` used to be the only record of what
still needed processing.

Own connection to the shared database file, same pattern as `SearchIndex` /
`ActivityStore` / `EmbeddingIndex`. A row lives for the duration of a job:
inserted on enqueue, deleted on success. `attempts` counts processing
*starts* (not failures), so a job that crashes the app mid-flight still
burns an attempt and a poison-pill meeting can't crash-loop launch resume
forever.

#### Completed flag proves this job committed the transcript, not an older one
`PipelineJobStore.PendingJob.transcriptionCompleted`: True only after this durable job committed its requested transcript.
A transcript left by an older job does not satisfy this phase.

#### Automatic summary intent follows current setting; explicit intent persists
`PipelineJobStore.PendingJob.summaryFollowsSetting`: Automatic summary intent follows the current setting when a job is
restored. Explicit toolbar/headless intent survives unchanged.

#### Auto-resume stops after three starts; explicit re-enqueue resets
`PipelineJobStore.maxAutoResumeAttempts`: Launch auto-resume gives up after this many processing starts; an
explicit user re-enqueue resets the counter and tries again.

#### Old rows without provenance treated as automatic so opt-out takes effect
`PipelineJobStore.init`: Rows written by older builds had no provenance. Treat their
summary bit as automatic so a current opt-out takes effect.

#### Old rows can't prove the transcript is theirs, so ASR resumes
`PipelineJobStore.init`: An older row cannot prove that this job produced the
transcript currently on disk. Conservatively resume ASR.

#### Explicit re-enqueue resets attempts as a deliberate retry
`PipelineJobStore.enqueue`: Record a fresh enqueue. Resets `attempts`: an explicit re-enqueue is a
deliberate retry, not a crash-loop continuation.

#### Updating a running job keeps attempts and makes toolbar choice durable
`PipelineJobStore.updateIntent`: Update a job that is already running without resetting its crash-loop
attempt count. This makes an active toolbar choice durable if the app
quits before the current transcription reaches the summary boundary.

#### Count attempt at start so a crash is already counted
`PipelineJobStore.markStarted`: Burn one attempt the moment processing starts, so a crash mid-job is
already counted when the row is read back on the next launch.

#### Recovery uses this marker, not an existing possibly older transcript
`PipelineJobStore.markTranscriptionCompleted`: Persist the transcription phase immediately after the transcript
commit. Crash recovery must use this marker rather than the existence of
a transcript that may predate the current request.

#### Persist last failure so parked jobs explain themselves after relaunch
`PipelineJobStore.markFailed`: Persist why the last processing attempt failed, so a job that ends up
parked (attempts exhausted) can still explain itself after a relaunch.

#### Exhausted jobs skip launch queue but show as failed rows for retry
`PipelineJobStore.parkedJobs`: Jobs that burned through the auto-resume attempt cap. They never
re-enter the launch queue, but the UI surfaces them as failed rows so
the user can retry explicitly.

#### Retry reads a parked job's exact scope before enqueue resets it
`PipelineJobStore.job`: Read one durable intent regardless of its automatic-resume attempt
count. An explicit Retry must recover even a parked job's exact scope
before `enqueue` resets that row.

#### Drop jobs whose meeting was deleted between crash and launch
`PipelineJobStore.prune`: Drop rows whose meeting no longer exists (deleted from the library
between the crash and this launch).

### `LokalBot/Services/Meetings/ProcessingPipeline.swift`

#### Serial post-meeting queue: transcribe tracks, merge, summarize, write artifacts
`ProcessingPipeline`: Serial post-meeting queue (design doc §6): transcribe each track,
merge by timestamp into a speaker-attributed transcript, then summarize
with the configured local LLM. Writes transcript.json / transcript.md /
summary.md next to the audio.

#### Meeting-list rows use compact stage labels; detail pane stays descriptive
`ProcessingPipeline.Stage.rowLabel`: Compact vocabulary for meeting-list rows. The detail pane keeps
the more descriptive label above; rows need to stay scannable.

#### Waiting-for-models is neither failure nor active work
`ProcessingPipeline.Stage.isWaitingForModels`: The job is parked because processing would trigger a model download
the user never asked for. Neither a failure nor active work.

#### Automatic jobs never download models; user-initiated jobs download on demand
`ProcessingPipeline.JobOrigin`: Who asked for this job. Automatic jobs (auto-transcribe after a
recording, launch crash-resume) must never trigger a model download —
they park as `.waitingForModels` instead. A user-initiated job (Retry,
the Process menu, `--process`) downloads missing models on demand,
because the user just asked for exactly that.

#### Crash-resumed jobs keep per-track checkpoints
`ProcessingPipeline.Job.resumed`: Re-enqueued from the persisted queue after a crash/quit — keep any
per-track checkpoints instead of starting from scratch.

#### Retry resumes durable request from latest artifact, keeping summary provenance
`ProcessingPipeline.retryWork(for:autoSummarize:)`: Resume the exact durable request from its latest completed artifact.
Failed rows retain their explicit/automatic summary provenance, even
after they exhaust the launch-resume attempt budget. Only jobs from an
older build with no durable row fall back to the current setting.

#### Without saved intent never overwrite a completed transcript
`ProcessingPipeline.retryWork`: With no saved intent, never overwrite a completed transcript.
The explicit Process menu remains available for a deliberate
re-transcription.

#### Injectable readiness checks keep tests off real models and network
`ProcessingPipeline.AutomationReadiness`: Injectable model-readiness checks so unit tests can exercise the
automation gate without touching real model folders (or the network).

#### Nil speech seconds means VAD unavailable, so the track is transcribed anyway
`ProcessingPipeline.speechSeconds`: Seconds of detected speech in a track; nil when voice activity
detection is unavailable (the track is then transcribed anyway).

#### Failed stage persists until next attempt; successes are removed
`ProcessingPipeline.stages`: Stage per meeting. `.failed` sticks around until the next attempt;
successful meetings are removed (the files on disk are the result).

#### jobStore mirrors the in-memory queue on disk for crash recovery
`ProcessingPipeline.queue`: In-memory work list; `jobStore` mirrors it on disk so a crash mid-queue
loses nothing — see `resumePending(meetings:)`.

#### Parked jobs keep durable rows pending without burning attempts
`ProcessingPipeline.waitingForModelsJobs`: Automatic jobs parked because their models are not downloaded yet.
Their durable rows stay pending (no attempt burned), so a relaunch
re-checks them; `retryJobsWaitingForModels()` re-checks mid-session.

#### No new heavy job during capture; running phase finishes and persists first
`ProcessingPipeline.setCaptureActive`: Never start another heavy job while capture is active. An already
running phase finishes and persists its result before yielding.

#### Active job task kept separately so deletion can cancel and await it
`ProcessingPipeline.activeProcessingTask`: The currently running job is retained separately from the queue-drain
loop so deletion can cancel and await it before removing source files.

#### Revocation survives cancellation-unaware engines; late commits must fail
`ProcessingPipeline.revokedMeetingIDs`: Revocation survives cancellation-unaware engine work. Any continuation
that resumes after deletion must fail its commit checks and callbacks.

#### Optional lifecycle seam for queue tests; nil in production
`ProcessingPipeline.transcriptionStarted`: Optional lifecycle seam for focused queue tests; production leaves it nil.

#### Fires before evidence is replaced; throwing keeps source artifacts unchanged
`ProcessingPipeline.onArtifactsWillChange`: Fired at the commit boundary before transcript or summary evidence is
replaced. Throwing keeps the source artifacts unchanged.

#### Fires after transcript/summary files land, triggering search re-index
`ProcessingPipeline.onArtifactsWritten`: Fired after transcript/summary files land on disk (search re-index).

#### Fires only for jobs that saved a complete summary
`ProcessingPipeline.onSummaryCompleted`: Fired when a job that saved a complete summary finishes. Unlike
`onArtifactsWritten`, failed, partial, and transcript-only jobs never
fire it.

#### Work describes requested steps and how enqueues merge per meeting
`ProcessingPipeline.Work`: One job's requested work, and how a fresh enqueue combines with work
already queued or parked for the same meeting.

#### Transcription ORs on merge; user-initiated summary intent overrides pending
`ProcessingPipeline.merged(pending:incoming:origin:)`: Transcription merges by OR — it is the prerequisite for everything
downstream, so a pending one must never be dropped. Summarization does
not: it is the discretionary half, and OR-ing it let a queued job
silently upgrade an explicit "Transcribe" click into "Transcribe &
Summarize". A user-initiated enqueue states the summary intent
outright and the older job defers to it; automatic work still merges,
so a parked summary survives an auto re-enqueue. Pure, so the
escalation rule is testable without a live queue.

#### Explicit waiting summary stays explicit; automatic follows setting at resume
`ProcessingPipeline.mergedSummaryFollowsSetting`: Whether merged summary work should be cancelled when auto-summarize is
off at crash-resume time. An explicit summary already waiting remains
explicit; otherwise automatic work follows the current setting.

#### Durable manual request takes precedence over automatic retry
`ProcessingPipeline.deferUntilNextLaunch`: A manual processing request made after a finalization failure is
already durable and takes precedence over the automatic retry.

#### Fresh enqueue supersedes parked job by merging requested work
`ProcessingPipeline.enqueue`: A fresh enqueue supersedes a parked waiting-for-models job: merge its
requested work so the new attempt (and its origin) covers both.

#### Re-check parked jobs on download finish; nothing downloads here
`ProcessingPipeline.retryJobsWaitingForModels`: Re-check every job parked on missing models — call when a model
download finishes or the selection changes. Jobs whose models are still
missing simply park again; nothing downloads from this path.

#### Drop pipeline state for deleted meetings so jobs cannot resurrect
`ProcessingPipeline.forget(meetingIDs:)`: Drop all pipeline state for deleted meetings so a parked or queued job
cannot resurrect processing for a folder that no longer exists.

#### Merge sources withdrawn from processing; only merge undo restores them
`ProcessingPipeline.restoreForgottenMeetings`: Merge sources remain on disk but are withdrawn from processing. Undoing
the merge explicitly restores them; permanent deletion never does.

#### Crash recovery caps auto-resume attempts to avoid crash loops
`ProcessingPipeline.resumePending`: Crash recovery, called once at launch: re-enqueue every persisted job
that never reached completion. Jobs whose durable transcription phase
completed skip straight to summarization; jobs that burned through
`PipelineJobStore.maxAutoResumeAttempts` starts stay parked until the
user retries explicitly — a meeting that reliably kills the app must
not crash-loop every launch.

#### Queued, parked and running meetings are excluded from repairs and health checks
`ProcessingPipeline.queuedMeetingIDs`: Meetings already queued, parked, or running, so repairs and health
checks never double-count them.

#### Repair missing transcripts once; merged gap marked before queueing
`ProcessingPipeline.enqueueMissingTranscriptions`: Queues finished recordings with a missing or incomplete transcript
that have no queued, parked, or running job (see
`MissingTranscription`). A merged gap is marked before queueing so it
is repaired at most once. Returns the queued meeting IDs.

#### Automatic work parks before markStarted instead of downloading models
`ProcessingPipeline.process`: Automatic work never ambush-downloads a model: park the job instead
(before markStarted, so waiting burns no auto-resume attempts and
the durable row is re-checked on the next launch). A user-initiated
job passes through and downloads on demand.

#### Check Think model before markStarted so waiting never burns attempt budget
`ProcessingPipeline.process`: A transcript may already exist because an earlier attempt
completed transcription before parking its summary. Check Think
before markStarted in that case: merely waiting for a model must
never consume the crash-loop attempt budget.

#### Fresh enqueue clears stale checkpoints; only crash resume trusts them
`ProcessingPipeline.process`: A fresh enqueue means "transcribe with today's settings" —
stale checkpoints from an earlier failed attempt may have
been produced by a different model. Only a crash resume
trusts them.

#### Engines prepare lazily inside transcribe
`ProcessingPipeline.process`: engines prepare lazily inside transcribe

#### No speech yields an empty finished transcript, not a failure
`ProcessingPipeline.process`: Nothing was said: an empty transcript is the finished
result. Failing instead kept silent recordings in the
failed list and re-ran the speech model on every launch.

#### Lexical similarity marks uncertainty; removing duplicates needs waveform evidence
`ProcessingPipeline.process`: Lexical similarity only marks uncertainty. Removing a full
duplicate additionally requires matching waveform evidence.

#### Remember mic and call voices; never the sample meeting's synthetic voices
`ProcessingPipeline.process`: Microphone and call voices are both remembered; the
sample meeting's synthetic voices never are.

#### Finalized AAC makes CAF redundant; recovery CAF stays if AAC is broken
`ProcessingPipeline.process`: A finalized AAC track makes its CAF duplicate redundant. A
crash-recovery CAF remains when the AAC container is broken,
preserving playable audio after the transcript is written.

#### Missing Think model parks only the summary, keeping the transcript
`ProcessingPipeline.process`: Missing Think model on automatic work: keep the transcript
that just landed and park only the summary. The durable row
stays pending, so the summary still happens once the model
is downloaded (or the user asks explicitly).

#### Speaker identity recovery is optional; locked-Mac sidecar must not block summary
`ProcessingPipeline.process`: Speaker identity is optional enrichment. The sealed
sidecar uses complete-file protection and can be
unreadable while the Mac is locked; that must not
block summary recovery from an already saved
transcript or burn an automatic retry.

#### Persist normalized attribution provenance even on summary-only retries
`ProcessingPipeline.process`: Persist normalized provenance even on summary-only retries.

#### Sanitize repeats of the transcription vocabulary so they never become notes evidence
`ProcessingPipeline.process`: The vocabulary this meeting was transcribed with, so rows
that only repeat it never become notes evidence.

#### Explicit user edits stay authoritative for outcome cards and sections
`ProcessingPipeline.process`: Explicit user edits remain the authority for both cards
and the action/decision sections rendered beside them.

#### Withdrawn transcription server consent restarts the meeting on current settings
`ProcessingPipeline.process`: The transcription server was revoked, or an on-device model
chosen, while this meeting was uploading. Start over with the
settings as they are now: an on-device model transcribes it,
and otherwise the meeting waits. Only a change since this
attempt began restarts, so a server that was never approved
still fails with its message.

#### Failed job row persists for relaunch re-enqueue, with message
`ProcessingPipeline.process`: The persisted job row stays — the next launch re-enqueues it
(until the attempt cap) so a crash or transient failure never
silently drops a meeting. The message is persisted so a job
that ends up parked still explains itself after a relaunch.

#### Failed write may leave partial artifact; drop cached derived memory
`ProcessingPipeline.process`: A failed write may have persisted only part of an artifact. Drop
cached derived memory even when the complete job did not finish.

#### Return nil when echo filter cancels little; propagate cancellation before ASR
`ProcessingPipeline.echoCancelledMicrophone`: The microphone track with the remote side subtracted, or nil to
transcribe the recording as it is.

Returns nil rather than a marginal copy when the filter found little to
cancel. The worker runs outside this type's main-actor isolation, while
cancellation is propagated so a cancelled job never starts ASR anyway.

#### Calendar, agenda and screen titles are secondary, source-labeled notes context
`ProcessingPipeline.meetingContextBlock`: Calendar title and invited names, the optional agenda, and on-screen
document titles as secondary, source-labeled context for notes.

#### Crash resume reuses saved vocabulary so checkpoints stay valid
`ProcessingPipeline.transcriptionPrompt`: The user's manual vocabulary plus names LokalBot already knows, for
speech models that read a prompt. A crash resume reuses the terms
saved with the meeting so its per-track checkpoints stay valid.

#### Sample meeting transcribes identically in every library; no user names
`ProcessingPipeline.transcriptionPrompt`: The sample transcribes the same way in every library, so names from
the user's own meetings never steer it.

#### Reject missing or unreadable recordings before any model download
`ProcessingPipeline.transcribeTracks`: Reject missing or unreadable recordings before any model download.

#### Per-track checkpoints survive crash and other track failing
`ProcessingPipeline.transcribeTracks`: Per-track checkpoint: a finished track's transcript survives a
crash — and the *other* track failing — so a retry never redoes
an hour of completed transcription.

#### Continue after one track fails; its checkpoint limits retry to that track
`ProcessingPipeline.transcribeTracks`: Keep going: the other track may still succeed, and its
checkpoint means only this track is redone on retry.

#### Withdrawn-server error wins over earlier track error to trigger restart
`ProcessingPipeline.trackFailure`: The failure a job reports when more than one track failed: the first,
unless a later one says the transcription server was withdrawn. That
one decides what happens next (the meeting starts over on the settings
as they are now), and an earlier server error on the other track must
not turn it into a failed meeting.

#### track-language-v1 checkpoint tag: silent regions skipped, language kept, Latin script
`ProcessingPipeline.checkpointInput`: Silent regions skipped, the track's language kept for regions, Latin script.

#### aligned-words v3: CoreML aligner, 1.7B windows merged to 30 s
`ProcessingPipeline.checkpointInput`: v3: the CoreML aligner, with 1.7B windows merged to 30 s instead of 60 s.

#### Track checkpoint deleted when merged transcript lands or on fresh enqueue
`ProcessingPipeline.checkpointURL`: Where a track's finished-but-not-yet-merged transcript is checkpointed.
Deleted once the merged transcript.json lands (or on a fresh enqueue).

#### Skip tracks with under 0.5 s speech; VAD errors still transcribe
`ProcessingPipeline.transcribeTrack`: Skip a track with no detected speech (e.g. your mic while muted the
whole call) — feeding silence to the ASR model can hallucinate words.
Conservative: only skip on a confident "nothing here"; VAD errors
return nil and we transcribe anyway, never dropping real audio.

#### Shared with transcription replay test to measure the same path
`ProcessingPipeline.transcribedTrack`: One track's attributed transcript after cleanup: what processing saves
for the track, before the tracks are merged. Shared with the opt-in
transcription replay test so it measures exactly this path.

#### Speech ranges reuse the cached detection that gated the track
`ProcessingPipeline.speechRanges`: Where the track has speech, from the same detection that gated it
(usually still cached), or nil when detection is unavailable.

#### Track cleanup: Whisper stock phrases, repetition, prompt echoes, then script
`ProcessingPipeline.cleanedTrack`: Cleanup of one track's attributed transcript: Whisper's stock phrases,
pathological repetition and prompt echoes, then script.

#### Retained diarizer instance reuses prepared models across prewarm and jobs
`ProcessingPipeline.prepareDiarizationModels`: Shared by recording-time prewarm and the post-meeting stage. The
`NeuralDiarizationEngine` instance is retained by this pipeline, so the
downloaded/prepared models are reused instead of rebuilt per job.

#### Aligner download failure is non-fatal; falls back to speaker regions
`ProcessingPipeline.prepareDiarizationModels`: Fetch the word aligner with the speaker models. A failure is not
fatal: attribution falls back to speaker regions for this job. A
server that times words itself fetches it only if a clip comes
back without word times.

#### Background voice samples wait for idle and never download the voice model
`ProcessingPipeline.savedCallVoiceSamples`: Call-track voice samples for an already transcribed meeting, labeled by
its saved transcript. Waits while LokalBot records or processes, and
never downloads the voice model for this background work.

#### Unavailable voice model is not 'no voices'; meeting revisited later
`ProcessingPipeline.savedCallVoiceSamples`: Unavailable is not "no voices": the meeting is revisited later.

#### Context limit read after engine checked server approval; only model id sent
`ProcessingPipeline.summarize`: After the engine checked the server's approval; only the model id is sent.

#### Resolve summary language from raw spoken text, not rendered Markdown
`ProcessingPipeline.summarize`: Resolve `.matchTranscript` against raw spoken text now so both the
chunk extractions and the final synthesis share the same language
directive. Do not use rendered Markdown here: timestamps and speaker
labels can skew NaturalLanguage on short transcripts.

#### Model writes only overview; code renders full activity log as evidence
`ProcessingPipeline.generateDayDigest`: Day digest (M4/M6) — shared by the Timeline UI, scheduler, and
`--digest`. The model writes only the task-first overview. LokalBot
renders the complete chronological activity/meeting log and time table
directly as optional evidence, so filtering summary noise never loses
the underlying workday record.

#### Code owns coverage and persistence; model filters and groups by task
`ProcessingPipeline.generateDayOverview`: Code owns evidence coverage and persistence. The model rejects
metadata-only segments, extracts substantive work, and groups it by task.

### `LokalBot/Views/Meetings/FollowUpDraftSheet.swift`

#### Follow-up is only reviewed, copied or saved; LokalBot never sends it
`FollowUpDraftSheet`: Review, rewrite with the on-device Think model, copy, or save a
meeting's follow-up. LokalBot never sends it.

### `LokalBot/Views/Meetings/LiveMeetingDetailView.swift`

#### Live preview is undiarized, notes.md folds into summary, ASR preview is explicit opt-in
`LiveMeetingDetailView`: The detail pane for the meeting being recorded right now, shown when the
in-progress row is selected (and as the Meetings empty state while
recording). Live Radar fills the main area; beside it, the rolling
transcript preview (undiarized — the full pipeline transcript replaces it
after the meeting) sits above a quick-notes pad, whose notes are saved to
`notes.md` in the meeting folder and folded into the summary.

Starting preview is an explicit ASR opt-in. Opening a live meeting alone
does not load a model or start speech inference. With fast live text on,
the preview streams to Muse Voice Transcribe and shows each turn as it is
spoken.

#### Starting preview would stream to Muse instead of running locally
`LiveMeetingDetailView.usesMuse`: Starting the preview now would stream to Muse rather than run locally.

### `LokalBot/Views/Meetings/MeetingDetailHeader.swift`

#### Warning marks a capture limitation to notice, not neutral metadata
`MeetingDetailMetadataItem.warning`: A capture limitation people should notice, not neutral metadata.

#### Imported files carry no mic-only capture limitation
`MeetingDetailMetadataItem.items`: An imported file's audio came from neither this Mac's microphone
nor its system audio, so it carries no capture limitation.

### `LokalBot/Views/Meetings/MeetingListView.swift`

#### Live row routes to LiveMeetingDetailView; deletion confirmed by host window via pendingDelete
`MeetingListView`: The meeting library list — live recording first, then finished meetings
grouped by day. Capture's Library scope (spec §2.2: unchanged behavior —
multi-select, delete). The live row routes to `LiveMeetingDetailView`
via the shared selection. Deletion is confirmed by the host window's
dialog via `pendingDelete`.

#### Header holds search and Record; Import stays in File menu, drag-drop, empty library
`MeetingListView.body`: The header is the search field and Record. Importing stays in
the File menu, on drag and drop, and in the empty library.

#### Row shared by Meetings list and Today so the two cannot drift
`MeetingRowView`: One meeting row — status dot, live waveform, metadata line, and the
processing/failed pipeline state. Shared by the Meetings list and the
Today home so the two surfaces can never drift.

#### Use list selection, not backgroundProminence, which never saw .increased on teal
`MeetingRowView.isSelected`: Comes from the list's selection, not `backgroundProminence`: the row
never saw `.increased` on the teal highlight, which left the
light-mode supporting grey on teal.

#### Sample meetings show 'Sample' where a meeting would name its app
`MeetingRowView.content`: When, how long, then where. The sample says what it is
where a meeting names its app.

#### Selected rows use primary foreground; white on teal is only 4.7:1, so no dimming
`MeetingRowView.content`: Selected rows take the title's own foreground, which the
list turns white on teal and keeps dark on the inactive
highlight. White is only 4.7:1 on teal, so no dimming.

#### Waiting-for-models is parked, no spinner; action starts missing model downloads
`MeetingRowView.status`: Parked, not in progress: no spinner. The action is explicit
about what it does — it starts the missing model downloads.

#### Expanded units are presentation only; exports keep compact duration format
`Meeting.displayDuration`: Expanded units are a visual presentation choice; exported summaries retain
their existing compact duration format.

### `LokalBot/Views/Meetings/MeetingMergeSheet.swift`

#### Merge keeps sources intact and speaker labels scoped until user confirms identity changes
`MeetingMergeSheet`: Reviewable merge confirmation. The copy makes the operation's data
contract explicit: sources remain intact and speaker labels stay scoped to
their original recording until the user confirms any identity changes.

### `LokalBot/Views/Meetings/MeetingNotesEditor.swift`

#### Placeholder padding matches where the editor puts its first character
`MeetingNotesEditor.body`: Where the editor puts its first character.

### `LokalBot/Views/Meetings/MeetingOutcomeRows.swift`

#### Negative trailing padding aligns the time itself, not its hit inset, to the edge
`MeetingDecisionRow.body`: The time, not the room around it for the pointer, meets
the row's trailing edge.

#### Others' actions show owner menu; owner turns amber when missing or unnamed voice
`MeetingActionRow`: One action on the meeting page. Someone else's action carries its owner as
a small menu; the owner turns amber while it is missing or still an unnamed
voice.

#### Owner shown only on others' actions; own actions are grouped
`MeetingActionRow.showsOwner`: Shown on other people's actions. Your own say so by their group.

#### Overdue red, due within week amber, later quiet, same rule as Actions list
`MeetingActionRow.dueColor`: Overdue reads red, due within the week amber, anything later quiet,
the same rule the Actions list uses.

#### Chip drawn in SwiftUI with native pull-down overlaid, since SwiftUI Menu is not accessible
`MeetingActionOwnerMenu`: An action's owner as a small menu on its row: you, this meeting's
speakers, people invited to it, or no owner. The chip is drawn here and the
app's native pull-down lies over it undrawn, because a SwiftUI `Menu` gives
assistive tools no way to open it.

#### Pull-down over chip is what assistive tools read and press
`MeetingActionOwnerMenu.body`: The pull-down over the chip is what assistive tools read and press.

#### Search and VoiceOver read the same words the chip shows
`MeetingActionOwnerMenu.missingOwnerText`: Search and VoiceOver read the same words the chip shows.

### `LokalBot/Views/Meetings/MeetingPlayerBar.swift`

#### Hide transcript link on the transcript tab, which already shows the line
`MeetingPlayerBar.showsTranscriptLink`: The transcript tab already shows the line, so the link is left out there.

### `LokalBot/Views/Meetings/MeetingScreenContextViews.swift`

#### Section title shown verbatim, not localized, like the section's other wording
`MeetingScreenMaterialsSection.body`: Shown as written, like the rest of this section's wording.

#### Detail omits source when the title already names it
`MeetingScreenMaterialsSection.detail`: "Gmail · 4 min on screen"; the source is left out when the title
already names it (an app with one window).

### `LokalBot/Views/Meetings/MeetingSearchTextField.swift`

#### AppKit owns accessibility role and first responder so Command-F bar is exposed at once
`MeetingSearchTextField`: Native editable field for page-level meeting find. AppKit owns the
accessibility role and first-responder transition so a bar inserted by a
Command-F request is immediately exposed to VoiceOver and XCUITest.

### `LokalBot/Views/Meetings/MeetingSpeakerNamingSheet.swift`

#### Sheet height capped at 420 pt because scroll views have no intrinsic height
`MeetingSpeakerNamingSheet.body`: A sheet sizes to its content, and a scroll view has no height of
its own: show every voice until the list would outgrow the window.

#### Recognized voice that is also a guest reuses that guest's chip
`MeetingSpeakerNamingSheet.voiceRow`: A recognized voice that is also a guest is that guest's
chip, already picked; otherwise it gets a chip of its own.

#### Guest already naming another voice is dimmed but still selectable
`MeetingSpeakerNamingSheet.isUsed`: Dimmed, and still a choice: the guest already names another voice.

#### Name the sheet's host view, which assistive tools see as unnamed group
`SheetContainerName`: Names the view a sheet is hosted in. Assistive tools see that host as a
group around the sheet's content, and it has no name of its own.

#### Only unnamed hosts are labelled; windows with their own label keep it
`SheetContainerName.Probe.apply`: Only an unnamed host is named, so a window that says what it is
keeps its own words.

#### Rounded rectangle, not capsule, whose inset border drew stray marks at ends
`MeetingNameChipStyle.makeBody`: A rounded rectangle, not a capsule: a capsule's inset border drew
stray marks at its ends at this size.

### `LokalBot/Views/Meetings/MeetingSpeakerPresentation.swift`

#### Friendly labels only; stored keys keep canonical names; 'Local speaker' unconfirmed as user
`SpeakerDisplayName`: Friendlier labels for LokalBot's placeholder speaker names. Stored keys,
aliases, owners, prompts, and exports keep the canonical names ("Me",
"Them 2"); "Local speaker" stays because that voice is not yet confirmed
as the user.

#### Free-form alias or owner 'Me' is not evidence of self identity
`SpeakerDisplayName.label`: A free-form alias/owner called "Me" is not evidence of self identity.

#### Merged-meeting names are display-only; source keys, identities, aliases stay untouched
`MeetingSpeakerPresentation`: Display-only names for a combined meeting. Source-scoped keys, confirmed
identities, and persisted aliases remain untouched for edits and evidence.

#### Color index stable across alias edits and action-prioritized review ordering
`MeetingSpeakerPresentation.colorIndex`: Stable across alias edits and the action-prioritized review ordering.

#### Replace longest names first to protect nested merges and source 1 versus 10
`MeetingSpeakerPresentation.text`: Longest first protects nested merges and source 1 versus source 10.

### `LokalBot/Views/Meetings/MeetingTranscriptList.swift`

#### Merged meeting transcript has no single model to name
`MeetingTranscriptEngineLine`: Which model wrote the transcript, in the Transcript panel's footer. A
merged meeting's transcript has no single model to name.

#### 52 pt time column fits '1:02:09' at trailing edge
`MeetingTranscriptList.timeColumnWidth`: Wide enough for "1:02:09" at the trailing edge of the time column.

### `LokalBot/Views/Meetings/MeetingWorkspaceView.swift`

#### Bind input event to load request so async task keeps correct animation policy
`MeetingLibraryDetailView.body`: Bind input intent to the load request so the async task cannot
capture the previous selection's animation policy.

#### Recording in progress keeps its own live surface and title
`MeetingLibraryDetailView.showsLiveMeeting`: A recording in progress keeps its own live surface and title.

#### All saved-library states share one toolbar; title-bearing toolbars were taller and pushed list down
`MeetingLibraryDetailView.selectionContent`: Every state of the saved library shares one toolbar: a meeting's
page carries its own title, and a toolbar that showed a title
only for "2 meetings selected", loading or no selection was
taller there and pushed the list and sidebar down.

#### Start with narrow controls until measured so toolbar cannot enlarge compact window
`MeetingWorkspaceDetail.compactToolbar`: Begin with the narrow controls until the detail column is measured so
the toolbar cannot enlarge a compact window during its first layout.

#### Scroll bar width also given to pinned title and player to share one edge
`MeetingWorkspaceDetail.pinnedTrailingInset`: What an always-visible scroll bar takes from the scrolling panels,
given to the pinned title and player too so both share one edge.

#### Pre-rename notes stay readable until a speaker-name refresh replaces them
`MeetingWorkspaceDetail.shownProjection`: What the summary shows. After speaker names change, the notes written
before the change stay readable until a refresh replaces them.

#### Command-F bar is pinned across tabs; transcript Find lives in panel header
`MeetingWorkspaceDetail.body`: Command-F searches every tab, so its bar stays put.
Find in transcript is in the Transcript panel's header.

#### UI-test capture route set before async load so readiness does not race
`MeetingWorkspaceDetail.body`: Establish the requested capture route before asynchronous document
and speaker recovery; readiness must not race those operations.

#### Review tab's work now happens in the naming sheet
`MeetingWorkspaceDetail.body`: The Review tab's work now happens in the naming sheet.

#### Refresh offered only after speaker names changed; old summary stays until done
`MeetingWorkspaceDetail.summaryRefreshBanner`: Offered only after speaker names changed. The summary written before
the change stays on the page until the refresh finishes.

#### Think model reports no cost; cost shown only for Meta-model radar runs
`MeetingWorkspaceDetail.summaryTabContent`: The Think model reports no cost; a cost is shown where a
meeting has one from when the radar ran on Meta's models.

#### Actions list link shown only for real meetings, not samples
`MeetingWorkspaceDetail.actionsSection`: The Actions list holds your open work from real meetings.

#### First document prepared before pane visible; only pipeline updates reload it
`MeetingWorkspaceDetail.load`: The first document was prepared before this pane became visible.
Only pipeline updates need to read it again.

#### Pipeline artifact refresh must not reset or re-prepare active audio
`MeetingWorkspaceDetail.load`: A pipeline artifact refresh must not reset or re-prepare active audio.

#### Evidence from another screen opens transcript at the moment, paused
`MeetingWorkspaceDetail.revealEvidence`: Another screen opened this meeting at a moment: show that line in the
transcript.

#### Show in transcript jumps to the line without interrupting playback
`MeetingWorkspaceDetail.showInTranscript`: The player's "Show in transcript": go to the line being said, without
interrupting playback.

#### Newly remembered voice can name speakers in other recent meetings
`MeetingWorkspaceDetail.saveSpeakerNames`: A newly remembered voice can name speakers in other recent meetings.

#### Newly remembered voice can name speakers in other recent meetings
`MeetingWorkspaceDetail.renameSpeaker`: A newly remembered voice can name speakers in other recent meetings.

#### Command-F is a pinned bar; transcript Find is a header field with count before it
`MeetingPageSearchBar`: The meeting's one find field. Command-F's search of the whole meeting is
a bar pinned under the player; Find in transcript is a field at the
trailing edge of the Transcript panel's header, with its count before it.

#### Count takes needed width and is cut short before the field
`MeetingPageSearchBar.body`: The count takes what it needs, down to the field's
narrowest, and is cut short before the field is.

#### Widths kept out of view state so window resize redraws nothing
`MeetingPaneWidths`: The pane's width and the scrolling column's, as last laid out. Kept out
of the view's state so a window resize redraws nothing on its own.

#### Values computed once per transcript, not on every redraw
`MeetingTranscriptDerived`: Values worked out once per transcript, not on every redraw of the page.

#### Placeholder speaker labels are not names; start field empty
`WorkspaceSpeakerRenameSheet.init`: Placeholder labels ("Them", "Local speaker") are not names; start
empty so typing a name doesn't begin by deleting one.

#### onSubmit steals Return from default button, so Return saves from the field
`WorkspaceSpeakerRenameSheet.body`: A field with a submit action keeps Return from the
default button, so Return saves from here as well.

#### Suggestion list min height prevents sheet shrinking on each filtering keystroke
`WorkspaceSpeakerRenameSheet.body`: Keep the sheet from shrinking on every keystroke while filtering.

#### Return fills top match first, then saves
`WorkspaceSpeakerRenameSheet.body`: Return fills in the top match first, then saves.

#### Only typing sets the search; choice-filled names do not filter
`WorkspaceSpeakerRenameSheet.nameBinding`: Typing records the name as the search; a name filled in by a choice,
here or in the voice review, doesn't filter.

#### Chosen guest stays listed while name is edited because save keeps it
`WorkspaceSpeakerRenameSheet.visibleSuggestions`: The chosen guest stays listed while its name is edited, since
saving keeps that guest.

#### Return fills top unchosen match; with none it saves the typed name
`WorkspaceSpeakerRenameSheet.returnSuggestion`: The top match not already chosen, which Return fills in. With none,
Return saves the name as typed.

#### Plain button hit-tests only drawn content, so whole card needs contentShape
`WorkspaceSpeakerSuggestionCard`: A plain button hit-tests only its drawn content; the whole card
chooses the suggestion.

#### Returns error message only; nil after success or cancelled save panel
`MeetingMarkdownActions.export`: Returns an error message for inline presentation, or nil after either
a successful export or a user-cancelled save panel.

### `LokalBot/Views/Meetings/RecordingImport.swift`

#### Choosing the folder is the consent; nothing asks again; only new meetings added
`ExternalImportPanel`: The open panel behind Recording → Import Meetings From. The person picks
the app's export or data folder; LokalBot adds the meetings it doesn't
have yet. Choosing is the consent, so nothing asks again.

### `LokalBot/Views/Meetings/SampleMeetingViews.swift`

#### Nothing downloads until chosen; sample added once models are ready
`SampleMeetingSetupSheet`: "Try a sample meeting" before its models are on this Mac: what downloads,
as its own step, then the steps that follow. Nothing downloads until the
person chooses to; the sample is added as soon as the models are ready.

### `LokalBot/Views/Meetings/SpeakerIdentityViews.swift`

#### Clear all needs confirmation: profiles cannot be restored and sit next to Done
`SpeakerProfilesView.body`: Profiles are built from speakers confirmed across many
meetings and cannot be brought back, so one click next to
Done must not remove them all.

#### Evidence stays out of ordinary transcript model, search and export paths
`SpeakerIdentityReview`: Lives inside the existing native rename sheet; evidence never joins the
ordinary transcript model or its search/export paths.

### `LokalBot/Views/Meetings/SummaryPresentation.swift`

#### Lift provenance line into metadata row; raw summary.md keeps full header
`SummaryPresentation`: The pipeline writes a bold inline provenance line under the summary title
("**Duration:** 32m · **App:** Zoom · … · **Model:** …"). Rendered as body
markdown it reads like debug output. These helpers lift that line out so
views can show it as a quiet metadata row while the raw `summary.md`
(exports, CLI, MCP) keeps the full header.

#### Require two Label:value pairs so ordinary bold opening text is kept
`SummaryPresentation.split`: Extracts the provenance line: the first non-empty, non-heading line
among the leading lines, consisting of at least two `**Label:** value`
pairs joined by "·". Requiring two pairs keeps a body that opens with
ordinary bold text ("**Next steps:** …") intact.

#### Older merge drafts' implementation-detail lines hidden; kept in saved Markdown
`SummaryPresentation.meetingBody`: Older merge drafts start with implementation details instead of
meeting content. They remain available in the saved Markdown.

#### Recap preview leaves stored Markdown unchanged; older summaries share paragraph with heading
`SummaryPresentation.recap`: Extract a reading preview without changing the stored/exported Markdown.
Headings may share a paragraph with their content in older summaries.

#### Citations and attribution stay in Full Summary and transcript, not recap
`SummaryPresentation.recapText`: The recap is reading copy. Speaker attribution and playback citations
remain in Full Summary and the transcript, not in this compact preview.

### `LokalBot/Views/Meetings/TranscriptSpeakerButton.swift`

#### AppKit button avoids SwiftUI flattening plain button in nested ScrollView on macOS 15
`TranscriptSpeakerButton`: A compact native control for transcript speaker labels. AppKit owns the hit
testing and accessibility role while the attributed title preserves meeting
find highlighting. This avoids SwiftUI flattening a plain button inside the
nested meeting ScrollView on macOS 15.

#### Button no wider than name so clicks beside it don't open rename
`TranscriptSpeakerButton.sizeThatFits`: No wider than the name: the button used to fill the whole line, so
a click anywhere beside the name opened the rename sheet. A long
name still truncates inside the width it is offered.

### `LokalBot/Views/Meetings/UpcomingMeetingView.swift`

#### Preparation open by default, folds to a count while another meeting records
`TodayNextMeetingCard.preparationChoice`: The reader's own choice. Without one, preparation is open, and folds to
a count while another meeting is being recorded.

#### Solo linkless event may not be a call; Record hides while another recording runs
`TodayNextMeetingCard.actions`: A solo event without a link may not be a call at all; the toolbar's
Record is still there for it. Record leaves the card while something
else is being recorded: the live card holds the only Stop.

#### Model brief is on request because it may load the Think model
`TodayNextMeetingCard.briefControl`: The model's brief is on request: it may load the Think model.

#### Email conversation opens in Gmail as the account that holds it
`TodayPreparationRowView.body`: A conversation opens in Gmail, signed in as the account that holds it.

#### Saved recording's row shows app and length instead of status
`TodayMeetingStatusText.text`: A saved recording's row shows its app and length instead.

### `LokalBot/Views/Meetings/WaveformView.swift`

#### Drag previews locally; release seeks once so playback is preserved
`WaveformView`: A compact audio overview with pointer scrubbing and a native accessibility
slider. The drag previews locally; releasing seeks once, preserving playback.

#### Timeline stays left-to-right in RTL like playback controls, one coordinate space
`WaveformView.body`: Media timelines stay left to right in right-to-left interfaces, like
platform playback controls. It also keeps the Canvas, the timestamp
bubble and pointer positions in one coordinate space.

#### Playhead marker so position does not rely on color alone
`WaveformView.waveform`: A playhead makes position readable without relying on color alone.

### `LokalBotTests/Models/Meetings/MeetingDetailPresentationTests.swift`

#### Blank segments are never shown; the last spoken line stays
`MeetingDetailPresentationTests.testCaptionFollowsThePlayheadAndSkipsBlankLines`: The blank fifth segment is never shown, so the last spoken line stays.

#### Overlay scroll bars leave the column as wide as the pane
`MeetingDetailPresentationTests.testPinnedHeaderTakesTheScrollBarsInset`: Overlay scroll bars: the scrolling column is as wide as the pane.

#### With always-shown scroll bars the column gives up the scroller's width
`MeetingDetailPresentationTests.testPinnedHeaderTakesTheScrollBarsInset`: Scroll bars always shown: the column gives up the scroller's width.

#### Unmeasured, rounding or in-flight layouts give zero inset
`MeetingDetailPresentationTests.testPinnedHeaderTakesTheScrollBarsInset`: Not yet measured, a rounding difference, or a layout in flight.

#### One find field at a time: pinned bar replaces the panel's field
`MeetingDetailPresentationTests.testFindIsInTheTranscriptPanelUntilCommandFSearchesTheWholeMeeting`: One field at a time: the pinned bar replaces the panel's field.

#### A zero text scale from an unset environment never collapses a width
`MeetingDetailPresentationTests.testTextBoundWidthsGrowWithTheTextSize`: A scale of zero from an unset environment never collapses a width.

#### Column is wider than its prose and than a row needs
`MeetingDetailPresentationTests.testTextBoundWidthsGrowWithTheTextSize`: The column is wider than the prose it holds and than a row needs.

#### Unnamed voice is saved under the transcript's own name for it
`MeetingDetailPresentationTests.testOwnerOptionsOfferYouThisMeetingsSpeakersInvitedPeopleAndNoOwner`: An unnamed voice is saved under the transcript's own name for it.

#### Regression: aliased speaker's menu item counted as chosen while action said Other speaker
`MeetingDetailPresentationTests.testAnOwnerLeftAsAPlaceholderIsNotTheNamedSpeakerUntilChosen`: Filmed by CI: after "Them" was named Ana Petrović, the action still
said "Other speaker", yet Ana's menu item counted as already chosen,
so choosing it did nothing.

### `LokalBotTests/Models/Meetings/MeetingIntegrityTests.swift`

#### Meet also shows the room under /meet/; same room (#372)
`MeetingIntegrityTests.testOnlyExactMeetRoomURLsIdentifyACallDocument`: \#372: Meet also shows the room under /meet/; it is the same room.

#### Reopened invite link shows the lobby in another window while still in call
`MeetingIntegrityTests.testJoinScreenEndsOnlyTheCallInItsOwnWindow`: A reopened invite link shows the same room's lobby in another window
while the user is still in the call.

#### Meet post-call page ends the call by its actions, whatever its heading says
`MeetingIntegrityTests.testBrowserRequiresCallControlsAndSustainedSameDocument`: Meet's post-call page ends the call by its actions, whatever its heading says.

#### Optional replay reads local recordings read-only with no inference; CI uses synthetic cases
`MeetingIntegrityTests.testLocalSavedTranscriptReplay`: Optional replay reads local recordings without modifying them or calling
an inference provider. CI uses only the synthetic regression cases.

#### Fixture mimics Parakeet erroring on audio under 0.3 s
`MeetingIntegrityTests.ShortAudioRejectingASR`: Behaves like Parakeet: audio shorter than 0.3 s is an error.

### `LokalBotTests/Models/Meetings/MeetingMenuAccessibilityTests.swift`

#### Views are hosted in an off-screen window for accessibility checks
`MeetingMenuAccessibilityTests`: What assistive tools and clicks meet on the meeting page's menus and
speaker names. Each view is hosted in a window that stays off screen.

#### Audit flagged owner chip lacking press action while a SwiftUI Menu
`MeetingMenuAccessibilityTests.testOwnerChipIsTheNativePullDownLaidUndrawnOverItsLabel`: The accessibility audit flagged the owner chip as having no press
action while it was a SwiftUI `Menu`.

#### Owner chip otherwise matches the menu the ellipsis buttons use
`MeetingMenuAccessibilityTests.testOwnerChipIsTheNativePullDownLaidUndrawnOverItsLabel`: In every other respect it is the menu the "…" buttons use, which
assistive tools can already open.

#### Speaker button ran 61 pt past text by taking the whole line
`MeetingMenuAccessibilityTests.testTranscriptSpeakerButtonIsNoWiderThanItsName`: Measured by CI: a turn's speaker button ran 61 pt past the text below
it, because it took the whole line and not just its name.

#### Audit flagged the sheet's hosting view as an unnamed group
`MeetingMenuAccessibilityTests.testNamingSheetNamesTheViewThatHostsIt`: The audit flagged the sheet's hosting view as a group with no name.

### `LokalBotTests/Models/Meetings/MeetingNotesReplayTests.swift`

#### Opt-in local latency/quality replay; manifest and files stay outside repo
`MeetingNotesReplayTests`: Opt-in, local-only latency/quality replay. Normal unit/CI runs skip it.
The manifest and all transcript/output files stay outside the repository.

#### Tokenizer returns nil without network; planning-only replay calls no generation
`MeetingNotesReplayTests.testLocalCloudPlanningAndTranscriptCleanup`: This engine's tokenizer returns nil without a network request. No
generation method is called by this planning-only replay.

#### Replay reconciles prior outcomes like notes-only regeneration, keeping unmatched manual edits
`MeetingNotesReplayTests.testLocalQwenReplay`: Optional prior outcomes/state live only in the copied replay input.
Exercise the same reconciliation as a notes-only regeneration, while
preserving unmatched manual edits for review rather than losing them.

### `LokalBotTests/Models/Meetings/MeetingOutcomesTests.swift`

#### Empty owner/due mean not stated and collapse to nil
`MeetingOutcomesTests.testParseToleratesReasoningFencesAndProse`: Empty owner/due (the schema's "not stated" convention) collapse to nil.

#### Same task extracted twice has one content-derived ID; re-summarizing must not stop
`MeetingOutcomesTests.testReprocessingKeepsEditedStateWhenTheSameActionIsExtractedTwice`: The same task extracted twice with a different basis is not merged
and has one content-derived ID. Summarizing again must not stop on it.

#### Empty cache is not archived evidence; on-disk outcomes still notify
`MeetingOutcomesTests.testArchivedActionsCanBeCorrectedWithoutReenteringCurrentIndex`: An empty cache is not archived evidence: current on-disk outcomes still notify.

#### Old meeting's outcomes fall outside the default 7-day scan
`MeetingOutcomesTests.testGetActionItemsAgainstPlantedLibrary`: A recent meeting with outcomes, and an old one whose outcomes should
fall outside the default 7-day scan.

### `LokalBotTests/Models/Meetings/MeetingScreenContextTests.swift`

#### Regression: Chrome captures without URL listed fragments and the call tab five times
`MeetingScreenContextTests.testBrowserCapturesWithoutURLsReadAsPagesAndHideTheCallTab`: Shaped like a real Google Meet call whose Chrome captures carried no
URL: the list showed URL fragments ("#inbox", a Gmail message id, the
Meet code) and the call's own tab, five times.

#### A stale meeting link from an earlier call must not matter
`MeetingScreenContextTests.testBrowserCapturesWithoutURLsReadAsPagesAndHideTheCallTab`: A stale link from an earlier call must not matter.

#### Fixture: every third window stays five minutes, the rest are glances
`MeetingScreenContextTests.testLongCallsKeepTheWindowsInFrontLongestInFirstAppearanceOrder`: Every third window stays in front for five minutes; the rest are glances.

#### Captures keep no query or fragment, so such URLs would open the wrong page
`MeetingScreenContextTests.testOnlyAddressesThatIdentifyThePageCanBeReopened`: Captures keep no query or fragment, so these would open the wrong page.

### `LokalBotTests/Models/Meetings/MeetingSpeakerIdentityTests.swift`

#### Codec-compressed chunks disagree but average is stable; all-pairs gate rejected real voices
`SpeakerVoiceMatcherTests.testCallVoiceMatchesByItsAverageWhenSingleChunksDisagree`: Codec-compressed call chunks disagree with each other, but their average
is stable; the old all-pairs gate rejected every real call voice.

### `LokalBotTests/Models/Meetings/MeetingTests.swift`

#### Fixture: 40 min wall-clock but only about 16 min of audio
`MeetingTests.testDurationLabelPrefersRecordedAudioLength`: Wall-clock span is 40 min, but only ~16 min of audio was captured.

### `LokalBotTests/Models/Meetings/SampleMeetingTests.swift`

#### Traditional Chinese gets the Mandarin recording, titled in Simplified Chinese
`SampleMeetingTests.testRecordingFollowsTheInterfaceLanguageThenEnglish`: Traditional Chinese gets the Mandarin recording too, titled in Simplified Chinese.

#### Asked for by id, the sample's own actions are still returned
`SampleMeetingTests.testDayEvidenceAndActionListsLeaveTheSampleOut`: Asked for by id, the sample's own actions are still there.

#### Overnight review compares earlier days; the sample used to be included
`SampleMeetingTests.testOvernightReviewLeavesTheSampleOutOfEarlierMeetingsAndActions`: The overnight review compares a day with the meetings and open actions
of the days before it. The sample used to be among them.

### `LokalBotTests/Services/Meetings/ExternalMeetingWriterTests.swift`

#### AVAudioFile header is finished only when it goes out of scope
`ExternalMeetingWriterTests.testVoiceMemosRecordingsGoOnTheMicrophoneTrack`: The file is closed, and its header finished, when it goes out of scope.

### `LokalBotTests/Services/Meetings/MeetingAudioAssetTests.swift`

#### Readers use ordinary file time; no consumer compensates with another offset
`MeetingAudioAssetTests.testLateSystemAttachmentPreservesMeetingTime`: Every reader continues to use ordinary file time. No consumer may
compensate with another offset or skip the newly attached live CAF.

#### Clock anchors use padded frame positions to stay on transcript timeline
`MeetingAudioAssetTests.testLateSystemAttachmentPreservesMeetingTime`: Clock anchors use the padded frame positions too, so visual speaker
evidence and echo-reference ranges stay on the transcript timeline.

#### Sleep passes on continuous clock while audio host clock pauses
`MeetingAudioAssetTests.testMeetingClockPreservesSleepTimeAndExcludesCallbackLatency`: 90 seconds of sleep pass on the continuous clock while the audio
host clock pauses. The resumed callback arrives 0.1s after its data.

#### System stays dominant, mic attenuated to tame bleed
`MeetingAudioAssetTests.testPlaybackSourcesGainStaging`: Both tracks: system kept dominant, mic attenuated to tame bleed.

#### System file unflagged for the meeting means mic only at full gain
`MeetingAudioAssetTests.testPlaybackSourcesGainStaging`: System present on disk but not flagged for this meeting: mic only, full gain.

#### Crash-safe CAF stays the source when the MP4 is unreadable
`MeetingAudioAssetTests.testUnreadablePrimaryFallsBackToCrashSafeCAFWithoutDeletingIt`: A process crash can leave an MP4 container on disk but unreadable. The
append-only CAF tee is then the only copy of the meeting and must remain
the source for playback and transcription until the user deletes it.

#### Mac must play and transcribe Windows/Linux 16 kHz WAV tracks
`MeetingAudioAssetTests.testWindowsAndLinuxWAVTracksAreReadWhenNoAACTrackExists`: The Windows and Linux app records, imports and merges into 16 kHz
16-bit `mic.wav` / `system.wav`. A library shared with a Mac must still
play and transcribe those meetings.

#### Player must load mic and system tracks of differing format
`MeetingAudioAssetTests.testPlayerLoadsMismatchedFormatTracks`: The mic and system files routinely differ in sample rate and channel
count; the player must load both and report the longer duration. The
previous composition-based player garbled mismatched tracks during
real-time playback — this guards the per-file engine that replaced it.

#### Fixture uses the capture paths' planner and silence writer, no devices
`MeetingAudioAssetTests.writeTimelineFixture`: Uses the same planner and bounded silence writer as both capture paths,
with synthetic host times and tones; no microphone or output is opened.

#### WAV fixture matches the port's WavWriter format
`MeetingAudioAssetTests.writeInt16WAVTone`: Matches the port's `WavWriter`: 16 kHz, mono, 16-bit little-endian PCM.

### `LokalBotTests/Services/Meetings/MeetingAudioRecoveryTests.swift`

#### Unbound recording may hold only an always-open stream (#179)
`MeetingAudioRecoveryTests.testOnlyAnAlwaysOpenStreamCanBeHeld`: \#179: an unbound recording may hold only an always-open stream. A
stream that is call evidence (Zoom's) goes through the verified path,
and a closed modulehost leaves nothing to hold.

### `LokalBotTests/Services/Meetings/MeetingImportServiceTests.swift`

#### Phone apps write ADTS AAC; file type follows .aac extension
`MeetingImportServiceTests.writeADTS`: An ADTS AAC stream, the way the phone apps write recordings: the file
type follows the `.aac` extension.

#### Noise costs the encoder far more bytes than silence
`MeetingImportServiceTests.writeADTS`: Noise costs the encoder far more bytes than silence does.

#### A killed recorder stops mid-frame
`MeetingImportServiceTests.testRecordingCutOffByACrashStillImports`: A killed recorder stops mid-frame.

#### Phone deletes its copy after import, so the whole recording must arrive
`MeetingImportServiceTests.testARecordingThatStartsLoudAndGoesQuietImportsWhole`: The phone deletes its copy after this, so all of it has to be here.

#### Modification time marks when a copied recording stopped; creation is copy time
`MeetingImportServiceTests.testImportedFileBecomesASystemTrackMeeting`: A copied recording: modification still marks when it stopped, while
creation is when it was copied.

#### Imported file arrives as diarized system track with no microphone track
`MeetingImportServiceTests.testImportedFileBecomesASystemTrackMeeting`: The pipeline transcribes whatever tracks the folder holds: the file
must arrive as the diarized system track with no microphone track.

#### Screen during an import's time span is unrelated, so no screen titles
`MeetingImportServiceTests.testImportedMeetingsTakeNoScreenTitles`: The screen during an imported file's time span shows what the user was
doing then, not that recording, so it must not reach the notes prompt.

### `LokalBotTests/Services/Meetings/MeetingMergeServiceTests.swift`

#### Loading between deletions simulates a restart checkpoint
`MeetingMergeServiceTests deletion order`: Loading between every operation simulates a restart checkpoint.

#### No partial transaction may tombstone parent while source restore fails
`MeetingMergeServiceTests.testFailedRecoveryKeepsJournalAndRetries`: No partial transaction may tombstone the parent while leaving the
failed source restore committed.

#### Older merge records can have the manifest without a source marker
`MeetingMergeServiceTests.testCLIProjection`: Older merge records can have the manifest without a source marker.

#### CLI must not persist repairs or mutate search state
`MeetingMergeServiceTests.testCLIProjection`: CLI must not persist repairs or mutate search state.

#### Screen context gated on import marker, so merges keep imported marker
`MeetingMergeServiceTests.testMergeKeepsImportedFileNames`: Screen context is gated on the import marker, so a merge that folds in
an imported recording, directly or through an earlier merge, keeps it.

### `LokalBotTests/Services/Meetings/MeetingNoteExportServiceTests.swift`

#### Only meetings looked at get a new note; skipped ones do not
`MeetingNoteExportServiceTests.testUnchangedMeetingsAreSkipped`: Without the note and its sidecar, a meeting that is looked at gets
a new note; one that is skipped does not.

### `LokalBotTests/Services/Meetings/PipelineJobStoreTests.swift`

#### Attempt is burned at start; cap stops crash-looping meetings on launch
`PipelineJobStoreTests.testJobStopsResumingAfterAttemptCap`: A crash mid-processing leaves the row with its attempt already burned,
and once the cap is reached the job stops auto-resuming — a meeting
that reliably kills the app must not crash-loop every launch.

#### Explicit user retry resets the crash-loop counter
`PipelineJobStoreTests.testExplicitReenqueueResetsAttempts`: An explicit user retry is a fresh decision — it resets the crash-loop
counter instead of staying parked forever.

#### Queue survives app relaunch
`PipelineJobStoreTests.testJobsSurviveReopen`: The queue survives the connection — a new store over the same file
(i.e. the next app launch) sees the unfinished job.

### `LokalBotTests/Services/Meetings/ProcessingPipelineAutomationGateTests.swift`

#### Automatic jobs never download models; they park without burning attempts
`ProcessingPipelineAutomationGateTests`: The automation gate: automatic jobs (auto-transcribe after a recording,
launch resume) must never trigger a model download — they park as
`.waitingForModels` without burning auto-resume attempts. User-initiated
jobs pass straight through.

#### Revoked server mid-upload means meeting waits for a model, not failed
`ProcessingPipelineAutomationGateTests.testMeetingWaitsWhenItsTranscriptionServerIsRevokedMidRun`: Revoking the transcription server while a meeting is uploading stops
the uploads; the meeting must then wait for a model, not sit failed.

#### A never-approved server fails with its message instead of retrying
`ProcessingPipelineAutomationGateTests.testMeetingWaitsWhenItsTranscriptionServerIsRevokedMidRun`: A server that was never approved still fails with its message
instead of going round again.

#### process() parks job before drain task clears active-work state
`ProcessingPipelineAutomationGateTests.testAutomaticJobParksWithoutBurningAttempts`: process() parks the job before the drain task resumes and clears
its active-work state. Await that cleanup before asserting it.

#### Passing the gate shows as the no-audio failure in hermetic meeting
`ProcessingPipelineAutomationGateTests.testParkedJobProcessesOnceModelsArrive`: "Download finished": the job passes the gate and actually runs —
this hermetic meeting has no audio, so passing the gate shows up
as the pipeline's no-audio failure rather than a parked stage.

#### Default origin is user-initiated: Retry, Process menu, --process
`ProcessingPipelineAutomationGateTests.testUserInitiatedJobBypassesTheGate`: Default origin is user-initiated (Retry, Process menu, --process):
the job runs — and fails on missing audio — instead of parking.

#### Download & process re-enqueue merges away the parked copy
`ProcessingPipelineAutomationGateTests.testExplicitRetryAbsorbsTheParkedJob`: "Download & process" re-enqueues user-initiated: the parked copy is
merged away and the job runs.

#### User Transcribe stays transcribe-only despite a queued summary
`ProcessingPipeline.merged`: Pressing "Transcribe" must stay transcribe-only even when a job for the
same meeting is already queued or parked asking for a summary.

#### Automatic re-enqueues merge and must not drop a parked summary
`ProcessingPipeline.merged`: The opposite direction still merges: automatic re-enqueues (launch
resume, a model finishing its download) must not drop a parked summary.

#### Transcription merges by OR regardless of origin; it is the prerequisite
`ProcessingPipeline.merged`: Transcription is the prerequisite for everything downstream, so it
merges by OR regardless of who asked: "Re-summarize" on a meeting whose
transcript is still queued must not cancel that transcription.

#### Retry must not destroy a completed transcript just to avoid a no-op
`ProcessingPipeline.retryWork`: With no durable intent, Retry must not destroy a completed transcript
merely to avoid becoming a no-op.

#### With a transcript on disk only the summary needs Think, so only it waits
`ProcessingPipelineAutomationGateTests.testAutomaticSummaryParksButKeepsExistingTranscript`: A transcript already on disk (live transcription, earlier run):
only the summary needs Think, so only the summary waits.

#### Repeated readiness checks while Think is absent are pure waits
`ProcessingPipelineAutomationGateTests.testAutomaticSummaryParksButKeepsExistingTranscript`: Repeated launch/download readiness checks while Think is still
absent must remain pure waits, not crash-loop processing attempts.

### `LokalBotTests/Services/Meetings/ProcessingPipelineNoSpeechTests.swift`

#### Silent recordings must finish with empty transcript, not stay failed and rerun
`ProcessingPipelineNoSpeechTests`: Three silent recordings (June 25, June 30, July 16) stayed in the failed
list for months as "No audio tracks found", were re-run through the speech
model on every launch, and came back each time the person pressed Retry.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
