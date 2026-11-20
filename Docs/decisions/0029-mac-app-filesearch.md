# 0029. Mac app: FileSearch

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Services/FileSearch/`, `LokalBotTests/Services/FileSearch/`.

## Decisions

### `LokalBot/Services/FileSearch/FileChangeFilter.swift`

#### Skip FSEvents changes the crawl ignores; when in doubt, sync
`FileChangeFilter`: Which changes FSEvents reports can alter what a sync finds. Every sync walks
the chosen folders again (on a developer's Mac 459,000 entries and 18 s of
CPU to find nothing), so a change the crawl would leave out never starts one:
in a place it doesn't walk, of a type it doesn't read, or inside a code
project, where it keeps only screenshots.

When in doubt it says yes: an extra sync costs seconds, a missed one leaves a
new file out of search until something else changes.

#### Roots kept as chosen and as FSEvents reports (/private/var)
`FileChangeFilter.roots`: Each chosen folder as chosen and as FSEvents reports it (/private/var where the chosen path says /var).

#### Per-root batch answers asked of filesystem once; nested roots differ
`FileChangeFilter.firstThatMatters`: The first change in a batch that can alter what a sync finds. A build reports thousands at a time, so what a
batch learns about a folder or a type is asked of the file system once, for each chosen folder (nested ones
answer differently: one's project can be the other's whole).

#### Lost-track or unknown-kind events always trigger a sync
`FileChangeFilter.matters`: FSEvents lost track of what happened here, or doesn't say what it is: only a sync can tell.

#### Unplaceable path spellings still count as changes
`FileChangeFilter.matters`: A spelling of the path that can't be placed in a chosen folder is no reason to miss a change.

#### Hidden-folder paths rejected without asking filesystem
`FileChangeFilter.matters`: Most of what a busy Mac reports is in hidden folders: no need to ask the file system.

#### Project marker appearing or going matters; editing it does not
`FileChangeFilter.matters`: A project's only marker appearing or going decides what the crawl keeps around it, unless a project above
it already does. Editing one changes nothing.

#### Folder contents report themselves unless moved or cloned
`FileChangeFilter.matters`: A folder's contents report themselves, unless it moved or was cloned: then this is all FSEvents says.

#### Code projects keep only screenshots; deleted files judged by name
`FileChangeFilter.matters`: Only screenshots count in a code project. A file that's gone goes by its name (the mark went with it); if
that's wrong, search still hides a missing file and the next sync drops it.

#### Answers cached per batch since folders and markers change between batches
`FileChangeFilter.Batch`: Answers kept for one batch: folders and markers can change between batches.

### `LokalBot/Services/FileSearch/FileImageSizing.swift`

#### Size images like reference processor; token budget set here, not llama.cpp
`FileImageSizing`: Sizes a picture for EmbeddingGemma 2's vision encoder the way the model's
reference processor does, so the media embedder sees the pixels DigUp's
reference vectors were made from. Ported from DigUp's `ImageSizing`
(github.com/ARahim3/DigUp, MIT; see THIRD_PARTY_NOTICES.md).

The media embedder runs llama-server with `--image-min-tokens 1
--image-max-tokens 1120`, so llama.cpp never rescales an image that already
has its final size: each image's token budget is set here. Left to size
images itself, llama.cpp spends about twice the tokens and the vectors
drift from the reference (Benchmarks/search/EmbeddingGemma2/2026-10-30-media-embedder).

#### Encoder accepts soft-token budgets 70 to 1120
`FileImageSizing.budgets`: Soft-token budgets the encoder accepts.

#### Scale to fill budget, sides rounded down to multiples of 48
`FileImageSizing.targetSize`: transformers' Gemma 4 image processor: scale to fill `budget` soft
tokens (each 3 × 3 patches of 16 px) keeping the aspect ratio, each side
rounded down to a multiple of 48 px. Nil for an image with no area.

#### Keep file's colour values; convert only non-RGB
`FileImageSizing.png(ofImageAt:budget:)`: The image at `url` as a PNG resized for `budget`. Pixels keep the file's
own colour values, as llama.cpp's decoder reads them: no colour-space
conversion unless the file is not RGB.

#### In-memory screen captures resized without writing to disk
`FileImageSizing.png(of:budget:)`: An image already in memory (a decrypted screen capture), the same way:
nothing is written to disk.

#### Bit-exact Pillow bicubic: a=-0.5, widened kernel, 22-bit fixed point
`FileImageSizing.resizeBicubic`: Pillow's bicubic resampling of packed RGB (a = −0.5, the kernel widened
when shrinking, 22-bit fixed point): what the reference gets from PIL's
`Image.resize`. Bit-for-bit with Pillow (see FileImageSizingTests).

### `LokalBot/Services/FileSearch/FileMediaEmbedder.swift`

#### Synchronous requests; inputs sent as parity run qualified, cosine 0.9997
`FileMediaEmbedder`: DigUpKit's `Embedder`, served by the media llama-server: EmbeddingGemma 2
with its image and audio projector (`LlamaServer.mediaEmbedder`). DigUp's
indexer calls it from its own thread, one call at a time, and waits, so the
requests here are synchronous.

Inputs travel the way the 30 October parity run qualified them
(Benchmarks/search/EmbeddingGemma2/2026-10-30-media-embedder): texts as given
(cut to one batch when longer, `fitted`), images as PNG sized for their budget (`FileImageSizing`), audio as WAV, each
medium as a typed content part. That run reproduced DigUp's reference
vectors at cosine ≥ 0.9997.
Immutable after init (an endpoint and a URLSession), so it can cross threads.

#### Bump when vectors change; all file indexes re-embed
`FileMediaEmbedder.vectorVersion`: Which vectors this pipeline makes: the model files, the llama.cpp build,
the image sizing and the request shapes. Bump it when any of them changes
the vectors (the reference-vector check says when); every file index then
embeds again.

#### 16 texts per request avoids multi-minute single requests
`FileMediaEmbedder.textsPerRequest`: Texts per request. One request is one llama-server batch; this keeps a
long document from becoming a single multi-minute request.

#### 2,048 token cap matches server batch and DigUp text cut
`FileMediaEmbedder.maxInputTokens`: The most tokens one input may have, `<bos>` and `<eos>` included: the
server's batch (`-ub 2048`; an embedding must fit in one), and where
DigUp's own embedder cuts a text.

#### WorkerError when server can't answer; other error for rejected picture
`FileMediaEmbedder.embedImage`: One picture already sized and encoded (`FileImageSizing.png(of:budget:)`),
for screen captures that are decrypted in memory. Throws `WorkerError`
when the server can't answer and any other error when it rejects the
picture.

#### Bad file must not sink neighbours; WorkerError leaves files pending
`FileMediaEmbedder.embedding`: One file's vector, or why it has none. A file the server cannot read
(a broken picture) must not sink its neighbours. A server that cannot
answer throws `WorkerError`: DigUp's indexer then stops the pass and
leaves the files pending for the next one, where any other error would
mark the whole batch failed for good.

#### Cut long texts to token limit; server returns HTTP 500 otherwise
`FileMediaEmbedder.fitted`: A text as it is sent: itself when it fits one batch, otherwise its
tokens cut the way DigUp's embedder (and transformers) cuts, the first
`maxInputTokens - 1` and `<eos>`. llama-server refuses a longer input
with HTTP 500 instead of cutting it, and a dense page of Cyrillic or
figures passes 2,048 tokens well within the 4,000 characters DigUp
sends. No token is shorter than a byte, so shorter texts skip the
tokenizer; tokens and text make the same vector.

#### Server answered but rejected input: HTTP 4xx or too large
`FileMediaEmbedder.RejectedInput`: The server answered, but not with vectors for this input (HTTP 4xx, or
an input too large for its batch).

#### Oversized input returns HTTP 500 though server is fine
`FileMediaEmbedder.isTooLarge`: llama-server's answer to an input longer than its batch: HTTP 500,
though the server is fine. Texts are cut to fit first (`fitted`); a
picture or recording that still doesn't fit fails alone instead of
stopping every pass at the same file.

#### Content part must nest one level; flat form rejected by llama.cpp
`FileMediaEmbedder.imagePart`: A typed content part nested one level inside the input item; a flat
`input: [{type: image_url}]` is rejected (ggml-org/llama.cpp#30082).

#### Vectors are L2-normalized and ordered by index
`FileMediaEmbedder.vectors`: L2-normalized vectors in input order (rows are ordered by `index`).

### `LokalBot/Services/FileSearch/FileMediaEmbedderRuntime.swift`

#### Projector and text model come from the same pinned revision
`FileSearchModels`: EmbeddingGemma 2's image and audio projector, the one extra file Files
needs. The text model is the one search by meaning already uses
(`EmbeddingIndex.preparedModel`); both come from the same pinned revision.

#### Projector is downloaded and checked against pinned size and SHA-256
`FileSearchModels.preparedProjector`: The verified projector in the library's models folder, downloading it
first if needed (checked against the pinned size and SHA-256).

#### Media server runs only for indexing, stops after two minutes; searches use text embedder
`FileMediaEmbedderRuntime`: The media embedder's llama-server (`LlamaServerRole.mediaEmbedder`): the
text model plus the projector, started for an indexing pass and stopped two
minutes after the last one. Searches never use it; they embed their words
on the small text-only embedder, whose vectors are identical
(Benchmarks/search/EmbeddingGemma2/2026-10-30-media-embedder).

#### Images are pre-resized; token limits stop llama.cpp rescaling them
`FileMediaEmbedderRuntime.serverArguments`: The embedder's arguments plus the projector. With images resized for
their budget before they are sent (`FileImageSizing`), the token limits
keep llama.cpp from rescaling them.

#### Allowance excludes weights; 30 October run peaked at 1.2 GiB RSS
`FileMediaEmbedderRuntime.runtimeAllowanceBytes`: Weights are counted separately (865 MB with the projector). The 30
October run peaked at 1.2 GiB RSS while indexing.

#### Server stays resident until end(_:) is called with the pass token
`FileMediaEmbedderRuntime.begin`: Starts (or reuses) the server for one pass and keeps it resident until
`end(_:)`. Returns the endpoint and a token to end the pass with.

### `LokalBot/Services/FileSearch/FileMomentTranscriber.swift`

#### Never downloads model, waits during recording, keeps text only in memory
`FileMomentTranscriber`: What was said at a recording's or video's matched moment, for the Ask
assistant: Files finds the 30-second window by meaning, and this
transcribes just that window with the person's own transcription model, so
the answer can quote it instead of only pointing at the moment.

It never downloads a transcription model (`ModelReadinessSnapshot`), waits
while a meeting records so it can't compete with live transcription, and
keeps the text only in memory: the tool's observation is not saved with
the conversation (`ChatMessage` stores the answer and activity line).

#### Model ignores sound past 30 s of one input
`FileMomentTranscriber.window`: The model ignores sound past 30 s of one input, so a match covers this.

#### Available when transcription model is local and no meeting is recording
`FileMomentTranscriber.isAvailable`: The transcription model is on this Mac and no meeting is recording.

### `LokalBot/Services/FileSearch/FileSearchService.swift`

#### Id is the passage's file-index id, cited as [file:\<id>]
`FileSearchHit.id`: The matching passage's id in the file index; `[file:<id>]` cites it.

#### PDF page numbers start from 1
`FileSearchHit.page`: A PDF page, from 1.

#### Seconds into a recording or video
`FileSearchHit.seconds`: Seconds into a recording or video.

#### Excerpt shows matched words in «», or the passage start
`FileSearchHit.excerpt`: The matched words in «», or the passage's start.

#### Photo capture date from EXIF, when present
`FileSearchHit.taken`: When a photo was taken (EXIF), if it says.

#### Semantic means found by meaning, without the query's words
`FileSearchHit.isSemantic`: Found by what it means or shows, without the query's words.

#### This is the date Ask's time scope filters on
`FileSearchHit.date`: The date Ask's time scope filters on.

#### EXIF DateTimeOriginal format, in the camera's local time
`FileSearchHit.exifDate`: EXIF `DateTimeOriginal`: "2026:05:14 18:02:11", in the camera's local time.

#### Indexing pass triggers, pause conditions, pacing and battery rules
`FileSearchService`: Files: the folders a person chooses, searched by what is in them. DigUp's
engine (DigUpKit, MIT) crawls and reads them and keeps the index; vectors
come from the media embedder (`FileMediaEmbedderRuntime`), and searches
embed their words on the text embedder search by meaning already runs.

Indexing happens in passes: at launch, after the folders change, and a few
seconds after a change in them that can alter the index (`FileChangeFilter`).
A pass reads only new and changed files, stops at the next file when a
meeting starts recording, in Low Power Mode, or when the Mac is hot, and
starts again when that ends. The image and audio model loads only while a
pass has files to read.

A big read (a folder's first pass, the rest of long files) is paced while
the person uses the Mac (`IndexPacing`) and, on battery, waits for a
charger unless reading on battery is on. A few new files are read right
away on any power source.

#### On battery a big read waits for a charger
`FileSearchService.State.waitingForPower`: On battery, a big read waits for a charger: `left` files.

#### Part of wall time spent resting while the person used the Mac
`FileSearchService.PassReport.restedSeconds`: Of `wallSeconds`, how long reading rested while the person used the Mac.

#### Media read as 30 s sound windows every 25 s, frame per shot at most every 3 s
`FileSearchService.Configuration.includesMedia`: Read recordings and video too: sound 30 seconds at a time (a new
window every 25 s) and a frame per shot, at most one every 3 s.

#### Off means first pass and long-file remainder wait for a charger
`FileSearchService.Configuration.readsOnBattery`: Read big passes on battery too. Off, a folder's first pass and the
rest of long files wait for a charger.

#### Source names the vectors as the index fingerprint; embedder made on indexing thread
`FileSearchService.EmbedderSession`: One pass's embedder: what its vectors are called (the index's
fingerprint), how to make it on the indexing thread, and how to let the
model go afterwards.

#### Extension list errs on the side of more; code excluded via includeCode off
`FileSearchService.mediaExtensions`: Recordings and video, by extension, for when the person turns them off
(DigUp recognises them by type, so the list errs on the side of more).
Code stays out because `IndexOptions.includeCode` is off.

#### DigUp state for files left unread when text recognition gave no answer
`FileSearchService.leftUnread`: The state DigUp's indexer gives a file, or a long PDF's next pages, it
did not read because text recognition gave no answer.

#### Up to 50 new files read on any power source, as DigUp's helper does
`FileSearchService.newFilesLimit`: New files a sync finds, up to this many, are read on any power source;
more is a big read that waits for a charger on battery (as DigUp's
helper does).

#### Estimated time left for the running pass at pace so far
`FileSearchService.secondsLeft`: About how long the pass reading now has left, at the pace so far.

#### Folder changes settle for this long before a pass reads them
`FileSearchService.changeDelay`: How long changes in the folders settle before a pass reads them.

#### Supplies words at a media moment for the assistant; nil leaves none
`FileSearchService.transcribeMoment`: The words at a recording's or video's matched moment, for the
assistant (`FileMomentTranscriber`); nil leaves moments without words.

#### Called between jobs on the index queue, so must not need main actor
`FileSearchService.isOnBattery`: Asked between jobs on the index queue, so it must not need the main actor.

#### Route text recognition through the app queue before any file is read
`FileSearchService.live`: Before anything reads a file: DigUp's text recognition waits its
turn on the app's queue, and no longer than its limit.

#### Called when settings change or app launches to start, re-read or stop
`FileSearchService.apply`: Settings changed (or the app launched): start, re-read or stop.

#### Turning off battery reading stops a running big read at next job
`FileSearchService.apply`: Reading on battery turned off: a big read going on battery stops at
the next job, and the next pass waits for a charger.

#### Called on recording start/stop and power or thermal changes
`FileSearchService.conditionsDidChange`: A recording started or stopped, or the power or thermal state changed.

#### On quit the current file finishes, then indexing stops
`FileSearchService.stop`: Quitting: let the current file finish, then stop.

#### Sync first so an unchanged library never loads the model
`FileSearchService.runOnePass`: Find what is new or changed first: an unchanged library never loads the model.

#### On battery read only few fresh files; first pass waits for charger
`FileSearchService.runOnePass`: On battery only what this sync just found, if it is a few files; a
folder's first pass waits for a charger.

#### If embedder goes away, files stay pending for next pass
`FileSearchService.runOnePass`: The embedder went away (WorkerError): files stay pending for the next pass.

#### Media off excludes by extension; next sync drops indexed ones
`FileSearchService.indexOptions`: Turning recordings and video off excludes them by extension; the next
sync then drops those already indexed.

#### Sync reports waiting files and, if few, which were just found
`FileSearchService.sync`: Brings the index in line with the folders and says how many files wait
to be read (new, changed, or long files read part way), and which ones
it just found, if they are a few.

#### Removed folders leave index; missing or unlistable folders keep their files
`FileSearchService.sync`: Folders taken off the list leave the index; a folder that is missing
(an unplugged drive) or that macOS won't list keeps its files.

#### Pending read stops when charger needed; unanswered text recognition left as-is and counted
`FileSearchService.index`: Reads what is pending (`only` some: new files on battery). A big read
stops at the next job when `waitsForPower` says so, and every job
rests as `pacer` says. A screenshot or scan whose text recognition
gave no answer (`FileTextRecognition`) is left as it was, and counted.

#### New model or pipeline version re-reads everything instead of mixing vectors
`FileSearchService.index`: A new model or pipeline version re-reads everything rather than mixing vectors.

#### DigUp reports a file left for later as still pending
`FileSearchService.index`: DigUp reports a file it left for a later pass as still "pending".

#### Estimate uses metadata only; costs measured here or scaled from M4 Pro
`FileSearchService.estimate`: What adding `folders` would read, before anything is read: files by
kind, how long the first pass takes on this Mac at full speed, and how
much room the index will take (`FileIndexSize`). DigUp's `Estimator`
goes by metadata alone (counts, PDF page counts and durations from
Spotlight); its costs are what indexing has measured here, or else its
M4 Pro costs scaled by a one-second speed check made once. Files
already under a chosen folder don't count.

#### Opening protected folders prompts macOS; declined ones can't be listed
`FileSearchService.estimate`: Opening a protected folder (Documents, Desktop, Downloads) is what
makes macOS ask the person; one they said no to can't be listed.

#### Nothing opened until chosen so macOS asks for access only then
`FileSearchService.suggestedFolders`: Documents, Desktop and Downloads, for one-click choices before any
folder is chosen: the ones that exist and aren't chosen already.
Nothing in them is opened until the person picks one, so macOS asks
for access only then.

#### Query vector uses 'task: search result | query: ' prefix; without it words only
`FileSearchService.search`: Files that match `text`, best first. With a query vector (the text
embedder's, made with `task: search result | query: `) it searches by
meaning and by words; without one, by words only.

#### Walks report real paths, so match both path spellings
`FileSearchService.search`: A walk reports a folder as its real path (/private/var where the
chosen path says /var), so a file matches either spelling.

#### Ask four times the limit to fill list after date filter
`FileSearchService.search`: Ask enough to fill the list after the date filter drops some.

#### Media moments return what was said in the 30-second window
`FileSearchService.passage`: The stored text of a matched passage, for the agent to read. For a
recording or video moment, what was said in its 30-second window.

#### Cited passage resolves by id; nil once its file left the index
`FileSearchService.hit`: A passage cited by an earlier answer, by its id; nil once its file left
the index.

#### Background model work waits on recording, Low Power Mode or heat; shared with screen vectors
`FileSearchService.PauseReason.current`: Why background model work should wait now: a meeting is recording, Low
Power Mode is on, or the Mac is hot. Files and picture vectors for
screens both use it.

#### First pass duration at full speed on this Mac
`FileFolderEstimate.seconds`: The first pass at full speed on this Mac.

#### Long PDFs and documents' remainder is read after every file's first part
`FileFolderEstimate.laterSeconds`: The rest of long PDFs and documents, read after everything's first part.

#### Index space once files are fully read
`FileFolderEstimate.indexBytes`: The room these files take in the index once read through.

#### Model bytes still to download before first pass; 0 once present
`FileFolderEstimate.downloadBytes`: The model still to download before the first pass (0 once it's here).

#### Folders macOS refuses because access was declined in Privacy settings
`FileFolderEstimate.unreadable`: Chosen folders macOS won't let LokalBot open (access was declined in
System Settings → Privacy & Security → Files and Folders).

#### Estimate per kind so PDF pages and video lengths count fully
`FileFolderEstimate.init`: DigUp's estimate of `candidates`, kind by kind, so each kind's size
can be told: PDFs' pages counted to the end and each video's length.

#### Name is English, localized in app; Finder's name is guarded by macOS
`FileFolderSuggestion`: A common folder offered before any is chosen. `name` is its English name,
looked up in the app's language: Finder's own name for it would have to be
read from inside the folder, which macOS guards.

#### Per-item index bytes measured 31 October 2026; 768 float16 vectors
`FileIndexSize`: Bytes the file index takes per item, measured on 31 October 2026 by
indexing samples of each kind: a 768 × float16 vector (1.5 KB) per passage,
picture, window or frame, the file's row, and any words, which the keyword
index keeps twice (about 2.3 bytes a character). Files themselves are never
copied.

#### Assumes about 1,500 characters of recognised words
`FileIndexSize.screenshot`: With about 1,500 characters of words read from it.

#### Assumes a page of about 2,400 characters
`FileIndexSize.pdfPage`: A page of about 2,400 characters.

#### Per 2,000 bytes of document, DigUp's chunk estimate
`FileIndexSize.docChunk`: For each 2,000 bytes of a document: DigUp's chunk estimate.

#### 30-second windows every audioHop (25) seconds
`FileIndexSize.soundWindow`: 30 seconds of sound, one window every `audioHop` (25) seconds.

#### One frame per shot, at most every 3 s and 1,200 per video
`FileIndexSize.videoFrame`: A frame per shot, at most one every `frameInterval` (3) seconds and
1,200 a video; near-duplicate frames are dropped, so this is the most.

#### Screenshots, scans and long PDFs with no text recognition answer wait for later pass
`FilePassOutcome.unanswered`: Screenshots and scans whose text recognition gave no answer, and long
PDFs that stopped at such a page: left for a later pass.

#### Files still waiting after a pass: held for charger or stopped
`FilePassOutcome.left`: Files still waiting afterwards (a big read held for a charger, or stopped).

#### Fresh files listed only when newFilesLimit or fewer
`FileSyncResult.fresh`: The ones this sync found, when they are `newFilesLimit` or fewer.

### `LokalBot/Services/FileSearch/FileSearchWorkers.swift`

#### Stop flag ends a pass at next job boundary
`FileIndexStopFlag`: Asked by DigUp's indexer before each job; set from the main actor to end a
pass at the next job boundary (a recording started, Files was turned off).

#### One serial queue and connection because DigUp's Database is single-threaded
`FileIndexWorker`: Owns the index while it is written: one serial queue, one connection
(DigUp's `Database` is single-threaded). Indexing runs here, off the main
thread, with a pool drained per call like DigUp's helper process.

#### Separate connection so searches never wait on indexing; vectors loaded lazily
`FileSearchReader`: Owns the searcher: its own connection on its own serial queue, so a search
never waits for indexing (SQLite's WAL lets it read while the index is
written). Vectors load on the first search by meaning and are released
after a while without one.

#### Passage text is nil for pictures and video frames
`FileSearchReader.passage`: The stored text of one passage (a PDF page, a document chunk, a
screenshot's text); nil for a picture or a video frame.

#### After new files are indexed the next search reads them
`FileSearchReader.markStale`: New files were indexed: the next search reads them.

#### Vectors (about 1.5 KB each) freed after idle period
`FileSearchReader.releaseIfIdle`: Frees the vectors (about 1.5 KB each) when nothing searched for a while.

#### Batches that cannot alter a sync are filtered; first relevant change reported
`FileFolderWatcher`: FSEvents on the chosen folders. A batch that can't alter what a sync finds
(`FileChangeFilter`) goes no further; from the others, the first change that
can is reported and the service decides whether a pass is due.

### `LokalBot/Services/FileSearch/FileTextRecognition.swift`

#### Route recognition through app queue with timeout after 2026-11-09 Vision hang
`FileTextRecognition`: Sends the text recognition of Files' indexer through the app's one queue
for it (`TextRecognitionQueue`), with a time limit, like every other
Vision text request in the app.

DigUp reads the words in screenshots and in scanned PDF pages. It used to
ask Vision itself and wait for as long as that took. On 2026-11-09 one
screenshot's request never came back: the pass and the media model it had
started stayed up until the app quit, and every other text recognition in
the app waited behind that request.

A file whose text gets no answer in time is not read without it, which
would settle it for good. DigUp leaves it waiting (a long PDF keeps its
place), the pass goes on with the next file, and a later pass reads it.

#### Same wait as a screen capture's text recognition
`FileTextRecognition.timeLimit`: As long as a screen capture waits for the text in its pixels.

#### Queue becomes the way DigUp reads text, incl. speed check; tests may stub
`FileTextRecognition.route`: Makes `queue` the way DigUp reads text in this process: the indexer's
screenshots and scans, and the one-off speed check behind a folder's
estimate. `recognize` is the reading itself, DigUp's own Vision
request unless a test stands in for it.

#### Nil result on timeout leaves file for a later pass
`FileTextRecognition.route`: The thread reading files waits here, for `seconds` at most. Nil
(no answer in time, or recognition is stalled) leaves the file
for a later pass.

### `LokalBot/Services/FileSearch/FilesAccessManager.swift`

#### Keeps files-access.json folder list so CLI/MCP search without the app
`FilesAccessManager`: App-side owner of the Files grant (Settings → External Agents).
While it is on and Files is on with a folder, the app keeps
`control/files-access.json` listing the chosen folders, so `lokalbot-cli`
and its MCP server can search the Files index without the app running and
without reading the app's settings. Anything else removes that list.

#### Folders Files reads; nil while Files is off
`FilesAccessManager.folders`: The folders Files reads, or nil while Files is off.

### `LokalBot/Services/FileSearch/IndexPacing.swift`

#### While person is present rest twice the batch; full speed after two idle minutes
`IndexPacing`: How hard a big read works the Mac: a folder's first pass in Files, or the
picture vectors of saved screens. While the person is at the Mac, reading
gets about a third of the time: after each batch it rests twice as long as
the batch took. After two minutes without a key press or mouse move it goes
at full speed, and the next input slows it again after the current batch.

#### Two seconds of rest per second of work while present
`IndexPacing.restPerSecondOfWork`: Seconds of rest for each second of work while the person is at the Mac.

#### 120 seconds without input means the person stepped away
`IndexPacing.awayAfter`: No input for this long: they stepped away.

#### Rest capped at 20 s so long batches never stall reading
`IndexPacing.longestRest`: A long batch (the frames of an hour of video) never holds reading up
for longer than this.

#### Idle time is read from keyboard and mouse; needs no permission
`IndexPacing.live`: Paced by the person's keyboard and mouse. Reading the idle time needs
no permission.

#### Rests in short sleeps between jobs so stop never waits; next job prefetched
`FileIndexPacer`: Paces a Files pass on the index queue. DigUp asks `shouldStop` between
jobs (a batch of up to 8 pictures, a file, or a step of a long one), and
the pacer rests there in short sleeps, so a stop never waits on a rest.
The next job is read and decoded ahead meanwhile, so no rest is wasted.

### `LokalBotTests/Services/FileSearch/FileImageSizingTests.swift`

#### Embedder must see transformers' resize target then Pillow bicubic; fixtures from DigUp (MIT)
`FileImageSizingTests`: The media embedder has to see the pixels the reference sees: transformers'
resize target, then Pillow's bicubic. The fixtures are DigUp's
(`Tests/LlamaRuntimeTests/ImageSizingTests.swift`, MIT), made with PIL.

#### Small images grow to fill the budget, as in the reference
`FileImageSizing.targetSize`: Small images grow to fill the budget, as in the reference.

#### A side rounding to zero gets one 48 px row; the other is capped at budget
`FileImageSizing.targetSize`: One side rounds to zero: it gets one 48 px row, the other side capped at the budget.

#### Embedder PNG is budget-sized and keeps file pixels when no resize is needed
`testPNGIsSizedForTheBudgetAndKeepsPixels`: The PNG the embedder sends is the budget's size and carries the file's
pixels unchanged when no resize is needed.

### `LokalBotTests/Services/FileSearch/FileIndexSizeTests.swift`

#### Projected index size is compared against DigUp's real index with real-sized vectors
`FileIndexSizeTests`: The index size the add-folder sheet projects (`FileIndexSize`) against
the index DigUp really writes for a folder of documents, pictures,
screenshots, a PDF and a recording, with real-sized vectors.

### `LokalBotTests/Services/FileSearch/FileMediaEmbedderReferenceTests.swift`

#### App path must reproduce DigUp vectors at cosine 0.999 (JPEG 0.998); rerun on llama.cpp updates
`FileMediaEmbedderReferenceTests`: DigUp's reference inputs through the app's own path (ImageIO decoding,
`FileImageSizing`, PNG content parts, the media llama-server with the app's
arguments) must reproduce DigUp's reference vectors at cosine ≥ 0.999, the
bar DigUp sets for runtimes that agree. JPEG inputs get 0.998: DigUp's
reference decodes them with stb_image and the app with ImageIO, and the two
decoders differ on 27% of the photo's pixels (mean 0.2 levels). Measured on
30 October with ImageIO-decoded pixels in Pillow's path too: photo-140
0.99964 and frame-70 0.99860, the same as this test, while text, the PNG
screenshot and speech match at 1.0. Run it for every llama.cpp update:
a failure means bump `FileMediaEmbedder.vectorVersion` (every file index
then reads its files again) or keep the old llama.cpp.

Needs both model files in one folder: set `LOKALBOT_MEDIA_EMBEDDER_MODELS`
(pass `TEST_RUNNER_LOKALBOT_MEDIA_EMBEDDER_MODELS` through xcodebuild) to a
folder holding `embeddinggemma-2-Q8_0.gguf` and
`mmproj-embeddinggemma-2-Q8_0.gguf`. Skipped otherwise. The fixtures are
DigUp's (MIT; `Fixtures/MediaEmbedderReference/LICENSE.DigUp`).

#### Text beyond the batch is cut to 2,047 tokens plus eos; whole input gave HTTP 500
`testATextLongerThanTheBatchIsCutLikeDigUpCutsIt`: A text longer than the server's batch gets the vector of its first
2,047 tokens and `<eos>`, as DigUp's embedder and transformers cut it,
so what follows the cut changes nothing. Sent whole, llama-server
refused such a page with HTTP 500 and every indexing pass stopped there
(1 November).

### `LokalBotTests/Services/FileSearch/FileMediaEmbedderTests.swift`

#### Request shapes match the 30 October parity run; outage stops a pass
`FileMediaEmbedderTests`: The media embedder's requests have the shapes the 30 October parity run
qualified, a text longer than one batch is cut the way DigUp cuts it, and a
server outage stops a pass instead of failing files.

#### Dense page past the batch is sent as tokens cut like DigUp; whole gave HTTP 500
`testATextLongerThanOneBatchGoesAsItsTokensCutLikeDigUp`: A dense page past the server's batch goes as its tokens, cut where
DigUp's embedder cuts. Sent whole, llama-server refused it with HTTP 500
and every indexing pass stopped at that page (1 November).

#### llama-server too-large input 500 fails that file alone; other 500s stop the pass
`testAnInputTooLargeForTheBatchFailsThatFileOnly`: llama-server answers an input too large for its batch with HTTP 500;
that input fails alone, and any other 500 still stops the pass.

### `LokalBotTests/Services/FileSearch/FileMomentTranscriberTests.swift`

#### Assistant hears only a recording's matched 30 seconds, when the person's model is present
`FileMomentTranscriberTests`: The assistant hears a recording's matched 30 seconds, transcribed on
demand with the person's own model, and only when that model is here.

### `LokalBotTests/Services/FileSearch/FileSearchServiceTests.swift`

#### A folder's only marker decides what is kept; editing it or a sibling changes nothing
`FileChangeFilter`: A folder's only marker decides what's kept around it. Editing it, or another beside it, changes nothing.

#### New folder contents report themselves; a moved or cloned folder reports only itself
`FileChangeFilter`: A new folder's contents report themselves; one that moved or was cloned says only this.

#### Lost FSEvents or unplaceable paths count as changes; only a sync can tell
`FileChangeFilter`: FSEvents lost track, or the path can't be placed: only a sync can tell.

#### Chosen folders are read whole; FSEvents reports /private/var for /var paths
`testAChosenFolderIsReadWholeWhateverHoldsIt`: Chosen on purpose: its own markers don't make it a project, and a hidden or skipped folder above it doesn't
count. FSEvents reports the real path, /private/var where the chosen one says /var.

#### Another chosen folder can still reach what this one skips
`FileChangeFilter`: Another chosen folder can still reach what this one skips.

#### Nested chosen folders answer separately; a project to the outer is whole to the inner
`FileChangeFilter`: Nested folders answer separately within a batch: a project to the outer one is whole to the inner one.

#### DigUp reads 30 s audio windows every 25 s
`testARecordingIsReadInOverlappingWindowsAndLeavesWhenMediaIsTurnedOff`: DigUp reads 30 s windows every 25 s: 0–30 s and 25–40 s.

#### 2026-11-09 unanswered text recognition stalled a pass and kept the media model until quit
`testAPassFinishesWithoutTextRecognitionThatNeverAnswers`: 2026-11-09: text recognition never answered for one screenshot the
indexer was reading. The pass waited for it, and kept the media model
it had started, until the app quit.

#### A screenshot without its words stays pending, unlike failed or read files
`testAPassFinishesWithoutTextRecognitionThatNeverAnswers`: The pass went on to the document. The screenshot is not settled
without its words: it waits, where failed or read it never would.

#### Test audio is a 16 kHz mono tone because DigUp drops silent windows
`FileSearchServiceTests.writeTone`: A 16 kHz mono tone: DigUp drops silent windows.

### `LokalBotTests/Services/FileSearch/IndexPacingTests.swift`

#### Rest between jobs does not count as work time
`IndexPacingTests.testRestBetweenJobs`: the second job; the rest above doesn't count as work

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
