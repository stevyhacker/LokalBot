# 0097. Windows and Linux: core — other modules

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-core/src/access.rs`, `LinuxWindows/crates/lokalbot-core/src/action_completion.rs`, `LinuxWindows/crates/lokalbot-core/src/actions.rs`, `LinuxWindows/crates/lokalbot-core/src/agent_handoff.rs`, `LinuxWindows/crates/lokalbot-core/src/agent_notes/`, `LinuxWindows/crates/lokalbot-core/src/audio_files.rs`, `LinuxWindows/crates/lokalbot-core/src/calendar/`, `LinuxWindows/crates/lokalbot-core/src/chats.rs`, `LinuxWindows/crates/lokalbot-core/src/cotyping_stats.rs`, `LinuxWindows/crates/lokalbot-core/src/demo.rs`, `LinuxWindows/crates/lokalbot-core/src/dictation_history.rs`, `LinuxWindows/crates/lokalbot-core/src/digest.rs`, `LinuxWindows/crates/lokalbot-core/src/due.rs`, `LinuxWindows/crates/lokalbot-core/src/embeddings.rs`, `LinuxWindows/crates/lokalbot-core/src/evidence.rs`, `LinuxWindows/crates/lokalbot-core/src/generated_file.rs`, `LinuxWindows/crates/lokalbot-core/src/github_star.rs`, `LinuxWindows/crates/lokalbot-core/src/health.rs`, `LinuxWindows/crates/lokalbot-core/src/ids.rs`, `LinuxWindows/crates/lokalbot-core/src/import.rs`, `LinuxWindows/crates/lokalbot-core/src/jobs.rs`, `LinuxWindows/crates/lokalbot-core/src/lib.rs`, `LinuxWindows/crates/lokalbot-core/src/library.rs`, `LinuxWindows/crates/lokalbot-core/src/meeting_review.rs`, `LinuxWindows/crates/lokalbot-core/src/meeting_screen.rs`, `LinuxWindows/crates/lokalbot-core/src/merge.rs`, `LinuxWindows/crates/lokalbot-core/src/paths.rs`, `LinuxWindows/crates/lokalbot-core/src/projects.rs`, `LinuxWindows/crates/lokalbot-core/src/remote_transcription.rs`, `LinuxWindows/crates/lokalbot-core/src/retention.rs`, `LinuxWindows/crates/lokalbot-core/src/routines.rs`, `LinuxWindows/crates/lokalbot-core/src/screen.rs`, `LinuxWindows/crates/lokalbot-core/src/screen_search.rs`, `LinuxWindows/crates/lokalbot-core/src/sealed.rs`, `LinuxWindows/crates/lokalbot-core/src/search.rs`, `LinuxWindows/crates/lokalbot-core/src/speaker_bleed.rs`, `LinuxWindows/crates/lokalbot-core/src/text.rs`, `LinuxWindows/crates/lokalbot-core/src/time.rs`, `LinuxWindows/crates/lokalbot-core/src/vocabulary.rs`, `LinuxWindows/crates/lokalbot-core/tests/`.

## Decisions

### `LinuxWindows/crates/lokalbot-core/src/access.rs`

#### Agent read access comes only from marker files under control/, as on macOS
Consent boundaries shared by the app, engine and CLI.

External agents get read access only through marker files under
`<root>/control/`, exactly as on macOS (`AgentAccessGate.swift`,
`ScreenMemoryAccessGate.swift`). Remote model servers need an approved
origin (`RemoteInferenceGate.swift`).

#### Settings grant is separate from meeting and screen grants; only the app writes it
`settings_control_enabled`: Like the other grants this is deliberately separate: meeting or screen access
never grants settings access, and this grant never grants either of them.
Only the app writes it, from its Privacy switch or an allowed setup request.

#### Meeting grant is marker content or capability token; long reads keep one grant identity
`meetings_authorization`: The grant behind meeting access: the marker's content, or a valid
capability token from `LOKALBOT_AGENT_CAPABILITY`. A long read keeps the
same grant identity from start to answer (`authorizationID`).

#### Capability is a bearer uuid.secret token; only the secret's SHA-256 is stored
`issue_agent_capability`: Issues a bearer capability (`<uuid>.<64 hex>`) for one embedded agent
process; only the secret's SHA-256 is stored.

#### Wake file asks the app to start its model server (ask_library protocol)
`touch_wake`: Asks the app to start its model server (`ask_library` wake protocol).

#### Empty screen marker means all history; unparsable marker means last 7 days
`screen_access_scope`: `None` when screen access is off or the marker cannot be read. An empty
(legacy) marker means all retained history; one that does not parse,
including whitespace, means the last 7 days (`ScreenMemoryAccessGate.profile`).

#### Reject credentials, backslashes and control characters in authorities to block host spoofing
`origin_of`: `scheme://host[:port]` of a URL, lowercased; `None` if it does not parse.

An authority with credentials, a backslash, whitespace or a control
character is rejected: WHATWG parsers (the Agent runtime's `new URL`) end
the host at `\`, so `https://evil.example\@localhost` would pass here as
loopback while the request went to `evil.example`.

#### Loopback is localhost, *.localhost, ::1 and 127.0.0.0/8; 0.0.0.0 is not
`is_loopback_url`: `localhost`, `*.localhost`, `::1` and `127.0.0.0/8`. `0.0.0.0` is not loopback.

#### Private network judged from URL alone; loopback has its own rule
`is_private_network_url`: A host on the user's own network, judged from the URL alone
(`InferenceEndpointPolicy.isPrivateNetwork`): RFC 1918, link-local, Tailscale
(100.64.0.0/10), unique-local IPv6, `.local`, `.home.arpa`, `.ts.net` and
single-label names. Loopback has its own rule and doesn't count.

#### IPv6 zone names the interface, so it is stripped before parsing
`is_private_network_url`: An IPv6 zone ("fe80::1%en0") names the interface, not the host.

#### Only loopback may use plain HTTP for Think, Agent Mode and Dream
`remote_block_reason`: Why Think, Agent Mode or Dream can't send context to a server yet, or `None`
if they may (`InferenceEndpointPolicy.validate` with its default). Only
loopback may use plain HTTP: an approved server on the user's own network
still needs HTTPS, unlike autocomplete and transcription, which opt in to
private-network HTTP with their own checks.

#### Approving a LAN or tailnet server never allows unencrypted transcripts
`think_refuses_plain_http_off_this_computer_even_when_approved`: `InferenceEndpointPolicy.validate` without `allowsPrivateNetworkHTTP`:
approving a server on the LAN or a tailnet never lets transcripts travel
unencrypted.

#### WHATWG parsing sends these URLs to evil.example, not localhost
`ambiguous_authorities_are_not_origins`: WHATWG URL parsing sends these to evil.example, not localhost.

### `LinuxWindows/crates/lokalbot-core/src/action_completion.rs`

#### Looks-done hint is a suggestion needing two distinctive words and a verb-fitting phrase
"Looks done?" (`ActionCompletionHints.swift`): a suggestion, never a status
change. A later screen capture that looks like the user finished one of
their open actions needs at least two of the action's distinctive words and
a completion phrase that fits the action's verb. Only locally retained
screen text and titles are read.

#### Distinctive words exclude stop words and need four letters, a digit or capital
`distinctive_terms`: Distinctive words: not stop words or generic task verbs, and either four
or more letters, containing a digit, or capitalized in the source.

### `LinuxWindows/crates/lokalbot-core/src/actions.rs`

#### Actions layer user corrections over extracted outcomes, mirroring the Swift types
Action items across meetings: the user's corrections layered over the
extracted outcomes (`MeetingOutcomeProjection.swift`), threads of the same
commitment (`ActionThreads.swift`), Today's attention order and the
correction workflow (`OutcomeIndex.swift`).

#### Clustering never joins mentions more than 30 days apart
`THREAD_MAXIMUM_SPAN_DAYS`: Clustering never joins mentions more than 30 days apart.

#### None keeps a field; Some(None) clears it; empty text reverts to extracted
`ActionCorrection`: A user correction of one extracted action.

`None` leaves a field as it is. `text: Some("")` reverts to the extracted
text. `owner`/`due`: `Some(None)` (or a blank string) clears the value
explicitly ("no owner", "no due date"), `Some(Some(value))` overrides it.

#### v0.11.0-0.11.5 saved translated 'Me' as owner; read back only in its language
`TRANSLATED_ME_OWNERS`: What the Windows/Linux correction sheet saved for "You" in v0.11.0–v0.11.5:
the interface word for "Me", which nothing reads as the user. Each word
counts only in the language that wrote it; elsewhere "Mimi", "Saya" or
"Moi" is more likely somebody's name.

#### Translated 'Me' reads back as Me; the file keeps the word
`saved_owner_override`: A saved owner override, with v0.11's translated "Me" read back as `Me`
under the interface language that wrote it. The file keeps the word.

#### Excluded, generic or ownerless references become single-member threads
`cluster_threads`: Joins equal canonical commitments across meetings (`ActionThreadClusterer`).
Unclusterable references (excluded, generic, ownerless) become threads of one.

#### Newest-first order means an expired group never becomes a candidate again
`cluster_threads`: Newest first, so an expired group never becomes a candidate again.

#### Ties pick the first element, matching Swift's max(by:)
`first_max_by_key`: The first element with the greatest key (Swift's `max(by:)`).

#### Short generic commitments recur naturally and are unsafe to merge
`source_key`: Short generic commitments recur naturally and are unsafe to merge.

#### Attention order: overdue, due within a week, then existing order
`attention_sorted`: Overdue work first, then work due within a week (each by due day), then
the rest in their existing order (`ActionAttentionOrder`).

#### Sample meeting's actions stay on its own page, not in cross-meeting lists
`Library::action_references`: Every action from meetings started in the last `days` days (all when
`None`). The sample meeting's actions stay on its own page.

#### None gives Today's attention order; a day gives that day's threads newest first
`Library::needs_attention`: The user's open threads. `None`: Today's list in attention order
(overdue, due within 7 days, the rest). `Some(day)`: threads mentioned
in a meeting on that local day, newest first (Timeline's day view).

#### Unlike macOS, summaries without claims are not archived after owner or text change
`Library::correct_action`: Saves a correction to `outcome-state.json` and refreshes the action
list in `summary.md` (`OutcomeIndex.correctAction`).

Unlike macOS, a summary without `summary-claims.json` is not archived
for regeneration after an owner or text change; its action list is
rewritten like any other.

#### Action items section renders Me, Others and Owner unclear subsections
`replace_action_items`: `summary.md` with its `## Action items` section rendered from `outcomes`
(`MeetingSummaryOutcomeSynchronizer`): `### Me`, `### Others` and, when
needed, `### Owner unclear`.

#### Sections go where the first controlled one was; own copies dropped; missing appended
`replace_sections`: Puts the rendered sections where the first controlled section was,
dropping the summary's own copies; missing sections are appended.

### `LinuxWindows/crates/lokalbot-core/src/agent_handoff.rs`

#### Handoff routes only fill the agent's input; the user sends it
Prompts for handing work to a coding agent (`ActionAgentHandoff.swift`,
`ExternalAgentHandoff.swift`). Nothing here sends anything: every route
only fills the agent's input, and the user sends it there.

#### 5,000 characters is Claude Code's deep-link limit; Codex gets the same
`ACTION_PROMPT_LIMIT`: Claude Code's limit for a deep link's `q`. Codex documents no limit; it
gets the same budget.

#### Claude cuts q near 14,000 characters; both apps use 12,000
`MEETING_PROMPT_LIMIT`: Claude cuts `q` at about 14,000 characters; both apps open with the same notes.

#### Meeting id is the short form the CLI and MCP tools accept
`Source.meeting_id`: The short ID the CLI and MCP tools accept.

#### Rows show You only for owner Me on the user's own work
`is_user_owner`: Rows show "You" only for an owner named "Me" on the user's own work.

#### Prompts stay in English like the Mac's, whatever the app language
`owner_label`: A speaker label as a person reads it. Prompts stay in English, like the
Mac's, whatever language the app shows.

#### One source per meeting, latest first; missing files are omitted
`sources`: One source per meeting, latest first; files that don't exist yet are left out.

#### Oldest meetings are dropped first when the prompt exceeds the limit
`action_prompt`: A prompt the user can send as is. Older meetings are left out first when
the prompt would pass `limit` (`ActionAgentHandoff.prompt`).

#### Notes render first; transcript gets whatever room the notes leave
`meeting_prompt`: A meeting's notes for "Open in Claude" and "Open in Codex"
(`ExternalAgentHandoff.prompt`). `notes(None)` renders the notes without a
transcript and `notes(Some(n))` adds up to n characters of it; the
transcript gets whatever room the notes leave.

#### Percent-encode every character apps read as space or parameter separator
`encode_query_value`: Keeps every character the apps would otherwise read as a space or a new
parameter out of a link's query (`encodeQueryValue`).

#### Plan in Agent includes at most eight open threads
`agent_prompt_for_plan`: Today's "Plan in Agent…": at most eight open threads.

#### Paths use each platform's own separator so the agent can open them
`action_prompt_matches_the_mac`: Each platform's own separator, as the agent will need to open them.

### `LinuxWindows/crates/lokalbot-core/src/agent_notes/access.rs`

#### Notes grant is a marker; CLI searches saved notes without the app; off deletes them
The Agent notes grant for external agents (`AgentNotesAccessGate`): a marker
the app sets from Settings → AI agents. `lokalbot-cli` and its MCP
server search the saved notes themselves, without the app running, and find
none while Read coding agent notes is off, because turning that off deletes
them. Separate from every other grant; no Agent Mode capability satisfies it.

### `LinuxWindows/crates/lokalbot-core/src/agent_notes/cjk.rs`

#### unicode61 indexes CJK runs as one token, so CJK queries use substring matching
Substring matching for Chinese, Japanese and Korean text (`CJKSearch.swift`).

SQLite's `unicode61` tokenizer indexes an unbroken run of CJK text as one
token, so FTS5 finds a word only at the start of that run. A query that
contains CJK text therefore matches by substring on the stored text.

#### Terms split on whitespace and punctuation; dots, hyphens, apostrophes, underscores stay
`SEPARATORS`: Separators between search terms: whitespace, sentence punctuation and
brackets in ASCII and full-width forms. Dots, hyphens, apostrophes and
underscores stay inside a term.

#### Terms are distinct and in order; every term must occur for a match
`terms`: Distinct terms of `query`, in order. Every term must occur for a match.

#### LIKE pattern escapes percent, underscore and backslash; use with ESCAPE backslash
`like_pattern`: A `LIKE` pattern that matches `term` anywhere, escaping `%`, `_` and `\`.
Use it with `ESCAPE '\'`.

#### Snippet marks matches with guillemets and cuts with ellipses; None without a match
`snippet`: An excerpt around the first match, with « » around every match inside it
and … where text was cut. `None` when no term occurs.

### `LinuxWindows/crates/lokalbot-core/src/agent_notes/index.rs`

#### Read side opens the notes database read-only per call so CLI and app can both search
Read side of the saved coding-agent notes (`AgentNotesIndex`):
`agent-notes.sqlite` in the library, written only by the app
([`super::store`]). Every call opens the file read-only and closes it, so
the CLI and the app can both search while the app replaces notes.

#### BM25 weights title 10, summary 4, text 1
`RANK`: Column weights for title, summary and text.

#### Note id is stable and cited as [note:id]
`NoteHit.id`: Stable id of the note, cited as `[note:id]`.

#### Category is Claude Code's own label: user, feedback, project or reference
`NoteHit.category`: Claude Code's own label: user, feedback, project, or reference.

#### Snippet wraps matched words in guillemets
`NoteHit.snippet`: A passage around the match, the matched words between « and ».

#### Connection is query-only so no write path to notes can grow
`NotesIndex::connection`: Query-only, so nothing here can grow a write path to the notes.

#### Match all words, else any; last word also matches as prefix while typing
`NotesIndex::search`: Notes matching every word of `query`, best first; when none has every
word, notes matching any. The last word also matches as a prefix, so
results appear while it is typed.

#### FTS5 cannot see words inside CJK runs, so CJK uses substring search
`NotesIndex::search`: FTS5 cannot see words inside a run of CJK text.

### `LinuxWindows/crates/lokalbot-core/src/agent_notes/mod.rs`

#### Saved notes are a search source only, not fed to digest, review or Personal Context
Coding-agent notes as a search source (`AgentMemoryNote.swift`,
`AgentMemoryStore.swift`, `AgentNotesAccess.swift`): the notes Claude Code
and Codex keep for their own later sessions, saved in `agent-notes.sqlite`
in the library while the person has **Read coding agent notes** on.

The readers live in `lokalbot-engine`. This is the saved copy every other
feature reads: [`store`] writes it, [`index`] searches it read-only, and
[`access`] is the external-agent grant. The notes are a search source only;
nothing here feeds the day digest, the overnight review or Personal Context.

#### The Mac writes the same agent-notes.sqlite file in the library root
`FILE_NAME`: The saved notes, in the library root. The Mac writes the same file.

#### The agent's own file stays the source and is never changed
`AgentNote`: A note a coding agent wrote for its own later sessions, as LokalBot keeps it
for search. The agent's file stays the source and is never changed.

#### Note id is stable across scans from agent, file and section
`AgentNote.id`: Stable across scans: the agent, the file, and the section inside it.

#### Category is Claude Code's label: user, feedback, project or reference
`AgentNote.category`: Claude Code's label for the note: user, feedback, project, or reference.

#### Note text has detected credentials redacted
`AgentNote.text`: The note's text with detected credentials redacted.

#### Id is twelve hex characters from agent, forward-slash relative path and anchor
`AgentNote::identifier`: Twelve hex characters from the agent, the file's path under the agent's
folder (always with `/`), and the section's anchor.

#### A bare drive letter names a drive, not a project
`project_name`: `C:` alone names a drive, not a project.

#### While files are unreadable, missing notes are not treated as deleted
`NoteScan.unreadable_files`: Files that exist but could not be read. While any are listed, notes
missing from the scan are not taken as deleted.

#### Counts notes left out by the never-read-folders setting
`NoteScan.excluded_notes`: Notes left out by "Never read sessions in these folders".

#### Id must equal the Mac's SHA-256 of agent, path and anchor
`identifiers_are_twelve_hex_characters_and_differ_by_anchor`: SHA-256 of "codex\u{1f}MEMORY.md\u{1f}", as the Mac computes it.

### `LinuxWindows/crates/lokalbot-core/src/agent_notes/store.rs`

#### Notes file holds only what readers kept; rebuildable and deleted when feature is off
Write side of the saved coding-agent notes (`AgentMemoryStore`). The file
holds only what the readers kept of the agents' own files, so it is rebuilt
from them at any time and deleted outright when the person turns the
feature off.

#### Schema matches the Mac's so either app reads the other's file
`SCHEMA`: The Mac's schema, so either app reads a file the other wrote.

#### Unreadable files keep their notes; other agents' notes are dropped
`apply`: Makes the saved notes of `agents` match `scan`, and drops notes of any
other agent. While a file could not be read, a note missing from the scan
stays: an unreadable file is not a deleted one.

#### WAL mode as on the Mac lets readers proceed while notes are replaced
`apply`: As the Mac opens it: readers proceed while notes are replaced.

#### On Windows an open search can keep the file until the next try
`delete_all`: Removes every saved note. The agents' own files are untouched. Returns
whether the file is gone: on Windows a search that has it open for a moment
keeps it until the next try.

### `LinuxWindows/crates/lokalbot-core/src/audio_files.rs`

#### Crash-damaged AAC loses to the PCM copy; Rust checks MP4 structure, not decoding
Which file holds a meeting's track (`MeetingAudioFiles.swift`). A Mac keeps
AAC in `mic.m4a`/`system.m4a` beside an append-only PCM copy in
`mic.live.caf`/`system.live.caf`. A crash can leave the AAC unreadable or
short while the copy stays readable, and then the copy is the recording.

The Mac decodes the AAC to prove it is whole. This crate has no decoder, so
it reads the files' structure instead: an MP4 without a complete `moov`, or
with a box that runs past the end of the file, doesn't count as readable.

#### Small encoder tail is tolerated; a larger gap means the copy is more complete
`COMPLETENESS_TOLERANCE_SECONDS`: Container finalization and the PCM copy can differ by a small encoder tail.
A larger gap means the AAC was cut short and the copy is more complete.

#### mic.live.caf is what the Mac recorder was still writing
`Track::recovery_file`: `mic.live.caf`: what the Mac's recorder was still writing.

#### mic.live.recovered.caf is rebuilt by the Mac from checkpoints
`Track::recovered_file`: `mic.live.recovered.caf`: rebuilt by the Mac from its checkpoints.

#### mic.live.recovery is the Mac's checkpoint folder
`Track::journal_folder`: `mic.live.recovery`: the Mac's checkpoint folder.

#### An unreadable AAC still goes to the decoder, which reports why
`track_file`: An AAC this can't read still goes to the decoder, which says why.

#### Unverified Mac checkpoints make the meeting page warn
`recovery_needs_attention`: Checkpoints from a Mac recording that were never verified as complete. The
meeting's page warns from this (`recoveryNeedsAttention`).

#### CAF data chunk of size -1 was still being written and runs to end
`caf_duration`: Seconds of audio in a CAF of fixed-size packets, from its header and size.
A data chunk of size -1 was still being written and runs to the end.

#### CAF data chunk opens with a four-byte edit count
`caf_duration`: The chunk opens with a four-byte edit count.

#### Missing complete moov or a box past the end marks a crash-cut recording
`mp4_duration`: The length an MP4 says it has. `None` when it has no complete `moov`, which
is what a recording cut off by a crash looks like, or a box past the end.

#### Test header mirrors AVAudioFile's tee: 16 kHz mono Float32 little-endian
`caf_header`: The header `AVAudioFile` writes for the tee: 16 kHz mono Float32 LE.

### `LinuxWindows/crates/lokalbot-core/src/calendar/agenda.rs`

#### Agenda keeps invitation agenda without joining info, links, numbers or markup, only if enabled
`CalendarAgenda.sanitize` (`MeetingGenerationContext.swift`): the agenda
part of an invitation, without joining instructions, links, phone numbers,
addresses or markup. Kept only when the user turns on agenda use.

### `LinuxWindows/crates/lokalbot-core/src/calendar/conference.rs`

#### Conference links mark online meetings and make browser calls calendar backed
Conferencing links in free text (`ConferenceURLDetector.swift`): they mark
an event as an online meeting and let a browser call count as calendar
backed when its window title says nothing.

#### Room address drops query and fragment, which may hold invitations or guest tokens
`meeting_room`: Canonical address of a room whose accessibility controls the app can
verify. Query and fragment may contain invitations or guest tokens.

#### Links stop at CJK punctuation because invitations omit the space
`SCHEME_LINK`: `http(s)` links, stopping at whitespace, angle brackets, quotes and CJK
punctuation (invitations write "会议：https://…" without a space).

### `LinuxWindows/crates/lokalbot-core/src/calendar/identity.rs`

#### Attendee email stays in local metadata; transcripts keep only the opaque id
`CalendarParticipantIdentity.swift`: one remote attendee of the calendar
event matched to a meeting.

The email address stays in local meeting metadata only, so the rename
sheet can tell same-named attendees apart. Transcripts keep the opaque
`id`, never the address.

#### Blank id gets a fresh uppercase UUID, as on macOS
`CalendarParticipantIdentity::new`: A normalized identity, or `None` when neither the name nor the address
is usable. A blank `id` gets a fresh uppercase UUID, as on macOS.

#### Address-derived names are editable suggestions, never automatic speaker identity
`CalendarParticipantIdentity::suggested_speaker_name`: An editable picker suggestion, never an automatic speaker identity.
Calendars often give an address without a display name; metadata
keeps that absence so automatic naming cannot treat a guess as fact.

#### Only mailto participants count as addresses, not opaque provider ids
`CalendarParticipantIdentity::email_from_participant_uri`: Accepts only `mailto:` participants, so opaque provider identifiers
are never mistaken for addresses.

#### Dedupe by address; by name only when address missing
`CalendarParticipantIdentity::normalized`: Deduplicates by address first, and by name only when an address is
missing. A same-name, different-address pair stays two people.

### `LinuxWindows/crates/lokalbot-core/src/calendar/mod.rs`

#### Calendar policy is pure and mirrors the Swift services; providers live in platform crate
Calendar-assisted meetings: the pure policy behind `LokalBot/Services/Calendar/`
(`CalendarEventFilter`, `CalendarMeetingCandidate`, `MeetingMatcher`,
`ConferenceURLDetector`) and the calendar fields a recording writes to
`meta.json` (`RecordingController.swift`). Providers live in
`lokalbot-platform`; nothing here reads a calendar or the network.

#### Detector matches meetings joined 15 minutes late and starting within 90 minutes
`LOOK_BEHIND`: Look-around window of the detector: a meeting joined up to 15 min late
still matches, and one starting within 90 min is visible early.

#### Events count as active one minute early because people join early
`EARLY_JOIN_GRACE`: A beat before an event's start during which it already counts as active
(people click Join about a minute early), not a long pre-roll.

#### Detection may not restart a stopped event for five minutes
`REPEAT_COOLDOWN`: Detection may not restart a calendar event the user stopped recording
for this long (`calendarRepeatCooldown`).

#### Native apps get extra 180 s stop grace while the event is in window
`CALENDAR_BACKED_GRACE`: Extra stop grace for a native app while its calendar event is still in
its scheduled window (`calendarBackedGrace`).

#### EDS means Evolution Data Server, including GNOME Online Accounts, on Linux
`provider::EDS`: Evolution Data Server, which includes GNOME Online Accounts (Linux).

#### Free means TRANSP:TRANSPARENT, which focus and hold blocks use
`RawCalendarEvent.availability_free`: Shown as free (`TRANSP:TRANSPARENT`); focus and hold blocks use it.

#### External id is uid#start-epoch so cooldown keys on one occurrence
`CalendarEvent.external_id`: One occurrence: `<uid>#<start epoch seconds>`, so the repeat cooldown
is keyed on this exact meeting instance.

#### Agenda stays in memory; a recording keeps it only when agenda use is on
`CalendarEvent.agenda`: Sanitized invitation agenda, held in memory. A recording keeps it
only when agenda use is on.

#### Event id alone is shared by every occurrence of a recurring series
`CalendarEvent::occurrence_id`: `<uid>#<epoch seconds>` (`occurrenceID`): the event id alone is shared
by every occurrence of a recurring series.

#### Calendar end never stops a recording, so activity is start-biased
`CalendarEvent::is_active_with`: In progress, or within `early_join` before its start. The calendar
end never stops a recording (only audio does), so this is start-biased.

#### Most recently started in-progress event beats upcoming; else soonest upcoming
`active_event`: The one event that best represents "now": an in-progress event (the most
recently started) beats one about to start; with none in progress, the
soonest upcoming wins. `None` when nothing is active.

#### Calendar, titles and audio are never proof of a call; strict mode needs calendar link
`browser_counts_as_meeting`: Calendar, titles and audio are supporting metadata, never proof of a
call: the caller must have verified the call itself. In strict mode a
browser call also needs an active calendar event with a meeting link.

#### Cooldown starts only when the user stopped; new occurrences are never blocked
`should_suppress_repeat`: Suppress an automatic start that would re-record the calendar event the
user just stopped. A call that ended on its own never starts the cooldown,
and a new occurrence has another id, so it is never blocked.

#### Recording splits when the active event changes so back-to-back meetings stay apart
`should_split_for_calendar_handoff`: A recording backed by one calendar event splits as soon as the active
event changes, so back-to-back meetings are not merged during the stop
debounce.

#### Owner splits; with nothing recording the next event starts; foreign recordings left alone
`switch_action`: The recording that owns the call splits. With nothing recording (the
user stopped the previous event), the next calendar event is a new meeting
and records; a recording the call does not own is left alone.

#### meta.json dates are whole seconds
`seconds`: `meta.json` dates are whole seconds.

### `LinuxWindows/crates/lokalbot-core/src/calendar/suggestion.rs`

#### Speaker suggestions are picker choices only; attendance does not identify a voice
`MeetingSpeakerSuggestion.swift`: names the Name Speaker sheet offers.
Picker choices only, never a speaker attribution: attendance does not
identify a voice.

#### Calendar guests first, same-named guests stay separate, then unseen hint names
`SpeakerSuggestion::choices`: Calendar guests first (same-named guests stay separate, each with its
own identity), then hint names not already offered.

#### Query words match ignoring case and accents; đ typed as d or dj
`SpeakerSuggestion::matches`: Every query word appears in the name or address, ignoring case and
accents, so "petrovic ana" finds "Ana Petrović". "đ" is typed as "d"
or "dj".

### `LinuxWindows/crates/lokalbot-core/src/calendar/tests.rs`

#### Other Feishu and DingTalk pages are documents and downloads, not calls
`detects_chinese_meeting_links`: Other Feishu and DingTalk pages are documents and downloads, not calls.

#### An email address on a conferencing domain is not a link
`finds_links_in_invitation_markup_and_without_a_scheme`: An address on a conferencing domain is not a link.

#### Never auto-record minutes ahead of an event's start
`is_active_window`: Beyond the grace: never auto-record minutes ahead of the start.

#### Mac meta.json uses sortedKeys, prettyPrinted and escaped slashes
`decodes_calendar_metadata_written_by_the_mac_app`: JSONEncoder output with `.sortedKeys`, `.prettyPrinted` and escaped
slashes, as StorageManager writes meta.json.

### `LinuxWindows/crates/lokalbot-core/src/calendar/upcoming.rs`

#### Today's schedule decides which events list, which leads, and how time reads
Today's meeting schedule (`UpcomingMeetingSelector`,
`UpcomingMeetingPresentation`): which events are listed, which one leads,
and how their time is described.

#### Solo events with meeting titles are listed without Join or Record
`UpcomingKind::SoloMeeting`: Only the user is invited, but the title names a meeting (a standup
joined from elsewhere). Listed, without Join or Record.

#### Solo non-meeting events are never listed as meetings
`UpcomingKind::Personal`: Only the user, with a non-meeting title (a doctor's visit, an errand).
Never listed as a meeting.

#### English and Serbian meeting words separate meetings from personal appointments
`MEETING_TITLE`: Meeting words in English and Serbian. A personal appointment title rarely
uses them; a meeting kept on a private calendar usually does.

#### Includes ended and distant meetings; personal appointments excluded so they cannot lead
`schedule`: Every meeting overlapping the local `day`, including meetings that ended
and meetings hours away, by start then end. Personal appointments are left
out so they cannot take a meeting's place.

#### In-progress event leads, else next today; recorded event skipped for its live card
`primary`: The meeting whose preparation deserves emphasis: an in-progress event
first, otherwise the next one at any later time today. The event being
recorded is skipped; Today has its own live card for it.

### `LinuxWindows/crates/lokalbot-core/src/chats.rs`

#### Chats are sealed per file; plaintext is migrated, never overwriting sealed
Ask conversations on disk (`ChatStore`): one sealed file per conversation,
`chats/<UUID>.json.enc`, under the per-install `chat-key`.

Plaintext `chats/<UUID>.json`, which earlier versions of this app and the
Mac's first versions wrote, still opens and is then re-sealed, and the
plaintext goes only once its sealed copy has landed. An encrypted copy wins
over a leftover plaintext one. A sealed file that can't be opened (the key is
missing, or the library came from another computer) is reported and left
alone: it is never overwritten or replaced by a plaintext copy beside it.

#### Mirrors Mac ChatViewModel.updatePersistenceError with credential store wording
`ChatLoad.problem`: `ChatViewModel.updatePersistenceError`, with this platform's credential
store in place of the Keychain.

#### Plaintext chat files exist in upper case (Mac) and lower case (earlier)
`plaintext_names`: Both spellings: the Mac names files in upper case, earlier versions of this
app in lower case.

#### Encrypted copy wins when migration left both files
`Library::load_conversations`: Encrypted copies win if an earlier migration left both files.

#### Never re-seal over a sealed store that cannot be opened
`Library::load_conversations`: Re-sealing here would replace a store that can't be opened.

#### Unsealable chat stays in memory, never written as plaintext
`Library::save_conversation`: Seals and saves. When that isn't possible the conversation stays in
memory for this run instead of being written as plaintext, and the error
says so.

#### Deleted conversation is not revived by a still-running answer
`Library::conversation_exists`: The legacy copy goes first: if that fails the sealed copy is still there
and the conversation can be deleted again. What was learned from the
questions in it goes too.
Whether the conversation is still kept, on disk or held unsaved. An answer
still being written never brings back one deleted meanwhile.

#### Demo library writes plaintext because no key exists yet; sealed on first load
`Library::write_plaintext_conversation`: For the demo library, which is built before any key exists. The app
seals it the first time it loads conversations.

#### Plaintext beside a foreign sealed file must not replace it
`a_file_sealed_elsewhere_is_reported_and_never_overwritten`: A plaintext copy beside it mustn't replace it either.

### `LinuxWindows/crates/lokalbot-core/src/cotyping_stats.rs`

#### Mac keeps stats in UserDefaults; here files hold same JSON, counts only
Autocomplete's counters and timings (`CotypingStats.swift`,
`CotypingUsageHistory.swift`, `CotypingLiveMeasure.swift`).

The Mac keeps these in `UserDefaults` (`lokalbotv3.cotypingStats`,
`lokalbotv3.cotypingUsage`), so there is no Mac file to match. Here they
are `<root>/cotyping-stats.json` and `<root>/cotyping-usage.json` in the
Mac's JSON encoding, the way `settings.json` stands in for its blob. A
damaged file reads as empty, as on the Mac. Counts and timings only: no
text, app name or window title.

#### Daily rows kept 92 days; months keep totals
`RETAINED_DAYS`: Daily rows are kept this long; months keep the totals.

#### Gaps over one second are pauses, not typing speed
`MAX_TYPING_GAP_MS`: A longer gap between typed characters is a pause, not typing speed.

#### Typing speed shown only after 200 measured gaps
`MINIMUM_TYPING_GAPS`: Typing speed is shown once this many gaps are measured.

#### 300 ms equals 40 words a minute at five characters
`FALLBACK_MS_PER_KEYSTROKE`: 40 words a minute at five characters a word.

#### Mac surface raw values and titles in display order
`SURFACES`: The Mac's surface raw values with their titles, in display order
(`CotypingSurfaceClass.measured`, `measureTitle`).

#### Report says numbers come from field reads; no keyboard monitor here
`CotypingStats::report`: `report(model:)`: a plain-text table for comparing runs. Counts and
timings only. Unlike the Mac's, it says the numbers come from field
reads: this port has no keyboard monitor.

#### Checks accepted text arrived by comparing field after with what was sent
`InsertionCheck`: Whether an accepted suggestion really arrived in the field
(`CotypingInsertionCheck`): what the app shows afterwards against what was
sent. Holds a little text only until it is resolved.

#### Accept sent while previous unread is checked together
`InsertionCheck::extend`: An accept sent while this one is still unread is checked with it.

#### Browsers publish trailing space as non-breaking space
`normalized`: Browsers publish a trailing space as a non-breaking space.

#### Zero counts left out of the file
`UsageCounts`: What autocomplete did for one period (`CotypingUsageCounts`). Zero counts
are left out of the file.

#### used capped at shown since accept after midnight lands on later day
`UsageCounts::acceptance_rate`: Share of shown suggestions used; `used` is capped at `shown`, since an
accept just after midnight can land on a later day than its suggestion.

#### Measured from all recorded data; typing speed is a habit, not per range
`UsageSummary.milliseconds_per_keystroke`: Measured from everything recorded: typing speed is a habit, not a
property of the range.

#### Headroom plus floor so a quiet week is not drawn full height
`UsageSummary::word_ceiling`: Headroom above the tallest bar, with a floor so a quiet week is not
drawn full height.

#### Elapsed time between reads stands in for key gaps, since no key tap
`UsageHistory::record_typed`: Characters typed in one read of the field. There is no key tap here,
so `elapsed_ms` since the previous read stands in for the gaps between
them: a read up to `MAX_TYPING_GAP_MS` after the last counts each
character as one gap, and a longer one counts none.

#### Fixtures derived from Swift Codable types; no real Mac capture exists
`tests::USAGE`: Derived from the Swift `Codable` types; no capture from a Mac exists.

### `LinuxWindows/crates/lokalbot-core/src/demo.rs`

#### Fictional studio demo library adapted from Python seeder, relative to now
A fictional demo library for screenshots, UI development and tests
(`Scripts/test/seed_demo_library.py --profile studio`, adapted to Linux and
Windows apps): a small video studio's meetings, actions, day memory,
digest, Ask conversations, people and projects, placed relative to `now`.

#### Marker lets a module-created directory be reseeded
`DEMO_MARKER`: Marks a directory this module created, so it may be reseeded.

#### Must match Python seeder's mid(n) UUID format
`mid`: `mid(n)` of the Python seeder: `{n:08}-0000-4000-8000-{n:012}`.

#### None lets the cited segment's speaker decide owner
`Action.owner`: `None`: the speaker of the cited segment decides (me → Me).

#### Early-morning demo anchor moves to 04:30 so Today is populated
`Clock::new`: Today's items sit just before `now`; very early in the morning they
move to 04:30 so Today is still populated.

#### Refuses non-empty directory unless an earlier seed marked it
`seed`: Seeds the demo library at `paths`, relative to `now`.

Refuses a non-empty directory unless an earlier seed created it (marked
with [`DEMO_MARKER`]); such a library is replaced.

#### Settings only skip onboarding so setup wizard doesn't cover demo
`seed`: Only this, so everything else keeps following the app's defaults: the
setup wizard would cover the library this exists to show.

#### Journal layout matches DayDigestEvidence.renderDocument
`render_journal`: The journal layout `DayDigestEvidence.renderDocument` writes.

### `LinuxWindows/crates/lokalbot-core/src/dictation_history.rs`

#### Recent dictations file is AES-256-GCM sealed; Mac and port keys differ
Recent dictations (`DictationHistory.swift`): the latest results, so a
dictation left on the clipboard can be copied again after the next copy
replaced it, even after a crash, a power cut or a restart.

\# File

`<root>/recent-dictations.json.enc` is JSON sealed with AES-256-GCM as
`nonce (12 bytes) ‖ ciphertext ‖ tag (16 bytes)`, like screen images. The
key is created per install and kept in the system credential store. A Mac
seals the same file name with its own Keychain key, so neither app reads
the other's: it reads as empty and the next save replaces it. Writes are
owner-only on Unix and reach the drive before they replace the old file.

#### NotInserted means transcribed but Compose failed, nothing delivered
`Outcome::NotInserted`: Transcribed, but Compose failed, so nothing was delivered.

#### Label returns a catalog key, not display text
`Outcome::label`: The catalog key for the outcome's label.

#### Menu title is time plus truncated preview, like 2:20 PM
`Entry::menu_title`: Time and the start of the text, such as "2:20 PM — Can you check…".

#### History is newest first, capped at LIMIT, none older than MAXIMUM_AGE_DAYS
`DictationHistory`: The latest dictations, newest first: at most [`LIMIT`], none older than
[`MAXIMUM_AGE_DAYS`].

#### Same words again move to top; blank text is not kept
`DictationHistory::record`: Adds a result at the top. The same words again (a retry) move to the
top instead of repeating; blank text is not kept.

#### Another key, damaged or unreadable-version file yields None
`dictation_history::open`: `None` for another key, a damaged file or one this version can't read.

#### Bad or foreign file reads empty; expired results are removed from file
`dictation_history::load`: What was saved. A missing, damaged or foreign file reads as empty, and
expired results leave the file too, not just the list.

#### Save via temp file, flush, rename so a power cut leaves one version
`dictation_history::save`: Replaces the file with `entries`; none deletes it. The new version is
written to a temporary file, flushed to the drive and renamed over the old
one, so a power cut leaves one whole version.

#### Rename reaches the drive only after the parent folder is flushed
`replace_with`: The rename reaches the drive once the folder is flushed too.

#### Reading as of an earlier time shows expired entry is gone from file
`expired_results_leave_the_file_and_an_empty_list_deletes_it`: Read as of a time when the old one was still fresh: it is gone from the file.

### `LinuxWindows/crates/lokalbot-core/src/digest.rs`

#### Journal stays lossless; presentation adds scannable hierarchy for new and legacy journals
The Day Digest journal read back for display (`DayDigestPresentation.swift`)
and its freshness (`DayDigestLifecycle.swift`).

The journal stays the lossless format; this only gives the UI a
scannable hierarchy for both new and legacy journals.

#### Empty sections and sentinels like _None._ yield None
`meaningful`: `None` for empty sections and sentinels like "_None._".

#### Rewrite 'The user did X' as 'Did X' keeping facts
`direct_voice`: "The user did X" → "Did X", keeping the journal's facts in the user's voice.

#### Must match Swift DayDigestTextSimilarity.isSimilar
`is_similar`: `DayDigestTextSimilarity.isSimilar`.

#### Next step format is 'Next — task: step'; longest matching task title wins
`next_step`: `Next — <task>: <step>`; the longest matching task title wins.

#### Parser accepts legacy layouts such as Today at a glance plus Next
`parse_digest`: Parses a journal (`DayDigestPresentation(markdown:)`), accepting legacy
layouts such as `## Today at a glance` + `## Next`.

#### Task sections ordered open work first, finished work last
`TASK_GROUP_ORDER`: Timeline's task sections in order: open work first, finished work last.

#### One-line rows shown before the Show N more fold
`BRIEF_ROW_LIMIT`: One-line rows a section shows before "Show N more".

#### Group holds indices into DayDigest::tasks in journal order
`TaskGroup`: A status section of the task list: its tasks' indices in
`DayDigest::tasks`, in journal order.

#### Mirrors DayDigestPresentation.timelineRows
`TimelineRows`: How Timeline shows a section's tasks (`DayDigestPresentation.timelineRows`).

#### Full rows show title, next step and summary
`TimelineRows::full`: Shown in full, with the title, next step and summary.

#### Brief rows are one line with summary opening on demand
`TimelineRows::brief`: Shown as one-line rows whose summary opens on demand.

#### Only task-first journals give tasks a status; older ones never do
`DayDigest::is_task_first`: Task-first journals give their tasks a status; older journals never do.

#### Next-step and blocked tasks shown full; older journals keep all full
`DayDigest::timeline_rows`: Timeline shows a section's tasks that carry a next step, and every
blocked task, in full; the rest become one-line rows, as does all of
Done. Older journals have neither statuses nor next steps, and their
summary is the only description, so all of their tasks stay in full.

#### Hiding a single row saves no room, so fold only beyond limit plus one
`folds_brief_rows`: Whether `count` one-line rows show only the first `BRIEF_ROW_LIMIT` until
asked for the rest. Hiding a single row would cost as much room as
showing it.

#### Trailing parenthetical becomes a tag; nested parens, parenthetical-only or over 32 chars gives no tag
`title_and_tag`: Splits a trailing parenthetical off a task title, such as the project in
"Review all open PRs (LokalBot)" or the pull request in "Staging
deployment (PR #487)", so it can show as a tag
(`DayDigestPresentation.titleAndTag`). Nested parentheses stay inside the
tag; a title that is only a parenthetical, or one over 32 characters, has
no tag.

#### Digest carries sidecar and freshness versus newer evidence
`Library::day_digest`: The journal for `day` parsed for display, with its sidecar and whether
newer activity, screen text or finished meetings exist than the
journal file covers (`DayDigestFreshness`).

#### Newest evidence spans activity, screen text, agent work, meetings and artifacts
`Library::latest_evidence_at`: The newest evidence for `day`: activity (clamped to the day), screen
text, coding-agent work, finished meetings' ends and their artifacts'
modification times.

#### Test guards full rows for next-step and blocked tasks
`timeline_rows_keep_next_steps_and_blockers_in_full`: Timeline gives full rows to open tasks with a next step and to blocked
tasks; the rest of a section, and all of Done, become one-line rows.

### `LinuxWindows/crates/lokalbot-core/src/due.rs`

#### Due phrases resolve deterministically; ranges to last day; weeks start Monday unlike macOS
Spoken due phrases to local calendar days (`ActionDueResolver.swift`).

Deterministic English and Serbian grammar resolved against the day the
phrase was said. It never guesses: phrases outside the grammar stay
unresolved. Ranges resolve to their last day ("next week" is the Friday
of next week, "end of Q3" is September 30).

Weeks start on Monday here (ISO), which only matters for "next \<weekday>"
said on a Sunday; macOS follows the user's locale.

#### Longest first so 'couple of' wins over shorter words
`NUMBER_WORDS`: Longest first, so "couple of" wins over shorter words.

#### Label shows resolved date with said phrase, or phrase with spoken day
`label`: "Due Fri, Oct 2 · said “Friday”", or the phrase with the day it was said.

#### Unmatched optional groups return empty strings
`captures`: Returns every capture group, with unmatched optional groups as "".

#### Sunday=1 to Saturday=7 as Foundation's Gregorian calendar
`weekday_number`: Sunday = 1 … Saturday = 7, as in Foundation's Gregorian calendar.

#### This weekday on same day is today; bare or next goes to following week
`weekday`: "This Friday" said on a Friday is that day; a bare or "next" weekday
said on the same weekday means the following week.

#### Yearless date over 31 days past rolls to next year
`month_day`: Without a year, a date well before the meeting refers to next year.

#### Friday of the week; a Saturday keeps the stated day
`end_of_work_week`: Friday of the week containing `day`; a Saturday keeps the stated day.

#### Fixture date matches Swift ActionDueResolverTests
`tests::tuesday`: Tuesday, 22 September 2026, as in `ActionDueResolverTests.swift`.

### `LinuxWindows/crates/lokalbot-core/src/embeddings.rs`

#### Vectors computed by AI layer; module chunks, stores and ranks them
Semantic search storage (`EmbeddingIndex.swift`). Vectors are computed
by the AI layer; this module chunks text, stores vectors and ranks them.

#### Must match macOS index version; other models' vectors incomparable
`MODEL_ID`: The macOS index version; vectors from another model are not comparable.

#### Pieces cut at whitespace in second half; concatenation reproduces input
`split_text`: Pieces of at most `maximum` characters, cut at whitespace in the second
half when possible; concatenating them reproduces the input.

#### Mirrors Swift transcriptChunks, summary sections and notesChunks
`embedding_chunks`: `(start seconds, text)` chunks to embed for one meeting
(`EmbeddingIndex.transcriptChunks`, summary sections, `notesChunks`).

#### RRF with k=60; ties go lexical, best rank, then key
`rrf_fuse`: Reciprocal rank fusion of a lexical and a semantic ranking (`k` = 60):
score = Σ 1/(k + rank). Ties: lexical evidence first, then the best single
rank, then the key.

#### Skip replacing if meeting deleted meanwhile or newer snapshot stored
`Library::store_meeting_embeddings`: Replaces a meeting's vectors (`chunks`: start, text, vector) unless the
meeting was deleted meanwhile or a newer snapshot is already stored.

#### Stale means newer sources or notes present on only one side
`Library::meetings_needing_embeddings`: Visible meetings whose vectors for `model_id` are missing or stale
(newer sources, or notes present on only one side).

#### Delete other models' vectors at startup
`Library::purge_embeddings_except`: Deletes vectors written by any other model (run at startup).

#### Brute-force dot product on L2-normalized vectors, strictly above floor
`Library::semantic_search`: Brute-force dot-product search over meeting chunks (vectors are
L2-normalized): `(meeting, start, text, score)` strictly above `floor`,
best first.

#### Scope filters before limit so passages aren't lost
`Library::semantic_search_in`: [`Self::semantic_search`] among `meetings` only, so a day or an evidence
boundary doesn't lose its passages to the limit.

#### Scope must filter before limit
`stores_and_ranks_vectors`: A scope filters before the limit, so it can't lose its passages.

### `LinuxWindows/crates/lokalbot-core/src/evidence.rs`

#### Evidence revision protocol withdraws overnight memory when sources change; retention bypasses it
Withdrawing overnight memory when the meetings it came from change
(`DreamStore.swift`, `DreamEvidenceMutation.swift`, `DreamModels.swift`).

`memory/evidence-revisions.json` holds a revision counter and the revision
at which each day and meeting last changed. Dream reports and work memory
record the revision they were built at, and both apps drop anything built
from a source that changed since when they read it. Under the shared
`.dream-store.lock`, a writer records the change, withdraws what depended on
it (`dream::store`), and only then changes the source.

A person deleting a source also withdraws that day's unedited generated
journal (`DayDigestLifecycle.retractGeneratedJournals`). Scheduled retention
goes through none of this: long-term memory outlives the screen window.

#### Present while macOS revocation unfinished; memory must not be used
`PENDING_FILE`: Present while a macOS revocation is unfinished; memory must not be used.

#### Swift decoder needs revision and invalidatedDays always written
`EvidenceState`: Swift's synthesized decoder needs `revision` and `invalidatedDays` present,
so both are always written.

#### Kinds are meeting, screenDay or digest
`Source.kind`: `meeting`, `screenDay` or `digest`.

#### Full meeting UUID, or day key for day-level evidence
`Source.id`: The full meeting UUID, or the day key for day-level evidence.

#### No provenance means untraceable, so first change withdraws item
`EvidenceState::invalidates`: `DreamStore.isInvalidated`: without provenance an item cannot be traced
to an unaffected source, so the first change withdraws it.

#### None while Mac revocation unfinished or state unreadable
`read_state`: The library's evidence state, or `None` while overnight memory must not be
read: a macOS revocation is unfinished, or the state is unreadable.

#### Filters out items built from changed evidence; None while blocked
`read_work_memory`: `memory/memory.json` without the items built from evidence that changed
since (`DreamMemory.retractingEvidence`), or `None` while overnight memory
must not be read.

#### Meeting UTC day plus two either side so time-zone change can't hide reports
`source_day_keys`: `DreamEvidenceInvalidation.sourceDayKeys`: each meeting's UTC day and the
two days either side, so a time-zone change can't hide a dependent report.

#### Mirrors AppState.EvidenceChange for digest handling
`EvidenceChange`: What a source write means for that day's generated digest
(`AppState.EvidenceChange`).

#### Revisions keep digest marked out of date until regenerated
`EvidenceChange::Revision`: Reprocessing, corrections, outcome edits and saved moments. The digest
stays, marked out of date, until it is regenerated.

#### Deleting source also removes unedited generated digest
`EvidenceChange::Removal`: The person deleted the source: its unedited generated digest goes too.

#### Advance state then mutate under lock; unwritable state leaves meetings unchanged
`with_meeting_mutation`: Advances the evidence state for `meetings`, then runs `mutation` while still
holding the lock (`DreamStore.withMeetingEvidenceMutation`). If the state
can't be written, the meetings are left unchanged.

#### Withdraw each day and, for meetings, following comparison windows
`dependent_reports`: The reports a change on `dates` withdraws: each day and, for meetings, the
comparison windows after it (`withSourceEvidenceMutation`).

#### Screen evidence is per-day, so leave meeting-derived facts alone
`with_screen_mutation`: Screen, activity and coding-agent evidence is read only for the day it
belongs to, so it withdraws what was built from those days and leaves
meeting-derived facts alone (`DreamStore.withScreenEvidenceMutation`).

#### Remove only still-generated journals; edited or unsigned ones are the person's
`retract_generated_journals`: Removes each day's journal while it is still the generated copy of its
evidence, with its sidecars. Edited and unsigned journals are the person's
and stay (`DayDigestLifecycle.retractGeneratedJournals`).

#### Interrupted Mac write record still says who owns journal
`journal_is_generated`: `DayDigestGenerationMetadataStore.load` and `journalMatches`, including an
interrupted Mac write, whose record still says who owns the journal.

#### Byte-identical rewrite that may not have landed keeps person's ownership
`journal_is_generated`: A rewrite of byte-identical content that may never have landed:
the person's earlier ownership wins.

#### Observers run after every source change so exports, routines and caches follow
`observe`: Runs `observer` after every source change in this process, with the
library's root and the changed dates (`AppState.primaryEvidenceDidChange`):
exports, routines and cached digest answers follow what changed.

#### flock excludes Mac and other processes; mutex covers same-process handles
`StoreLock`: The advisory lock macOS takes around every revision check and commit.
`File::lock` is `flock` on Unix, so it excludes the Mac app on a shared
folder as well as other processes here. `flock` doesn't exclude a second
handle in this process, hence the mutex too.

#### Activity-only changes leave meeting sources alone
`invalidation_follows_dream_models`: Activity-only changes leave meeting sources alone.

#### Reprocessing keeps digest, marked out of date
`deleting_a_meeting_withdraws_that_days_generated_journal_and_reprocessing_keeps_it`: Reprocessing revises the source: the digest stays, marked out of date.

#### Person-edited journal stays on deletion
`deleting_a_meeting_withdraws_that_days_generated_journal_and_reprocessing_keeps_it`: A journal the person edited is theirs and stays.

#### Byte-identical rewrite that may never have landed stays the person's
`an_interrupted_mac_write_still_counts_as_generated`: Rewriting identical bytes that may never have landed stays the person's.

### `LinuxWindows/crates/lokalbot-core/src/generated_file.rs`

#### Marker identifies generated files; only recorded hash permits replacing
The ownership contract for exports and routines (`GeneratedFileWriter.swift`).
A marker identifies a generated file; only the recorded hash grants
permission to replace it. The hash lives in a hidden sidecar beside the file.

#### Owner-only on Linux; Windows files inherit folder access
`set_private`: Owner-only on Linux, where the mode exists. On Windows a file takes the
access of the folder it's in.

#### Legacy files adopted only when bytes are identical; returns false then
`write`: Writes `data` unless the person owns what is there. Returns false when
identical bytes were already present: legacy files can be adopted only then,
without replacing their content.

### `LinuxWindows/crates/lokalbot-core/src/github_star.rs`

#### GitHub star prompt state stays local and learns nothing about starring
The one-time request on Today to star LokalBot's repository
(`GitHubStarPrompt.swift`). Everything here stays on this computer:
LokalBot keeps only whether a meeting summary has finished, which calendar
days it was used, and whether the request was answered. It sends nothing
and never learns whether anyone starred.

#### Seven distinct days of use make prompt eligible without a summary
`ACTIVE_DAYS_BEFORE_ASKING`: Distinct days of use that make the request eligible without a summary.

#### Marker written at root of every demo library including screenshot ones
`DEMO_LIBRARY_MARKER`: Written at the root of every demo library, including the screenshot ones.

#### Show after first summary or seven active days until answered
`should_show`: After the first completed meeting summary or `ACTIVE_DAYS_BEFORE_ASKING`
distinct days of use, whichever comes first, until it is answered.

#### Each day counts once and only until enough to ask
`should_record_day`: Whether `day_key` still needs counting; each day counts once, and only
until there are enough to ask.

### `LinuxWindows/crates/lokalbot-core/src/health.rs`

#### Health reads counts and timestamps only, never window text or meetings
Library health (`LibraryHealth.swift`, `LibraryHealthLoader.swift`,
`LibraryHealthReportStore.swift`): judges one day of a library the way a
person would notice a problem. Reads counts and timestamps only, never window
text or meeting content. Reports stay in `diagnostics/health`.

#### Capture skips LokalBot's own windows and lock screen by design
`UNCAPTURED_APPS`: Capture skips LokalBot's own windows and the lock screen by design.

#### Transcripts read for finished recordings of last seven days
`RECORDINGS_WINDOW_DAYS`: Reads transcripts for finished recordings of the last week.

#### Must match DayDigestGenerationMetadataStore.maximumDegradedAttempts
`MAXIMUM_DEGRADED_ATTEMPTS`: `DayDigestGenerationMetadataStore.maximumDegradedAttempts`.

#### Recordings under 5 s hold no speech worth a model run
`MINIMUM_RECORDING_SECONDS`: Shorter recordings hold no speech worth a model run.

#### Merged source under 30 s may legitimately have no segments
`MINIMUM_GAP_SECONDS`: A merged source shorter than this may legitimately have no segments.

#### Fields in sorted-key order so JSON matches the Mac encoder
`HealthFinding`: Fields are in sorted-key order, so the JSON reads as the Mac's
`.sortedKeys` encoder writes it.

#### Past day is final once journal written after next day starts
`PastDay::needs_finalization`: A past day with evidence is final once its journal was written at or
after the start of the following day (`DayDigestScheduler.needsFinalization`).

#### Yesterday relative to now as the digest scheduler sees it
`SchedulerHealth.previous_day`: Yesterday relative to `now`, as the digest scheduler sees it.

#### Counts undreamed eligible days in catch-up window through yesterday
`SchedulerHealth.missing_dream_days`: Undreamed eligible days in the catch-up window through yesterday.

#### Private share of earlier active days in the last week
`HealthInput.private_share_history`: Private share of each earlier day in the last week that had activity.

#### Off means app never auto-repairs missing transcripts
`HealthInput.automatic_transcription`: Off means the app never repairs a missing transcript on its own.

#### Avoid sum: empty float sum is -0.0 and prints as -0.0 h
`total`: Not `sum`: an empty float sum is -0.0, which would read as "-0.0 h".

#### Marker written before repair so empty spans aren't retranscribed each launch
`mark_gap_repair_requested`: Written before a merged-gap repair is queued, so a span that stays empty
(silence, for example) isn't transcribed again on every launch.

#### Completed means journal finished; None while it needs repair
`digest_completed_at`: `DayDigestGenerationMetadataStore.completedAt`: when the day's journal was
finished, or `None` while it still needs a repair.

#### Unapproved remote model is not a scheduler problem
`schedulers_are_judged_after_their_grace_period test`: A remote model nobody approved isn't a scheduler problem.

### `LinuxWindows/crates/lokalbot-core/src/ids.rs`

#### FNV-1a 64 gives stable outcome, thread and person IDs matching the Mac
`fnv1a64`: FNV-1a 64-bit, as used for stable outcome, thread and person IDs.

#### Hex form is %016llx of fnv1a64, matching the Mac
`fnv_hex`: `%016llx` of [`fnv1a64`].

#### CLI short meeting ID is first 8 lowercase hex characters
`short_id`: The CLI's short meeting ID: the first 8 lowercase hex characters.

#### Uppercase hyphenated UUID to match Swift uuidString
`uuid_upper`: Uppercase hyphenated form, matching Swift's `UUID.uuidString`.

#### Folder slug rules match StorageManager.slugify
`slugify`: Folder slug: lowercase, diacritics stripped, every non-alphanumeric run
becomes one `-`, trimmed at both ends (`StorageManager.slugify`).

#### Uuid fields serialize uppercase to match macOS JSON
`uuid_upper_serde`: Uppercase serialization for `Uuid` fields, matching the macOS JSON.

### `LinuxWindows/crates/lokalbot-core/src/import.rs`

#### Imported audio is the system track; phone recordings become mic track
Turning an audio or video file into a meeting (`MeetingImportService.swift`).

The file's audio becomes the meeting's system track, so it is separated
into speakers like call audio. The original file is only read. Decoding
happens in `lokalbot-audio`; these are the rules around it. A recording from
a paired phone or tablet becomes the microphone track instead; see
`import_device_recording` in `lokalbot-engine`.

#### Shown where a recorded meeting shows its meeting app
`IMPORTED_APP_NAME`: Shown where a recorded meeting shows its meeting app.

#### Offered types; readability is only known after decoding
`IMPORTABLE_EXTENSIONS`: File types the import dialog offers and a drop accepts. Whether the audio
in one can actually be read is only known once it is decoded.

#### Start guess: recorder metadata, then earlier file date; pre-2001 ignored; never future
`recording_start`: Best guess at when the recording began, never so late that it would end
in the future (`MeetingImportService.recordingStart`). A recorder's own
creation date names the start. File dates are weaker: modification usually
marks when recording stopped and survives a copy, while a copy's creation
date is when it was copied, so the earlier reading wins. Dates before 2001
are unset container fields, not recordings.

### `LinuxWindows/crates/lokalbot-core/src/jobs.rs`

#### attempts counts starts so crashing meetings can't loop on launch
The durable post-meeting processing queue (`PipelineJobStore.swift`):
a row per job, deleted on success; `attempts` counts starts so a meeting
that crashes processing cannot loop forever on launch.

#### Launch auto-resume gives up after three starts
`MAX_AUTO_RESUME_ATTEMPTS`: Launch auto-resume gives up after this many starts.

#### True only after the job committed its transcript
`PipelineJob.transcription_completed`: True only after this job committed its transcript.

#### Automatic jobs summarize only while automatic summaries are on
`PipelineJob.summary_follows_setting`: An automatic job: its summary runs only while automatic summaries are
on (`ProcessingPipeline.resumedWork`). False for an explicit request.

#### Old rows get Mac defaults: summary follows setting, transcription reruns
`migrate`: Adds the columns older builds' `pipeline_jobs` lacked, with the Mac's
defaults (`PipelineJobStore`): an old row has no provenance, so its
summary follows the current setting, and it cannot prove it committed the
transcript on disk, so transcription runs again.

#### User enqueue resets attempts; automatic keeps count and follows setting
`Library::enqueue_job`: Records a job. A user-initiated enqueue is a deliberate retry: it
resets `attempts` and the last error. An automatic one keeps the
attempt count of an existing row and lets the summary follow the
current setting when the job is restored.

#### Each start burns one attempt
`Library::mark_job_started`: Burns one attempt as processing starts.

#### Test uses the 0.6.2 pipeline_jobs table lacking three columns
`older_queue_tables_gain_the_missing_columns test`: The 0.6.2 table: no last_error, transcription_completed or
summary_follows_setting.

#### Migration must be idempotent on reopening
`older_queue_tables_gain_the_missing_columns test`: Opening again must not try to add the columns a second time.

### `LinuxWindows/crates/lokalbot-core/src/lib.rs`

#### On-disk format follows macOS; libraries readable by both; audio track extensions differ
LokalBot's local library for Linux and Windows.

The on-disk format follows the macOS app (`LokalBot/Services/Storage/StorageManager.swift`):
one folder per meeting with `meta.json`, `transcript.json`, `summary.md`,
`outcomes.json` and friends, plus `lokalbotv3.sqlite` for search indexes,
activity blocks and screen context. A library written by either app can be
read by the other; audio tracks are the one difference (`mic.wav`/`system.wav`
here, `mic.m4a`/`system.m4a` on macOS), and each app reads the other's.

### `LinuxWindows/crates/lokalbot-core/src/library.rs`

#### Library methods are synchronous; UI must not call whole-library ops on main thread
The library handle shared by the app, engine and CLI.

Files follow the macOS layout. Every method is synchronous and cheap enough
to call from a background task; the UI must not call them on its main
thread for whole-library operations (lists, search, rebuilds).

#### SQLite schema is shared with the macOS app
`SCHEMA`: SQLite schema shared with the macOS app (`SearchIndex.swift`,
`ActivityTracker.swift`, `EmbeddingIndex.swift`, `PipelineJobStore.swift`).

#### Chat key is set once the engine installs its source
`Inner.chat_keys`: The `chat-key`, once the engine has installed its source.

#### Unsaveable conversations kept in memory for this run
`Inner.unsaved_chats`: Conversations that couldn't be saved, kept for this run.

#### Owner-only 0700 root also repairs older world-readable libraries
`Library::open`: Owner-only (0700 on Unix), which also repairs an older library
whose files were created world-readable under the usual umask.

#### Missing database tolerated so file-based reads still work
`Library::open_read_only`: Opens an existing library for reading only (CLI, MCP). Missing database
files are tolerated: file-based reads still work.

#### Merge markers resolved as on macOS; writable libraries save repairs
`Library::list_meetings`: Every visible meeting (merged sources hidden), newest first.

Merge markers are resolved as on macOS (`StorageManager.loadAllMeetings`):
a merged meeting's source list covers a source marker an interrupted
merge never wrote, and a source whose merged meeting is gone is shown
again. A writable library saves those repairs.

#### Keep old marker on repair failure: it is the retry journal
`Library::list_meetings`: Keep the old marker: it is the journal a later load retries.

#### Restore order: tombstone merged, untombstone source, clear marker last
`Library::restore_merged_source`: Makes a merge source visible again once its merged meeting is gone
(`StorageManager.restoreMergedSource`): the merged meeting is
tombstoned, the source's tombstone removed so it is indexed again, and
the marker cleared last.

#### Trim keeps segments in range, notes move aside, audio untouched
`Library::set_meeting_boundaries`: Keeps only `range` of a finished meeting (`AppState.setMeetingBoundaries`):
the transcript keeps the segments inside it, generated notes move aside
to `*.previous.*` until they are written again, and the raw audio stays
as recorded. The caller re-indexes and queues transcription and notes.

#### Withdraw evidence from old range even when no segment survives
`Library::set_meeting_boundaries`: Withdraw what was built from the old range even when no segment survives.

#### Own meetings exclude the sample; digests, people, projects use them
`Library::list_own_meetings`: The user's own meetings, newest first: every visible meeting except the
sample. Digests, the day, people, projects and action lists use these.

#### Reference is latest, full UUID, or unique short-id prefix
`Library::find_meeting`: `latest`, a full UUID, or a unique short-id prefix.

#### Scan ignores folder until meta.json written, so write it last
`Library::reserve_meeting_folder`: Creates an empty `meetings/YYYY/MM/DD-<slug>[-N]` folder and returns
its relative path. A library scan ignores it until `meta.json` is
written, so imports and merges write that last.

#### Create parents outside the match: file-as-parent also gives AlreadyExists
`Library::reserve_meeting_folder`: Outside the match: a file where a parent folder belongs also says
AlreadyExists, and no other name gets past that.

#### Delete sources first so interrupted deletes retry safely
`Library::delete_meeting`: Deletes a meeting and, for a merged meeting, the sources folded into it
(`StorageManager.deletionOrder`): sources go first, so an interrupted
delete leaves the survivors folded and a retry skips what is gone.
Overnight memory built from them is withdrawn first.

#### Non-reciprocal source or a cycle means corrupt markers
`Library::deletion_order`: Descendants before their merged meeting. A source that doesn't point
back at its merged meeting, or a cycle, means the markers are corrupt.

#### Tombstone removes from search, meaning search and queue
`Library::tombstone_meetings`: Takes meetings out of search, meaning search and the processing queue,
with a tombstone, as deleting or folding them into a merge does.

#### Withdraw overnight memory built from the old transcript first
`Library::save_transcript`: Writes `transcript.json` and the matching `transcript.md`, withdrawing
overnight memory built from the old transcript first.

#### Changed transcript moves old summary, claims, outcomes to previous
`Library::save_new_transcript`: Saves a fresh transcription (`ProcessingPipeline.write`). When it
differs from the saved transcript, the summary, claims and outcomes
written from the old one move aside to `*.previous.*` first, so they
are not shown, searched or asked about as current until notes are
written again.

#### Port can't reproduce Swift JSON bytes so treats outcomes as current
`Library::outcomes`: Extracted outcomes in display order (`MeetingOutcomes.load`).

macOS treats outcomes whose `transcriptRevision` no longer matches the
transcript's SHA-256 (over Swift's exact JSON bytes) as stale. This
port cannot reproduce those bytes, so it treats outcomes as current;
its own new transcriptions move them aside instead
([`Self::save_new_transcript`]).

#### Status and corrections count as evidence
`Library::save_outcome_state`: Status and corrections are evidence too (`OutcomeIndex.mutateEvidence`).

#### Journal written before sidecar; empty digest and modified time filled in
`Library::save_digest`: Writes the journal and its sidecar (journal first, as on macOS). An
empty `journal_digest` and a missing `journal_modified_at` are filled
in from the written journal.

#### Marker present while generated notes predate the transcript
`REFRESH_MARKER`: Present while generated notes predate the transcript (`MeetingAttributionArtifacts`).

#### Notes move to previous names, refresh marker written, unfinished notes dropped
`invalidate_generated_notes`: `MeetingAttributionArtifacts.invalidate`: summary, claims and outcomes
move to their `*.previous.*` names, the refresh marker is written and
unfinished notes are dropped.

#### Source marker holds only while merged meeting lists it; last uppercase ID wins
`resolve_merge_relationships`: `Meeting.resolvingMergeRelationships`: the merged meeting each meeting is
folded into, in the same order. A source marker holds only while its
merged meeting still lists it; otherwise whichever merged meeting lists it
(the last by uppercase ID, as on macOS) wins, or none.

#### Pretty-printed sorted keys to match the macOS encoder
`write_json`: Pretty-printed with sorted keys, like the macOS encoder.

#### Temp files created owner-only for transcripts, notes and settings
`write_atomic`: Transcripts, notes and settings are readable by their owner only.

#### File in place of folder yields AlreadyExists forever; thread avoids hang
`a_file_where_a_month_folder_belongs_is_an_error test`: That says AlreadyExists, like a taken name, and trying more names never
ended. On its own thread so this fails instead of hanging the test run.

#### Older build libraries created under umask 022 get repaired
`library_files_are_private_to_their_owner test`: A library from an older build, created under umask 022.

#### macOS Undo or crash removes merged meeting first
`merge_sources_come_back_when_their_merged_meeting_is_gone test`: macOS Undo, or a crash part-way through it, removes the merged meeting first.

### `LinuxWindows/crates/lokalbot-core/src/meeting_review.rs`

#### Holds notes a transcript change moved aside
`PREVIOUS_OUTCOMES_FILE`: `outcomes.previous.json`: the notes a transcript change moved aside.

#### Transfer edits only on unambiguous two-way match with compatible evidence
`reconcile_state`: Carries user-owned state across a safe re-extraction. A transfer requires
an unambiguous match in both directions and compatible source evidence;
unmatched edits stay available for review.

#### Without a saved request, a finished transcript is never overwritten
`retry_work`: What a retry should run. With no saved request a finished transcript is
never overwritten; the Process menu stays there for a deliberate redo.

#### Moved-aside actions shown for review until new notes exist
`Library::previous_outcome_projection`: The actions a refresh moved aside, shown for review until new notes
exist (`MeetingOutcomeProjection.load(includingPrevious:)`).

#### Keys the Mac decoder requires are always written
`RecordingHealthReport`: `recording-health.json`, written while recording and read for the warning
on the meeting's page. Keys the Mac's decoder requires are always written.

#### Fewer than five dropped buffers are unnoticeable
`RecordingHealthReport::NOTICEABLE_DROPPED_BUFFERS`: Fewer than this are isolated callbacks no listener would notice.

#### History bounded at 1,000 events, first failure kept
`RecordingHealthReport::observe`: Records a change of warnings, keeping the history bounded but its first
failure. Returns whether anything changed.

#### Missing audio must persist 15 s before notifying
`SUSTAINED_AUDIO_WARNING_SECONDS`: Audio that stops arriving must persist this long before it notifies.

#### Nearly full volume risks truncated tracks; 1 GB floor
`RECORDING_FLOOR_BYTES`: Recording onto a nearly full volume risks truncated tracks.

#### Warn when audio is 60 s short and under 80% of session
`MISSING_AUDIO_SECONDS`: A session this much longer than its audio is worth saying so, as long as
the audio is also well under its length (`stop`).

#### Refuse recording up front on low disk rather than lose meeting mid-way
`recording_advisory`: Why a recording can't start on this volume, when the system can say
(`DiskSpacePrecheck.recordingAdvisory`). A recording that dies mid-meeting
loses the meeting; a clear refusal doesn't.

#### Match Mac ByteCountFormatter: decimal units, whole KB/MB, two decimals from GB
`byte_count`: A file size as the Mac's `ByteCountFormatter` writes it: decimal units,
whole KB and MB, up to two decimals from GB on.

#### Notify only for lasting conditions because notifications interrupt calls
`CaptureWarningNotifications`: When a live capture warning also becomes a notification. The meeting view
shows every warning as it happens; a notification interrupts the call, so
it is kept for conditions that lasted long enough to matter.

#### None until first system audio arrives
`CaptureObservation.system_age`: Seconds since system audio reached the writer; `None` before the first.

#### Quiet loopback delivers nothing while nothing plays, which is fine
`CaptureObservation.system_quiet_is_normal`: A quiet loopback delivers nothing while nothing plays, and that is fine.

#### Non-optional Swift fields are required when the Mac decodes
`reads_and_writes_the_macs_health_report test`: Non-optional Swift fields are required when the Mac decodes.

#### Quiet Windows loopback delivers nothing while nothing plays
`capture_warnings_follow_what_arrives test`: A quiet Windows loopback delivers nothing while nothing plays.

### `LinuxWindows/crates/lokalbot-core/src/meeting_screen.rs`

#### Meeting screen context uses retained rows only, never pixels or captured text
What was on screen while a meeting recorded, aligned to its audio
(`MeetingScreenContext.swift`). Built only from retained screen rows
(titles, document names, URLs and times); pixels and captured text are not
read here. Captures expire with screen retention, so this can shrink.

#### Cap materials at 12 because long calls touch dozens of windows
`MAXIMUM_MATERIALS`: A long call can touch dozens of windows; these are kept.

#### Query-chosen pages get no link because stored addresses drop the query
`QUERY_ROUTED_HOSTS`: Pages chosen by their query get no link: stored addresses drop it.

#### Offset is seconds from the start of the meeting's audio
`Moment.offset`: Seconds from the start of the meeting's audio.

#### End offset is when the next stretch began, or recording end
`Moment.end_offset`: When the next stretch began, or the end of the recording.

#### Site comes from browser tab title, else the web page host
`Moment.site`: The site named in a browser tab's title, else a web page's host.

#### is_call means the call's own app window or conference tab was in front
`Moment.is_call`: The call itself (its app window or conference tab) was in front.

#### Materials are distinct documents referenced during the call, in order of first appearance
`Material`: A distinct document, page or window referenced during the call, in order
of first appearance.

#### On-screen time is approximate: capture to next change
`Material.seconds_on_screen`: Approximate time in front, from capture to the next change.

#### page_url is set only when the stored address can reopen the page
`Material.page_url`: A web address that reopens this page, when the stored one can.

#### Moments include the call's own window, in order
`MeetingScreenContext.moments`: Every stretch in order, including the call's own window.

#### Only window and document titles feed notes, never captured text
`MeetingScreenContext.material_titles`: Window and document titles for use as secondary context in notes,
never the captured text itself.

#### Browser document name is a URL fragment, so non-browser apps only use it
`page_for`: A browser's document name is the last piece of the page's URL, not
something the user would recognize.

#### Drop account addresses and unread counts so revisits group together
`splitting_site`: "Weekly sync - you@example.com - Gmail" reads as the page "Weekly sync" on
"Gmail". Account addresses and unread counts are dropped so revisits of
one page group together.

#### No link rather than one that opens the wrong page when query is dropped
`reopenable_url`: Stored addresses drop their query and fragment, so a page chosen by either
gets no link rather than one that opens the wrong page.

#### The call itself is not material the user referenced
`is_call_window`: The call itself is not material the user referenced.

#### Captures can lack tab URL; camera/mic tabs and Meet tabs count as the call
`is_call_window`: Captures can lack the tab's URL. A tab using the camera or
microphone during the meeting is the call, and so is a Meet tab.

#### Includes the meeting's rows and unlinked ones around it; Swift twin
`Library::meeting_screenshots`: This meeting's rows and the unlinked ones around it
(`ActivityStore.screenshots(forMeeting:from:to:)`).

#### Imported files have no on-screen context because they were not played here
`Library::meeting_screen_context`: The on-screen context of a meeting. An imported file was not played on
this computer, so its time on the clock means nothing here.

#### Test: damaged meta.json can hold a length no calendar date can hold
`an_impossible_recorded_length_does_not_panic`: A damaged `meta.json` can carry a length no calendar date can hold.

#### Test: revisits add up and repeat row counts as one stretch
`material_is_what_was_shown_besides_the_call`: 60→180 and 300→400; revisits add up and the repeat row was one stretch.

### `LinuxWindows/crates/lokalbot-core/src/merge.rs`

#### Merge keeps sources untouched except an Undo marker; speaker keys source-prefixed
Merging finished meetings into one (`MeetingMergeService.swift`).

The merged meeting is the selected part of each source laid end to end.
Source folders are never changed beyond a marker that folds them into the
merged meeting, so Undo can bring them back. Speaker keys are prefixed with
their source, so "Me" in one recording can't claim a voice in another.

#### Shown where a recorded meeting shows its meeting app
`MERGED_APP_NAME`: Shown where a recorded meeting shows its meeting app.

#### Slice semantics: source range padded with silence when track is shorter
`Slice`: One source track's part of the merged timeline: `source` (when it has
that track) from `start` to `end` seconds, padded with silence to
`end - start` when the track is shorter.

#### Splice returns which slices contributed; writes nothing when none did
`Splice`: Writes one merged track from `slices`, in order, and returns which slices
contributed audio. Nothing is written when none did.

#### False coverage means a requested summary must transcribe merged audio first
`MergeResult.transcript_coverage_complete`: False when a source part contributed no transcript; a requested
summary must then transcribe the merged audio first.

#### Manifest version 2 field; older manifests stay readable without claiming coverage
`ManifestSource.has_audio`: Version 2. Older manifests stay readable without claiming coverage.

#### On failure sources stay unfolded and the half-made meeting is removed
`merge_meetings`: Builds the merged meeting. On any failure the sources are left unfolded
and the half-made meeting is removed.

#### Merge of imported sources stays imported so screen context ignores its span
`build`: Screen context reads this marker: an imported source's span shows
unrelated screen activity, so the merge stays imported.

#### Segments are shifted onto merged timeline with source-scoped speakers
`merged_transcript`: The sources' segments inside their ranges, shifted onto the merged
timeline, with source-scoped speakers. Also returns which sources had any.

#### Merged meeting removed first; failed source restores retry on next library load
`undo_merge`: Removes a merged meeting and restores its sources (`AppState.undoMerge`).
The merged meeting goes first; a source whose restore fails keeps its
marker, and the next library load restores it.

#### Delete merged meeting without its source ids because sources are restored
`undo_merge`: Deleting the merged meeting alone: its sources are about to come back.

#### Re-transcribing keeps earlier text for sources that had text but no audio
`preserve_transcript_only_sources`: Re-transcribing a merged meeting covers only sources that had audio.
Keeps the earlier transcript in the parts of sources that had text but
no audio, which would otherwise come back silent
(`MeetingMergeService.preservingTranscriptOnlySources`).

### `LinuxWindows/crates/lokalbot-core/src/paths.rs`

#### Env var redirects app and CLI to another library, as macOS libraryRoot
`STORAGE_ROOT_ENV`: Environment variable that points the app and CLI at another library, as on
macOS (`AppDirectories.libraryRoot`).

#### One LibraryPaths is shared by app, engine and CLI; built via resolve
`LibraryPaths`: Every path the app, engine and CLI share. Construct once with
[`LibraryPaths::resolve`] (or [`LibraryPaths::new`] in tests).

#### Library root order: explicit, env var, then per-OS data directory
`LibraryPaths::resolve`: The library root: an explicit override, then `LOKALBOT_STORAGE_ROOT`,
then `%LOCALAPPDATA%\LokalBot` on Windows or `$XDG_DATA_HOME/LokalBot`
(`~/.local/share/LokalBot`) on Linux.

### `LinuxWindows/crates/lokalbot-core/src/projects.rs`

#### Project matching is deterministic word matching; no model decides membership
Projects: tracked projects and recurring topics joined to meetings,
actions, decisions, people and window time (`ProjectLinks.swift`,
`ProjectTopicDetector.swift`). Matching is deterministic word matching on
the project's names; no model decides what belongs to a project.

#### Identifying terms: 3+ characters and not generic words
`significant_terms`: Words of a project name that can identify it: 3+ characters, not generic.

#### A name matches only when all its terms are whole words
`matches_words`: Any one of a project's names matches when all its terms are whole words.

#### Topics are proper nouns recurring across three or more meetings
`detect_topics`: Proper nouns that recur across three or more meetings.

#### People and projects are built together since each refers to the other
`build_people_and_projects`: People (with notes and project links) and projects, built together
because each refers to the other.

#### Paired-device sharing reaches no further than the meetings it may see
`build_people_and_projects_from`: The same, from only these meetings: what is shared with a paired device
reaches no further than the meetings it may see.

#### Work memory read through evidence check; changed-source projects vanish
`build_people_and_projects_from`: Through the evidence check: a project whose source changed is gone.

#### People notes and project links mirror WorkMemoryConnections on macOS
`build_people_and_projects_from`: People's recent notes and project links (`WorkMemoryConnections`).

#### Summaries use tracked:UUID profile ids and local YYYY-MM-DD dates
`Library::project_summaries`: Saved "Where it stands" notes, with profile ids (`tracked:<UUID>`) and
local `YYYY-MM-DD` meeting dates.

#### Note dropped when project untracked or merged, as ProjectStore.removeSummary
`Library::remove_project_summary`: Drops a project's note when it stops being tracked or is merged away
(`ProjectStore.removeSummary`).

#### macOS decodes the file whole, so untracked-project notes are left out
`write_project_summaries`: Writes `projects/summaries.json` the way macOS reads it (`ProjectStore`):
a bare project UUID and ISO-8601 meeting dates. macOS decodes the file as
a whole, so a note that is not for a tracked project is left out.

### `LinuxWindows/crates/lokalbot-core/src/remote_transcription.rs`

#### Audio leaves only for approved origins; loopback free; HTTP only private networks
A speech-to-text server the user configures, speaking OpenAI's
`/audio/transcriptions` API (`RemoteTranscriptionConfiguration`). Audio leaves
this computer only for an origin approved for transcription; loopback needs
no approval, and plain HTTP is accepted only on the user's own network or
tailnet. The approvals are separate from Think's: approving a Think server
never sends it audio.

#### transcriptionModel raw value for remote server matches the Mac
`MODEL_ID`: `transcriptionModel` when audio goes to a server (the Mac's raw value).

#### Only models verified for word times get verbose_json; whisper-large-v3 excluded
`WORD_TIMING_MODELS`: Models checked to return word times for `response_format=verbose_json` with
`timestamp_granularities[]=word`, by origin (`wordTimingModels`). Other servers
keep plain `json`: several reject those fields. On OpenRouter, 2026-10-19, these
placed every speaker turn within 0.25 s of its onset in 30 s windows, whichever
provider served them. whisper-large-v3 is left out: one of its providers stretched
a word across the pause before the next speaker.

#### Words are clip-relative; empty when server gave no word times
`WindowTranscription`: One clip's reply (`WindowTranscription`). `words` are relative to the clip; empty
when the server returned no usable word times.

#### Server-timed words let windows span speaker turns
`RemoteTranscription::requests_word_timings`: The server times words itself, so its windows can span speaker turns.

#### Word-timing rejection is remembered per server and model
`RemoteTranscription::word_timing_key`: Remembers a rejection of the word-timing fields per server and model.

#### Base URLs get /audio/transcriptions appended; named endpoints and /inference kept
`RemoteTranscription::endpoint`: The request URL. A base such as `https://api.openai.com/v1` gets
`/audio/transcriptions` appended; a URL that already names that
endpoint, or whisper.cpp's default `/inference`, is used as is.

#### Readiness treats an allowed server as the model being on disk
`RemoteTranscription::is_ready`: Configured and allowed to receive audio. Readiness treats this as the
model being "on disk".

#### Engine string in transcript.json never includes credentials
`RemoteTranscription::transcript_engine`: Recorded in `transcript.json`. Never includes credentials.

#### None for local models, local servers or servers not yet allowed
`audio_destination`: The host audio goes to now (`transcriptionPresentation`): `None` for a model
on this computer, a server on this computer or one not allowed to receive
audio yet.

#### Think key reused only for same origin; never sent to another origin
`request_key`: The key sent with requests: the server's own key, or, when none is saved
and the server is the same origin as Think's OpenAI-compatible connection,
that connection's key, so one OpenAI or OpenRouter key serves both. Never
sent to another origin.

#### whisper-large-v3 provider stretched a word across a pause
`only_models_checked_to_time_words_are_asked_for_them`: One of its providers stretched a word across a pause.

### `LinuxWindows/crates/lokalbot-core/src/retention.rs`

#### Retention deletes pixels and text past cutoff; passes delete only reviewed items
Screen and activity retention (`ScreenshotService.performRetentionPrune`,
`ActivityStore.retentionReview`, `clearRetainedText`), and the reviews a
person sees before anything is deleted (`RetentionReview.swift`,
`CaptureDeletionReview.swift`).

Older than the cutoff and not saved: pixels are deleted; unless text is
kept forever, screen text, vectors, window titles, URLs, document names
and coding-agent sessions are removed. Activity window titles are always
cleared; app names and durations stay. Meetings are never touched.

A pass deletes only what its own review listed, so a broad cutoff can never
remove evidence nobody looked at.

#### Failed cleanups stay listed and are retried
`RetentionReport.failures`: What could not be cleaned up; it stays listed and is retried.

#### Stored times let clearing match exactly the reviewed row
`RetentionActivityTitle`: An activity block whose window title a review would clear. Its times are
the stored values, so clearing it matches exactly the row that was reviewed.

#### Counts equal exactly what applying removes; building changes nothing
`RetentionReview`: The counts behind "Review expired context…": exactly what applying it
removes. Building one changes nothing.

#### Agent requests and reports are text and expire with screen text
`RetentionReview.coding_agent_bursts`: Agent requests and reports are text, so they expire with screen text.

#### One date per local and UTC day pair, avoiding a date per row
`RetentionReview::distinct_evidence_days`: Evidence dates reduced to one per distinct pair of local day and UTC
day, sorted. Consumers key only on those days; a pass after a long gap
would otherwise hand them a date per row.

#### A review may shrink safely; growth or changed paths need fresh review
`RetentionReview::covers`: A disappearing file or newly saved moment may shrink a review safely.
Additional data, changed paths or new text require a fresh review.

#### Orphans use own timestamps and exact row identities, no broad cutoff
`OrphanedEvidence`: Text and vectors whose capture row is gone. Their own timestamps establish
the evidence day, and exact row identities mean a pass never needs a broad
cutoff (`ActivityStore.OrphanedScreenEvidence`).

#### Dry run; measuring_bytes stats every candidate file for space recovered
`Library::retention_review`: The dry run: what a retention window of `days` removes as of `now`.
`measuring_bytes` stats every candidate file for "space recovered".

#### A read-only library may predate these tables
`Library::retention_review`: A read-only library may predate these tables.

#### Window titles expire even with keep-text; app names and durations remain
`Library::retention_review`: App names and durations remain useful aggregate history. Window
titles are content and expire even with the text exception.

#### Agent requests and reports follow the text rule
`Library::retention_review`: Agent requests and reports are text: they follow the text rule.

#### Reviewed cleanup counts as user deletion; stale scope deletes nothing
`Library::apply_retention_review`: Runs a reviewed cleanup (`ScreenshotService.applyRetentionReview`). It
counts as the person deleting the source: dependent overnight memory and
unedited generated journals go first. A review that no longer covers
what is there fails with [`RetentionReviewError::ScopeChanged`] and
nothing is deleted. The caller sets the new policy once this returns.

#### Scheduled retention keeps digests and overnight memory, since nobody deleted evidence
`Library::apply_retention`: Applies the retention window of `settings` as of `now`. Scheduled
retention expires evidence on its own clock; nobody deleted or
corrected it, so day digests and overnight memory stay
(`AppState.withScheduledRetention`).

#### Establish exact sources first; a failed read must never look empty
`Library::apply_retention`: Establish the exact sources before removing anything. A failed read
must never look empty.

#### Re-read saved moments before irreversible steps; failed files keep references
`Library::execute_retention`: Removes exactly what `review` lists, re-reading saved moments right
before the irreversible file steps. A file that can't be removed keeps
its reference, so the cleanup can be retried.

#### FTS5 cannot index snapshot_id, so rowids come via metadata index in chunks
`Library::clear_retained_text`: Bookmark-aware at execution time (`ActivityStore.clearRetainedText`).
FTS5 can't index its unindexed `snapshot_id`, so the exact rowids come
through the metadata index, in bounded chunks.

#### Recheck orphans before deletion since new screenshots can revive them
`Library::clear_orphaned_evidence`: New screenshots and bookmarks can make a reviewed orphan live again, so
each is checked once more before it goes.

#### Saved moments excluded unless chosen; failed read is an error, not empty
`Library::capture_deletion_review`: The dry run for "Delete Captures in a Time Range…": every moment in
`[start, end)`, saved ones left out unless they were chosen. A failed
read is an error, never an empty scope.

#### Delete moment by moment for consistency; newly saved moments stay
`Library::apply_capture_deletion_review`: Deletes a reviewed range one moment at a time, so successful deletions
stay consistent even if another fails, and returns what failed
(`ScreenshotService.applyCaptureDeletionReview`). A moment saved since
the review stays unless saved moments were chosen.

#### Picture vectors are removed before the path, since made from those pixels
`clear_pixels`: Removes the file, then every reference to it. Each picture vector goes
before its path: it was made from these pixels and must not outlive them
(`ActivityStore.clearScreenshotPath`).

#### Test table mirrors the one macOS creates for picture vectors
`mac_image_vectors`: The table a Mac creates for picture vectors (`ScreenImageEmbeddings`).

#### Scheduled retention keeps digest and overnight memory
`a_reviewed_cleanup_retracts_journals_but_a_scheduled_pass_does_not`: Retention expires evidence; the digest and overnight memory stay.

### `LinuxWindows/crates/lokalbot-core/src/routines.rs`

#### Crashed running rows are not success so the scheduler retries after launch
The audit trail for every routine attempt (`MemoryRoutineRunStore`). A
`running` row left by a crash is intentionally not success, so the scheduler
can retry it after the next launch instead of silently losing a due output.

#### Stored raw values are shared with the Mac
`MemoryRoutineKind::raw_value`: The stored raw value, shared with the Mac.

#### Scheduled tokens end on success or failure; stale running rows stay retryable
`Library::routine_has_finished`: A scheduled token is terminal after either success or failure, so a bad
destination or malformed source never becomes a tight retry loop. Manual
runs use unique tokens and stay available. A stale `running` row is
deliberately not terminal, so launch recovery can retry.

#### Only latest revision reused so a reverted correction runs again
`Library::routine_revision_token`: Reuses only the latest revision in this scope. A correction can be
reverted (A -> B -> A), so an older success for A must not suppress it.

#### Kinds written by a newer app stay out of the list
`Library::routine_runs`: A kind a newer app wrote stays out of this list.

### `LinuxWindows/crates/lokalbot-core/src/screen.rs`

#### Frames are AES-256-GCM sealed files with per-install key, Mac-incompatible
Writing screen context: capture rows (`ActivityStore.insertScreenshot`,
`deleteScreenshots`), the perceptual hash that groups near-identical
frames (`ScreenPerceptualHash`), and the encrypted image files
(`ScreenshotService.captureFileURL`, `encryptionKey`).

\# Image files

Each kept frame is `activity/<YYYY-MM-DD>/shots/<epoch ms>-<uuid>.jpg.enc`
under the library root, with the day in UTC as on macOS. The file is a
JPEG sealed with AES-256-GCM and no associated data, laid out as
`nonce (12 bytes) ‖ ciphertext ‖ tag (16 bytes)`: the layout of CryptoKit's
`AES.GCM.SealedBox.combined`, which the Mac app uses for its `.heic.enc`
files. The 32-byte key is created once per install and kept in the system
credential store (account `screenshot-key`), never in the library. A Mac
keeps its own key in its Keychain, so frames captured there cannot be
opened here (and the other way round); their text is unaffected.

The `screenshots.path` column holds the file's absolute path, as macOS
writes it, or is empty for text-only moments and after the pixels expire.

#### Frames written here use .jpg.enc where macOS uses .heic.enc
`IMAGE_FILE_SUFFIX`: File suffix of frames written here (`.heic.enc` on macOS).

#### Hashes within 6 bits belong to one scene, matching Swift threshold
`NEAR_DUPLICATE_DISTANCE`: Automatic captures whose perceptual hashes differ in at most this many
bits belong to one scene (`ScreenPerceptualHash.defaultDistanceThreshold`).

#### Wrong key, truncation or changed byte fails authentication
`open_image`: Opens bytes written by [`seal_image`]. Any other key, a truncated file
or a changed byte fails authentication.

#### Frame path layout mirrors ScreenshotService.captureFileURL on macOS
`capture_file_path`: Where a frame taken at `ts` is stored (`ScreenshotService.captureFileURL`).

#### Foreign absolute paths are re-rooted under this library's activity folder
`resolve_capture_path`: The file behind a stored `screenshots.path`, inside `root`. Paths written
on another computer (an absolute Mac or Windows path) are found again
under this library's own `activity` folder. `None` for text-only moments
and for anything that would leave the library.

#### 9x8 difference hash stable across cursor blinks, matching ScreenPerceptualHash
`perceptual_hash`: 64-bit difference hash of a 9×8 grayscale reduction (`ScreenPerceptualHash`).
It stays stable across cursor blinks and small animations, so frames of
one scene share a similarity group. `rgba` holds `width × height` pixels.

#### Box-filter each cell to mimic Mac's 9x8 context drawing
`perceptual_hash`: Box-filter each cell, like drawing into a 9×8 context.

#### Sample at most 16x16 points per cell, enough for the hash
`perceptual_hash`: Sample at most 16×16 points per cell: plenty for a 72-cell hash.

#### Stored form is %016llx hex, same as macOS
`encode_perceptual_hash`: `%016llx`, the stored form.

#### Empty path means text-only; text is already redacted
`ScreenCapture`: One capture to store. `path` is the sealed image file, empty when only
text was kept; `text` is already redacted and empty when none was read.

#### Trigger values mirror macOS ScreenCaptureTrigger
`ScreenCapture.trigger`: `app_switch`, `window_change`, `click`, `typing_pause`, `scroll_settled`,
`clipboard_change`, `interval` or `manual` (`ScreenCaptureTrigger`).

#### Text source values with _redacted suffix when redacted
`ScreenCapture.text_source`: `accessibility`, `ocr` or `hybrid`, with `_redacted` when something was redacted.

#### One transaction writes capture, FTS row and similarity group
`Library.insert_screen_capture`: Stores one capture row and its searchable text in one transaction and
returns its id (`ActivityStore.insertScreenshot`): a `screenshots` row,
an `ocr_fts` row and its `ocr_metadata` index entry when there is text,
and the similarity group from the previous frame's perceptual hash.

#### Withdraw derived memory and unedited journals before deleting a source
`Library.delete_screen_moments`: Deletes moments with their pixels, text, bookmark and vectors. The
person deleted the source, so overnight memory built from those days
and their unedited generated journals are withdrawn first
(`AppState.withPrimaryEvidenceChange`). Returns how many were removed.

#### Delete files first so a failed removal keeps its row for retry
`Library.remove_screen_moments`: `ScreenshotService.deleteCapture`, `ActivityStore.deleteScreenshots`.
Files go first: a file that cannot be removed keeps its row, so the
deletion can be retried.

#### Upgrade screen tables from older Mac builds before storing
`screen::migrate`: Brings screen tables written by older Mac builds to the current shape
before anything is stored (`ActivityStore.migrateScreenshotColumns`,
`migrateOCRTable`, `backfillUnlinkedOCRRows`).

#### FTS5 cannot add columns, so rebuild legacy OCR table linking by time
`screen::migrate`: FTS5 tables cannot add columns: rebuild a legacy (text, ts, app) table,
linking each row to the capture taken within a second of it.

#### Link unlinked text rows to the capture within one second
`backfill_unlinked_text`: Links text rows an earlier migration left with `snapshot_id = 0` to the
capture taken within a second of them.

#### Reuse previous frame's group if its representative is near duplicate
`similarity_group`: The group of a new frame: the previous frame's group when its group's
representative is a near duplicate, else a group of its own.

#### Test that Mac-written paths are found under this library
`stored_paths_resolve_inside_the_library_only`: Written on a Mac: found again under this library's activity folder.

#### Test that deleting a source advances evidence for its days
`deleting_a_moment_removes_its_file_and_rows`: Deleting a source advances the evidence for its days.

### `LinuxWindows/crates/lokalbot-core/src/screen_search.rs`

#### Screen ranking follows DigUp: meaning z-score plus word-coverage bonus, half-words qualify
Screen search by meaning: text and picture vectors of saved screens, and their
ranking with keyword hits (`ScreenSearch`, `ScreenSearchRanking`,
`EmbeddingIndex.screenMeanings`).

Ranked the way DigUp ranks files: meaning is how far a capture stands out for
this query among all stored vectors of its kind, and the query's words add a
bonus that grows with how many of them the capture holds. A capture qualifies
by standing out in meaning or by holding at least half of the query's words, so
one common word can't outrank a clear meaning match, while all the words of an
exact lookup ("INV-2041") usually win.

#### Capture counts by meaning at 2.0 deviations above query average
`Z_GATE`: How far above this query's average a capture must score to count by meaning.

#### Kinds with under 20 vectors use the all-kinds average
`MODALITY_MINIMUM_COUNT`: Fewer vectors of a kind than this take the average of all kinds.

#### Only first 100 OR-fallback hits get full text read for coverage
`FULL_TEXT_LIMIT`: How many OR-fallback hits get their full text read to count the query's words;
the rest are counted from their snippet and title.

#### Center scores per kind then z-scale over all vectors, ignoring filters
`meaning`: Each capture's best vector on this query's scale. Scores are centred per kind
first, because text scores higher than pictures for the same topic, then put on
one z scale. Pass every stored vector, not only those in the date or app scope:
the scale must not depend on the filter.

#### Exact lookup when every word carries digits; words outweigh meaning
`is_lookup`: An exact lookup: every word carries digits. Words then count for more than
meaning.

#### Words match as prefixes of longer words, ignoring case and diacritics
`coverage`: The share of `terms` in any of `texts`, ignoring case and diacritics. A word
matches as the start of a longer word ("deploy" in "deployment").

#### Qualify by meaning or half the words; lookups weigh words double
`rank`: Captures that stand out in meaning or hold at least half of the query's words,
best first. Score: meaning z plus a word bonus that grows with coverage; for a
lookup, words weigh double and meaning half. Ties go to word matches, then to
keyword order, then to the newer capture.

#### A marked match counts for more than any word count
`query_match_count`: How many of the query's words `text` holds; a marked «match» counts for more
(`RecallPassage.queryMatchCount`).

#### Recheck live text in write transaction so expired text never returns
`Library.store_screen_vectors`: Stores text vectors. Retention or deletion may remove text while embedding
runs, so the exact live text is checked again under the write transaction;
a late pass can't bring expired text back into this table.

#### Vectors from another model are rebuilt once searched by meaning
`Library.has_stale_screen_vectors`: Text vectors another model made: this library searched by meaning before,
so they are rebuilt.

#### Picture vectors from changed model, sizing or request shape are dropped
`Library.purge_picture_vectors_except`: Picture vectors a changed model, sizing or request shape made are dropped.

#### Store empty vector for unreadable pixels; never store for deleted pixels
`Library.store_picture_vector`: Stores a capture's picture vector, or an empty one for pixels that can't be
read, so a broken capture isn't tried on every pass. The pixels may have
been deleted or replaced while this was embedded: a vector is never stored
for pixels that are gone.

#### Scale from all vectors so filters never change standing out
`Library.screen_meanings`: Every screen vector, text and picture, scored against the query on one
scale, then limited to `filter`. The scale comes from all vectors, so a date
or app filter never changes how far a capture stands out.

#### Skip reading text here; it was a third of scan time at 30,000 captures
`Library.screen_meanings`: Text stays unread here: a search shows a few hundred captures at
most (`screen_texts` reads theirs), and reading every capture's
text was about a third of this scan's time at 30,000 captures.

#### Text is read afterwards only for captures a search shows
`Library.screen_texts`: The text behind each capture's text vector, for the captures a search shows
(`screen_meanings` leaves it unread). A capture with only a picture vector,
or none, has no entry.

#### Try all words, fall back to any word; flag says which
`Library.keyword_screen_hits`: Keyword hits under `filter`: all the words, or any of them when that finds
nothing. `true` when they hold every word.

#### All-words hits hold every word; OR fallback reads text; stopword-only counts all
`Library.screen_coverage`: The share of the query's words each keyword hit holds. Hits found by the
all-words search hold them all; for the OR fallback the capture's text is
read. A query of only stopwords counts every hit it found.

#### Meaning-only captures show best passage or window title as snippet
`Library.ranked_screen_hits`: Keyword hits and meaning matches as one ranked list. A capture found only by
meaning gets its text's best passage as the snippet, or its window title
when it has no text (a picture-only match). Returns `(hit, is_semantic)`.

#### Remember searched libraries for an observer that starts late
`SEARCHED`: Libraries searched by meaning in this run, for an observer that starts late.

#### Start picture vectors only after a meaning search, avoiding unused model download
`note_searched_by_meaning`: Someone searched screens by meaning: vectors for what's waiting start now.
Nobody downloads the image model for a search they never make.

#### Test that date and app filters limit results, not scale
`stores_and_ranks_text_and_picture_vectors`: The date and app filters limit the result, not the scale.

#### Test that a capture deleted after scoring is omitted, not blank
`a_text_match_found_by_meaning_shows_its_passage_read_after_ranking`: A capture deleted after scoring is left out, not shown blank.

### `LinuxWindows/crates/lokalbot-core/src/sealed.rs`

#### Sealed files share chat-key; Mac files with its own key are never overwritten
Files sealed with AES-256-GCM, as `nonce (12) ‖ ciphertext ‖ tag (16)`
(`AES.GCM.SealedBox.combined`), with no associated data. Ask conversations,
Personal Context and the dictation learning log all share the per-install
`chat-key`. A Mac seals the same files with its own Keychain key, so a copied
file can't be opened here: callers report that and never overwrite it.

#### Credential store lives above this crate so engine installs key source
`KeySource`: Gives the `chat-key`, creating it when the flag is set. The credential store
lives above this crate, so the engine installs this on the library.

### `LinuxWindows/crates/lokalbot-core/src/search.rs`

#### Keyword search mirrors SearchIndex.swift and ActivityStore.searchOCR on FTS5
Keyword search over meetings (`SearchIndex.swift`) and screen text
(`ActivityStore.searchOCR`), both SQLite FTS5 in `lokalbotv3.sqlite`.

#### Any newer write to these meeting files triggers reindexing
`SOURCE_FILES`: Files whose contents become documents; any newer write reindexes.

#### Deleting a source cannot raise newest mtime, so check rows separately
`DOCUMENT_SOURCES`: Source file behind each removable document kind: deleting one cannot
raise the newest modification time, so its rows are checked separately.

#### Function words are dropped from natural-language queries in OR mode
`STOP_WORDS`: Function words dropped from natural-language queries in OR mode.

#### Date range filters meetings by start time with exclusive until
`SearchQuery`: A keyword search. `kinds`/`meeting_ids` restrict the documents;
`since`/`until` restrict meetings by start time (`until` exclusive).

#### Start in seconds, only for transcript hits
`SearchHit.start`: Segment start in seconds (transcript hits only).

#### Matched terms are wrapped in « » markers
`SearchHit.snippet`: A few words around the match, matched terms wrapped in « ».

#### FTS5 bm25 rank where lower is better
`SearchHit.rank`: FTS5 bm25 rank; lower is better.

#### Every term must match, last as prefix for search-as-you-type
`MatchMode.All`: Every term, the last one as a prefix (search as you type).

#### Any term matches; stop words dropped unless all terms are stop words
`MatchMode.Any`: Any term, stop words dropped unless every term is one.

#### Quote terms so punctuation cannot cause FTS5 syntax errors
`fts_query`: The FTS5 expression for `raw` (`SearchIndex.ftsQuery`): terms quoted so
punctuation cannot cause syntax errors.

#### Newest source file mtime in epoch seconds decides reindex
`source_mtime`: Newest modification time among the meeting's source files, epoch seconds.

#### Backfill search tables for libraries indexed by older app versions
`search::migrate`: Creates the search tables' migrations for libraries indexed by older
app versions (`backfillDocumentRowsIfNeeded`, notes/outcomes backfill).

#### One searchable row per decision, action with corrections, open question
`Library.outcome_search_texts`: One searchable row per decision, action (with the user's corrections)
and open question (`SearchIndex.outcomeTexts`).

#### A committed deletion wins; older snapshots never overwrite newer ones
`Library.reindex_meeting`: A deletion that committed first wins; an older snapshot never
overwrites a newer one.

#### Fall back to any-term with stop words dropped when all-terms finds nothing
`Library.search`: Keyword search: every term (the last as a prefix), falling back to
any term with stop words dropped when nothing matches.

#### Meaning match maps to summary or notes, else transcript rows within two minutes
`Library.semantic_passage`: The searchable passage behind a meaning match (`semanticPassage`): the
summary or notes that hold the chunk, else the transcript rows in the two
minutes it covers. `None` when neither holds a readable passage.

#### One result per window and day or similarity group; all terms first
`Library.search_screen`: Screen text search, one result per window and day (or similarity
group), best match first. All terms first, then any term.

#### Interval is half-open; app matches case-insensitively, as macOS grouped searchOCR
`Library.search_ocr`: `ActivityStore.searchOCR` in grouped mode; `interval` is half-open and
`app` matches the stored name case-insensitively.

#### Matched words are wrapped in « » markers
`ScreenHit.snippet`: Matched words wrapped in « ».

#### Test that clearing notes removes their row though no mtime advanced
`indexes_searches_and_tombstones`: Clearing notes removes their row even though no mtime advanced.

### `LinuxWindows/crates/lokalbot-core/src/speaker_bleed.rs`

#### Words alone only mark uncertainty; removal needs waveform evidence
Speaker bleed in a transcript (`SpeakerBleedFilter.swift`): a microphone
row that repeats a remote row. Words alone only mark uncertainty, because a
genuine repetition can have identical words and timing. Removing a row also
takes waveform evidence, which the speech crate measures from the tracks.

#### Blocks over 15 s may be fallbacks with distant words
`MAX_COMPARABLE_SPAN`: Longer blocks may be whole-track or fixed-window fallbacks, so their words
could be far apart inside the block.

#### Independent passes place same utterance boundaries slightly apart
`MAX_BOUNDARY_DRIFT`: Independent passes place the same utterance's boundaries slightly apart.

#### A few generic words are plausible simultaneous speech, not echo proof
`MIN_WORD_TOKENS`: A few generic words are plausible simultaneous speech, not proof of echo.

#### Ideographic tokens are characters and carry less evidence than words
`MIN_IDEOGRAPHIC_TOKENS`: Ideographic tokens are characters and carry less evidence than words.

#### Share of words in one overlapping remote row to treat as possible echo
`MIN_ECHO_WORD_COVERAGE`: Share of a row's words that must appear in one overlapping remote row for
notes evidence to treat it as possible echo.

#### Only confirmation or remembered voice decides identity, not mic default
`has_identity_decision`: Confirmation or a remembered voice decided who this is. A microphone's
default identity is not such a decision.

#### Keep inner apostrophes so short contractions cannot manufacture enough tokens
`comparison_tokens`: Case- and punctuation-insensitive tokens. Apostrophes inside a word stay
inside it, so short contractions can't manufacture enough tokens.

#### Crowded timing is ambiguous; stop scanning at candidate cap
`is_remote_row_match`: Crowded timing is ambiguous; stop before work can grow with it.

#### Remove only with precise remote row and waveform agreement; else drop default identity
`filter_bleed`: Removes a row only when a precisely timed remote row carries the same words
at the same time and `verified` says the waveform agrees. A row that matches
without that keeps its words and loses the microphone's default identity.

#### Never deletes text; only withholds mic identity so remote words don't become user evidence
`near_duplicate_echo_indices`: Microphone rows that mostly repeat simultaneous remote speech. This needs
no exact span or token equality and never deletes text; callers only
withhold the microphone's default identity, so a remote participant's words
can't become the user's evidence (`nearDuplicateEchoIndices`).

#### Fixed transcription windows bound remote spans; look-back plus cap keeps it linear
`near_duplicate_echo_indices`: Remote spans are bounded by fixed transcription windows, so a
generous look-back plus a candidate cap keeps this linear.

#### Likely echo keeps words and row ids but loses mic default identity
`Transcript.marking_suspected_echo`: Likely microphone echo keeps its words and row ids but loses the
microphone's default identity (`markingSuspectedEcho`).

### `LinuxWindows/crates/lokalbot-core/src/text.rs`

#### Sanitizer lives here because coding-agent titles are compared with its output
`PromptContextSanitizer`: text without control bytes, ragged spacing or
stacked blank lines. Punctuation is kept. It lives here because coding-agent
titles are compared with what it produced.

#### Control chars become spaces, newlines normalized, cap cuts at word boundary with ellipsis
`sanitize`: Control characters become spaces, every newline variant becomes `\n`,
inline whitespace collapses to one space, blank-line runs collapse to one,
edges are trimmed. With `max_characters`, the result is cut at a word
boundary with a trailing `…` counted inside the cap.

#### Unicode Cf characters also removed to match Swift's control set
`is_format`: Unicode format characters (Cf) Swift's control set also removes.

#### Every query word matches ignoring case, diacritics, punctuation; empty matches all
`settings_search_matches`: The Settings search matcher (`SettingsSearchRanker.swift`): every word of the
query appears somewhere, ignoring case, diacritics and punctuation, so
"auto-record" finds "auto record". An empty query matches everything.

#### Model output and screen text pass redaction before shown, saved or sent
`redaction`: Secrets, payment cards and IBANs replaced by `[REDACTED…]` markers
(`ScreenContextPrivacy.redact`), with how many were replaced. Model output
and screen text pass through it before they are shown, saved or sent.

#### Only checksum-valid cards and IBANs redacted so order and phone numbers stay readable
`checked_rules`: Numbers whose checksum makes them almost certainly a payment card (a
known issuer prefix and Luhn) or an IBAN (mod 97); order, tracking and
phone numbers stay readable.

### `LinuxWindows/crates/lokalbot-core/src/time.rs`

#### macOS writes four date encodings; each JSON file uses matching serde helper
Date encodings and display helpers shared by every crate.

The macOS app writes four date encodings (see `docs/library-format.md`).
Each JSON file uses the matching serde helper below so libraries stay
readable by both apps.

#### Writers must not emit fractional seconds because Swift's formatter rejects them
`iso_seconds`: ISO-8601 with whole seconds and a `Z` suffix (`meta.json`, chats, projects).
Swift's `ISO8601DateFormatter` rejects fractional seconds, so writers must
not emit them. Readers accept fractions anyway.

#### Swift JSONEncoder dates are seconds since 2001; readers also accept ISO strings
`swift_date`: Swift's default `JSONEncoder` date: a number of seconds since
2001-01-01Z (`journal/*.meta.json`, `coding_agent_bursts.payload`).
Readers also accept ISO-8601 strings.

#### SQLite timestamp columns hold REAL Unix epoch seconds
`from_epoch`: SQLite timestamp columns hold REAL Unix epoch seconds.

#### Day bounds are half-open [start, end) in UTC
`local_day_bounds`: `[start, end)` of a local calendar day in UTC.

### `LinuxWindows/crates/lokalbot-core/src/vocabulary.rs`

#### Vocabulary sources are local; no addresses, speaker evidence or voice profiles read
Names and terms LokalBot already knows, offered to speech models that take a
vocabulary prompt (`TranscriptionVocabulary.swift`). Every source is local
and already part of the library: calendar attendee display names (never
addresses or names derived from addresses), speaker names the user applied
in related meetings, pinned overnight-review projects, tracked project names
and distinctive meeting-title terms. Speaker evidence, suggestions and voice
profile links are not read.

#### Dictation looks back 45 days for names
`RECENT_DAYS`: How far back dictation looks for names (`recentSources`).

#### Per-meeting record so a crash resume reuses the same prompt
`Record`: Per-meeting record, so a crash resume uses the same prompt even if the
library changed in between.

#### Priority attendees, applied names, projects, title terms; deduped and bounded
`terms`: Priority order: attendees, names the user applied before, projects, then
title terms. Deduplicated ignoring case and accents, and bounded so the
prompt never crowds out the audio context.

#### Manual vocabulary stays first and verbatim; known terms follow
`prompt`: The user's own vocabulary stays first and verbatim; known terms follow.

#### Meeting sources: attendees, names from up to eight related meetings, projects, title words
`sources`: What is known for one meeting: its attendees, names applied in up to eight
earlier related meetings (the same series, or a shared attendee), projects
and its title's distinctive words.

#### Tracked project names are confirmed spellings too
`sources`: Names the person tracks in Projects are confirmed spellings too.

#### Dictation uses recent attendees and projects, most frequently met first
`recent_sources`: Recent attendee names and projects for dictation, which has no meeting of
its own. The most frequently met people come first.

#### Only pinned projects; unpinned labels biased transcripts toward earlier mishearings
`endorsed_project_names`: Only projects the person pinned in `memory/memory.json`. Unpinned ones are
model labels, often built from earlier mishearings; as vocabulary they
biased the next transcript toward the same errors.

#### A pending retraction fails closed
`endorsed_project_names`: A retraction in progress (`DreamStore.evidenceIsAvailable`) fails closed.

#### Cleanup after transcription uses manual vocabulary plus saved terms
`saved_prompt`: The prompt a finished meeting was transcribed with, for cleanup that runs
after transcription: the manual vocabulary plus the saved terms.

#### A resume reuses the terms saved with the meeting
`transcription_prompt`: The manual vocabulary plus names LokalBot already knows, for speech models
that read a prompt (`ProcessingPipeline.transcriptionPrompt`). A resume
reuses the terms saved with the meeting.

#### Sample transcribes identically in every library; user meeting names never steer it
`transcription_prompt`: The sample transcribes the same way in every library, so names from the
user's own meetings never steer it.

#### Department words relate a series but are excluded from vocabulary
`COMMON_TITLE_WORDS`: Department and format words name a series ("Product standup", so they still
relate its meetings) but are ordinary words a speech model spells on its
own; as vocabulary, "Product" came back in prompt-echo rows.

#### Capitalized or mixed-case title words and acronyms are likely names
`title_terms`: Capitalized or mixed-case words and acronyms from a title ("Acme", "iOS",
"SDK") are likely names worth spelling; generic words are not.

#### Structured identities first, else legacy name list; display names only
`attendee_names`: `Meeting.resolvedCalendarParticipantIdentities`: structured identities when
there are any, else the legacy name list. Only display names.

#### Placeholder speaker labels excluded because recognizers echoed them as transcript rows
`is_placeholder_name`: Placeholder labels ("Them 6", "Speaker unclear", "Local speaker") and
collective words carry no spelling value; fed to a recognizer, a label came
back as transcript rows on silent spans.

#### Strip merge suffix naming a recording, plus whitespace and edge punctuation
`cleaned_term`: Merges suffix applied names with "· source 2", which names a recording
rather than a person; whitespace and edge punctuation go too.

#### Fixture mimics JSONEncoder output: pretty-printed, sorted keys, ISO 8601
`a_mac_record_reads_back`: As `JSONEncoder` writes it: pretty-printed, sorted keys, ISO 8601.

#### A resume ignores later changes; a fresh run sees them
`a_resume_reuses_the_saved_terms_and_the_sample_stays_neutral`: A resume ignores what changed since; a fresh run sees it.

### `LinuxWindows/crates/lokalbot-core/tests/demo_library.rs`

#### Before 04:30 demo dates today ahead of clock, so week time is zero
`people_and_projects_join_the_demo`: Before 04:30 the demo dates today's activity at 04:30 (demo::Clock), still
ahead of the clock, and a project's week only counts time already spent.

#### Command to write the demo library to LB_DEMO_OUT
`write_demo_library`: `LB_DEMO_OUT=/tmp/x cargo test -p lokalbot-core --test demo_library -- --ignored`

### `LinuxWindows/crates/lokalbot-core/tests/microphone_preference.rs`

#### Microphone-is-me setting is process-wide so test needs its own binary
"My microphone is me" is one value for the process, so this test has a
binary of its own: flipping it cannot race the library's other tests.

### `LinuxWindows/crates/lokalbot-core/tests/translated_owner.rs`

#### Interface language is process-wide so test needs its own binary
Action owners under a non-English interface. The interface language is
process-wide, so this file stays one test in its own test binary.

#### v0.11.0 to v0.11.5 stored the German word for You as owner
`owners_stay_canonical_under_a_german_interface`: What v0.11.0–v0.11.5 stored for "You" under German.

#### Other languages read the German word as a name
`owners_stay_canonical_under_a_german_interface`: Another interface language reads the German word as a name.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
