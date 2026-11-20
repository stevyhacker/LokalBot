# 0100. Windows and Linux: engine — companion

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-engine/src/companion/`.

## Decisions

### `LinuxWindows/crates/lokalbot-engine/src/companion/advertise.rs`

#### Advertise neutral LokalBot-XXXX name and key fingerprint so owner isn't revealed
Advertises the listener as `_lokalbot._tcp` on the local network with a
neutral instance name, `LokalBot-XXXX`, and the key fingerprint in its TXT
record, so paired devices recognize this computer without learning who
owns it (`CompanionBonjourAdvertiser`). Phones browse with Bonjour and NSD,
which read this as they read the Mac's.

#### TXT record value for key k is the fingerprint prefix
`txt_value`: The value of TXT `k`.

#### Neutral name also replaces host name so the computer's name isn't announced
`service_info`: What goes on the network: the neutral name stands in for the host name
too, so the computer's own name is not announced.

#### Opening the daemon binds multicast sockets, so only once sharing is on and listener up
`MdnsAdvertiser`: mDNS for real. Opening the daemon binds multicast sockets, so nothing does
it until sharing is on and the listener is up.

#### Tests never announce on the network of machines where it isn't welcome
`MdnsAdvertiser::start`: Tests run on machines where announcing on the network isn't welcome.

#### Enable only interfaces holding addresses devices may use
`MdnsAdvertiser::start`: Only the interfaces holding the addresses devices may use.

### `LinuxWindows/crates/lokalbot-engine/src/companion/ask.rs`

#### Companion Ask uses same agent and approvals; tools limited to shared classes; answers survive disconnects
Answers questions from paired devices (`CompanionAskResponder.swift`) with
the same Ask agent, Think engine and remote-inference approvals as Ask on
this computer. Tools are limited to the classes the person shares:
meetings, and the Timeline's activity summary only when window titles are
shared too, because it names windows. Screen search, Dream memory and
Personal Context are never used.

A device that disconnects doesn't stop its answer: the sink keeps it, in
memory, for the device to collect (`lokalbot-sync`'s `answers`). Only
turning sharing off, or quitting, cancels one.

#### Citation marker pattern mirrors ChatCitationParser: id forms and M:SS, MM:SS, HH:MM:SS stamps
`MARKER`: `ChatCitationParser.pattern`: short or full meeting ids, positive screen
and file row ids; meeting stamps accept M:SS, MM:SS or HH:MM:SS.

#### Repeated sources keep first number; malformed markers stay as text
`extract_citations`: Replaces markers with ordered `[n]` references and returns the deduped
citations (`ChatCitationParser.extract`). Repeated sources keep their
first number; a malformed marker stays as text.

#### Line-leading indentation stays because Markdown renderers use it
`cleaned`: Tidies the gaps removed markers leave. Line-leading indentation stays: it
means something to the Markdown renderer.

#### Only an unambiguous short or full id matches a meeting
`resolve_meeting`: Short ids and full UUIDs both work. Only an unambiguous match names a
meeting.

#### Screen and file citations stay text only and never name what they point at
`map_citations`: Turns the agent's `[meeting:ID@HH:MM:SS]` markers into records.md's `[n]`
references and citation list. Screen and file citations stay text only and
never name what they point at.

#### Files are never searched for a device, so a stray marker names no file
`map_citations`: Files are never searched for a device; a stray marker names no file.

#### Agent notes are never searched for a device either
`map_citations`: Agent notes are never searched for a device either.

#### Non-extending partials send nothing since the final result replaces streamed text
`AnswerStream`: Converts the agent's growing answer into the next piece for the phone,
with citation markers already numbered. A partial that is not an extension
of what was sent (the agent restarted its answer) sends nothing; the final
result replaces the streamed text anyway.

#### A citation marker still being written is held back until closed
`without_partial_marker`: A marker still being written is held back until it closes.

#### on_text receives the whole visible answer so far
`AskEngine::answer`: Runs the Ask agent. `on_text` gets the whole visible answer so far.

#### Unapproved remote servers fail exactly as in Ask
`LiveAskEngine`: The Think engine, with its existing approvals: an unapproved remote server
fails here exactly as it does for Ask.

#### CPU-only or small-window models answer in one turn, as in Ask
`LiveAskEngine::answer`: A CPU-only or small-window model answers in one turn, as in Ask.

#### Sharing is read fresh per question; answering runs on its own thread
`AskResponder::answer`: Checks the question against what is shared, then answers on its own
thread. `sharing` is read fresh for each question.

#### The history window is the only limit, being what the computer shares
`AskResponder::answer`: The history window is the only limit: it is what the computer shares.

#### Asked-about day or meeting is a starting point, never a limit
`AskResponder::answer`: The day or meeting a question was asked about is where the answer
starts, never a limit: "Ask About Today" on a tablet once answered
"the library has only one meeting".

#### Empty list means all meetings in Ask, so use a nil id to keep tools empty
`AskResponder::answer`: An empty list means "all meetings" to Ask, and here nothing is
shared: an id no meeting has keeps the tools empty-handed.

#### Phones never get screen search, overnight review memory or Personal Context
`AskResponder::answer`: A phone never gets screen search, the overnight review's memory
or Personal Context (`CompanionAskResponder`).

#### Phones also never get Files folders or coding-agent notes
`AskResponder::answer`: Nor the folders chosen under Files, nor coding-agent notes.

#### The window is named with the meetings, not as a date the person could remove
`AskResponder::answer`: The window is named with the meetings, not as a date the
person could remove.

### `LinuxWindows/crates/lokalbot-engine/src/companion/builder.rs`

#### Records are built from display-ready sources so emails, speaker evidence and screen text never enter
Turns a `CompanionLibrary` into companion records
(`CompanionRecordBuilder.swift`). Pure reads: every field a record carries
is chosen here, from display-ready sources, so attendee emails, speaker
evidence, screenshot paths and screen text never enter one.

#### Saved-moments query bound exceeds what a person saves in a day
`SAVED_MOMENTS_PER_DAY`: More than a person saves in a day; the query wants a bound.

#### Every record the current scope shares, manifest excluded
`RecordBuilder::all_records`: Every record the current scope shares, manifest excluded.

#### Transcript record only when transcripts are shared
`RecordBuilder::meeting_records`: The meeting record and, when transcripts are shared, its transcript.

#### Days with digest, activity or shared meeting inside history window, newest first
`RecordBuilder::day_keys`: Days that have a digest, recorded activity, or a shared meeting,
inside the history window, newest first.

#### An unknown sidecar version is not one this build wrote or understands
`RecordBuilder::digest`: An unknown sidecar version is not one this build wrote or understands.

#### One definition of active time for every day surface: non-system intervals clipped to the day
`RecordBuilder::timeline`: One definition of active time for every day surface: valid,
non-system intervals clipped to the day (`DayActivityProjection`).

#### Without window titles class, titles fall back to project or apps
`RecordBuilder::work_session`: A work session as the Timeline rail shows it. Without the window
titles class, a title made from window titles falls back to the
session's project or apps.

#### Transcript carries display data only, never attribution or identity evidence
`transcript_body`: Display text, times, display names and a stable color per speaker; never
attribution, identity evidence or calendar identity links.

#### 0 is the person, 1-7 palette by first appearance, -1 for unclear voice
`color_index`: 0 is the person themselves, 1–7 the speaker palette in order of first
appearance, -1 a voice that could not be told apart.

#### Window titles with at least a minute of attention, most time first, max six
`sustained_titles`: A session's window titles that held attention for at least a minute,
most time first, at most six (`titleEvidence`).

#### Overnight review points stay on this computer with Dream memory
`where_it_stands`: The note's overview and the points taken from meetings. Points from
overnight review notes stay on this computer with the rest of Dream memory.

#### Drop provenance line and title heading because the phone draws them from the record
`shareable_summary`: The summary as the Meetings page shows it: no provenance line and no title
heading, which the phone draws from the record itself.

#### Lift the first provenance line only when it holds two or more Label: value pairs
`without_provenance`: `SummaryPresentation.split`: lifts out the first non-empty, non-heading
line among the leading four when it holds at least two `**Label:** value`
pairs joined by "·", so a body opening with bold text stays intact.

#### Older merge drafts open with implementation details instead of meeting content
`merged_meeting_body`: `SummaryPresentation.meetingBody`: older merge drafts open with
implementation details instead of meeting content.

#### Level-2 sections rendered from raw capture rather than written by LokalBot
`EVIDENCE_SECTIONS`: Level-2 sections LokalBot renders from raw capture rather than writes.

#### Raw evidence log stays on computer; screen citations become the moment's time
`shareable_digest`: Day Digest Markdown made fit for a phone: the raw evidence log, which
quotes screen text and window titles, stays on this computer, and screen
citations become the time of the moment they point at.

#### Screen markers become a time; unresolved and bare markers are dropped
`rewriting_screen_citations`: `[screen:42]` becomes "(screen moment at 14:32)"; a marker whose capture
is gone, and a bare `[screen]`, are dropped.

#### Returns list items without markers, or paragraphs when written as prose
`items`: Top-level list items without their markers, or the paragraphs of a passage
written as prose.

#### Stored keys keep canonical names; Local speaker stays unconfirmed; sent in English like the Mac
`label`: `SpeakerDisplayName.label`: stored keys keep their canonical names ("Me",
"Them 2"); "Local speaker" stays because that voice is not yet confirmed
as the user. These go to the phone in English, as from the Mac.

#### Display-only names; source keys, identities and aliases stay untouched
`SpeakerPresentation`: Display-only names for a meeting's speakers (`MeetingSpeakerPresentation`).
Source-scoped keys, confirmed identities, and saved aliases stay untouched.

#### Color stable across alias edits and action-prioritized review ordering
`SpeakerPresentation::color_index`: Stable across alias edits and the action-prioritized review ordering.

#### Replace longest first to protect nested merges and source 1 versus 10
`SpeakerPresentation::text`: Longest first protects nested merges and source 1 versus source 10.

### `LinuxWindows/crates/lokalbot-engine/src/companion/host.rs`

#### Today's record is rebuilt every 15 minutes while there is activity
`REFRESH_MINUTES`: Today's record is rebuilt this often while there is activity.

#### An unanswered prompt expires with the device's pairing request
`APPROVAL_TIMEOUT`: An unanswered prompt expires with the device's pairing request.

#### Debounce so a burst of edits costs one publish pass
`PUBLISH_DEBOUNCE`: A burst of edits costs one pass.

#### Set to 1 by development runs: loopback only, never announces
`LOOPBACK_VARIABLE`: Set to 1 by development runs: listens on loopback only and never announces.

#### Abstract machine access so lifecycle tests avoid credential store, interfaces and network
`Environment`: What the host needs from the machine, so its lifecycle can run in tests
without the credential store, a real interface, or the local network.

#### Only the private half of the key is kept
`Environment::static_key`: Only the private half of the key is kept.

#### Addresses are private LAN and Tailscale only
`Environment::addresses`: This machine's private LAN and Tailscale addresses.

#### Whether the local network announcement may run at all
`Environment::announces`: Whether the local network announcement may run at all.

#### A device recording becomes a meeting: queue processing and show it anywhere in the app
`Environment::recording_stored`: A device's recording is now this meeting: queue it for processing and
show it, wherever the person is in the app.

#### Queue like a local recording, waiting for models rather than downloading unseen
`LiveEnvironment::recording_stored`: Queued like a recording finished on this computer, which waits for
missing models rather than downloading them with nobody here to see it.

#### Computer name shows in pairing code and phones but is never announced
`computer_name`: The computer's name, as the pairing code and phones show it. It's never
announced on the network.

#### Outlives the sync host, which restarts when sharing toggles during an import
`Bridge.importing`: Outlives the sync host, which restarts when sharing is switched off and
on while an import goes on.

#### Blocks until the person answers or the prompt expires
`Bridge::approve`: Blocks until the person answers or the prompt expires.

#### A newer request drops the older answer channel, refusing it
`Bridge::approve`: A newer request drops the older answer channel, which refuses it.

#### Changed records reach the device before the op's result
`Delegate::apply_op`: The changed records reach the device before the op's result.

#### Sync host keeps the whole file, so waiting costs no second transfer
`Delegate::receive_recording`: The sync host keeps a whole file, so waiting costs no second transfer.

#### The new meeting's record exists for the sync that follows the upload
`Delegate::receive_recording`: Its record is there for the sync that follows the upload.

#### Track what is announced so a tick restarts it only on change
`Host.announced`: What is being announced, so a tick restarts it only when that changes.

#### Track what Settings last heard so unchanged ticks stay quiet
`Host.emitted`: What Settings last heard, so a tick that changed nothing stays quiet.

#### When sharing is off, delete in-flight uploads; devices still hold their copies
`Host::apply`: Nothing can finish arriving, so audio on its way has no reason to
stay. The devices still have their copies.

#### Rebuild today while active; reconcile daily, withdrawing records outside history window
`Host::tick`: Today's record while there is activity, and a full reconcile once a
day, which also withdraws records that left the history window.

#### If mDNS fails, paired devices still try their saved addresses
`Host::start_announcing`: Devices paired before still try the addresses they saved.

#### A successful pairing consumes the pairing offer
`Host::refresh_devices`: A successful pairing consumes the offer.

### `LinuxWindows/crates/lokalbot-engine/src/companion/library.rs`

#### Companion library reads only; a build never repairs metadata
What one companion build reads from the library (`CompanionLibrary.swift`).
Nothing here writes: a build never repairs metadata.

#### Own finished meetings in history window, newest first; excludes merged sources, sample, in-progress
`CompanionLibrary.meetings`: The person's own finished meetings inside the history window, newest
first. Merged sources, the sample meeting, and a meeting still being
recorded are left out.

#### Only tracked projects; their UUIDs are the record keys
`CompanionLibrary.projects`: Tracked projects only: their UUIDs are the record keys.

#### Merge markers are resolved in memory only, newest first
`read_all_meetings`: Every meeting on disk with its merge marker resolved in memory only,
newest first (`SessionLookup.loadAllMeetings`).

#### Optional all-meetings reuses existing read; outcomes reused from known
`CompanionLibrary::load`: `all`, when given, is used instead of reading the meetings again, and
outcomes are reused from `known` where present.

#### Dream memory is never read; its projects and review notes stay on this computer
`CompanionLibrary::load`: Dream memory is never read: its projects and review notes stay
on this computer, so only tracked projects and recurring topics
remain.

#### Reload meetings, reuse cached outcomes, rebuild people and projects only when asked
`CompanionLibrary::reloading`: The library again after a change: meetings re-read, outcomes reused
from `cached` where present, people and projects rebuilt only when
asked.

### `LinuxWindows/crates/lokalbot-engine/src/companion/mod.rs`

#### Nothing listens, announces or builds records unless phone sharing is on
Serves paired phones and tablets (`Services/Companion/`). Everything below
the switch exists only while Settings → Phones & tablets is on: with sharing
off nothing listens, nothing is announced and no record is built.

`lokalbot-sync` holds the listener, Noise sessions and pairing. This module
decides what is shared: `builder` turns the library into allowlisted
records, `publisher` keeps them current, `ask` answers questions, `ops`
applies action changes and `recordings` makes meetings of what devices send.
`host` runs the lifecycle.

#### Only the interactive app enables the host; tools and examples never listen
`CompanionCommand::Enable`: The interactive app is running: follow the setting from now on. Tools
and examples that start the engine never listen.

#### Pairing code holds a one-time secret and never reaches a log
`CompanionPairing`: An open pairing offer. The code holds a one-time secret, so it never
reaches a log.

#### Empty addresses means nothing on private network or Tailscale can reach this computer
`CompanionSnapshot.addresses`: The addresses a new device would be given. Empty means nothing on a
private network or Tailscale can reach this computer.

#### Device picks its own name, so show a bounded single-line version
`device_display_name`: A device chooses its own name; show a bounded, single-line version.

#### Tailscale ranges are 100.64.0.0/10 and fd7a:115c:a1e0::/48
`CompanionNetwork::classify`: Tailscale hands out `100.64.0.0/10` and `fd7a:115c:a1e0::/48`.

#### Engine handle on host thread; calls only queue work
`Companion`: The engine's handle on the host thread. Calls only queue work.

#### Source changes arrive from the one route every change takes
`Companion::evidence_changed`: Source changes on these days, from the one route every change takes.

#### Host thread starts idle until CompanionCommand::Enable
`companion::start`: Starts the host thread, idle until `CompanionCommand::Enable`.

### `LinuxWindows/crates/lokalbot-engine/src/companion/ops.rs`

#### Device status ops use the same library path as action rows so all surfaces update
Applies `action.setStatus` ops from paired devices
(`CompanionOpApplier.swift`) through the same library path as the action
rows, so the outcome state and every derived surface update exactly as for
a click here.

#### Holds the op's meeting when parsed, for the following republish
`Outcome`: The op's meeting when it parsed, for the republish that follows.

#### Action ids are content hashes; match by text snapshot only if exactly one, never guess
`match_action`: Finds the action a phone's op names. Action ids are content hashes, so
reprocessing a meeting can change them while the phone still holds the old
one; the op's text snapshot then finds the action when exactly one matches.
Anything else is reported back as unmatched, never guessed.

### `LinuxWindows/crates/lokalbot-engine/src/companion/publisher.rs`

#### Reconcile publishes all records and withdraws stale keys; edits coalesce on one thread
Keeps the host's records equal to what the library shares
(`CompanionPublisher.swift`). A full reconcile builds every record,
publishes it, and withdraws keys that no longer exist (deleted, merged,
out of the history window, or a class turned off). Change hooks queue
narrower rebuilds, coalesced on one thread, so a burst of edits costs one
pass.

#### Publishing an unchanged record body is a no-op on the host
`RecordSink`: Where built records go: the sync host while sharing is on, an in-memory
store in tests. Publishing an unchanged body is a no-op on the host.

#### Rescan compares library with what records were built from
`Pending.rescan`: Compare the library with what the records were built from.

#### Different record scope rebuilds everything; manifest always refreshed
`Publisher.update`: Replace the settings the records depend on. A different record scope
rebuilds everything; the manifest is always refreshed.

#### Changed meetings found by comparing library with built records
`Publisher.evidence_changed`: Meeting evidence changed on these days: outcomes, notes, processing,
deletion or a merge. Which meetings is found by comparing the library
with what the records were built from.

#### Rebuild today's record when anything was recorded within the window
`Publisher.refresh_today_if_active`: Today's Timeline grows while the person works; rebuild today's record
when anything was recorded within `window`.

#### Writes from other pages reach no hook; one stat per file finds them
`Publisher.check_for_changes`: Writes from other pages (notes, a new title, people and project
choices) reach no hook. One stat per file finds them.

#### Blocks for device-awaited ops; false if pass misses the timeout
`Publisher.republish_now`: Rebuild one meeting and what depends on it before returning, for ops
the device waits on. Returns false when the pass did not finish in time.

#### Queued work is dropped; a pass under way finishes on its thread
`Publisher.stop`: Queued work is dropped; a pass under way finishes on its own thread.

#### Per-meeting source change times as of last build
`Worker.fingerprints`: When each shared meeting's sources last changed, as of its last build.

#### Reread meeting list each time; reload outcomes only for changed meetings
`Worker.apply`: The meeting list is cheap to read again; outcomes are reloaded only
for the meetings that changed.

#### Just-rebuilt meetings drop their fingerprint, needing no second pass
`Worker.apply`: What was just rebuilt needs no second pass.

#### Change hook only gets dates; recording and summary writes reach no hook
`Worker.rescan`: Names the meetings whose files changed, and those gone or newly
shared. Only dates reach the change hook here, and writes outside the
evidence path (a finished recording, a summary) reach it not at all.

#### Curation and project note files whose mtimes signal People/Projects changes
`curation_stamp`: When People and Projects choices and the "Where it stands" notes last
changed: `people/curation.json`, `projects/tracked.json`,
`projects/summaries.json`.

### `LinuxWindows/crates/lokalbot-engine/src/companion/recordings.rs`

#### Device deletes its copy on accepted; rejected only for unfixable, else deferred
Makes meetings of the recordings paired devices send
(`CompanionRecordingReceiver.swift`). A device deletes its copy once it hears
`accepted`, so that answer waits until the meeting is stored; `rejected` is
for what no retry can fix, and everything else is `deferred`.

#### ADTS AAC stays readable when a recorder dies
`SUPPORTED_FORMAT`: ADTS AAC, which a recorder that dies leaves readable.

#### Earlier attempt's meeting already queued, may have notes
`Received.new_meeting`: The meeting this call made of it. One from an earlier attempt already
went through the queue, and may have notes by now.

#### Recording JSON per Companion/protocol/ffi.md; device name from pairing
`receive`: Reads `file` and makes a meeting of it. `recording_json` is the recording as
`receive_recording` describes it (Companion/protocol/ffi.md); the device name
comes from the pairing, the rest from the device.

#### Failure message names the recording, so keep titles out of the log
`receive`: The message names the recording; keep titles out of the log.

### `LinuxWindows/crates/lokalbot-engine/src/companion/records.rs`

#### Record types are the phone allowlist; optional omitted; ISO instants, local day keys
Companion records, schema version 1 (`Companion/protocol/records.md`,
`CompanionRecords.swift`).

These types are the allowlist: a field reaches a phone only if it is
declared here. Optional fields are omitted from the JSON, never `null`.
Instants are ISO 8601 UTC strings with milliseconds; calendar days are
`YYYY-MM-DD` in this computer's time zone; offsets inside a meeting are
seconds from the start of its audio.

#### Manifest is a single record set via set_manifest, not reconciled
`RecordKind::RECONCILED`: Kinds whose keys the publisher reconciles. The manifest is a single
record set through `set_manifest`.

#### Host adds the envelope fields version, seq, sortKey, deleted
`Record`: One built record. The host adds the envelope (`version`, `seq`, `sortKey`,
`deleted`).

#### Meeting and project UUIDs travel in lower case, as in fixtures
`id`: Meeting and project UUIDs travel in lower case, as in the fixtures.

#### Holds this computer's name; protocol keeps the Mac's key
`ManifestBody.mac_name`: This computer's name; the protocol keeps the Mac's key.

#### action.setStatus is the only op in schema version 1
`SetStatusOp`: `action.setStatus`, the only op in schema version 1.

#### mac means local engine (protocol value); remote means approved server
`AskResult.location`: `mac` for an engine on this computer (the protocol's value), `remote`
for an approved server.

### `LinuxWindows/crates/lokalbot-engine/src/companion/sharing.rs`

#### Sharing choices captured from Settings and handed to builders as a value
What the person chose to share (`CompanionSettings.swift`): captured from
`Settings` and handed to the builders as a value.

#### Value is number of days, 0 for all, matching records.md historyDays
`HistoryWindow`: How far back the copy on paired devices reaches. The value is the number
of days, 0 for all history, as records.md's `historyDays`.

#### Unknown value keeps default, as the Mac decoder does
`HistoryWindow.from_days`: An unknown value keeps the default, as the Mac's decoder does.

#### Data classes follow records.md manifest order
`DataClasses`: The data classes in records.md's manifest, in its order.

#### Transcripts need the meeting record or phone cannot open them
`DataClasses.shares_transcripts`: A transcript belongs to its meeting: without the meeting record a
phone has nothing to open it from.

#### Window titles are part of the Timeline class
`DataClasses.shares_window_titles`: Window titles are part of the Timeline.

#### What devices actually receive, as the manifest reports
`DataClasses.effective`: What devices actually receive, as the manifest reports it.

#### Scope changes rebuild library; port and advertising restart the listener
`RecordScope`: What decides which records exist. Changing only these rebuilds the
library; the port and advertising restart the listener instead.

#### Day keys use this computer's time zone
`day_key`: `YYYY-MM-DD`, the day in this computer's time zone.

#### Only canonical YYYY-MM-DD keys accepted, matching AskDayScope.isCanonicalKey
`parse_day_key`: A canonical `YYYY-MM-DD` key (`AskDayScope.isCanonicalKey`).

### `LinuxWindows/crates/lokalbot-engine/src/companion/tests.rs`

#### Fixture library holds all private data kinds that must never reach a phone
A synthetic library (`CompanionFixtureLibrary.swift`) that deliberately
holds every kind of private data that must never reach a phone, and the
host run end to end against the protocol's own client, on loopback only.

#### Strings that must never appear in any record body
`SECRETS`: Strings that must never appear in any record body.

#### Main meeting's day, at local noon
`Fixture.day`: The day of the main meeting, at local noon.

#### Speaker evidence beside meeting is private, never read by builders
`fixture`: Private speaker evidence beside the meeting; never read by builders.

#### Merged source folds into parent and is never shared
`fixture`: A merge: the source is folded into the parent and never shared.

#### Bundled sample meeting is made up and never shared
`fixture`: LokalBot's bundled sample meeting is made up and never shared.

#### Overnight review notes in project note stay on this computer
`fixture`: A tracked project with a "Where it stands" note; one point came from
overnight review notes, which stay on this computer.

#### Dream memory and Personal Context files are never read
`fixture`: Dream memory and Personal Context files: never read.

#### Exclusion contract: attendee emails, evidence, paths, screen text, agenda, links, memory never shared
`no_record_contains_excluded_data`: The exclusion contract: no record carries attendee emails, speaker
evidence, calendar identity links, screenshot paths, screen text, agenda
or meeting links, Dream memory, or Personal Context.

#### Transcript class is off when its meeting class is off
`manifest_reports_what_devices_receive`: A transcript needs its meeting.

#### Speaker identity evidence stays on this computer
`transcript_uses_display_names_and_stable_colors`: Identity evidence stays home.

#### People and projects reach no further than visible meetings
`history_window_leaves_older_records_out`: People and projects reach no further than the meetings they may see.

#### Protocol sample library must round trip unchanged through Rust types
`the_protocols_sample_library_round_trips_through_these_types`: Every record of the sample library the phones and the protocol test
against reads and writes back unchanged: same keys, nesting, optional
fields and types as the Mac's `Codable` bodies.

#### Records built here must be accepted by the phones' store
`built_records_are_accepted_by_the_sync_host`: What this computer builds, the phones' store accepts.

#### Sample meeting is never shared, even with all history
`out_of_window_scope_is_refused`: The sample is never shared, even with all history.

#### Model is told the window is the limit, not a removable date
`the_window_limits_what_the_agent_may_read_and_the_day_only_focuses_it`: The model is told the window is the limit, not a date to remove.

#### Ask About Today once restricted to one day; day only focuses, window limits
`the_window_limits_what_the_agent_may_read_and_the_day_only_focuses_it`: "Ask About Today" on a tablet once held the question to that day and
answered "the library has only one meeting": the day and the meeting
are where the answer starts, and only the window limits it.

#### Empty meeting list means all for Ask but none for a device
`no_shared_meetings_reach_no_meetings`: To Ask an empty list means every meeting, and to a device it must mean none.

#### Writes without evidence hook found by comparing library with built records
`a_rescan_finds_what_changed_without_a_hook`: A write with no evidence hook, such as a finished recording or a summary,
is found by comparing the library with what was built.

#### Notes saved from meeting page reach no hook
`the_periodic_check_finds_a_write_no_hook_reports`: Notes saved from the meeting page reach no hook.

#### Building the announcement must open nothing
`advertised_name_and_txt_record_are_neutral`: Building the announcement opens nothing.

#### Tools and examples start engine too; only the app's Enable listens
`nothing_follows_the_setting_until_the_app_enables_it`: Tools and examples start the engine too; only the app's Enable listens.

#### End-to-end host tests use loopback only; advertiser just records calls
------------------------------------------------------------- the host, end
to end, against the protocol's client. Loopback only: the environment asks
for it, and the only advertiser here records calls.

#### Publisher's first pass runs after its debounce, so test polls
`a_phone_pairs_syncs_changes_status_asks_and_is_removed`: The publisher's first pass runs after its debounce.

#### Device recording queues like local one; one event updates list and publisher
`a_stored_recording_is_queued_like_a_finished_one_and_shown`: Queued like a recording finished on this computer, which waits for missing
models, and the Meetings list and the publisher hear of it from the one event.

#### Repeat request with same id attaches to running answer; model runs once
`an_answer_outlives_the_connection_that_asked`: A device that asks again with the same id attaches to the answer this
computer is still writing: the model runs once and both get the result.
`lokalbot-sync`'s own tests cover a device that dropped its connection.

#### Sync key must never be written to a file
`a_missing_credential_store_says_why_and_listens_for_nothing`: The key never reached a file.

#### Pairing code reads addresses when made so new networks reach next device
`a_code_carries_the_current_addresses`: The addresses a code carries are read when it's made, so a new network or
Tailscale coming up reaches the next device.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
