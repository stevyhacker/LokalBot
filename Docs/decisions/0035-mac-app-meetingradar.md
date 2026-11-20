# 0035. Mac app: MeetingRadar

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Services/MeetingRadar/`, `LokalBotTests/Services/MeetingRadar/`.

## Decisions

### `LokalBot/Services/MeetingRadar/AppLiveAnswers.swift`

#### Everything read locally; only prompt and tool results reach Think model
`AppLiveAnswerEnvironment`: Live answers' view of the app: what LokalBot remembers that bears on a
question, Ask's meeting and screen tools, and the folders chosen in
Settings. Everything is read on this Mac; only what the prompt and the
tools return goes to the Think model.

#### Re-read git details periodically so links match checkout
`AppLiveAnswerEnvironment.places`: Re-read git details now and then, so links point at what is checked out.

### `LokalBot/Services/MeetingRadar/LiveAnswerTools.swift`

#### Checked-out commit keeps links pointing at what was read
`LiveAnswerPlace.head`: The checked-out commit, for links that keep pointing at what was read.

#### Self-naming output line lets a quote in it cite it
`LiveAnswerLine`: One line of a tool's output that names something on its own (a file
line, a commit, a pull request), so a quote found in that line cites it.

#### Read-only; paths stay in approved folders; hidden/secret files and untracked files unread; capped output
`LiveAnswerTools`: The read-only tools over the person's folders and repositories. Every path
stays inside an approved folder; hidden and secret-looking files are never
read; in a repository only files git tracks are. Commands run with a short
timeout and their output is capped.

#### 8 s for live calls; 60 s in unit tests after CI git start exceeded 8 s
`LiveAnswerTools.commandTimeout`: Short, because an answer during a call can't wait for a slow command.
Unit tests get more room: on a loaded CI runner, starting git alone
took longer than 8 s (Build run 44300644348, 2026-11-18).

#### Fall back to filename ranking when Spotlight is off or skips folder
`LiveAnswerTools.searchDocuments`: Spotlight can be off, still indexing, or skip the folder (it
doesn't index ~/Library): rank file names by the query's words.

#### Words match on same word or first four letters
`LiveAnswerTools.nameScore`: How many of the query's words a file name holds: the same word, or one
with the same first four letters, so "price" finds "pricing".

#### Hidden, node_modules and secret files stay unread; pathspecs plus name rule
`LiveAnswerTools.searchCode`: Tracked is not enough: hidden files and folders, `node_modules` and
secret-looking files stay unread here as in the document tools. Git
skips the first two; the name rule drops the rest before the cap.

#### Tracked symlink targets held to same path rules
`LiveAnswerTools.readFile`: A tracked symlink is read through, so where it leads is held to the
same rules as the path that was asked for.

#### Hidden, node_modules and secret-looking paths are never read
`LiveAnswerTools.isWithheld`: A path inside an approved folder that no tool reads: a hidden file or
folder, anything under `node_modules`, or a secret-looking name.

#### Git applies hidden/node_modules exclusion so git grep never opens them
`LiveAnswerTools.withheldPathspecs`: The hidden and `node_modules` part of `isWithheld`, as pathspecs git
applies itself, so `git grep` never opens those files.

#### Folder-prefixed path names folder; bare path searched in each folder
`LiveAnswerTools.resolve`: "Folder/sub/file.pdf" names the folder first; a bare path is
looked up in each folder.

### `LokalBot/Services/MeetingRadar/LiveAnswers.swift`

#### Quote is verbatim from source; answer kept because it is there
`RadarAnswer.Source.quote`: Words from the source, as read; the answer was kept because they are there.

#### Seconds from question caught to answer
`RadarAnswer.seconds`: From the question being caught to the answer.

#### Last lines before question formatted as 'Me: …' and 'Others: …'
`LiveAnswerMeeting.recentLines`: The last few lines before the question, as "Me: …" and "Others: …".

#### Every cited source must contain its quote, checked against tool returns
`LiveAnswerSession`: One live answer: memory first, then up to a few read-only tool calls, on
the Think model chosen in Settings → Models. Every source the answer cites
must contain its quote, checked here against what the tools returned, so
an answer can't rest on something nobody read.

#### Keep only sources whose quote is present; multi-line results use found line
`LiveAnswerSession.ground`: The answer, keeping only sources whose quote is in what they name.
A source inside a multi-line result takes the line it was found on
(a file line, a commit, a pull request) as its title and link.

#### Whole normalized quote, or most of a longer quote's words on one line
`LiveAnswerSession.quoteIsIn`: The radar's rule for quotes: the whole quote after normalizing, or
most of a longer quote's words on one line.

### `LokalBot/Services/MeetingRadar/MeetingRadar.swift`

#### Turn feeds deliver lines about a second after speech, per turn
`RadarLineFeed.deliversTurns`: Lines arrive turn by turn, about a second after being said, rather
than in windows of several seconds, so passes can follow each turn.

#### Radar pass cadence, inputs, opt-in start, privacy boundaries and radar.json saving
`MeetingRadar`: Live Radar for the meeting being recorded. It reads the live transcript
preview, and every pass gives only the lines that arrived since the last
one (plus a little context, what is already on the radar, and passages
local search found in earlier meetings) to the Think model chosen in
Settings → Models, under that model's own local or remote setting.
Passes run about every 20 s, or after each turn when fast live text
delivers turns: cut at pauses on this Mac, or streamed from Muse Voice
Transcribe. Speaker separation stays on this Mac, and audio does too
unless fast live text streams it to Muse.

Radar starts only when the person presses Start Radar during a recording,
and only once Live Radar is turned on in Settings. It stops with the
recording, after one last pass over lines it hasn't read yet, and saves
what it found to `radar.json` in the meeting folder.

#### Minimum gap is measured between pass starts, 20 s
`MeetingRadar.Timing.minimumInterval`: Shortest gap between the starts of two passes.

#### Turn-delivering feeds use a 3 s gap, batching close turns
`MeetingRadar.Timing.turnInterval`: The same gap when the feed delivers turns (fast live text): a
pass follows each finished turn, batching turns that end close together.

#### A burst of ten lines skips the interval wait
`MeetingRadar.Timing.burstLines`: A burst of speech this long doesn't wait for the interval.

#### Passes list short items with no reasoning budget
`MeetingRadar.passOptions`: A pass lists what it caught as short items and doesn't reason first.

#### Live answer is one tool call per turn with small reasoning budget
`MeetingRadar.answerOptions`: A live answer is one tool call per turn, with a little room to choose it.

#### Spotlight is the last changed item, shown by the floating panel
`MeetingRadar.spotlightID`: The item that changed last: the newest one a pass added, or the
question that just got an answer. The floating panel shows it.

#### Answered questions hold the spotlight 12 s; contradictions take it at once
`MeetingRadar.answerSpotlightHold`: How long a question that just got an answer keeps the spotlight
before a newer item takes it, so the answer can be read during the
call. A contradiction still takes it at once.

#### Think model reads crop text, not crop pictures
`MeetingRadar.sendsScreenCrops`: Whether a screen answer's request carries the crops as pictures. The
Think model reads the text of each crop instead.

#### Radar keeps its own lines because the preview keeps only 400 and clears them
`MeetingRadar.lines`: Every live line seen this recording, by id. The preview keeps only its
latest 400 and clears them when recording stops; the radar keeps its own.

#### Epoch stops late answers landing in the next meeting; finish keeps it
`MeetingRadar.answerEpoch`: Changes when answers are cancelled, so a late reply can't land in the
next meeting. `finish()` keeps it, so answers still arriving are saved.

#### Passes and answers use the Think engine unless callers inject calls
`MeetingRadar.init`: Passes and live answers run on `engine`, the Think model, unless a
caller supplies `call` or `answerCall` itself (tests, and the hosted
film of the feature).

#### Live Radar gated only by its setting; Think model errors show as radar error
`MeetingRadar.unavailableReason`: Why Start Radar can't run, or nil when it can. Live Radar is offered
only once it is turned on in Settings; after that the Think model's
own setup decides, and a request it refuses shows as the radar's error.

#### Stopping leaves unread lines unread
`MeetingRadar.stop`: The person pressed Stop Radar. Lines not yet read stay unread.

#### Finishing reads remaining lines, saves and turns off
`MeetingRadar.finish`: The recording ended or moved to another meeting: read what is left,
save, and turn off.

#### Screen answers search locally, crop, send up to three crops' text, beside passes
`MeetingRadar.answerFromScreen`: Looks for the answer to a question the radar just caught in earlier
screen captures: local search and cropping on this Mac, then one
request with the text of up to three crops. Runs beside the passes.

#### Live answers use LokalBot memory first, then read-only lookups, showing steps
`MeetingRadar.answerLive`: Looks for the answer to a question or problem in the person's work:
what LokalBot remembers first, then a few read-only lookups. Runs
beside the passes; the card shows each step while it works.

### `LokalBot/Services/MeetingRadar/MeetingRadarAnalyzer.swift`

#### Pass inputs and grounding: replies must quote new lines or be dropped
`MeetingRadarAnalyzer`: The request and the checks for one Live Radar pass. Pure, so the prompt,
schema, and grounding rules are covered without a model or network.

A pass sends the lines that arrived since the previous pass, a little of
the conversation before them, what is already on the radar, and passages
from earlier meetings that local search found for the new lines. Whatever
comes back must quote one of the new lines; a contradiction must also name
a passage it was shown. Anything else is dropped, never shown.

#### Line labels are stable for the whole recording
`MeetingRadarAnalyzer.Line.label`: "L12": stable for the whole recording.

#### Speaker is the live track: local microphone or them
`MeetingRadarAnalyzer.Line.speaker`: The live track: "local" (this Mac's microphone) or "them".

#### Excerpt labels are numbered per pass
`MeetingRadarAnalyzer.Excerpt.label`: "E1": numbered per pass.

#### Only grounded new items kept; ids numbered across the recording
`MeetingRadarAnalyzer.apply`: Parses a reply and keeps only grounded, new items. `nextID` numbers the
kept items r1, r2, … across the whole recording.

#### Source line is the named one if it contains the quote, else the unique match
`MeetingRadarAnalyzer.sourceLine`: The line an item quotes: the one it names, when the quote is really
in it, else the only new line that contains the quote.

#### Quotes match normalized or by 80% of words; under three words need whole line
`MeetingRadarAnalyzer.quoteMatches`: Exact after normalization, or at least 80% of the quote's words in the
line, so punctuation and a dropped filler word don't reject a real
quote. A quote under three words only counts when it is the whole line.

#### Duplicate means same kind and same quote or mostly same words
`MeetingRadarAnalyzer.isDuplicate`: Same kind and the same quote, or mostly the same words.

### `LokalBot/Services/MeetingRadar/MeetingRadarModels.swift`

#### Radar items are four kinds and always quote their live line
`RadarItem`: Something Live Radar caught while a meeting was recorded: a promise, a
decision, a question nobody has answered yet, or a conflict with an
earlier meeting. Every item quotes the live line it came from.

#### Owner is Me, a spoken name, or Others; nil if unknown
`RadarItem.owner`: "Me", a name said in the meeting, or "Others". Nil when unknown.

#### Due is kept as said, not parsed
`RadarItem.due`: The deadline as it was said.

#### Time is seconds into the recording of the quoted line
`RadarItem.time`: Seconds into the recording of the quoted line.

#### Speaker is the live track label, local or them
`RadarItem.speaker`: The live track label of the quoted line ("local" or "them").

#### Answered means a later transcript line answered the question
`RadarItem.answered`: A later line answered this question.

#### Screen answer exists only when screen answers are on and found something
`RadarItem.screenAnswer`: What an earlier screen capture says about this question, when screen
answers are on and Muse found the answer there.

#### Evidence is a passage shown to the model so contradictions can cite it
`RadarEvidence`: A passage from an earlier meeting (or earlier in this one) that a radar
pass showed the model, so a contradiction can point at it.

#### Rejected counts items failing quote or evidence checks
`RadarPass.rejected`: Items the model returned that failed the quote or evidence check.

#### radar.json lives in the meeting folder and is deleted with it
`MeetingRadarRecord`: `radar.json` in the meeting folder. Deleted with the meeting.

#### One screen-answer request per locally matched question
`MeetingRadarRecord.screenAnswerRequests`: Screen-answer requests, one per question that local search matched.

### `LokalBot/Services/MeetingRadar/MeetingRadarReplay.swift`

#### Radar replay CLI flags, reproducibility, synthetic-only data and key handling
`MeetingRadarReplay`: `LokalBot --radar-replay <fixture.json> [--model <id>] [--interval <s>] [--delay <s>]
  [--base-url \<url> [--reasoning-line \<level>]] [--audio \<folder>] [--screens \<folder>]
  [--answers [--folders \<a,b>] [--answer-model \<id>]]`

Replays a timed transcript through Live Radar's request, grounding checks,
and Meta Model API client, and prints one JSON line per pass and a summary.
`--base-url` sends the same requests to another OpenAI-compatible server,
such as llama-server running Meta's open-weight Muse Glimmer, which needs
no key; `--reasoning-line` then adds the "Reasoning effort: \<level>" line
that Glimmer's chat template reads from the system prompt.
A line becomes visible `delay` seconds after it starts (the live preview's
chunking), and a pass runs every `interval` seconds of meeting time, as in
the app. Earlier-meeting passages come from the fixture instead of the
library, so a run is reproducible. For public or synthetic transcripts
only: the key is read from `META_API_KEY`, never from the Keychain, and
nothing is read from or written to a library.

`--audio` replays the meeting as fast live text does, in real time: the
folder's `me.wav` and `them.wav` (from `Benchmarks/think/MuseRadar/voice_fixture.py`)
stream to Muse Voice Transcribe through the app's client, each finished
turn becomes a line, and a pass follows each turn (`--interval` defaults
to the app's 3 s turn interval). Times are measured on the wall clock.

`--screens` adds screen answers: the folder's `screens.json` lists
synthetic captures (`file`, `capturedAt`, `app`, `windowTitle`), and each
question the radar catches is answered from them as the app does from
screen memory, with the crops made by Vision on this Mac.

`--answers` runs live answers for each question, as the app does: the
fixture's `memory` stands in for what LokalBot remembers, its earlier
passages for meeting search, and `--folders` are read for real (documents,
and code, commits, and GitHub through `gh` in repositories).

#### Fixture memory stands in for LokalBot memory, with kind project, action or memory
`MeetingRadarReplay.Fixture.memory`: What LokalBot would remember: `kind` is project, action, or memory.

#### shownAt is simulated meeting time when the person would see an item
`MeetingRadarReplay.run`: Simulated meeting time at which the person would see each item.

#### Replay screen answers run the app's search, crop and grounding on fixtures
`MeetingRadarReplay.ScreenAnswerRuns`: Screen answers for a replay: the app's search-and-crop step and
grounding check, run against fixture captures. Each result is printed
as a `screenAnswer` line and kept for the summary.

#### Returns nil without --screens or --answers; elapsed is wall-clock delay
`MeetingRadarReplay.ScreenAnswerRuns.answer`: Nil without `--screens` or `--answers`. `elapsed` gives the
wall-clock delay from the question to the answer.

#### Replay tracks lead by 0.1 s to mimic a live microphone
`MeetingRadarReplay.audio`: About one frame of lead, as from a live microphone.

#### Answers run beside passes as in the app, timed on wall clock
`MeetingRadarReplay.audio`: Beside the passes, as in the app, timed on the wall clock.

### `LokalBot/Services/MeetingRadar/MuseLiveText.swift`

#### Fast live text streams tracks to Muse, off by default, sends audio, track-based speakers
`MuseLiveText`: Fast live text: the live transcript preview streams each recorded track to
Muse Voice Transcribe's realtime endpoint and gets each turn's text about
0.7 s after the speaker stops, instead of transcribing 12-second chunks on
this Mac. Off by default; turning it on sends meeting audio to api.meta.ai
while the preview runs. Speaker identity still comes from the track (the
microphone is the person), because Muse's own speaker labels measured less
accurate than local diarization. Built for the Meta Global AI Developer
Hackathon (2026).

#### Server rejects streams over 5 s ahead; sessions start 3 s back
`MuseLiveText.backlogSeconds`: The server rejects a stream more than 5 s ahead of real time; a fresh
session may start this far back in the recording.

#### When fast live text can't run, the preview uses the local model
`MuseLiveText.unavailableReason`: Why fast live text can't run, or nil when it can. The preview then
uses the local model as before.

#### The API key is sent in the first frame, not a header
`MuseLiveText.handshake`: The first frame of a session. The key travels here, not in a header.

#### The handshake acknowledgement is the only frame without a type
`MuseLiveText.parse`: The handshake acknowledgement is the only frame without a type.

#### Endpoint expects 16-bit little-endian PCM
`MuseLiveText.pcm16`: 16-bit little-endian PCM, as the endpoint expects.

#### Pads silence on stalled files so server never sees below-real-time ingress
`MuseLiveTextPacer`: How much of a growing track to send on each tick. Audio goes out as it is
recorded; if the file stops growing (a silent or missing source) the
session is padded with silence so the server never sees below-real-time
ingress, and the padded stretch of the file is skipped when it arrives.

#### Lead is the backlog in the app, about one frame for replays
`MuseLiveTextPacer.leadSeconds`: How far audio may run ahead of the session clock: a fresh session's
backlog in the app, about one frame for a replay of a finished file.

#### Sessions start at most backlogSeconds before file end, never before sent audio
`MuseLiveTextPacer.origin`: A session starts at most `backlogSeconds` before the end of the file,
and never before audio already sent.

#### Undelivered planned frames are returned to be read on a later tick
`MuseLiveTextPacer.unread`: Gives back planned frames the file couldn't deliver yet, so they are
read on a later tick instead of being skipped.

#### Socket protocol lets tests replace the network
`MuseRealtimeSocket`: The socket a session talks through, so tests can replace the network.

#### Track streams 16 kHz file in 100 ms frames; caller reconnects after 60-minute cap
`MuseLiveTextTrack`: One track's realtime session: reads the growing 16 kHz preview file from
`cursor`, streams it in 100 ms frames, and reports each turn on the
recording's timeline. Returns when the server ends the session (for
example at its 60-minute cap); the caller reconnects from `cursor`.

#### Connected origin is seconds into the recording where session audio starts
`MuseLiveTextTrack.Output.connected`: The server accepted the session; its audio starts `origin` seconds
into the recording.

#### Partial is the turn in progress; nil text means it ended empty
`MuseLiveTextTrack.Output.partial`: The turn in progress, or nil when it ended without text.

#### Replay-only start frame streams a finished file in real time
`MuseLiveTextTrack.startFrame`: Replays only: stream a finished file from this frame, in real time.

#### Closing the socket unblocks the pending receive on handshake timeout
`MuseLiveTextTrack.run`: unblocks the pending receive

#### Closing the socket on send failure ends the receiver too
`MuseLiveTextTrack.run`: ends the receiver too

#### The receiver ends the session when the server closes it
`MuseLiveTextTrack.run`: The receiver ends the session when the server closes it.

#### Returns frames actually sent, fewer while the writer is mid-append
`MuseLiveTextTrack.send`: Returns the frames actually sent, which can be fewer than asked for
while the writer is mid-append.

#### Point-in-time file reader while the writer keeps appending, like local preview
`MuseLiveTextTrack.send`: A point-in-time reader, as the local preview uses: the writer keeps
appending to the same file.

### `LokalBot/Services/MeetingRadar/RadarEvidenceSource.swift`

#### Evidence search runs locally; only returned passages join the request
`RadarEvidenceSource`: Finds passages from earlier meetings that the newest live lines may agree
or conflict with. Search runs on this Mac; only the passages it returns
are added to the radar request.

#### Keyword plus optional semantic search over meetings that started earlier
`LibraryRadarEvidenceSource`: Keyword search over transcripts, summaries, and saved outcomes, plus the
semantic index when it is on, limited to meetings that started before the
one being recorded.

#### Query uses 600 characters of newest speech to find topic without dilution
`LibraryRadarEvidenceSource.maximumQueryCharacters`: Enough of the newest speech to find the topic without diluting it.

#### Saved decisions and actions rank first since new lines most often contradict them
`LibraryRadarEvidenceSource.evidence`: Saved decisions and actions first: they are what a new line most
often contradicts.

### `LokalBot/Services/MeetingRadar/RadarScreenAnswers.swift`

#### Quote is on-Mac screen text the model's quote had to match
`RadarScreenAnswer.quote`: What the screenshot says, as read on this Mac; the model's quote had
to match it.

#### Image is decrypted HEIC, PNG or JPEG, read lazily
`RadarScreenCapture.imageData`: The decrypted image (HEIC, PNG or JPEG), read only when needed.

#### Screen source returns captures from before now matching the question, searched locally
`RadarScreenSource`: Screen memory as the radar sees it: captures from before now whose text
matches a question. Search runs on this Mac.

#### Crop is the part of a capture sent, with its on-Mac text
`RadarScreenCrop`: The part of a capture that is sent, and its text as read on this Mac.

#### Screen answers pipeline; quote must be in crop text; off by default; text only
`RadarScreenAnswers`: Screen answers: when Live Radar catches a question, local screen search
finds earlier captures that mention it, Vision on this Mac crops each one
to the rows that do, and the Think model reads the text of the crops. An
answer counts only when its quote is in the crop's own text, so the model
can't invent one. Off by default; only that text (with each crop's app,
window title, and time) is given to the model.

#### Search terms drop question words and fillers; need 3 letters or a digit
`RadarScreenAnswers.terms`: Words worth finding on screen: no question words or fillers, three or
more letters, or any number.

#### Search text is the radar's question plus the words actually said
`RadarScreenAnswers.question`: What to look for: the question as the radar wrote it, plus the words
actually said.

#### Warm Vision recognizer ahead of first question; first use takes many seconds
`RadarScreenAnswers.warmUp`: Loads Vision's text recognizer ahead of the first question. Its very
first use on a Mac can take many seconds.

#### Crop keeps strongest matches, at most half the screen tall, centered on best
`RadarScreenAnswers.crop`: The strongest matches, and the band around them, at most half the
screen tall, centered on the best one when they spread wider.

#### Crop width trimmed to text so it reads in the narrow radar pane
`RadarScreenAnswers.crop`: Only as wide as the text in the band, so the crop stays readable
in the narrow radar pane and leaves the rest of the screen out.

#### Vision's origin is bottom-left while CGImage cropping is top-left
`RadarScreenAnswers.crop`: Vision's origin is bottom-left; CGImage cropping is top-left.

#### Reading order groups rows so a label and its value read as one line
`RadarScreenAnswers.readingOrder`: Top to bottom, and left to right within a row, so a label and its value
on one row read as one line.

#### Image-request form is for image models; Live Radar sends textMessages
`RadarScreenAnswers.messages`: The request for a model that reads images: each crop as a picture.
The Think model reads text, so Live Radar sends `textMessages`.

#### Text request sends no pixels; quote is checked against the same text
`RadarScreenAnswers.textMessages`: The same request with each crop as the text read from it on this Mac,
which is also what the quote is checked against. No pixels are sent.

#### On-screen quote match ignores case and punctuation, mirroring radar quote checks
`RadarScreenAnswers.quoteIsOnScreen`: The whole quote in the crop's text, ignoring case and punctuation, or
most of a longer quote's words, as radar quotes are checked.

#### Screen source uses on-Mac OCR search, earlier captures only, never LokalBot's windows
`LibraryRadarScreenSource`: Screen memory through the app's activity store: OCR search on this Mac,
captures from before the question, never LokalBot's own windows.

### `LokalBotTests/Services/MeetingRadar/LiveAnswersTests.swift`

#### Fixtures are copies of meta-hackathon demo files; see project.yml
`LiveAnswersTests.testDemoSheetAndBriefAreReadable`: Copies of the two files in LokalBotTests/Fixtures/meta-hackathon/demo-files; see project.yml.

#### Outside Spotlight's index, document names are ranked instead
`LiveAnswersTests.testDocumentNamesRankByTheQuerysWords`: Outside Spotlight's index (the temporary folder), names are ranked.

#### Git-tracked hidden, vendored and secret-looking files stay out of code tools
`LiveAnswersTests.testCodeToolsLeaveOutHiddenVendoredAndSecretFilesGitTracks`: Git tracking a file does not make it readable: hidden files and
folders, `node_modules` and secret-looking files stay out of the code
tools as they do out of the document tools. `search_code` and
`read_file` used to return them.

#### A tracked ordinary-named symlink to a withheld file must stay unreadable
`LiveAnswersTests.testCodeToolsLeaveOutHiddenVendoredAndSecretFilesGitTracks`: A tracked link with an ordinary name that leads to a withheld file.

#### Think model turns are one JSON object; lookup results return as observations
`LiveAnswersTests.testTheThinkModelLooksUpAndAnswers`: The same loop on the Think model, as the app runs it: each turn comes
back as one JSON object, and a lookup's result reaches the next turn
as an observation.

### `LokalBotTests/Services/MeetingRadar/MeetingRadarTests.swift`

#### Radar items must be said in a new line
`MeetingRadarAnalyzerTests apply grounding`: Not said in any new line.

#### Radar quotes from context rather than new lines are rejected
`MeetingRadarAnalyzerTests apply grounding`: Quoted from context, not from a new line.

#### A contradiction must cite a passage it was shown
`MeetingRadarAnalyzerTests apply grounding`: A contradiction must cite a passage it was shown.

#### Settings saved before the Live Radar switch keep it on if Meta Muse approved
`MeetingRadarTests.testSettingsFromBeforeTheSwitchKeepLiveRadarWhereMetaMuseWasApproved`: Live Radar used to be offered once Meta Muse was approved. Settings
saved before it had its own switch keep it on with that approval.

#### Without own calls, radar uses Think engine: schema-held reply, no cost
`MeetingRadarTests.testPassesRunOnTheThinkModel`: Without its own calls, the radar asks the Think engine: a pass as one
schema-held reply, named after the Think model and with no cost.

#### A priced model, as in the hosted film, has pass cost counted from reply tokens
`MeetingRadarTests radar fixture`: A model with a price, as when the hosted film runs the radar on
Meta's models: the pass cost is counted from the reply's tokens.

#### The pass interval holds the next line until the recording ends
`MeetingRadarTests.testPassesSendOnlyNewLinesAndFinishReadsTheRest`: The interval holds the next line until the recording ends.

### `LokalBotTests/Services/MeetingRadar/MuseLiveTextTests.swift`

#### Test track is 16 kHz mono float CAF like the live preview tee
`MuseLiveTextTests.writeTrack`: A 16 kHz mono float CAF like the live preview tee writes.

#### A stalled file is padded with silence after 1.5 s behind real time
`MuseLiveTextPacer`: The file stops growing; after 1.5 s behind real time the session is padded.

#### The padded stretch of the file is skipped when it arrives
`MuseLiveTextPacer`: The padded stretch of the file is skipped when it arrives.

#### Frames the file could not deliver are read again, not skipped
`MuseLiveTextPacer.unread`: Frames the file couldn't deliver are read again, not skipped.

#### Never send more than three seconds ahead of the clock
`MuseLiveTextPacer`: Never more than three seconds ahead of the clock.

#### Session starts three seconds back of recorded time
`MuseLiveText session`: Five seconds recorded: the session starts three seconds back, at 2.0 s.

#### Three-second backlog sent as 16-bit samples; last packet may be held back
`MuseLiveText session`: The three-second backlog as 16-bit samples; AVAudioFile may hold
back the last packet of a just-written file.

### `LokalBotTests/Services/MeetingRadar/RadarScreenAnswersTests.swift`

#### Metrics page is drawn, not captured, so Vision reads it on any machine
`RadarScreenAnswersTests.dashboardPNG`: A synthetic metrics page, drawn rather than captured, so Vision reads it
on any machine.

#### Think model reads text from on-Mac crop OCR; no pixels leave the Mac
`RadarScreenAnswersTests.testRadarAnswersACaughtQuestionFromTheScreenAndSavesTheCrop`: The Think model reads text, so it is given what was read from each
crop on this Mac, and no pixels leave it.

#### Hosted film and replay use a picture-reading model with a price
`RadarScreenAnswersTests.testAModelThatReadsPicturesIsSentTheCropAndItsCostCounts`: The hosted film and the replay ask a model that reads pictures.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
