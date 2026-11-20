# 0012. Mac app: CLISupport — MeetingImport

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/CLISupport/MeetingImport/`, `LokalBot/CLISupport/MeetingImport/Readers/`, `LokalBotTests/CLISupport/MeetingImport/Readers/`.

## Decisions

### `LokalBot/CLISupport/MeetingImport/ExternalImportText.swift`

#### Accepted timestamp formats and units
`ExternalImportText.timestamp`: "01:02:03,450", "01:02:03.450", "1:02:03", "02:03", or "02:03.5" in
seconds. Nil for anything else.

#### Missing time zone is read as UTC
`ExternalImportText.date`: ISO 8601 with or without fractional seconds or a time zone (a
missing zone is read as UTC, as the formats that omit it mean).

#### Same parts always hash to the same 32-hex id
`ExternalImportText.stableID`: A 32-character hex id from parts that identify a meeting when the
source has no id of its own. The same parts always give the same id.

#### Text encoding fallback order UTF-8, UTF-16, Windows-1252; normalize line endings
`ExternalImportText.readText`: UTF-8 (with or without a byte-order mark), else UTF-16 with a mark,
else Windows-1252, the encodings exports use. Line endings become "\n".

#### Sorted file walk skips hidden files and macOS archive litter
`ExternalImportText.files`: Regular files under `folder` (or `folder` itself when it is a file),
sorted by path, skipping hidden files and macOS archive litter.

#### File-name titles drop extension and turn underscores into spaces
`ExternalImportText.title`: A title from a file name: no extension, underscores as spaces.

#### Treat text before colon as speaker only if it reads like a name
`ExternalImportText.splitSpeaker`: Splits "Ana Petrović: Let's ship it" into a speaker and the rest when
the part before the colon reads like a name: short, starting with a
letter, and without sentence punctuation.

#### SRT and WebVTT supported; speaker from voice tag or Name: prefix
`SubtitleTranscript`: SubRip (`.srt`) and WebVTT (`.vtt`) captions, the transcript exports
Otter, Fireflies, Zoom, and MacWhisper all offer. A speaker comes from a
WebVTT voice tag (`<v Ana>`) or a leading "Name:".

#### WebVTT allows cue settings after the end time
`SubtitleTranscript.parse`: WebVTT allows cue settings after the end time.

#### Merge consecutive same-speaker cues into one turn
`SubtitleTranscript.parse`: Consecutive cues from the same speaker read as one turn.

#### WebVTT voice tags may carry classes before the name
`SubtitleTranscript.voiceTag`: `<v.loud Ana>` carries classes before the name.

### `LokalBot/CLISupport/MeetingImport/ExternalMeeting.swift`

#### Raw value is the import CLI argument and importSource.app value
`ExternalMeetingSource`: Another app's meetings LokalBot can bring in. The raw value is what
`lokalbot-cli import` takes and what a meeting's `importSource.app` stores.

#### Hint uses the source's own menu wording; shown in import panel
`ExternalMeetingSource.exportHint`: What the person points LokalBot at, said the way the source's own
menus say it. Shown in the import panel and by `import sources`.

#### Default locations use ~ and apply when no path is given
`ExternalMeetingSource.defaultLocations`: Where the source keeps data LokalBot can read on this computer, with
`~` for the home folder. Used when the person names no file or folder.

#### Readers fill it; ExternalMeetingWriter turns it into a meeting folder
`ExternalMeeting`: One meeting as another app kept it, before LokalBot stores it. Readers
fill it from exports or local files; `ExternalMeetingWriter` turns it into
a meeting folder.

#### Line times are seconds from meeting start when the source kept them
`ExternalMeeting.Line.start`: Seconds from the start of the meeting, when the source kept them.

#### Speaker is the source's label; nil when source names nobody
`ExternalMeeting.Line.speaker`: The name the source shows, such as "Ana" or "Speaker 2". Nil when
the source names nobody.

#### Lines from the user's own microphone become Me
`ExternalMeeting.Line.isMe`: The source says this came from the person's own microphone, as
Granola does for its "microphone" lines. Such lines become "Me".

#### Stable source id makes re-imports skip the meeting
`ExternalMeeting.sourceID`: Stable within the source: the same meeting read twice, from the same
or a newer export, gets the same id, so importing again skips it.
Prefer the source's own id; otherwise hash what can't change, such as
the start time and title.

#### Source notes are stored as Markdown
`ExternalMeeting.notes`: The source's own notes or summary, as Markdown.

#### Recording is kept; transcribed when source had no transcript
`ExternalMeeting.audioURL`: A recording to keep with the meeting. LokalBot transcribes it when the
source had no transcript.

#### importKey is how a meeting's importSource is matched
`ExternalMeeting.importKey`: The key a meeting's `importSource` is matched on.

#### Problems name files, never their contents
`ExternalImportScan`: What reading a file or folder found: the meetings, and what couldn't be
read and why. Problems name files, never their contents.

#### Readers only read and open databases read-only
`ExternalMeetingReader`: Reads one source's exports or local files. A reader only reads: it never
writes, moves, or changes what it reads, and opens databases read-only.

#### Export hint is one or two sentences in the source's own wording
`ExternalMeetingReader.exportHint`: Where to find what this reader reads, said the way the source's own
menus say it, in one or two sentences.

#### Default locations empty when source needs an export
`ExternalMeetingReader.defaultLocations`: Paths with `~` for the home folder where the source keeps data this
reader can read without an export. Empty when it needs an export.

#### Quick check from names, extensions or header, used to pick files in folders
`ExternalMeetingReader.recognizes`: A quick check, from names, extensions, or a header, that `url` holds
this source's data. Used to pick files inside a folder.

#### Throw only when nothing is readable; single bad items go to problems
`ExternalMeetingReader.read`: Every meeting in `url`, a file or a folder. Throws only when nothing
in it can be read; single bad items go to `problems`.

#### Zips unpacked to temp; callers run cleanup; dedupe by id, drop empties
`ExternalMeetingReaders.scan`: Reads every url with `source`'s reader. A `.zip` is unpacked into a
temporary folder first; `cleanup` removes those folders, so call it
once nothing reads the meetings' `audioURL`s any more. Meetings with
the same source id are kept once, and empty ones are dropped.

#### Staged recordings go to temp folders cleaned up with the rest
`ExternalMeetingReaders.scan`: A reader that had to stage a recording (MacWhisper unpacks the one
inside a .whisper document) leaves it in a `lokalbot-import-…`
temporary folder. Those copies go with the rest, including ones for
meetings dropped below.

#### Staged folders are lokalbot-import-prefixed folders directly under temp directory
`ExternalMeetingReaders.stagedFolders`: The temporary folders, directly under the temporary directory and
named `lokalbot-import-…`, that hold meetings' recordings.

#### Use ditto for zips: ships with macOS and keeps Unicode names
`ExternalImportArchive`: Unpacks a `.zip` export with `ditto`, which ships with macOS and keeps
Unicode file names intact.

### `LokalBot/CLISupport/MeetingImport/Readers/FathomMeetingReader.swift`

#### Fathom inputs: copied transcript, summary, MP4 and API JSON; nothing fetched or written
`FathomMeetingReader`: Reads what a person can take out of Fathom, which keeps calls in its cloud
and has no export file:

- the transcript a call page's "Copy Transcript" button copies, pasted into
  a `.txt` or `.md` file: a "Title - Month Day" line, a "VIEW RECORDING"
  line with the call's share link, `---`, then turns such as
  "1:02:03 - Ana Petrović (Acme)" with indented speech, and BOOKMARK,
  HIGHLIGHT, and ACTION ITEM marks inside them;
- the summary "Copy Summary" copies, plain or Markdown, with or without
  links, under the same header;
- the MP4 "Download Video" saves, named after the meeting title;
- meeting JSON in the shape Fathom's API and webhooks return
  (`recording_id`, `share_url`, `transcript`, `default_summary`,
  `action_items`), alone, in a list response's `items`, or in an array.

Files of one call are joined by the share link they carry, and a video by
its file name. Nothing is written and nothing is fetched.

#### Fathom keeps calls in its cloud, nothing on the Mac
`FathomMeetingReader.defaultLocations`: Fathom keeps calls in its cloud, not on this Mac.

#### Download Video saves MP4; MP3 listed as coming
`FathomMeetingReader.recordingExtensions`: "Download Video" saves MP4; Fathom's help lists MP3 as coming.

#### Section names come from Fathom's default summary and API Summary
`FathomMeetingReader.sectionNames`: The sections of Fathom's default summary, and the API's "Summary".

#### WATCH link suffix points back into the recording
`FathomMeetingReader.watchPattern`: " - WATCH: \<link>" or " - WATCH (5 secs): \<link>" after a mark or a
summary line, pointing back into the recording.

#### Keep link text, drop Fathom links since they die with the account
`FathomMeetingReader.fathomLinkPattern`: A Markdown link into Fathom; its text is kept and the link dropped,
since it stops working once the account is gone.

#### Transcript and summary endpoints return recognizable keys on their own
`FathomMeetingReader.looksLikeMeetingJSON`: What the transcript and summary endpoints return on their own.

#### Headerless copies recognized by turn lines followed by indented speech
`FathomMeetingReader.looksLikeCopiedText`: Without the header: Fathom's turn lines, each followed by indented speech.

#### Failure reasons never quote file contents
`FathomMeetingReader.Failure`: Why a file couldn't be read, said without quoting it.

#### Rank API JSON over copied transcript over summary on conflict
`FathomMeetingReader.Part.Kind`: Lower ranks win when files of one call disagree: the API's JSON has
exact times and owners, a copied transcript beats a summary.

#### Normalized names a downloaded video of this call may carry
`FathomMeetingReader.Part.names`: Names a downloaded video of this call may carry, normalized.

#### Source listed all action items so other files' guesses don't add
`FathomMeetingReader.Part.actionsListed`: The source listed its action items, done ones included, so other
files' guesses don't add to them.

#### Join by order found; videos go to the one matching call or stand alone
`FathomMeetingReader.assemble`: Joins the files of each call, in the order they were found, then gives
each video to the one call its name points to. A video no call claims,
or more than one could, is a meeting of its own.

#### Strip browser's (1) suffix from repeat downloads when matching names
`FathomMeetingReader.recordingName`: A video's name as a call would know it: no extension, no " (1)" a
browser adds to a second download of the same name.

#### Copied text may hold transcript, summary or both in one file
`FathomMeetingReader.copiedText`: A transcript or summary copied from a call page, or both pasted into
one file. Nil when it holds neither.

#### Indented speech means margin headings start a pasted summary
`FathomMeetingReader.copiedText`: Speech is indented, so a section heading at the margin starts a
summary pasted after the transcript.

#### Turn lines at margin; strip company or email from speaker name
`FathomMeetingReader.turn`: "1:02:03 - Ana Petrović (Acme)" as a start and a name without the
company or email Fathom puts in parentheses. Turn lines start at the
margin; speech under them is indented.

#### Fathom marks inside turns; speech after WATCH link is kept
`FathomMeetingReader.annotation`: A mark Fathom puts in a turn: "ACTION ITEM: …", "BOOKMARK: … - WATCH:
\<link>  speech", "HIGHLIGHT: …", or the " - WATCH: \<link>  speech" line
that can follow an action item. Speech after the link is kept.

#### Header date is the last dash part; nil if it isn't a date
`FathomMeetingReader.splitTitle`: "Weekly sync - Q3 - May 19" → ("Weekly sync - Q3", "May 19"). The date
is nil when the last part isn't one.

#### Header writes day as 'May 19' with optional year
`FathomMeetingReader.monthDay`: "May 19" or "May 19, 2025", as Fathom's header writes the call's day.

#### Yearless header date resolves to latest day not after file save
`FathomMeetingReader.startOfDay`: The day's local midnight. The header has no year, so it is the latest
one that doesn't put the call after the file was saved.

#### Duration read from VIEW RECORDING line minutes
`FathomMeetingReader.minutes`: "VIEW RECORDING - 48 mins (No highlights): …" → 48.

#### Call id is share-link token, else calls-link id
`FathomMeetingReader.fathomID`: Fathom's id for a call: the token of its share link, else the id in a
calls link.

#### Plain copies regain headings; actions from Action Items else Next Steps
`FathomMeetingReader.summaryNotes`: A copied summary as Markdown, and the action items it lists: its
"Action Items" section, else its "Next Steps" with their owners. Plain
copies get headings back: Fathom's section names, and a short line
followed by bullets (a topic under "Topics").

#### Accept single object, items list, array, or bare endpoint payloads
`FathomMeetingReader.jsonMeetings`: Meetings in a JSON file: one meeting object, a list response's
`items`, or an array of them. The transcript and summary endpoints'
`{"transcript": […]}` and `{"summary": {…}}` count too, titled from the
file name.

#### Writer lists only open items so lists with done items are written here
`FathomMeetingReader.jsonMeeting`: The writer lists only open items, so a list with done ones is
written here, marked as Fathom has them.

#### API transcript line JSON shape
`FathomMeetingReader.jsonLine`: `{"speaker": {"display_name": …}, "text": …, "timestamp": "00:05:32"}`.

#### Highlight rendered as bold label, time, summary and quoted text
`FathomMeetingReader.highlightRow`: "- **Objection** at 0:16: Pushed back on price — “They pushed back hard”".

### `LokalBot/CLISupport/MeetingImport/Readers/FirefliesMeetingReader.swift`

#### Undocumented Fireflies downloads are read defensively across formats
`FirefliesMeetingReader`: Reads what Fireflies.ai lets a person download for a meeting, from the
Download icon at the bottom of the meeting: the transcript (JSON, SRT, CSV,
or MD), the summary (JSON or MD), and the audio (MP3) or video (MP4). It
also reads JSON shaped like the Fireflies API's `transcript`, which API
backup tools save, and the text transcripts, summaries, and JSON metadata
of an account data export. Files of one meeting are put together by name
("Weekly sync transcript.json" and "Weekly sync summary.md") or by sharing a
folder of their own. PDF and DOCX downloads aren't read.

Fireflies doesn't document the layout of its downloads, so each format is
read defensively: JSON keys match without regard to case or underscores,
times may be seconds, milliseconds, or "00:01:02", and text transcripts
may put the speaker and time before each line or on a line above it.

#### Fireflies keeps meetings in its cloud; nothing readable on the Mac
`FirefliesMeetingReader.defaultLocations`: Fireflies keeps meetings in its cloud; nothing readable stays on the Mac.

#### Failure reasons never quote the file
`FirefliesMeetingReader.Failure`: Why one file couldn't be read. Never quotes the file.

#### Pieces of one meeting are merged before becoming a meeting
`FirefliesMeetingReader.Piece`: What one file says about a meeting. Several pieces of one meeting
(transcript, summary, metadata) are merged before it becomes one.

#### Marks pieces from a JSON file holding several meetings
`FirefliesMeetingReader.Piece.fromCollection`: Came from a JSON file holding several meetings.

#### JSON fields win over text guessed from layout
`FirefliesMeetingReader.Piece.isStructured`: Came from JSON, whose fields win over text guessed from a layout.

#### A recording chosen alone is transcribed by LokalBot
`FirefliesMeetingReader.readFile`: A recording chosen on its own: LokalBot transcribes it.

#### Recording joins a meeting only if transcript or notes sit beside it
`FirefliesMeetingReader.readFolder`: A recording only joins a meeting whose transcript or notes
sit beside it; on its own it is just an audio file.

#### Quick recognition checks read only the first 64 KB
`FirefliesMeetingReader.peek`: The first 64 KB, for the quick checks in `recognizes`.

#### Account exports keep meeting details without a transcript
`FirefliesMeetingReader.looksLikeFirefliesJSON`: Meeting details without a transcript, as an account export keeps them.

#### Group files by name stem minus role words; collection meetings match by id or title
`FirefliesMeetingReader.assemble`: One meeting per group of files: a folder's files that share a name
once words like "transcript" or "summary" are dropped, or all of a
folder's files when it holds one meeting. Meetings from a JSON file
that holds several take in the groups that name their id or title.

#### Keep different meetings sharing a name apart
`FirefliesMeetingReader.assemble`: Different meetings that happen to share a name: keep them apart.

#### Match by id in a file path, else the only matching title
`FirefliesMeetingReader.collectedMatch`: The meeting of a several-meeting JSON file that a group of files
belongs to: one whose id is in a file's path, else the only one with
the group's name as its title.

#### JSON beats guessed text; timed transcript beats untimed
`FirefliesMeetingReader.merge`: One meeting from its pieces. JSON wins over text guessed from a
layout, and a timed transcript wins over an untimed one.

#### Prefer Fireflies id; else hash stable across newer downloads
`FirefliesMeetingReader.sourceID`: Fireflies' own id when a file kept it (a JSON `id` or a link to the
meeting); otherwise a hash of the start and title, or of the title and
the first words, which a newer download of the same meeting repeats.

#### Strip role words from file names to group parts of a meeting
`FirefliesMeetingReader.groupStem`: A file's name without words that only say which part of a meeting it
holds, as letters and digits: "Weekly_sync - Transcript" is "weekly sync".

#### Strip trailing transcript-like words but keep titles like Team notes
`FirefliesMeetingReader.fallbackTitle`: "Design sync transcript", but not "Team notes" or "Spatial audio".

#### Generic file in own folder takes the folder name as title
`FirefliesMeetingReader.fallbackTitle`: "transcript.txt" in a folder of its own: the folder names the meeting.

#### Meeting id sits in app.fireflies.ai/view/Title::ID links
`FirefliesMeetingReader.viewID`: The meeting's id in a link to it, "app.fireflies.ai/view/Title::ID".

#### Without :: only a bare id counts since titles aren't unique
`FirefliesMeetingReader.viewID`: Without "::" only a bare id counts; a title alone isn't unique.

#### Drop Fireflies branding lines that say nothing about the meeting
`FirefliesMeetingReader.isBranding`: "Powered by Fireflies.ai" and links back to Fireflies, which branded
downloads add and which say nothing about the meeting.

#### Unwrap GraphQL data envelope around payload
`FirefliesMeetingReader.jsonPieces`: GraphQL answers wrap the payload: {"data": {"transcript": {…}}}.

#### Keep sibling summary beside a transcript object
`FirefliesMeetingReader.jsonPieces`: {"transcript": {…}, "summary": {…}} keeps the summary beside it.

#### Fireflies may keep all addresses in one comma-separated string
`FirefliesMeetingReader.meetingPiece`: Fireflies sometimes keeps every address in one comma-separated string.

#### API duration is minutes; detect files that counted seconds
`FirefliesMeetingReader.meetingPiece`: The API counts minutes. A file that counted seconds gives about
the transcript's own length, which as minutes would be far too long.

#### Summary downloads may keep fields at top level
`FirefliesMeetingReader.meetingPiece`: A summary download may keep its fields at the top level.

#### Summary order follows meeting page; action items kept out of notes
`FirefliesMeetingReader.summaryNotes`: Fireflies' summary fields as Markdown, in the order its meeting page
shows them, and its action items. Action items stay out of the notes;
the writer lists them after.

#### Fireflies action items grouped under bold owner names with trailing times
`FirefliesMeetingReader.actionItems`: Fireflies writes action items as lines grouped under each owner's
name in bold, each ending with when it was said: "**Ana**\nSend the
deck (03:12)".

#### Join sentences into turns like subtitle cues so JSON and SRT read alike
`FirefliesMeetingReader.sentenceLines`: Sentences as transcript lines, joined into turns the way subtitle
cues are, so a meeting reads the same from JSON or SRT.

#### Detect millisecond times by comparing latest time to duration
`FirefliesMeetingReader.sentenceLines`: Times in milliseconds would put the meeting's end many times past
its length, or days away when the file doesn't say its length.

#### JSON keys match ignoring case, underscores and spaces
`FirefliesMeetingReader.field`: A value under any of `names`, matching keys without regard to case,
underscores, or spaces: "speakername" finds "speaker_name".

#### Times accepted as numbers or timestamp strings, in seconds
`FirefliesMeetingReader.time`: Seconds from a number or from "62.5" or "00:01:02.5".

#### API date is milliseconds since 1970; other files use seconds or ISO
`FirefliesMeetingReader.date`: The API's `date` counts milliseconds since 1970; other files may
count seconds or write ISO 8601.

#### CSV parsed per RFC 4180 with quoted delimiters and line breaks
`FirefliesMeetingReader.delimitedRows`: RFC 4180 rows: quoted fields may hold the delimiter, quotes ("") and
line breaks.

#### Text downloads: header details then sections in any order
`FirefliesMeetingReader.TextDocument`: What a text download says: a title and details at the top, then
summary sections, action items, and the transcript, in any order.

#### Notes keep headings; a transcript heading is not a line
`FirefliesMeetingReader.textDocument`: Notes keep their headings; a transcript's isn't a line.

#### A section can start on one line like Action items: text
`FirefliesMeetingReader.textDocument`: "Action items: Send the deck" starts a section on one line.

#### Preamble is a transcript when mostly spoken lines, else notes
`FirefliesMeetingReader.textDocument`: The part before any heading: a transcript when most of it is
spoken lines, else notes.

#### Headings are Markdown headings, bold lines or known section names
`FirefliesMeetingReader.headingText`: The text of a Markdown heading, a line in bold, or a line that is only
a known section name such as "Action Items:".

#### Durations accepted as clock, minutes or hours-minutes forms
`FirefliesMeetingReader.durationValue`: "00:32:10", "32 min", or "1h 5m" in seconds.

#### Standalone time applies to the line below
`FirefliesMeetingReader.Row.time`: A time on its own line, for the line below it.

#### Firm headers are unambiguous speaker rows
`FirefliesMeetingReader.Row.header`: A speaker, and maybe a time, above what they said. `firm` when the
row can't be anything else ("**Ana**", "Ana:", "Ana (00:01)").

#### Support several text transcript layouts including speaker above speech
`FirefliesMeetingReader.transcriptLines`: Lines from a text transcript in any of the layouts Fireflies and
other tools write: "[00:01:02] Ana: …", "Ana (00:01): …", "Ana: …",
or the speaker and time on a line above what they said.

### `LokalBot/CLISupport/MeetingImport/Readers/GranolaMeetingReader.swift`

#### Import only Granola's handed-over export, copied note and transcript; never its encrypted files
`GranolaMeetingReader`: Reads what Granola lets a person take out of it. Granola keeps its own
data on this Mac encrypted (`cache-v6.json.enc`, `granola.db`), so
LokalBot never opens those; it reads the files Granola hands over:

- **The historical data export.** Settings → Profile → Export historical
  data → Generate CSV, emailed as a `.csv` or a `.zip` of them. One row
  per note: `document_id`, `user_email`, `document_title`,
  `workspace_name`, `document_created`, `summary` (the AI-enhanced notes,
  Markdown), `notes` (what the person typed), and `transcript`.
- **A copied note.** "Copy notes" puts Markdown on the clipboard: `# Title`,
  a "Tue, 03 Nov 26 · Ana, Leo" line, the notes, and a closing "Chat with
  meeting transcript:" link. Saved by the person as `.md` or `.txt`.
- **A copied transcript.** The transcript panel's copy button gives
  "Meeting Title:", "Date:", and "Meeting participants:" lines, then
  "Transcript:" and one "Speaker: text" line per turn.

Transcript lines carry Granola's own labels: "Me" for the person's
microphone, "Them" for system audio, a display name from speaker tags,
or "Speaker A" from diarization. Granola keeps no audio and no line times,
so these meetings have neither.

#### No default location because Granola's own files are encrypted
`GranolaMeetingReader.defaultLocations`: Granola's own files on this Mac are encrypted, so there is nothing to
read without an export.

#### Sniff only first and last kilobytes, never the whole file
`GranolaMeetingReader.kind(of:)`: Reads at most the first and last few kilobytes, never the whole file.

#### A copy without the link still opens with title and date line
`GranolaMeetingReader.kind(of:)`: A copy without the link still opens with `# Title` and Granola's date line.

#### Recognise Granola CSV by document_* column names other tools lack
`GranolaMeetingReader.isExportHeader`: Granola's own column names; other tools' CSVs don't use `document_*`.

#### Copied notes layout: title, date and attendees line, notes, rule and link
`GranolaMeetingReader.readCopiedNotes`: "Copy notes": `# Title`, a "Tue, 03 Nov 26 · Ana, Leo" line, the notes,
then a rule and the "Chat with meeting transcript:" link.

#### Transcript panel copy layout: header lines, Transcript:, then turns
`GranolaMeetingReader.readCopiedTranscript`: The transcript panel's copy: header lines, "Transcript:", then turns.

#### Copied note and transcript with same title and day merge into one meeting
`GranolaMeetingReader.mergeCopies`: A copied note and a copied transcript of the same meeting (same title
and day) become one meeting, kept under the note's id.

#### Lowercase UUID ids so the same note matches across files
`GranolaMeetingReader.documentID`: The source's id; a UUID is lowercased so the same note matches
whichever file it came from.

#### Only /d/ note links carry the id; shared /t/ links carry a slug
`GranolaMeetingReader.documentID(inLink:)`: A note link of the form `…granola.ai/d/<document id>`. Shared `/t/`
links carry a slug, not the id.

#### document_created is ISO 8601; database-style and epoch values also read
`GranolaMeetingReader.exportDate`: `document_created` is ISO 8601 ("2026-10-24T14:34:40.866Z"); a
database-style "2026-10-24 14:34:40.866+00" or epoch number is read too.

#### Granola dates are British English with non-breaking spaces; placed at local noon
`GranolaMeetingReader.notesDateLine`: "Tue, 03 Nov 26 · Ana Petrović, Leo" — Granola writes the date in
British English and joins the parts with non-breaking spaces. The
date has no time, so the meeting is placed at local noon.

#### Yearless transcript date resolves to latest such day not after file save
`GranolaMeetingReader.monthDay`: "Nov 3", as a copied transcript dates itself: no year, so the latest
such day not after the file was saved, at local noon.

#### Enhanced notes first, typed notes under My notes unless already included
`GranolaMeetingReader.composeNotes`: The AI-enhanced notes, then what the person typed under "My notes"
(Granola's own name for them) unless the summary already holds it.

#### Granola footer rule and transcript link point to its cloud copy and are stripped
`GranolaMeetingReader.strippingFooter`: Granola ends enhanced notes with a rule and "Chat with meeting
transcript: \<link>", which points back at its cloud copy.

#### checked is nil for plain bullet, false for [ ], true for [x]
`GranolaMeetingReader.ListEntry.checked`: Nil for a plain bullet, false for "[ ]", true for "[x]".

#### Action items: unchecked tasks, bullets under next-steps headings, name bullets as owners
`GranolaMeetingReader.actionItems`: Unchecked "- [ ]" items anywhere, and every bullet under a heading
such as "Next Steps" or "Action Items". A bullet that is only a name
with tasks under it ("- Ana" / "  - Send the deck") names their owner,
as does "Ana: send the deck".

#### Headings include markdown hashes or a bold-only line
`GranolaMeetingReader.headingText`: "### Next Steps" or a line that is only bold, "**Action Items:**".

#### Owner bullet is one to four capitalized words
`GranolaMeetingReader.ownerName`: A bullet that is only a person's name: one to four capitalized words.

#### Strip emphasis only when notes contain it plain, avoiding duplicate listing
`GranolaMeetingReader.displayText`: The item without emphasis or escapes when the notes still contain it
that way, so LokalBot doesn't list it twice; otherwise as written.

#### Them or unnamed source means other people, not told apart
`GranolaMeetingReader.Speaker.unnamed`: "Them" or an unnamed source: other people, not told apart.

#### Speaker A or room labels are a voice, not a known person
`GranolaMeetingReader.Speaker.voice`: "Speaker A", "Speaker 2", or "[Room] Board room": a voice, not a known person.

#### Fixed labels accepted anywhere; names only when most lines are labeled
`GranolaMeetingReader.parseTranscript`: Granola writes one turn per line as "Label: text". Labels it always
uses ("Me", "Them", "Speaker A", "[Room] …") are taken wherever they
appear; a name is taken only when most lines are labeled, so a line
such as "and then she said: we ship" stays text. Lines without a
label continue the turn before them, or are unattributed when the
transcript has no labels at all.

#### Granola's copy starts a new line at each mid-line Speaker A
`GranolaMeetingReader.parseTranscript`: Granola's own copy starts a new line at each mid-line "Speaker A: ".

#### Display name heuristic: not lowercase start, at most six words, no sentence punctuation
`GranolaMeetingReader.isDisplayName`: A display name as meeting apps show them: "Ana Petrović", "Ana P.",
"Ana (Acme)", "Leo Marić (he/him)". Not a sentence: it doesn't start
lowercase, has at most six words, and no sentence punctuation.

#### Text ending inside quotes means a cut-off export; unfinished row dropped
`GranolaMeetingReader.CSVTable.endsInsideQuotes`: The text ended inside a quoted field: the export was cut off.
The unfinished row is left out.

#### RFC 4180 parsing because Granola transcripts hold commas, quotes and line breaks
`GranolaMeetingReader.parseCSV`: RFC 4180: quoted fields may hold commas, quotes (doubled), and line
breaks; transcripts in Granola's export do all three.

### `LokalBot/CLISupport/MeetingImport/Readers/MacWhisperMeetingReader.swift`

#### Reads .whisper, library database and exports; never writes or sends anything
`MacWhisperMeetingReader`: Reads MacWhisper (Good Snooze) transcripts from three places:

- `.whisper` documents. A `.whisper` file is a zip holding `metadata.json`
  (segments with millisecond `start`/`end`, a `speaker` object, and
  `dateCreated` as seconds since 2001) and `originalAudio`, the recording.
  The recording is unpacked into a temporary folder so it can be imported.
- MacWhisper's own library, `~/Library/Application Support/MacWhisper/
  Database/main.sqlite` (GRDB): sessions, transcript lines in
  milliseconds, speakers, recorded meetings, AI summaries, and recordings
  in `Database/ExternalMedia`. Opened read-only with `immutable=1`; when
  MacWhisper still holds changes in its write-ahead log, a private copy of
  the database and log is read instead, so the originals are never opened.
- What the Export button saves: SRT, WebVTT, JSON (the Segments export and
  the structured export), CSV (semicolon-separated start, end, transcript,
  speaker), TXT, Markdown, and DOCX. A recording with the same name beside
  an export is kept with it.

Nothing is written next to what is read, and nothing is sent anywhere.

#### Failure reasons never quote file content
`MacWhisperMeetingReader.Failure`: Why one file couldn't be read, in words that never quote its content.

#### Kinds ordered richest first; only richest of same-name exports is read
`MacWhisperMeetingReader.Kind`: Ordered richest first: when exports of one transcript share a name,
only the richest is read.

#### In folders take only main.sqlite; hand-picked databases checked for tables
`MacWhisperMeetingReader.kind(of:chosen:)`: Inside a folder only MacWhisper's own database is taken; a file
the person picks by hand is checked for MacWhisper's tables.

#### Exports of one transcript share a name; the richest wins
`MacWhisperMeetingReader`: Exports of one transcript share its name; the richest one wins.

#### Export id hashes the spoken words so re-exports stay one meeting
`MacWhisperMeetingReader.exportedMeeting`: One meeting from an export, which keeps no id or date of its own. Its
id comes from the words said, so the same transcript exported again,
or as SRT and as WebVTT, is still one meeting; a short transcript adds
its title so two brief clips that say the same thing stay apart.

#### Unpacked .whisper document is metadata.json beside originalAudio
`MacWhisperMeetingReader.readJSON`: An unpacked .whisper document: metadata.json beside originalAudio.

#### Structured export has millisecond start and end per segment
`MacWhisperMeetingReader.readJSON`: The structured export: millisecond start and end per segment.

#### Segments export shape: timestamp range, text, speaker
`MacWhisperMeetingReader.readJSON`: The Segments export: [{"timestamp": "00:05-00:07", "text", "speaker"}].

#### Times are milliseconds unless fractional values, then seconds
`MacWhisperMeetingReader.timedLines`: Lines from JSON segments, timed either by a "timestamp" range or by
numeric start and end. MacWhisper writes milliseconds; a segment list
with fractional values is read as seconds.

#### MacWhisper dates: 2001 epoch, unix s or ms, GRDB UTC text, ISO 8601
`MacWhisperMeetingReader.date`: A date MacWhisper stored: Swift's default encoding (seconds since
2001), seconds or milliseconds since 1970, GRDB's "2026-03-18
18:12:42.251" in UTC, or ISO 8601.

#### Action items from checkboxes and bullets under action headings
`MacWhisperMeetingReader.actionItems`: Action items in an AI summary: checkboxes anywhere, and bullets under
a heading such as "Action items" or "Next steps".

#### AI title may hold a structured note; keep only subject line
`MacWhisperMeetingReader.cleanedAITitle`: MacWhisper sometimes keeps a structured note as its AI title
("Subject: …"); this keeps only the subject line.

#### Early .whisper files may be the metadata alone
`WhisperDocument.read`: Early .whisper files may be the metadata alone.

#### recording closure takes name and extension, returns importable location
`WhisperDocument.meeting`: A meeting from `metadata.json`. `recording` gets a file name and an
extension for the recording and returns where it can be imported from.

#### Unpack to temp folder keyed by checksum and size for reuse
`WhisperDocument.unpackRecording`: Unpacks the recording into a temporary folder named after its
checksum and size, so reading the document again, or another copy of
it, reuses what was unpacked before.

#### Copy extensionless originalAudio to a temp file with extension; APFS clone is cheap
`WhisperDocument.copyRecording`: Copies an unpacked document's `originalAudio`, which has no extension,
to a temporary file that has one. APFS clones the file, so this is cheap.

#### Key by size, date and opening bytes since zip unpack path varies
`WhisperDocument.copyRecording`: Size, date, and opening bytes rather than the path, which differs
each time a zip holding the document is unpacked.

#### Detect container from first bytes when extension was not kept
`WhisperDocument.sniffedExtension`: The container a recording's first bytes name, for files whose
extension MacWhisper didn't keep.

#### ADTS raw AAC distinguished from MP3 by layer bits 00
`WhisperDocument.sniffedExtension`: Both start with a frame sync; ADTS (raw AAC) has layer bits 00.

#### Minimal zip reader: central directory, Zip64, stored or deflated, memory-mapped
`MacWhisperZip`: The few parts of the zip format a `.whisper` document or a `.docx` uses:
the central directory (with Zip64 sizes) and stored or deflated entries,
read from a memory-mapped file.

#### Foundation's zlib is raw DEFLATE, as zip stores it
`MacWhisperZip.contents`: Foundation's zlib algorithm is raw DEFLATE, as zip stores it.

#### Out-of-range reads return -1, which matches no signature
`MacWhisperZip.uint16`: Little-endian integers; -1 when out of range, which no signature matches.

#### MacWhisper CSV is semicolon rows start,end,text,speaker; header, commas, other order accepted
`MacWhisperCSV`: MacWhisper's CSV: semicolon-separated rows of start, end, transcript, and
a speaker when one was detected. A header row, commas, or another column
order are accepted too.

#### Without header the longer of last two columns is the text
`MacWhisperCSV.parse`: Without a header, the longer of the last two columns is the text.

#### Supported MacWhisper text export layouts and markdown handling
`MacWhisperText`: MacWhisper's text exports: plain paragraphs; speaker blocks ("Speaker 1"
on its own line, then what they said); timestamp lines ("00:05",
"00:00:01,000 --> 00:00:04,000"); lines that start with a timestamp
("[00:05] …"); and "Name: …" lines. Markdown emphasis and headings are
read through, and a leading "# Title" names the meeting.

#### Bare leading times count as timestamps only if consistent, not '10:30 works'
`MacWhisperText.parse`: First pass: what each line is, and whether lines that start with a
bare time do so consistently enough to be timestamps, not "10:30 works".

#### Name prefix on a timed segment is MacWhisper's speaker prefix
`MacWhisperText.parse`: A timed segment's "Name:" is MacWhisper's speaker prefix, as in subtitles.

#### Rules for accepting standalone speaker-name lines
`MacWhisperText.speakerHeaders`: Lines standing alone as a speaker's name: name-like, followed by what
they said, and either a "Speaker N" label, a heading, beside a
timestamp line, or used at least twice. When any line passes, every
name-like line in that position does.

#### Once layout is speaker blocks, single-use names are speakers too
`MacWhisperText.speakerHeaders`: Once the layout is plainly speaker blocks, a name used only once is
a speaker too.

#### Speaker heading is short, letter-first, without sentence punctuation
`MacWhisperText.headerName`: The name in a line that could be a speaker heading: short, starting
with a letter, without sentence punctuation; a trailing colon is allowed.

#### main.sqlite GRDB tables used; columns looked up by name for version tolerance
`MacWhisperLibrary`: `Database/main.sqlite`, as GRDB keeps it: `session` (one per
transcription), `transcriptline` (text, start and end in milliseconds,
`speakerID`), `speaker`, `recordedmeeting` and `systemaudiorecording`
(whose `date` is when recording stopped), `voicememos`, and `mediafile`
(recordings in `ExternalMedia`). Columns are looked up by name, so a
version without one still reads.

#### Podcasts and downloaded videos are not meetings
`MacWhisperLibrary.read`: Podcasts and downloaded videos aren't meetings.

#### Meetings with separate mic and app tracks import transcript only
`MacWhisperLibrary.recordingFile`: The session's recording when it is one file. A meeting kept as
separate microphone and app-audio tracks has no single recording, so
only its transcript comes along.

#### GRDB 16-byte UUID blobs become lowercase hex ids
`MacWhisperLibrary.key`: GRDB keeps ids as 16-byte UUID blobs; they become lowercase hex.

#### Deletion date set means anything but null or zero
`MacWhisperLibrary.isSet`: A deletion date: anything but null or zero.

#### Open immutable; copy database and WAL to temp when log is non-empty
`MacWhisperDatabase`: A read-only connection to MacWhisper's database. The file is opened with
`immutable=1`, which never creates `-wal` or `-shm` files beside it. GRDB
keeps a persistent write-ahead log that MacWhisper doesn't fold back on
quit, and an immutable open can't see it; when the log isn't empty, the
database and log are copied to a private temporary folder and that copy
is read instead, then removed.

### `LokalBot/CLISupport/MeetingImport/Readers/OtterMeetingReader.swift`

#### Otter needs an export; TXT/DOCX/SRT layouts and id hashed from name and words
`OtterMeetingReader`: Reads Otter.ai conversations from what Otter's Export dialog gives: TXT,
DOCX, and SRT files, one at a time or many in a bulk export's ZIP, with
the MP3 its Audio toggle adds. Otter keeps nothing on this computer that
LokalBot can read, so it always needs an export. PDF exports aren't read.

A TXT turn is a header, the speaker's name, two spaces, and the time it
starts (`Ana Petrović  0:07`, `1:02:10` past the hour), then its words on
the next line and a blank line. An export made without the names or the
times leaves that part of the header out, and one made with neither is
paragraphs alone. The file closes with `Transcribed by https://otter.ai`
unless the branding is removed. Word and PDF exports open with the
title, the date and length (`Wed, Mar 4, 2026 10:15AM • 32:15`),
`SUMMARY KEYWORDS`, and `SPEAKERS`. An SRT names the speaker on the first
cue of each turn (`Ana: …`). Summary sections the dialog adds (Overview,
Action Items, Outline) are read by their headings wherever they stand.

Exports carry no conversation id, so a meeting's id hashes its file name
(without Otter's `_otter_ai` suffix or a browser's ` (1)`) and the words
of its transcript: the same conversation exported again, as TXT, DOCX, or
SRT, gets the same id.

#### Chosen transcript and recording pair into one meeting
`OtterMeetingReader.readFile`: One file the person chose. A transcript takes the recording named
like it from its folder; a recording chosen on its own reads the
transcripts named like it, so choosing both gives one meeting.

#### Two same-format files with same key are separate conversations
`OtterMeetingReader.readFolder`: Two files of one format are two conversations whose names
only differ in punctuation.

#### Lone transcript and recording in a folder pair even when named apart
`OtterMeetingReader.readFolder`: One transcript and one recording alone in a folder belong
together even when Otter named them apart.

#### Direct unreadable file throws; in a folder it becomes a problem
`OtterMeetingReader.readGroup`: Reads a conversation's files into one meeting. When the person chose
the file itself, a file that can't be read throws; in a folder it
becomes a problem and the rest is still read.

#### Any Word file passes recognizes; only Otter-laid-out ones are read
`OtterMeetingReader.readGroup`: Any Word file in a folder passes `recognizes`; only one
laid out like Otter's is read.

#### Pick transcript with most info: speakers then times; TXT wins ties
`OtterMeetingReader.merge`: The transcript that says the most: speakers, then times. TXT
wins a tie, since its turns are whole paragraphs.

#### Otter downloads may carry _otter_ai or _otter.ai suffix
`OtterMeetingReader.hasOtterSuffix`: Otter names a download after the conversation, sometimes with
`_otter_ai` or `_otter.ai` after it.

#### Normalize words so same text across formats compares equal
`OtterMeetingReader.normalized`: Lower-case words without punctuation, so the same words written by
different formats compare equal.

#### Failure reasons never quote file content
`OtterReadError`: Why a file couldn't be read, in words that never quote it.

#### Named mode: headers with times, Unknown label for unlisted names
`OtterLayout.Mode.named`: Headers with times: `Ana  0:07`, or `Unknown 0:00` for a name
Otter's opening lists or a label of its own.

#### Times-only headers mean export made without speaker names
`OtterLayout.Mode.times`: `0:07` alone: exported without speaker names.

#### Name-only headers mean export made without timestamps
`OtterLayout.Mode.names`: `Ana  ` alone: exported without timestamps.

#### Header takes two rows when Word lays name and time apart
`OtterLayout.Header.rows`: Rows it takes: two when a name and its time stand on rows of
their own, as a Word file can lay them out.

#### Recognise Otter by first and last bytes only
`OtterLayout.looksLikeExport`: A quick look at a file's first and last bytes: Otter's closing
line, its keyword heading, or turn headers with words under them.

#### Last row may be cut short so never weighed
`OtterLayout.looksLikeExport`: The last row may be cut short, so it is never weighed.

#### Opening block ends at blank rows after title, date, lists and sections
`OtterLayout.openingEnd`: Where Otter's opening block ends, when a transcript without timed
headers follows it: the title, the date, the keyword and speaker
lists, and summary sections, each running to a blank row.

#### Keyword and speaker lists are one row each
`OtterLayout.openingEnd`: The keyword and speaker lists are one row each.

#### Parse name and time from the row end without a regex
`OtterLayout.nameAndTime`: "Ana Petrović  0:07": the name, whether two spaces or a tab part it
from the time, and the time. Read from the end, without a pattern.

#### Clock is whole minutes and seconds, optional hours
`OtterLayout.isClock`: `0:07`, `12:30`, `75:12`, or `1:02:10`: whole minutes and seconds.

#### Name-only header ends with two spaces Otter writes; paragraphs don't
`OtterLayout.hasWideTrailingGap`: A name-alone header ends with the two spaces Otter writes after each
part of a header; a paragraph's line doesn't.

#### Otter PDF puts speaker initial before name; strip it
`OtterLayout.stripInitial`: "A Ana Petrović" in a layout that puts a speaker's initial before
their name, as Otter's PDF does, read as "Ana Petrović".

#### Opening block and trailing summary sections parsed by heading
`OtterExport.readSections`: Reads the opening block, or summary sections after the transcript:
the title (the first row, before anything else), the date line, the
keyword and speaker lists, and sections by their headings.

#### Old export dates lack year but length still counts
`OtterExport.readSections`: An old export's date has no year; its length still counts.

#### Distinct headings after a blank line end the transcript
`OtterHeading.endsTranscript`: Distinct enough to end a transcript when one stands after a blank
line, as a summary exported after the transcript does.

#### Unknown Speaker gets no speaker; Speaker 2 is a distinct voice
`OtterSpeakers.name`: "Unknown Speaker" is someone Otter couldn't tell apart, so the line
has no speaker; "Speaker 2" is a distinct voice without a name.

#### Otter date line is in exporter's time zone, assumed this computer's
`OtterDate`: Otter's date line: `Wed, Mar 4, 2026 10:15AM • 32:15`, in the time zone
of whoever exported it, which LokalBot takes to be this computer's.

#### Date and length without bullet when the bullet was lost
`OtterDate.parse`: "… 10:15AM 32:15" when the bullet was lost on the way.

#### Action items one per bullet; owner from trailing name or name row
`OtterActionItems`: Action items under an `Action Items` heading: one per bulleted row, an
owner from a trailing "(Name)" or a name row heading the rows under it.

#### Otter SRT names speaker on first cue of a turn only
`OtterSubRip.lines`: Otter names the speaker on the first cue of a turn only, so cues
without a name continue the turn before them.

#### Read DOCX with macOS tar to stream one entry without disk writes
`OtterDocx`: A Word file's paragraphs, one per row, read from `word/document.xml`
with the `tar` that ships with macOS (bsdtar reads ZIP), which streams
the one entry without writing to disk and takes the path literally.

#### Paragraph-properties tab stops are also tab; only run tabs are text
`OtterDocx.parser`: Tab stops in a paragraph's properties are `tab` too; only a run's
tab is text.

#### Keep UTF-16 tail on a character boundary
`OtterPeek.init`: Keep a UTF-16 file's tail on a character boundary.

### `LokalBot/CLISupport/MeetingImport/Readers/ScreenpipeMeetingReader.swift`

#### Read Screenpipe db read-only immutable; meeting sources, splitting, compressed storage handling
`ScreenpipeMeetingReader`: Reads meetings out of Screenpipe's own database. Screenpipe has no
transcript export, so LokalBot opens the database in its data folder
(`~/.screenpipe`) read-only and immutable, which never disturbs a running
Screenpipe.

- The database is `db.sqlite`, or, once Screenpipe has upgraded its
  history storage, the index `storage.json` names
  (`storage/<generation>/index.sqlite`). A `db.sqlite` left beside it is
  the original Screenpipe keeps as a recovery copy; it is read second, to
  fill in transcripts the index has compressed away.
- Each closed row of `meetings` is a meeting: its title, times, attendees,
  and note (the person's notes and Screenpipe's `## Summary`), with the
  background `audio_transcriptions` inside its time and its live
  `meeting_transcript_segments`, combined and de-duplicated the way
  Screenpipe's meeting view combines them.
- Audio from before Screenpipe kept meetings, or from a database without
  a `meetings` table, is split into conversations at five minutes of
  silence; fragments under a minute or 30 words are skipped.
- Lines from an input device (the person's microphone) are the person's
  own. Screenpipe's 30-second audio chunks are not attached.
- Compressed storage moves older transcript text into files LokalBot
  can't read. Meetings whose text moved are skipped rather than imported
  half, and reported with the way to export them.

#### Five minutes of silence ends a conversation without meetings
`ScreenpipeMeetingReader.conversationGap`: Silence that ends a conversation where Screenpipe kept no meetings.

#### Conversations under a minute or 30 words are fragments
`ScreenpipeMeetingReader.minimumConversationLength`: Conversations shorter than this, or with fewer words, are fragments.

#### Compressed meetings may come whole from original db; report only missing
`ScreenpipeMeetingReader.read`: A meeting the index compressed away may still come whole from the
original database; only the rest are worth a problem.

#### Screenpipe vault writes SPVAULT1 at start of locked files
`ScreenpipeMeetingReader.vaultHeader`: What Screenpipe's vault writes at the start of every file it locks.

#### Active index before originals so newer meetings win
`ScreenpipeMeetingReader.databases`: A folder holding copies: the active index before any original, so
its newer meetings win over the original's older versions.

#### storage.json names the upgraded database path
`ScreenpipeMeetingReader.activeIndex`: The database Screenpipe's upgraded storage uses, which `storage.json`
names as a path inside the data folder.

#### Identity is creation time, stable across edits and merges
`ScreenpipeMeetingReader.MeetingRow.identity`: What never changes for this row, even when the person edits or
merges it: when Screenpipe created it.

#### Utterance times are milliseconds since 1970
`ScreenpipeMeetingReader.Utterance`: One transcript line, with times in milliseconds since 1970.

#### Row timestamp used for meeting windows and duplicate checks, as Screenpipe does
`ScreenpipeMeetingReader.Utterance.time`: The row's own timestamp, which meeting windows and duplicate
checks use, as Screenpipe's meeting view does.

#### Text is empty when compressed storage holds it
`ScreenpipeMeetingReader.Utterance.text`: Empty when compressed storage holds the text.

#### Named means a person's name, not a label
`ScreenpipeMeetingReader.Utterance.isNamed`: The speaker is a person's name, not a label like "speaker 1".

#### Unknown device direction defaults to input as Screenpipe assumes
`ScreenpipeMeetingReader.Utterance.isInput`: Input when unknown, as Screenpipe's duplicate check assumes.

#### Pre-meetings audio grouped into conversations; afterwards only meetings count
`ScreenpipeMeetingReader.readDatabase`: Audio from before Screenpipe kept meetings is grouped into
conversations; after that, only meetings count.

#### Drop background lines repeating a live one within 15 seconds
`ScreenpipeMeetingReader.combine`: A meeting's live lines and the background lines in its time, minus
background lines that repeat a live one from the same device within
15 seconds, the rule Screenpipe's meeting view uses.

#### speaker N and Unknown #N are labels, not people
`ScreenpipeMeetingReader.isLabel`: "speaker 1" from live captions and "Unknown #4" for a voice nobody
named are labels, not people.

#### Normalize sqlx timestamp forms to unix milliseconds in SQL
`ScreenpipeMeetingReader.milliseconds`: Milliseconds since 1970 from every timestamp form sqlx writes or
reads: RFC 3339 or SQLite text, unix seconds (or milliseconds) as an
integer, or a Julian day as a real. SQLite parses the text, so any
number of fractional digits and any offset work.

#### In-progress meetings are skipped until Screenpipe closes them
`ScreenpipeMeetingReader.readMeetings`: A meeting still in progress has no end yet; it is imported
once Screenpipe closes it.

#### Meetings start at the sqlx migration time that created the table
`ScreenpipeMeetingReader.meetingsBegan`: When this database began keeping meetings: the time sqlx applied the
migration that created the table.

#### Stream once; place by timestamp so unwanted lines are never kept
`ScreenpipeMeetingReader.readTranscriptions`: Streams every background line once. `place` decides from the row's
time alone where it belongs, so lines nothing wants are never kept.

#### Exclude cloud-synced chunks without local audio, as Screenpipe does
`ScreenpipeMeetingReader.readTranscriptions`: Chunks synced from another device have no local audio; Screenpipe's
meeting view leaves them out, and so does LokalBot.

#### Offsets are seconds into the 30 s chunk; live captions keep own time
`ScreenpipeMeetingReader.readTranscriptions`: Offsets are seconds into the 30-second chunk the row's
timestamp starts. A live caption copied into this table keeps
its own time instead.

#### Old rows default to input; chunk file name gives the device
`ScreenpipeMeetingReader.readTranscriptions`: Rows older than the device columns carry the default "input";
their chunk's file name says which device it was.

#### Chunk files are named '\<device> (input)_date_time.mp4'
`ScreenpipeMeetingReader.inputFromChunk`: Screenpipe names chunk files `<device> (input)_<date>_<time>.mp4`.

#### reach[i] is latest end among meetings[0...i]
`ScreenpipeMeetingReader.MeetingWindows.reach`: The latest end among `meetings[0...i]`.

#### Bullets under action headings; sub-heading or bold name is owner
`ScreenpipeMeetingReader.actionItems`: Bullets under an action-items heading of Screenpipe's note ("Action
items", "Next steps", "To-do", "Follow-ups"), whether a Markdown
heading, a bold line, or a line ending in a colon. A sub-heading or a
bold name before the item names its owner.

#### Owner from bold name or @name, else sub-heading
`ScreenpipeMeetingReader.ownedItem`: "**Leo**: Send the deck", "**Leo:** Send the deck", or "@Leo Send the
deck" names Leo; otherwise the sub-heading's name, if any.

#### Name must not look like a note section such as Decisions
`ScreenpipeMeetingReader.isName`: Reads like a person's name, not a section of the note such as
"Decisions" or "Open questions".

#### Open mode=ro&immutable=1 so no locks or wal files disturb Screenpipe
`ImmutableDatabase`: A query-only SQLite connection opened with `mode=ro&immutable=1`:
SQLite takes no locks, writes no `-wal` or `-shm` file, and never
changes the database, so a running Screenpipe is never disturbed.

#### Failure reasons name only SQLite result code, never file content
`ImmutableDatabase.failure`: Reasons name SQLite's result code only, never anything the file holds.

#### SQLite booleans are integers but older writers left text
`ImmutableRow.bool`: SQLite booleans are integers, but older writers may have left text.

#### Not-Screenpipe databases skipped in folders; unreadable reasons never quote content
`ScreenpipeReadFailure`: Why one database gave nothing: it isn't Screenpipe's (skipped inside a
folder), or it can't be read, for a reason that never quotes its content.

### `LokalBot/CLISupport/MeetingImport/Readers/VoiceMemosMeetingReader.swift`

#### Voice Memos library schema, embedded tsrp transcript and voice-memo-uuid linkage
`VoiceMemosMeetingReader`: Reads Apple Voice Memos recordings: the app's own `Recordings` folder, or
`.m4a` and `.qta` files dragged out of it.

The folder holds `CloudRecordings.db`, a Core Data store whose
`ZCLOUDRECORDING` rows give each recording's id (`ZUNIQUEID`), title
(`ZENCRYPTEDTITLE`, plain text despite its name, or the older
`ZCUSTOMLABEL`), start (`ZDATE`, seconds since 2001), length (`ZDURATION`),
audio file (`ZPATH`), and whether it is in Recently Deleted
(`ZEVICTIONDATE`). Recent releases write the transcript into the audio
file: a `tsrp` atom in an `.m4a` track's user data, or the
`com.apple.VoiceMemos.tsrp` item of a `.qta` track's QuickTime metadata,
holding a Foundation `AttributedString` in its JSON coding whose runs,
usually one word each, carry `timeRange: [start, end]` in seconds. Each
`.m4a` also carries the recording's id as the iTunes item
`voice-memo-uuid`, the same value as `ZUNIQUEID`, so a dragged-out copy
and the library row are one meeting.

The database is opened read-only and immutable, so SQLite never touches
its journal; a recording whose row is still only in the write-ahead log is
read from its audio file like a dragged-out copy.

#### Unopenable file still offered so reading can say why
`VoiceMemosMeetingReader.recognizes`: A file that can't be opened is still offered, so reading it can say why.

#### Empty file is a recording kept only in iCloud
`VoiceMemosMeetingReader.recognizes`: An empty file is a recording Voice Memos keeps only in iCloud.

#### Composition fragments are parts of the neighbouring recording
`VoiceMemosMeetingReader.isInsideComposition`: Fragments of an edited recording in the older library layout, which
are parts of the recording beside them, not recordings of their own.

#### Claim every audio file the library names, including Recently Deleted
`VoiceMemosMeetingReader.readLibrary`: The recordings a library database lists, and every audio file it names,
so the folder walk doesn't read them again, including the ones in
Recently Deleted.

#### ZPATH is a file name or absolute path; paths leaving folder rejected
`VoiceMemosMeetingReader.audioURL`: The audio file a row's `ZPATH` names, which is usually a file name in
the database's folder and sometimes an absolute path into it. A path
that leads out of the folder names nothing.

#### Reject date placeholder titles older devices show
`VoiceMemosMeetingReader.cleanTitle`: A title that names something: not empty, and not the date placeholder
older devices show for a title they can't read ("2023-08-11T07:53:31Z").

#### Voice Memos timestamp file names are not titles
`VoiceMemosMeetingReader.fileTitle`: The file name as a title, unless it is the time stamp Voice Memos names
its own files with ("20260304 101500-1A2B3C4D.m4a").

#### File-name stamp is device local time read in this Mac's zone
`VoiceMemosMeetingReader.originalStamp`: When a recording started, from the name Voice Memos gives its own files:
the device's local time, read in this Mac's time zone.

#### Recording ids are upper-case UUIDs
`VoiceMemosMeetingReader.normalizedID`: A recording id as Voice Memos writes it: an upper-case UUID.

#### Id fallback: original name else title, start and length
`VoiceMemosMeetingReader.fallbackID`: For a file that carries no id: its original name when Voice Memos gave
it one, else its title, start, and length.

#### Pause of 1.5 s starts a new transcript line
`VoiceMemosMeetingReader.pauseBreak`: A pause this long starts a new line.

#### Line of 4 s ends at next sentence end
`VoiceMemosMeetingReader.sentenceBreak`: A line this long ends at its next sentence end.

#### No transcript line longer than 30 s
`VoiceMemosMeetingReader.longestLine`: No line runs longer than this.

#### Group words at pauses and sentence ends; empty if not Voice Memos JSON
`VoiceMemosMeetingReader.transcriptLines`: The lines of a transcript Voice Memos wrote into a recording: its
words, grouped at pauses and sentence ends. Empty when the transcript
is empty or isn't the JSON Voice Memos writes.

#### QuickTime values may carry data header; payload may be zero-padded
`VoiceMemosMeetingReader.transcriptLines`: A QuickTime metadata value can come with its `data` header, and a
payload can be padded with zeros.

#### AttributedString JSON has two codings; speechless transcript is plain string
`VoiceMemosMeetingReader.transcriptWords`: The runs of an `AttributedString` in either of its JSON codings: text
and attributes interleaved (`["Hi", {…}, " there", {…}]`), or text and
indexes into an `attributeTable` (`{"runs": ["Hi", 0], "attributeTable": [{…}]}`).
A transcript with no speech is a plain string.

#### timeRange is start and end seconds, not start and length
`VoiceMemosMeetingReader.timeRange`: `timeRange` is a start and an end in seconds, not a start and a length.

#### Reads only moov header fields, never audio
`VoiceMemoMovie`: What a Voice Memos recording says about itself in its movie header
(`moov`), read without its audio: length and creation time (`mvhd`),
iTunes tags (`©nam`, `©too`, `----:com.apple.iTunes:voice-memo-uuid`), the
`date` user data string, QuickTime metadata (`com.apple.quicktime.*`), and
the transcript.

#### Header over 64 MB is treated as damage
`VoiceMemoMovie.largestHeader`: No real movie header comes near this; a larger one is damage.

#### QuickTime times count from 1904; offset to 1970
`VoiceMemoMovie.quickTimeEpoch`: Seconds from 1904-01-01, where QuickTime times count from, to 1970-01-01.

#### mvhd creation is end of recording since Voice Memos stamps at finish
`VoiceMemoMovie.creationTime`: `mvhd`'s creation time. Voice Memos appears to stamp it when it
finishes writing, so it is the end of the recording, or of an export.

#### date user data string is UTC
`VoiceMemoMovie.dateTag`: The `date` user data string, in UTC.

#### quicktime.creationdate carries its offset
`VoiceMemoMovie.creationDate`: `com.apple.quicktime.creationdate`, which carries its offset.

#### Transcript is track metadata; movie-level one is fallback
`VoiceMemoMovie.parse`: The transcript is track metadata; a movie-level one is the fallback.

#### Creation before 2001 or in future is an unset clock
`VoiceMemoMovie.readMovieHeader`: Before 2001 or in the future is an unset or wrong clock.

#### moov/udta holds date string and iTunes tags in meta/ilst
`VoiceMemoMovie.readUserData`: `moov/udta`: the `date` string and the iTunes tags in `meta/ilst`.

#### date is bare string; ©day has length and language the pattern skips
`VoiceMemoMovie.readUserData`: `date` is a bare string; a QuickTime `©day` text atom has a length
and language before it, which the date pattern skips.

#### QuickTime ilst item type is 1-based index into keys
`VoiceMemoMovie.quickTimeItems`: The values of a QuickTime metadata atom, by key: `keys` lists names in
the `mdta` namespace, and each `ilst` item's type is its key's 1-based
index, holding a `data` atom.

#### ISO meta atom starts with zero version and flags; QuickTime one does not
`VoiceMemoMovie.metadataStart`: An ISO `meta` atom starts with a version and flags, which are zero; a
QuickTime one starts with its first child, whose size isn't.

#### Stop at first atom with damaged size
`VoiceMemoMovie.atoms`: The atoms directly inside `range`, up to the first whose size is damaged.

#### Older libraries and backups keep manifest.plist beside edited recordings
`CompositionManifest`: `<recording>.composition/manifest.plist`, which older Voice Memos
libraries and device backups keep beside an edited recording.

#### Open CloudRecordings.db immutable; every Core Data attribute optional so missing columns are NULL
`VoiceMemosLibrary`: `CloudRecordings.db`, opened read-only and immutable: SQLite reads the
main file only and never creates or touches `-wal` or `-shm` files.
Every attribute is optional in Voice Memos' Core Data model, so columns
the table lacks read as NULL.

#### Dates far from real recordings are damage
`VoiceMemosLibrary.rows`: Dates far from any real recording's are damage.

#### SQLite codes reported in words never quoting database contents
`VoiceMemosLibrary.failure`: SQLite's codes in words that never quote the database's contents.

### `LokalBot/CLISupport/MeetingImport/Readers/ZoomMeetingReader.swift`

#### Read Zoom computer and cloud recordings in place; audio-only preferred; chat never read
`ZoomMeetingReader`: Reads Zoom recordings where they already are, with no export step:

- **Computer recordings.** The Zoom app saves each one in its own folder
  under `~/Documents/Zoom`, named for the start in local time and the
  topic (`2026-03-04 10.15.00 Pricing review`, older apps append the
  meeting ID). It holds the audio-only file (`audio_only.m4a`, or
  `audio12345678.m4a` in newer apps), the video (`zoom_0.mp4` or
  `video12345678.mp4`), `chat.txt`, and sometimes saved captions
  (`meeting_saved_closed_caption.txt`, `closed_caption.txt`, a `.vtt`).
  Separate participant tracks sit in an `Audio Record` subfolder.
- **Cloud recordings.** The web portal's downloads start with the UTC
  start (`GMT20260304-091500_Recording.m4a`, `…_Recording_1920x1080.mp4`,
  `…_Recording.transcript.vtt`, `…_Recording.cc.vtt`), so files that
  share that prefix are one meeting.

The audio-only file becomes the meeting's recording (else the video), and
the audio transcript its transcript. Chat is never read. Files are only
read, never changed.

#### Whole-meeting audio file names across Zoom versions
`ZoomMeetingReader.Kind.audio`: The whole meeting's audio: `audio_only.m4a`, `audio12345678.m4a`,
or a cloud recording's `…_Recording.m4a`.

#### Participant tracks are never the meeting recording
`ZoomMeetingReader.Kind.participantAudio`: One participant's track, from "Record a separate audio file for
each participant". Never the meeting's recording.

#### Unconverted .zoom recording is unreadable except by Zoom
`ZoomMeetingReader.Kind.unconverted`: `double_click_to_convert_01.zoom`: a recording Zoom hasn't
converted yet, which nothing but Zoom can read.

#### Zoom's generic audio-only file name patterns
`ZoomMeetingReader.isGenericAudio`: `audio_only`, `audio_only_1`, `audio12345678`: the names Zoom gives
the meeting's audio-only file.

#### Participant track name is audio plus name plus Zoom number
`ZoomMeetingReader.looksLikeParticipantTrack`: `audioJohnSmith12345678`: a participant's name between "audio" and
Zoom's number.

#### Zoom's generic video file name patterns
`ZoomMeetingReader.isGenericVideo`: `zoom_0`, `zoom_1`, `video12345678`.

#### App-only file names tie files to folder even after rename
`ZoomMeetingReader.hasComputerRecordingName`: Names only the Zoom app gives a computer recording's files, which tie
them to their folder even after the person renamed it.

#### Check folder name shape only to keep folder walks cheap
`ZoomMeetingReader.isRecordingFolderName`: "2026-03-04 10.15.00" and an optional topic: how Zoom names a
computer recording's folder. Checks the shape only, so walking a
folder of recordings stays cheap.

#### Folder name is local time with topic; older apps append meeting ID
`ZoomMeetingReader.FolderStamp`: "2026-03-04 10.15.00 Topic": a computer recording's folder. Zoom names
it in the computer's local time; older apps append the meeting ID.

#### Seconds since local midnight anchor clock-timed captions
`ZoomMeetingReader.FolderStamp.secondsIntoDay`: Seconds since local midnight, for captions saved with clock times.

#### Lenient parsing keeps folders from the skipped DST hour
`ZoomMeetingReader.FolderStamp.init`: A folder made in the hour clocks skip for daylight saving
still has a start.

#### Cloud downloads start with UTC stamp GMTyyyymmdd-hhmmss
`ZoomMeetingReader.CloudStamp`: "GMT20260304-091500": the UTC start every file a cloud recording
downloads as begins with.

#### Any chosen file reads the whole recording with the same id
`ZoomMeetingReader.recording(around:)`: The whole recording one chosen file belongs to: its folder's files
for a computer recording, the files sharing its stamp for a cloud
one. Choosing the audio or the transcript alone, or both, reads the
same meeting with the same id.

#### Text captions are last resort; own transcription gives exact times and voices
`ZoomMeetingReader.meeting`: Text captions are a last resort: a recording LokalBot can
transcribe itself gives exact times and voices.

#### Prefer Zoom's own video names; screen-share-only video last
`ZoomMeetingReader.videoRank`: Zoom's own video names first; a cloud recording's screen share alone
(`_as_`) last.

#### Audio transcript before closed captions
`ZoomMeetingReader.subtitleRank`: The audio transcript (`.transcript.vtt`) first, closed captions
(`.cc.vtt`) last.

#### Saved transcript names speakers; automatic closed_caption.txt does not
`ZoomMeetingReader.captionRank`: "Save transcript" in a meeting writes `meeting_saved_…`, which names
speakers; the automatic `closed_caption.txt` doesn't.

#### Prefer first VTT with named speakers since Zoom's naming varies by version
`ZoomMeetingReader.transcript`: Lines from the best WebVTT file: the first that names speakers (Zoom
has written names into the audio transcript or the closed captions,
depending on the version), else the first with any lines.

#### Zoom's Unknown Speaker label means no speaker
`ZoomMeetingReader.named`: Zoom labels voices it couldn't attribute "Unknown Speaker", which is
nobody in particular.

#### Caption layouts undocumented; clock times anchored to folder start within six hours
`ZoomMeetingReader.captionLines`: Captions Zoom saved as text. Zoom documents neither file's layout, so
this reads the shapes they take: a "[Name] 10:15:32" header above the
words, "10:15:32 Name: words" or "[10:15:32] words" on one line, or
subtitle cues. Clock times count from `meetingClock`, the folder's
start in seconds since midnight, when the captions begin within six
hours of it, else from the first caption.

#### Clock always has hours so mid-sentence 10:15 isn't one
`ZoomMeetingReader.clockTime`: "10:15:32" as seconds; a clock always has hours, so "10:15" in a
sentence isn't one.

### `LokalBotTests/CLISupport/MeetingImport/Readers/FathomMeetingReaderTests.swift`

#### Fixtures are synthetic, shaped like Fathom's copy buttons and API output
`FathomMeetingReaderTests`: Every fixture is synthetic and built here, shaped like what Fathom's "Copy
Transcript" and "Copy Summary" buttons copy and what its API returns.

#### Folder walks name temp files under /private/var, the test under /var
`FathomMeetingReaderTests.assertSameFile`: Folder walks name temporary files under /private/var, the test under /var.

### `LokalBotTests/CLISupport/MeetingImport/Readers/FirefliesMeetingReaderTests.swift`

#### Fixtures are synthetic, in the shapes of Fireflies downloads and API
`FirefliesMeetingReaderTests`: Every fixture is synthetic: made-up meetings in the shapes Fireflies'
downloads and API take, written to a temporary folder by the test.

#### Fireflies API transcript as API backup tools save it
`FirefliesMeetingReaderTests.apiTranscript`: The Fireflies API's `transcript`, as API backup tools save it.

#### Folder walk resolves /var to /private/var
`FirefliesMeetingReaderTests.testFolderWithAnUnreadableFileStillReadsTheRest`: The folder walk resolves /var to /private/var.

### `LokalBotTests/CLISupport/MeetingImport/Readers/GranolaMeetingReaderTests.swift`

#### Fixtures follow Granola's CSV export and Copy notes and transcript clipboard shapes
`GranolaMeetingReaderTests`: Every fixture is synthetic and built here: the shapes follow Granola's
historical data export (Settings → Profile → Generate CSV) and what its
"Copy notes" and transcript-panel copy put on the clipboard.

#### Export CSV has BOM, CRLF rows, all fields quoted, cells with commas, quotes, line breaks
`GranolaMeetingReaderTests.Fixture.exportCSV`: UTF-8 with a byte-order mark, CRLF rows, every field quoted, and
cells with commas, quotes, and line breaks.

#### Writer stores Me as the mic, Them as nobody in particular, actions in notes
`GranolaMeetingReaderTests.testExportRoundTripKeepsTitleStartSpeakersNotesAndActions`: How the writer stores it: "Me" is the person's microphone, "Them"
nobody in particular, and the actions are already in the notes.

### `LokalBotTests/CLISupport/MeetingImport/Readers/MacWhisperMeetingReaderTests.swift`

#### Fixtures are synthetic literals, zipped or SQLite; no real MacWhisper data
`MacWhisperMeetingReaderTests`: Every fixture here is synthetic: written as literals, zipped with ditto or
zip, or created with SQLite. No real MacWhisper data is used.

#### WAV whose extension MacWhisper did not keep, zipped inside a top folder
`MacWhisperMeetingReaderTests.testWhisperDocumentWithoutExtensionStoredEntriesOrAudio`: A WAV recording whose extension MacWhisper didn't keep, zipped inside a top folder.

#### Stored rather than deflated entries, as zip -0 writes them
`MacWhisperMeetingReaderTests.testWhisperDocumentWithoutExtensionStoredEntriesOrAudio`: Stored rather than deflated entries, as `zip -0` writes them.

#### Fixture is MacWhisper's Share, Segments, .json export
`MacWhisperMeetingReaderTests.testSegmentsAndStructuredJSONExports`: Share › Segments › .json

#### The structured export keeps milliseconds
`MacWhisperMeetingReaderTests.testSegmentsAndStructuredJSONExports`: The structured export keeps milliseconds.

#### Speaker-grouped text is what --group people writes
`MacWhisperMeetingReaderTests.testTextMarkdownAndWordExports`: Grouped by speaker, as `--group people` writes it.

#### A leading time is not a timestamp and Note: is not a speaker
`MacWhisperMeetingReaderTests.testTextMarkdownAndWordExports`: A time at the start of a sentence isn't a timestamp, and "Note:" isn't a speaker.

#### metadata.json has milliseconds, speaker objects, dates as seconds since 2001
`MacWhisperMeetingReaderTests.whisperMetadata`: `metadata.json` as MacWhisper writes it: milliseconds, speaker objects,
and dates as seconds since 2001.

#### MacWhisper's library keeps its AI summary under aiSummary
`MacWhisperMeetingReaderTests.whisperMetadata`: Read when present; MacWhisper's library keeps its AI summary under this name.

#### GRDB layout: UUID blobs, UTC text dates, ms lines; keepOpenInWAL keeps changes in the WAL
`MacWhisperMeetingReaderTests.makeLibrary`: MacWhisper's library as GRDB lays it out: UUID blobs, UTC dates as
text, transcript lines in milliseconds. With `keepOpenInWAL`, the
writer stays open and every change is still in the write-ahead log.

### `LokalBotTests/CLISupport/MeetingImport/Readers/OtterMeetingReaderTests.swift`

#### Otter TXT turn format: name, two spaces, time, two spaces, words on next line, blank line
`OtterMeetingReaderTests.transcriptLines`: Otter's TXT turns: name, two spaces, time, two spaces; the words on
the next line; a blank line; the closing line.

#### Otter SRT names the speaker on a turn's first cue only
`OtterMeetingReaderTests.srt`: Otter's SRT names the speaker on a turn's first cue only.

#### Word export: tab parts header name and time; one header uses a single space
`OtterMeetingReaderTests.docxParagraphs`: The Word export's paragraphs; a tab parts a header's name and time,
and one header uses a single space for a listed speaker.

#### Otter date line is read in this computer's time zone
`OtterMeetingReaderTests.meetingStart`: 10:15 on 4 March 2026 in this computer's time zone, as Otter's date
line is read.

#### Tab stops in paragraph properties must not read as text
`OtterMeetingReaderTests.makeDocx`: Tab stops in the paragraph's properties must not read as text.

#### A filename the shell would read as a pattern is read literally
`OtterMeetingReaderTests.testSameConversationAsSubRipAndWordGetsTheSameID`: A name the shell would read as a pattern is read as itself.

### `LokalBotTests/CLISupport/MeetingImport/Readers/ScreenpipeMeetingReaderTests.swift`

#### Fixtures mirror Screenpipe migrations in crates/screenpipe-db; no real data
`ScreenpipeFixtures`: Synthetic Screenpipe databases with the columns Screenpipe's migrations
create (crates/screenpipe-db/src/migrations). Nothing here is real data.

#### archived adds the columns compressed storage adds
`ScreenpipeFixtures.schema`: Today's schema; `archived` adds the columns compressed storage adds.

#### 2024 database lacks meetings and speakers; device columns default; one timestamp is unix seconds
`ScreenpipeFixtures.writeOld`: A 2024 database: no meetings, speakers, or segment times; the device
columns hold their defaults, so only chunk names tell the devices
apart. One timestamp is unix seconds.

#### Upgraded storage: storage.json, index with compressed and resident meetings, kept db.sqlite
`ScreenpipeFixtures.writeUpgradedFolder`: A data folder after Screenpipe upgraded its storage: `storage.json`,
the index (one meeting's text compressed away, one resident, one
compressed and nowhere else), and the original `db.sqlite` it kept.

#### Screenpipe's vault leaves an SPVAULT1 header when it locks a database
`ScreenpipeFixtures.writeLocked`: What Screenpipe's vault leaves when it locks a database.

### `LokalBotTests/CLISupport/MeetingImport/Readers/VoiceMemosMeetingReaderTests.swift`

#### A row only in the write-ahead log is skipped by immutable read, so it comes from the file
`VoiceMemosMeetingReaderTests.testLibraryFolderRoundTrip`: Its row is still only in the write-ahead log, which an immutable
read skips, so it comes from the file.

#### mvhd marks the end in whole seconds; start is end minus length
`VoiceMemosMeetingReaderTests.testDraggedOutCopyIsTheSameMeetingAsItsLibraryRow`: mvhd marks the end in whole seconds; the start is the end minus the length.

#### A long recording's mdat uses a 64-bit box size
`VoiceMemoFixture.extendedBox`: A box with a 64-bit size, as a long recording's `mdat` has.

#### QuickTime metadata: names in keys, values in ilst items typed by index
`VoiceMemoFixture.quickTimeMeta`: QuickTime metadata: names in `keys`, values in `ilst` items typed by index.

#### Transcript at trak/mdia/udta instead of trak/udta
`VoiceMemoFixture.Recording.transcriptInMedia`: `trak/mdia/udta` instead of `trak/udta`.

#### A .qta has the QuickTime brand and transcript in trak/meta
`VoiceMemoFixture.Recording.quickTime`: A `.qta`: QuickTime brand, the transcript in `trak/meta`.

#### Voice Memos writes ftyp, mdat, moov; otherwise moov first
`VoiceMemoFixture.Recording.movieLast`: `ftyp`, `mdat`, `moov`, as Voice Memos writes; else `moov` first.

#### Library DB shaped like Voice Memos' Core Data store, in WAL mode as the real one
`VoiceMemoFixture.library`: A library database shaped like Voice Memos' Core Data store, in WAL
mode as the real one is.

#### Separated coding: runs index an attribute table; comma lacks time; pause starts last line
`VoiceMemoFixture.pricingTranscript`: The separated coding: runs index an attribute table. The comma has an
attribute without a time, and a pause starts the last line.

#### Interleaved coding: each run followed by its attributes
`VoiceMemoFixture.errandTranscript`: The interleaved coding: each run followed by its attributes.

#### Recordings folder fixture covers titled, label-titled, deleted, iCloud-only and WAL-only recordings
`VoiceMemoFixture.libraryFolder`: A `Recordings` folder: a database with a titled recording, an older
one titled by its label under an absolute path, one in Recently
Deleted, and one only in iCloud; a recording whose row is still only in
the write-ahead log; and that log, which an immutable read ignores.

### `LokalBotTests/CLISupport/MeetingImport/Readers/ZoomMeetingReaderTests.swift`

#### Fixtures are synthetic, laid out as the Zoom app and web portal name them
`ZoomMeetingReaderTests`: Every fixture is synthetic: folders and files laid out the way the Zoom
app and web portal name them, written to a temporary folder.

#### Reader never opens recordings, only names them
`ZoomMeetingReaderTests.writeMedia`: Stand-in bytes: the reader never opens recordings, only names them.

#### A cue file inside a recording's folder belongs to it whatever its name
`ZoomMeetingReaderTests.testComputerRecordingFolderRoundTrip`: A cue file inside a recording's folder belongs to that folder,
whatever its name says.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
