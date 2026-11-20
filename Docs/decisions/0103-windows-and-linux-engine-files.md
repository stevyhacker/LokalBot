# 0103. Windows and Linux: engine — files

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-engine/src/files/`.

## Decisions

### `LinuxWindows/crates/lokalbot-engine/src/files/documents.rs`

#### Supported document formats and extraction methods; legacy .doc is not read
Text from documents (`DocExtractor`, `OfficeText`, `RTF`, as DigUp's Linux and
Windows builds read them): plain text directly, HTML by stripping tags, docx
and odt from the XML inside their zip, rtf stripped of its control words, and
spreadsheets and presentations from their XML. Legacy .doc isn't read here.

#### Zip entries over 64 MiB are not inflated, guarding zip bombs
`MAX_ENTRY_BYTES`: Larger zip entries aren't inflated: a zip bomb, or XML far past what the index
keeps of a document.

#### Reading stops at 10M characters, beyond what the index keeps
`MAX_OFFICE_CHARACTERS`: Reading stops past what the index keeps of a document.

#### Encoding order UTF-8, UTF-16 with BOM, then Latin-1, matching Swift
`read_text`: UTF-8 (with or without a BOM), UTF-16 with a BOM, else Latin-1, as
`String(contentsOf:usedEncoding:)` falls back.

#### Declared entry size is checked before allocating
`Zip::data`: The entry's bytes, or `None` when there's no such entry. The declared size
is checked before anything is allocated.

#### Read is capped at the declared size whatever the stream says
`Zip::data`: Never more than was declared, whatever the stream says.

#### A password-protected Office file is an OLE compound file wrapping the zip
`office_text`: An Office file with a password is an OLE compound file holding the zip.

#### Strip namespace prefixes because writers use different ones
`local`: A tag's name without its namespace prefix: writers don't all use the same ones.

#### Boolean and error cells are skipped as useless for search
`workbook`: TRUE/FALSE and #N/A say nothing to search for.

#### Absolute relationship targets start at package root, others at part folder
`resolve_target`: Absolute targets start at the package's root, others at the part's folder.

#### CDATA text is raw so its ampersand is literal
`Event::Text`: Text between tags; `raw` for CDATA, whose `&` is a plain `&`.

#### Minimal XML reader: no DTDs, namespace prefixes stay in names
`XmlScanner`: A small XML reader for the parts of Office files (`XMLScanner`): no DTDs, and
namespace prefixes stay in the names.

#### A leading colon in the name matches any namespace prefix
`XmlScanner::attribute`: The value of attribute `name`. A name starting with ":" matches any
prefix (":id" finds "r:id" but not "id").

#### RTF unicode values are signed 16-bit; negatives wrap
`rtf_text`: A signed 16-bit value; negative ones wrap.

#### Only the upper half differs from Latin-1
`windows_1252`: Windows-1252's upper half; the rest is Latin-1.

### `LinuxWindows/crates/lokalbot-engine/src/files/image_sizing.rs`

#### Image sizing matches the reference processor; token budget set here, not by llama.cpp
Sizes a picture for EmbeddingGemma 2's vision encoder the way the model's
reference processor does (`FileImageSizing`, from DigUp's `ImageSizing`, MIT),
so the media embedder sees the pixels the reference vectors were made from.

The media embedder runs with `--image-min-tokens 1 --image-max-tokens 1120`,
so llama.cpp never rescales an image that already has its final size: each
image's token budget is set here.

#### Scale to fill the soft-token budget, sides rounded down to multiples of 48
`target_size`: transformers' Gemma 4 image processor: scale to fill `budget` soft tokens
(each 3 × 3 patches of 16 px) keeping the aspect ratio, each side rounded
down to a multiple of 48 px. `None` for an image with no area.

#### Resized image is encoded in memory so decrypted captures never touch disk
`png`: The picture resized for `budget`, encoded as a PNG. Nothing is written to
disk, so a decrypted screen capture stays in memory.

#### Replicates Pillow bicubic exactly so pixels match the reference
`resize_bicubic`: Pillow's bicubic resampling of packed RGB (a = −0.5, the kernel widened when
shrinking, 22-bit fixed point): what the reference gets from `Image.resize`.

#### Extreme aspect ratios round one side to a 48 px row
`target_size_fills_the_budget`: One side rounds to zero: one 48 px row, the other capped at the budget.

#### Fixtures are PIL-resized outputs shared with DigUp's tests
`tests::SOURCE`: A 7×5 image resized by PIL (`Image.resize`, BICUBIC). The fixtures are
DigUp's, as `FileImageSizingTests` uses them.

### `LinuxWindows/crates/lokalbot-engine/src/files/media.rs`

#### Decoders per format; ffmpeg fallback and video frames need ffmpeg
Pictures, sound and video for the model (`ImageExtractor`, `AudioExtractor`,
`VideoExtractor`, `Platform/Portable`).

Pictures decode here (JPEG, PNG, GIF, BMP, TIFF, WebP, TGA, PNM); HEIC and AVIF
go through ffmpeg when it's installed. Sound decodes through Symphonia, which
the meeting pipeline already uses (MP3, AAC, FLAC, Ogg Vorbis, WAV, AIFF, CAF,
MP4, MKV), with ffmpeg as the fallback for the rest. A video's frames need
ffmpeg: without it a video is read for its sound and its name only, and
Settings says so.

#### RMS 0.003 (about -50 dBFS) counts as silence and gets no vector
`SILENCE_RMS`: ≈ −50 dBFS: silence isn't worth a vector.

#### A file's tail must add at least 2 seconds to get its own piece
`MINIMUM_SECONDS`: The tail of a file must add at least this much.

#### CREATE_NO_WINDOW flag prevents a console flash on Windows
`ffmpeg command`: CREATE_NO_WINDOW

#### Decode in full then apply orientation; tiny pictures are skipped
`decode_image`: Decodes a picture in full, no matter its size, then applies its orientation.
Pictures smaller than `min_side` on both sides aren't worth a vector.

#### EXIF read from JPEG APP1, TIFF or WebP; HEIF left to ffmpeg
`read_exif`: The two EXIF facts the indexer wants (`EXIF`), from a JPEG's APP1 segment, a
TIFF's own tags or a WebP's EXIF chunk. HEIF files are left to ffmpeg, which
turns them itself.

#### Only the first 1 MiB is read; late WebP EXIF is ignored
`read_exif`: Headers come first in JPEG and most TIFFs; WebP's chunk may trail, but a
photo's vector doesn't depend on it.

#### APP1 length under 8 means no TIFF block to read
`read_exif`: A declared length under 8 ends the segment before its own
"Exif\0\0" header does: there is no TIFF block to read.

#### Sound is streamed as 16 kHz mono samples
`SoundSource`: A stream of 16 kHz mono samples.

#### Symphonia first; ffmpeg handles Opus, AVI and WMA
`SoundSource::open`: Symphonia first; ffmpeg for what it doesn't read (Opus, AVI, WMA).

#### Windows skip silence; model ignores past 30 s; memory bounded by streaming
`sound_windows`: Sound cut into `window`-second pieces `hop` seconds apart, skipping silent
ones; one model input ignores anything past 30 s. Memory stays at one window
plus the pieces that are ready, and `on_piece` takes each away as it comes.

#### Clip is returned in memory as samples; nothing written to disk
`sound_clip`: `seconds` of sound from `start`, as a WAV: the moment a search found, for the
assistant to hear (`FileMomentTranscriber.exportClip`). Nothing is written.

#### Near-duplicate frames within 4 hash bits extend the previous one; needs ffmpeg
`keyframes`: A frame per shot, through ffmpeg: a frame every `interval` seconds, and one
that looks like the previous kept one (8×8 average hash within 4 bits) only
extends it. Frames reach `on_frame` one at a time with the second they show;
it returns false to stop. Nothing happens without ffmpeg.

#### Test guards a past panic on short APP1 segments
`a_jpeg_exif_segment_shorter_than_its_header_is_not_read`: APP1 declares 2 to 7 bytes but still carries "Exif\0\0": the segment
ends before the TIFF block starts. This used to panic the Files pass.

### `LinuxWindows/crates/lokalbot-engine/src/files/mod.rs`

#### Files indexing passes: triggers, pause conditions, paced big reads, small reads immediate
Files: the folders a person chooses, searched by what is in them
(`FileSearchService`). Nothing is read until they turn it on after a notice
and choose a folder.

Indexing happens in passes: at launch, after the folders change, and a few
seconds after a change in them that can alter the index (`ChangeFilter`). A
pass reads only new and changed files, stops at the next file when a meeting starts recording, in battery
saver, or when the computer is hot, and starts again when that ends. The image
and audio model loads only while a pass has files to read.

A big read (a folder's first pass, the rest of long files) is paced while the
person uses the computer and, on battery, waits for a charger unless reading on
battery is on. A few new files are read right away on any power source.

#### Up to 50 new files read on any power source
`NEW_FILES_LIMIT`: New files a sync finds, up to this many, are read on any power source; more is
a big read that waits for a charger on battery.

#### Folder changes settle 5 s before a pass reads them
`CHANGE_DELAY`: How long changes in the folders settle before a pass reads them.

#### Power and heat are checked every 30 s while Files is on
`CONDITIONS_TICK`: How often power and heat are looked at while Files is on.

#### Unsearched vectors are released every 120 s
`RELEASE_TICK`: How often vectors nothing searched for a while are let go.

#### Files and screen picture vectors share one background-pause rule
`PauseReason::current`: Why background model work should wait now. Files and picture vectors for
screens both use it.

#### On battery, a big read waits for a charger
`FileSearchState::WaitingForPower`: On battery, a big read waits for a charger.

#### Part of wall_seconds spent resting while the person used the computer
`PassReport.rested_seconds`: Of `wall_seconds`, how long reading rested while the person used the computer.

#### Estimate of time left uses the pace so far
`FileSearchStatus.seconds_left`: About how long the pass reading now has left, at the pace so far.

#### Called when a recording starts or stops
`FileSearch::conditions_changed`: A recording started or stopped.

#### Tracks whether settings were acted on since launch
`Control.applied`: These settings have been acted on since launch.

#### Who may search follows the folders regardless of other state
`Control::apply`: Who may search moves with the folders, whatever else happens.

#### Turning off battery reading stops a big read at the next job
`Control::apply`: Reading on battery turned off: a big read going on battery stops at the
next job, and the next pass waits for a charger.

#### Reacts to recording, power or heat changes
`Control::conditions_changed`: A recording started or stopped, or the power or heat changed.

#### ChangeFilter drops changes that cannot alter a pass; others request one
`start_watcher`: Changes in the chosen folders. One that can't alter what a pass finds
(`ChangeFilter`) goes no further; any other asks for a pass.

#### Access events are ignored because reading changes nothing
`start_watcher`: Reading a file changes nothing.

#### Folder facts learned in a burst of changes are trusted for 2 s
`ANSWERS_LAST`: How long what a burst of changes learned about folders is trusted.

#### Unknown folder-ness is resolved from the path unless it is gone
`change_facts`: What a watcher event says about a path. Where it doesn't say whether that's a
folder, the path still can, unless it's gone.

#### When the embedder goes away, files stay pending for the next pass
`PassRun::run`: The embedder went away: files stay pending for the next pass.

#### Sync first so an unchanged library never loads the model
`PassRun::pass`: Find what is new or changed first: an unchanged library never loads
the model.

#### On battery only a few fresh files are read; first passes wait for charger
`PassRun::pass`: On battery only what this sync just found, if it is a few files; a
folder's first pass waits for a charger.

#### The model downloads once, as the consent notice said
`PassRun::pass`: The model downloads once, as the notice said.

#### Time-left estimate appears only after 10 files for a usable pace
`PassRun::pass`: At the pace so far, once there is enough of it to go by.

#### Reconciles index with folders, reports waiting files and fresh ones if few
`sync`: Brings the index in line with the folders and says how many files wait to be
read, and which ones it just found, if they are a few (`FileSearchService.sync`).

#### Removed folders leave the index; missing or refused folders keep files
`sync`: Folders taken off the list leave the index; a folder that is missing (an
unplugged drive) or refused keeps its files.

#### Screenshot keyword text uses already-installed OCR and never downloads it
`ScreenshotWords`: The words in screenshots, for keyword search, with the OCR the person already
has; Files never downloads it. It reads what screen text recognition reads.

#### Safety: setpriority takes no pointers and who 0 is this thread
`lower_this_threads_priority`: SAFETY: a plain system call with no pointers; `who` 0 is this thread.

#### Safety: both calls act on the current thread pseudo-handle
`lower_this_threads_priority`: SAFETY: both calls act on the current thread's pseudo-handle.

#### Estimate uses metadata and headers only, measured or fixed costs, excludes chosen folders
`estimate`: What adding `folders` would read, before anything is read: files by kind, how
long the first pass takes and how much room the index will take. Goes by
metadata and headers alone; its costs are what indexing has measured here, or
else the fixed ones. Files already under a chosen folder don't count.

#### Suggested folders are not opened until the person picks one
`suggested_folders`: Documents, Desktop and Downloads, for one-click choices before any folder is
chosen: the ones that exist and aren't chosen already. Nothing in them is
opened until the person picks one.

#### Video frames need ffmpeg
`reads_video_frames`: Whether video frames can be read here: they need ffmpeg.

#### Windows reports only that something changed, so ask the path
`a_watcher_event_says_what_it_can_and_the_path_says_the_rest`: Windows says only that something changed: ask the path.

### `LinuxWindows/crates/lokalbot-engine/src/files/moments.rs`

#### Moment transcription: never downloads, waits for recordings, text kept in memory, remote approval checked
What was said at a recording's or video's matched moment, for the Ask
assistant (`FileMomentTranscriber`): Files finds the 30-second window by
meaning, and this transcribes just that window with the person's own
transcription model, so the answer can quote it.

It never downloads a transcription model, waits while a meeting records so it
can't compete with live transcription, and keeps the text only in memory: the
tool's observation isn't saved with the conversation. A remote transcription
server receives the clip only if its origin is approved, which `SpeechCache`
checks each time.

#### Model ignores audio past 30 s of one input
`WINDOW_SECONDS`: The model ignores sound past 30 s of one input, so a match covers this.

#### Returns None for non-moments, unavailable transcription or unreadable clips
`MomentTranscriber::passage`: The words at `hit`'s moment, or `None` when it isn't a moment,
transcription isn't available, or the clip can't be read.

#### Never downloads a model; it must already be installed
`MomentTranscriber::passage`: Never downloads: the model must already be on this computer.

### `LinuxWindows/crates/lokalbot-engine/src/files/pacing.rs`

#### Big reads get about a third of time while the person is present
How hard a big read works the computer (`IndexPacing`): a folder's first pass
in Files, or the picture vectors of saved screens. While the person is at the
computer, reading gets about a third of the time: after each batch it rests
twice as long as the batch took. After two minutes without input it goes at
full speed, and the next input slows it again after the current batch.

#### Two seconds of rest per second of work while present
`REST_PER_SECOND_OF_WORK`: Seconds of rest for each second of work while the person is at the computer.

#### 120 s without input counts as stepped away
`AWAY_AFTER`: No input for this long: they stepped away.

#### A rest never exceeds 20 s
`LONGEST_REST`: A long batch never holds reading up for longer than this.

#### Unknown idle time counts as the person being present
`rest_after`: How long to rest after `worked` seconds of reading, given the seconds since
the last input. When nothing can tell (a desktop that doesn't say, or a
headless session), the person counts as being there.

#### Rests in short sleeps so a stop never waits on a rest
`Pacer`: Rests between a pass's jobs, in short sleeps, so a stop never waits on a rest
(`FileIndexPacer`).

#### Idle time needs no permission and reveals no key or position
`Pacer::live`: The person's keyboard and mouse pace it. Reading the idle time needs no
permission and says nothing about which key or where.

### `LinuxWindows/crates/lokalbot-engine/src/files/pass.rs`

#### Pending order, long documents finish last, unreachable server stops the pass
Extracts and embeds whatever is pending (`Indexer`): pending files first,
screenshots first and newest first; long PDFs and documents get their first
step, and the rest after everything else. Per-file problems are recorded on the
file; a server that can't answer stops the pass, and files stay pending.

#### Model calls run one at a time and wait
`Embed`: The model calls a pass makes. One at a time, and they wait.

#### Without the OCR model a screenshot has only picture vector and name
`ReadText`: Screenshots' words, for keyword search. Without the model there are no words:
a screenshot then has its picture vector and its name.

#### Embedder going away stops the pass and leaves files pending
`WorkerGone`: What a pass was stopped by: the embedder went away. Files stay pending.

#### Audio decodes a window at a time so long recordings never sit whole in memory
`Payload::Audio`: Decoded while the model embeds, a window at a time: long recordings never
sit in memory whole.

#### Later step of a long file: pages or chunks to read, counted from 0
`Job.step`: A long file's later step (`Job.step`): the pages or chunks to read, from 0.

#### Images and screenshots go to the model 8 at a time
`batches`: Images and screenshots go to the model 8 at a time; other files one by one.

#### Scan words come from OCR for keyword search only; meaning stays picture vector
`read_scan`: A scan, or a page that's mostly a picture: its words come from OCR, for keyword
search only (an invoice number on a scan, as on a screenshot), and its meaning stays
the picture's vector. Not for a text layer that came out in glyph order, which OCR
can't read either.

#### Decoded PDF kept across steps because the parser reads whole files
`PdfCache`: A pass's source of decoded long documents, kept while their steps go by: the
PDF parser reads a whole file at a time.

#### A model or settings change empties the index since vectors are incomparable
`Pass::check_model`: Compares the index with the current model and settings; a change empties
it, since vectors from different settings can't be compared.

#### Each long-file step is one transaction so stopping loses nothing
`Pass::finish_long_files`: The later pass: the rest of long PDFs and documents, a step at a time.
Each step is saved as one transaction, so stopping loses nothing.

#### A long file that cannot be read further keeps what was read
`Pass::stop_reading`: A long file that can't be read any further keeps what was read of it.

#### An unreachable server stops the pass
`Pass::commit`: Writes one job's results. Returns the slots read; a server that can't
answer stops the pass.

#### Screen words serve keyword search; meaning comes from the picture alone
`Pass::images`: The words on screen are for keyword search: codes, names and
errors typed exactly. Meaning comes from the picture alone.

#### Long PDFs stay partial with read_to and read_end until the last step
`Pass::pdf`: Pages `read` of a PDF. A long one stays `partial` with `read_to` and
`read_end` in its info until its last step.

#### Garbled page words are never shown or matched, meaning only
`Pass::pdf`: Meaning only: the garbled words are never shown or matched.

#### A rejected picture fails alone; the page words still count
`Pass::pdf`: The picture fails alone; any words still count.

#### Mostly-digit text gets keyword search only, no vector
`Pass::doc`: Text that's mostly digits gets keyword search only.

#### Each kept frame covers the span until the next kept frame
`Pass::video`: Each kept frame stands for the stretch until the next kept frame.

#### A video with unreadable sound may still have its frames
`Pass::video`: A video with no sound we can read may still have its frames.

#### Test embedder uses the index's 768 dimensions
`StubEmbedder`: A model with one dimension per keyword, in the index's 768.

#### Stopping before further reading loses nothing
`long_documents_are_read_in_steps_and_can_stop`: Stopped before anything else is read: nothing is lost.

#### Test runs only where ffmpeg is installed
`video_becomes_frames_and_sound`: Runs only where ffmpeg is installed, which is what frames need.

### `LinuxWindows/crates/lokalbot-engine/src/files/pdf.rs`

#### No PDF renderer here; scans read from largest embedded JPEG or raster, others unread
PDFs read for their words, page by page. The Mac (PDFKit) and DigUp's other
builds (PDFium) draw pages with little text and embed the picture. No PDF renderer
ships here, so a page with little text is read from the largest picture stored in
it, when that's a JPEG or a plain raster. Other scans (JBIG2, CCITT, JPEG 2000)
and pages drawn from vectors stay unread, and Settings says so.

#### PDFs over 1 GiB are not loaded whole
`MAX_BYTES`: Larger files aren't loaded whole.

#### Scanned pages read at 1400 px to match the Mac
`SCAN_PIXELS`: A scanned page is read at this size, like the Mac's rendered page (`renderPixels`).

#### Stored pictures over 200 million pixels are not decoded
`MAX_SCAN_PIXELS`: A stored picture with more pixels than this isn't decoded.

#### Page numbers start at 1
`Page.number`: From 1.

#### Glyph-order text is too garbled to match but fine for a meaning vector
`Page.garbled`: Text read in glyph order: too garbled to show or match words against, but
enough of its words survive for a meaning vector.

#### None for an encrypted file
`Document.parsed`: For reading pictures. `None` for an encrypted file.

#### Parser panics on malformed files fail that file only
`pdf::read`: Every page's text. A malformed file can make the parser panic: that fails
this file only.

#### Decoder panics on malformed pictures lose that picture only
`scan_of`: The largest picture stored in page `number` (from 1), at least `min_side` pixels
each way. A malformed one can make a decoder panic: that loses this picture only.

#### JBIG2, CCITT and JPEG 2000 have no decoder here
`scan_of`: JBIG2, CCITT and JPEG 2000 have no decoder here.

#### Supports 8-bit colour or gray and 1-bit gray as office scanners write
`raster`: Plain samples: 8-bit colour or gray, or 1-bit gray as office scanners write it.

#### Decode [1 0] swaps which bit is white
`raster`: `/Decode [1 0]` swaps which bit is white.

#### Owner-password-only PDFs open with an empty password
`opens_without_password`: An owner password alone still lets anyone read: an empty password opens it.

#### Unknown page count defaults to one, as Estimator.pages guesses
`page_count`: How many pages a PDF has, from its page tree alone. One when it can't say,
as `Estimator.pages` guesses.

#### Low-text pages also bring their picture if at least min_side pixels
`pages_in`: Pages `range` (from 0) of `document`. A page with fewer than `min_text` characters
also brings its picture, when it has one of at least `min_side` pixels.

#### Dependent vowel signs follow a consonant or nukta in real words
`glyph_order_problem`: Dependent vowel signs of Bengali and Devanagari: in a real word, each follows
a consonant or its nukta (`PageTextProblem.glyphOrder`).

#### Test fixture is 300x400, Flate compressed
`ScanPicture::Flate`: Colour space, bits per component, samples; 300 × 400, Flate compressed.

#### 1-bit set bit is white; 304 wide gives whole bytes per row
`plain_rasters_are_read_in_colour_gray_and_one_bit`: 1-bit: a set bit is white. 304 wide so each row is 38 whole bytes.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
