# 0090. Windows and Linux: core — files

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-core/src/files/`.

## Decisions

### `LinuxWindows/crates/lokalbot-core/src/files/access.rs`

#### Files grant is a marker plus folder list so CLI and MCP search with app closed
The Files grant for external agents (`FilesAccessGate`, `FilesAccessManager`):
a marker the app sets from Settings → AI agents or Settings → Files,
plus a list of the chosen folders, so the CLI and its MCP server can search
the index with the app closed and without reading the app's settings. Separate
from every other grant; no Agent Mode capability satisfies it.

#### Keys sorted the way the Mac writes them
`FilesProjection`: What Files lets agents search, as the app last wrote it. Keys sort the way
the Mac writes them.

#### Revoking the grant also removes the folder list
`set_enabled`: Turns the grant on or off. Revoking removes the folder list too.

#### None when grant off, Files off, or folders unwritten
`read_projection`: The chosen folders, or `None` when the grant is off, Files is off, or the app
hasn't written them.

#### Rewrite or remove folder list; None folders means Files off
`refresh`: Files' settings changed: rewrite the folder list, or remove it
(`FilesAccessManager.refresh`). `folders` is `None` while Files is off.

#### Fixture mimics Swift JSONEncoder: sorted keys, ISO dates, unescaped slashes
`reads_and_writes_the_macs_json`: `JSONEncoder` with sorted keys, ISO 8601 dates and unescaped slashes.

#### Newer projection version isn't trusted
`reads_and_writes_the_macs_json`: A newer version isn't trusted.

### `LinuxWindows/crates/lokalbot-core/src/files/change_filter.rs`

#### Filter passes only changes the crawl would see; errs toward yes
Which changes the file watcher reports can alter what a pass finds
(`FileChangeFilter`). Every pass walks the chosen folders again, so a change the
crawl would leave out never starts one: in a place it doesn't walk, of a type it
doesn't read, or inside a code project, where it keeps only screenshots.

When in doubt it says yes: an extra pass costs seconds, a missed one leaves a new
file out of search until something else changes.

#### Lost watcher track means only a pass can tell
`ChangeFacts.lost_track`: The watcher lost track of what happened here: only a pass can tell.

#### None when watcher silent and path gone; watchers here often don't say
`ChangeFacts.is_folder`: `None` when the watcher doesn't say and the path is gone. Unlike FSEvents,
the watchers here often don't say.

#### Moved-in folder: this event is all watcher reports about contents
`ChangeFacts.arrived_whole`: It moved here whole: then this is all the watcher says about what it holds.

#### Keep each root as chosen and as file system resolves it
`ChangeFilter.roots`: Each chosen folder as chosen and as the file system resolves it.

#### Nested chosen folders answer differently since one's project is other's whole
`ChangeFilter::matters`: Whether this change can alter what a pass finds. Nested chosen folders answer
differently: one's project can be the other's whole.

#### Path unplaceable in any root still counts, to avoid missing changes
`ChangeFilter::matters`: A spelling of the path that can't be placed in a chosen folder is no reason
to miss a change.

#### Hidden-folder changes dominate; reject without file system queries
`ChangeFilter::matters_under`: Most of what a busy computer reports is in hidden folders: no need to ask
the file system.

#### Unknown type and gone path: only a pass can tell
`ChangeFilter::matters_under`: The watcher doesn't say what it is, and it's gone: only a pass can tell.

#### Project marker appearing or vanishing matters; edits don't
`ChangeFilter::matters_under`: A project's only marker appearing or going decides what the crawl keeps
around it, unless a project above it already does. Editing one changes
nothing.

#### Folder contents report themselves unless folder moved in
`ChangeFilter::matters_under`: A folder's contents report themselves, unless it moved here.

#### Code projects keep only screenshots; gone files judged by name safely
`ChangeFilter::matters_under`: Only screenshots count in a code project. A file that's gone goes by its
name; if that's wrong, search still hides a missing file and the next pass
drops it.

#### Cache file system answers during bursts, reset every couple of seconds
`Answers`: Answers kept while changes arrive in a burst: a build reports thousands at a time,
so what's learned about a folder or a type is asked of the file system once. Start
afresh every couple of seconds, because folders and markers do change.

#### Marker added or removed changes what crawl keeps
`a_folders_only_marker_decides_what_is_kept_around_it`: Removed or added: the crawl now keeps something else.

#### Editing the marker or a sibling marker changes nothing
`a_folders_only_marker_decides_what_is_kept_around_it`: Editing it, or another beside it, changes nothing.

#### Hidden folders are never walked even for unknown changes
`when_only_a_pass_can_tell_it_counts`: Even so, nothing in a hidden folder is walked.

### `LinuxWindows/crates/lokalbot-core/src/files/costs.rs`

#### Cost numbers measured on M4 Pro; other machines start from them and self-calibrate
What reading files costs and how much room the index takes: `Costs`,
`MeasuredCosts`, `Estimator`, `FileFolderEstimate` and `FileIndexSize`.
Measured on an M4 Pro; other machines start from the same numbers (DigUp's
Linux and Windows builds have no speed check either) and go by what indexing
measures on them.

#### Costs are seconds of indexing per unit
`Costs`: Seconds of indexing per unit.

#### Units needed per kind before measured cost is trusted
`enough`: Units a kind needs before its measured cost is trusted.

#### costs.json beside index; Mac's speed block preserved as written
`MeasuredCosts`: `costs.json` beside the index. The Mac's `speed` block is kept as written.

#### Recent work counts most: past 10x threshold, older tallies halved
`MeasuredCosts::add`: A job that took `seconds` for `units` of `name`. Recent work counts most:
past ten times what's enough, what came before is halved.

#### Use measured costs when enough, else fixed costs scaled by pace
`MeasuredCosts::costs`: The costs to estimate with: measured ones where there are enough, else the
fixed ones at the pace indexing has kept on the kinds it has measured.

#### Pace is measured over expected, second-weighted; None before enough data
`MeasuredCosts::pace`: Measured cost over the expected one, over the kinds with enough measured,
weighted by their seconds. `None` before any kind has enough.

#### Unmeasured means estimates use fixed costs
`MeasuredCosts::is_unmeasured`: Nothing has been measured here yet: estimates are the fixed costs.

#### Index bytes per item measured 31 Oct 2026; files never copied
`index_size`: Bytes the index takes per item, measured on 31 October 2026 by indexing
samples of each kind (`FileIndexSize`). Files themselves are never copied.

#### Size assumes about 1,500 characters of read words
`index_size::SCREENSHOT`: With about 1,500 characters of words read from it.

#### Size assumes a page of about 2,400 characters
`index_size::PDF_PAGE`: A page of about 2,400 characters.

#### Size is per 2,000 bytes of a document
`index_size::DOC_CHUNK`: For each 2,000 bytes of a document.

#### Window is 30 seconds of sound every 25 seconds
`index_size::SOUND_WINDOW`: 30 seconds of sound, one window every 25 seconds.

#### One frame per shot, at most every 3 s and 1,200 per video
`index_size::VIDEO_FRAME`: A frame per shot, at most one every 3 s and 1,200 a video.

#### Page counts and durations only the engine can read
`Measures`: Page counts and durations, which only the engine can read.

#### Mirrors Swift FileFolderEstimate
`FolderEstimate`: What adding folders would read (`FileFolderEstimate`).

#### First pass at full speed on this computer
`FolderEstimate.seconds`: The first pass at full speed on this computer.

#### Rest of long files is read after everything's first part
`FolderEstimate.later_seconds`: The rest of long PDFs and documents, read after everything's first part.

#### Model still to download before first pass; 0 once present
`FolderEstimate.download_bytes`: The model still to download before the first pass (0 once it's here).

#### Computed per kind so each kind's size can be told
`FolderEstimate::of`: Kind by kind, so each kind's size can be told.

#### Durations rounded to precision an estimate deserves, like 25 min
`estimate_duration`: "25 min", "2 hr, 10 min": the precision an estimate deserves
(`FileFolderAddSheet.duration`).

#### First pass reads 30 of 100 pages and 40 of 100 chunks
`estimates_read_long_files_in_two_parts`: 30 of 100 pages and 40 of 100 chunks in the first pass.

#### Unmeasured kinds use the same measured pace
`measured_costs_take_over_with_enough_of_them`: Unmeasured kinds go at the same pace.

#### Past ten times the threshold, earlier tallies are halved
`measured_costs_take_over_with_enough_of_them`: Past ten times what's enough, what came before is halved.

### `LinuxWindows/crates/lokalbot-core/src/files/crawler.rs`

#### Crawler reads metadata only, never contents except rules' sniff
Walks the chosen folders and applies the rules (`Crawler`). Reads metadata
only, never file contents (except the sniff in `rules`).

#### Facts about a file itself, not following links
`FileInfo`: A file's own facts, not following a link (`FileSystem.info`).

#### Cloud placeholders are never read to avoid downloads
`FileInfo.dataless`: A cloud placeholder whose contents would be downloaded on read: never read.

#### CLOUD mask covers OneDrive placeholder attributes
`file_info`: RECALL_ON_DATA_ACCESS, RECALL_ON_OPEN, OFFLINE: OneDrive's placeholders.

#### Volume file id stands in for inode so moved files keep vectors
`windows_file_id`: The file's id on its volume stands in for the inode: it's what lets a moved
file keep its vectors.

#### Unsafe block soundness: NUL-terminated path, checked and closed handle
`windows_file_id`: SAFETY: `wide` is a NUL-terminated path that outlives the call; the handle
is checked and closed, and `info` is a plain struct filled by the call.

#### Unplugged drive or refused folder reads as not readable
`is_readable_folder`: The folder exists and opens for listing (`isReadableFolder`): an unplugged
drive or a refused folder says no.

#### Progress callback throttled to four times a second
`crawl`: Walks `roots`, calling `progress` with the entries checked so far, at most
four times a second.

#### Chosen folder read whole; code-project rule applies to nested projects
`crawl`: A folder chosen on purpose is read whole, whatever markers it holds;
the code-project rule applies to project folders found inside it.

#### Inside a code project only screenshots count
`crawl`: Inside a code project only screenshots count.

### `LinuxWindows/crates/lokalbot-core/src/files/index.rs`

#### Index is Mac DigUpKit schema 5 with vectors in same file for crash consistency
The on-disk index (`IndexStore`): one SQLite file with files, their segments
(with float16 vectors) and an FTS5 table, in schema 5, the layout the Mac's
DigUpKit writes. Vectors live with everything else, so a crash can never
leave them out of step with the rows that describe them.

#### Tokenizer treats marks as letters so Bengali and Arabic words stay whole
`FTS_COLUMNS`: Keyword search's tokenizer. Marks count as letters, so Bengali vowel signs
and Arabic harakat stay inside their words.

#### Queued ids let a watcher index exactly those first
`SyncSummary.queued`: Files this sync queued, so a watcher can index exactly those first.

#### Newer-version index refused; older schema rebuilt since all is derived
`FileIndex::open`: Opens the index in `directory`, creating it when there is none. An index
a newer version made is refused; an older schema is rebuilt from the
folders, since nothing in it isn't derived from them.

#### Agent access never creates, migrates or writes
`FileIndex::open_read_only`: For agents: never creates, migrates or writes anything.

#### Ranges of UNIQUE path index per folder spelling, including real path
`FileIndex::path_ranges`: The ranges of the UNIQUE path index that hold the files under `folder`,
for the folder as given and for its real path when that's spelled
differently.

#### Skip roots nested in another listed root
`FileIndex::files_under`: A folder inside another one listed is already covered.

#### Same inode, size, date at new path is a move; no re-embedding
`FileIndex::move_to`: Same inode, size and date at a new path: a move. Only the path changes;
nothing is embedded again.

#### Text goes to normalized keyword search, vector to meaning search
`FileIndex::add_segment`: Adds a segment; `text` goes into keyword search (normalized), `vector`
into meaning search.

#### Sync queues new, requeues changed, re-paths moved, removes gone or excluded
`FileIndex::sync`: Reconciles the index with what the walk found: new files are queued,
changed ones queued again, moved ones re-pathed, and files that are gone
or newly excluded removed (`Indexer.sync`).

#### Root vanished mid-walk keeps its rows instead of deleting them
`FileIndex::sync`: A root that went away while it was being walked looked emptier
than it is: keep its rows rather than take that for "deleted".

#### Home-relative folder names added as low-weight keywords
`folder_text`: The folders a file sits in, relative to the home folder, as low-weight
keywords ("Downloads Invoices").

#### Schema must contain every column the Mac reads
`creates_the_macs_schema`: Every column the Mac reads.

#### Nonexistent root keeps its rows
`syncing_queues_requeues_moves_and_removes`: A root that doesn't exist keeps its rows.

### `LinuxWindows/crates/lokalbot-core/src/files/mod.rs`

#### Files module is the shared, DigUp-derived core for app, engine, CLI
Files: the folders a person chooses, searched by what is in them
(`Services/FileSearch`, DigUp's engine: github.com/ARahim3/DigUp, MIT).

This module holds what the app, engine and CLI share and what the Mac's
index needs to stay readable: the rules for what gets read, the walk, the
`files-index.noindex/index.sqlite` store (schema 5), keyword and meaning
search, and the agents' grant. Reading files and running the model are the
engine's (`lokalbot_engine::files`).

#### Index folder name must match the Mac's FileSearchService.indexFolderName
`INDEX_FOLDER`: The index's folder in the library (`FileSearchService.indexFolderName`).

#### Stored vectors are 768 float16 values
`DIMENSION`: Vectors are 768 × float16.

#### Code kind exists only in DigUp's code index, unused by LokalBot
`FileKind::Code`: Only in DigUp's code index, which LokalBot doesn't use.

#### First indexing pass handles most-sought kinds first
`INDEXING_ORDER_SQL`: The order of the first pass: what people look for most comes first.

#### Name segments hold file and folder names, keyword search only
`SegmentKind::Name`: File name and folder names (keyword search only).

#### Scores are centred per modality because text scores higher than images or sound
`Modality`: What made a segment's vector. Scores are centred per modality because text
scores higher than images or sound for the same topic.

#### Extension list for turning off recordings and video; mirrors Mac mediaExtensions
`MEDIA_EXTENSIONS`: Recordings and video, by extension, for when the person turns them off
(`FileSearchService.mediaExtensions`).

#### Vector-changing settings are in fingerprint; an index never mixes settings
`IndexOptions`: Indexing settings. Anything that changes vectors is part of `fingerprint`;
an index never mixes settings (`IndexOptions`).

#### PDFs up to this many pages are read whole at once
`IndexOptions.big_pdf_pages`: PDFs up to this many pages are read whole at once.

#### Long PDFs are read this many pages per step
`IndexOptions.pdf_step`: Pages of a long PDF read per step.

#### Long documents are read in steps of about 64,000 characters
`IndexOptions.doc_step`: Chunks of a long document read per step (about 64,000 characters).

#### Pages with fewer characters are embedded as pictures on the Mac
`IndexOptions.min_page_text`: Fewer characters than this: a page is embedded as a picture on the Mac.

#### Model silently ignores sound past 30 s of one input
`IndexOptions.audio_window`: The model silently ignores sound past 30 s of one input.

#### Turning media off excludes by extension; next sync drops indexed media
`IndexOptions::for_settings`: Turning recordings and video off excludes them by extension; the next
sync then drops those already indexed.

#### EmbeddingGemma 2 task prompts; media inputs take no prompt
`document_prompt`: EmbeddingGemma 2's task prompts. Media inputs take no prompt.

#### FileHit is what Ask, Quick Recall and the agent show; mirrors FileSearchHit
`FileHit`: A file that matched a search: what Ask, Quick Recall and the agent show
(`FileSearchHit`).

#### Id is the passage id in the index; [file:\<id>] cites it
`FileHit.id`: The matching passage's id in the index; `[file:<id>]` cites it.

#### PDF page numbers start at 1
`FileHit.page`: A PDF page, from 1.

#### Seconds offset into a recording or video
`FileHit.seconds`: Seconds into a recording or video.

#### Excerpt marks matched words in «» or shows the passage start
`FileHit.excerpt`: The matched words in «», or the passage's start.

#### Photo taken date comes from EXIF when present
`FileHit.taken`: When a photo was taken (EXIF), if it says.

#### Semantic hits matched by meaning without the query's words
`FileHit.is_semantic`: Found by what it means or shows, without the query's words.

#### Ask's time scope filters on taken date, else modified date
`FileHit::date`: The date Ask's time scope filters on.

#### Kind label is English for the model; interface builds its own
`FileHit::kind_label`: "PDF · page 3", "Recording · 00:01:15", in English for the model; the
interface builds its own from the same facts.

#### Mirrors FolderSelection.isInside; strictly inside, not equal
`is_inside`: Whether `path` is inside `folder` (`FolderSelection.isInside`).

#### Walk reports links resolved; Windows verbatim prefix dropped; mirrors FolderSelection.realPath
`real_path`: The path as a walk of the folder reports it, links resolved
(`FolderSelection.realPath`). Windows' `\\?\` prefix is left off.

#### Strip Windows verbatim prefix from paths
`plain_path`: `path` as text, without Windows' `\\?\` verbatim prefix.

#### EXIF DateTimeOriginal is in the camera's local time
`exif_date`: EXIF `DateTimeOriginal`: "2026:05:14 18:02:11", in the camera's local time.

#### Matches Swift Float16: nearest half, ties to even
`half_from_f32`: `Float16(value)`: the nearest half, ties to even.

#### Index stores vectors as little-endian float16
`vector_blob`: A vector as the index stores it: little-endian float16s.

#### Test guards ties-to-even rounding at 1 + 2^-11
`halves_round_like_float16 test`: Ties to even: 1 + 2^-11 lies halfway between 1 and the next half.

### `LinuxWindows/crates/lokalbot-core/src/files/rules.rs`

#### Only metadata and name decide indexing, except 600-byte MPEG-TS sniff
What gets indexed (`Rules`, with `Platform/Portable`'s extension sets, which
stand in for macOS's type system). Only metadata and the file's name decide,
except the 600-byte sniff that tells a real MPEG-TS video from TypeScript.

#### Walk itself skips hidden folders and bundles
`SKIPPED_FOLDER_NAMES`: Folders never worth walking into. Hidden folders and bundles are skipped by
the walk itself.

#### A marker makes a folder a code project: only screenshots indexed
`PROJECT_MARKERS`: Any of these in a folder makes it a code project, where only screenshots are
indexed.

#### Code and data files off by default; editors and ripgrep search them better
`CODE_EXTENSIONS`: Source code and data files: off, as on the Mac (`includeCode`): an editor and
ripgrep search them better, and they flood an index.

#### Mac bundles on shared disks are skipped whole by name
`PACKAGE_EXTENSIONS`: Mac bundles that may sit on a shared or copied disk: skipped whole by name,
since nothing here knows them as one thing.

#### RAW pictures stay images and fail with a note rather than vanish
`classify`: `classify` by extension. RAW pictures, which nothing here decodes yet, are
still images: they fail with a note that says so, rather than vanish.

#### MPEG-TS sync byte 0x47 every 188 or 192 bytes
`is_mpeg_transport_stream`: MPEG-TS packets start with 0x47 every 188 bytes (or every 192 with a 4-byte
timecode, as in .m2ts).

#### Pictures in a Screenshots folder count as screenshots by name
`is_screenshot`: By name: GNOME, KDE and Windows save into a "Screenshots" folder, and a
picture there is a screenshot whatever it's called.

#### Cache Directory Tagging spec requires this exact signature header
`is_cache_directory`: The Cache Directory Tagging specification requires this exact header.

#### A chosen folder is read whole whatever holds it
`is_walked`: Whether the crawl walks this far, from a chosen folder that is itself read whole
whatever holds it.

#### Chosen folder itself never counts as a project
`is_inside_project`: Whether a code project sits between the chosen folder and this path. The chosen
folder itself doesn't count: it's read whole.

#### Only-marker coming or going decides whether folder is a project
`decides_project`: A marker that is its folder's only one: its coming or going decides whether the
folder is a project.

#### Changes inside bundles or of unread types are ignored
`change_may_matter`: Whether a change here could be something the crawl keeps: not inside a bundle,
and for a file, a type it reads.

#### Machine-made names flagged; camera and dated names excluded
`looks_machine_named`: Machine-made names like "clip_000123" or "3f9a1c0e-…", but not camera names
like "IMG_1234" or the dates phones write.

#### Folders of hundreds of machine-named media are datasets, unless user-picked
`dataset_folders`: Folders with hundreds of same-kind, machine-named media files: training data,
not the person's own. Folders they picked themselves are never datasets.

### `LinuxWindows/crates/lokalbot-core/src/files/search.rs`

#### Hybrid search: z-scored meaning gates results, words rescue exact codes
Hybrid search over the file index (`Searcher`): meaning (EmbeddingGemma's
vectors) and words (FTS5).

Meaning is the model's cosine similarity put on one scale per query, and only
segments that stand out count, which also gives an honest "nothing found".
Words rescue what a vector can't hold exactly: codes, IDs and names.

#### Float16 table expanded to float32 so scoring is a plain product
`HALVES`: Every float16 as float32, so scoring stays a plain product.

#### Vectors stored row-major, 768 float16 per row, as on disk
`Vectors.halves`: Rows × 768 float16s, row-major, as stored.

#### Later pages of long files are scored but don't set the scale
`Vectors.row_sets_scale`: False for the later pages of long files: scored, but they don't set the
scale.

#### Vectors load lazily on first meaning search, about 1.5 KB each
`Searcher`: Search over one index. With `load_vectors` off only keyword search is ready;
vectors load on the first meaning search, about 1.5 KB each.

#### Kinds narrow results not scale; words searched in best thousand passages
`Searcher::search`: The hits for `text`, best first. Kinds narrow the result, not the scale.
Words are looked for in the best thousand passages, which is more than
a page of results needs.

#### Reads every matching passage so fewer than limit hits means no more files
`Searcher::search_through`: [`Self::search`] for a caller that drops hits afterwards and asks
again for more: every matching passage is read until `limit` files
are found, so fewer hits than `limit` means no other file matches.

#### Unindexed typed words match as prefixes; indexed and two-letter words stay whole
`Searcher::search_passages`: A word in no file as typed matches as the start of longer words. One
that is in the index stays whole, and so does a word of two letters.

#### Word matches capped at max(limit,100) files so deeper callers get more
`Searcher::search_passages`: A caller looking further down the ranking gets more files.

#### Snippets quote the original text, not the normalized form
`Searcher::search_passages`: Text normalizing changed is quoted as it's written.

#### Qualify by meaning z or half the query words; score formula
`Searcher::search_passages`: A file qualifies by standing out in meaning, or by holding at least
half of the query's words. Score: meaning z + a bonus that grows with
word coverage, + 1 for the kind the query asks for.

#### Point at meaning segment if it stands out, else keyword segment
`Searcher::search_passages`: Point at the best meaning segment if it stands out; else at the
segment the words matched.

#### Quote words only from pointed segment so PDF page hits stay accurate
`Searcher::search_passages`: Quote the matched words only when they come from the segment we
point at, so a PDF hit on page 5 never shows page 2's words. A
segment with no place and no text of its own (a screenshot's image
vector) can borrow them from its file's text, unless they matched
only the name.

#### Cited passage returns None once its file left the index
`Searcher::hit`: A passage cited by an earlier answer, by its id; `None` once its file left
the index.

#### All stored vectors are L2-normalized so dot product is cosine
`score`: Cosine similarity with every stored vector (all are L2-normalized).

#### Scale set by sets_scale rows so long books don't shift it
`meaning`: Each vector's cosine minus the average of its modality, in standard
deviations of all of them together. The scale comes from `sets_scale`, so a
book's hundreds of later pages don't move it (`Searcher.meaning`).

#### Fewer than 20 vectors use the average of all
`modality_means`: The average score of each modality for this query. Fewer than 20 vectors take
the average of all.

#### Kind words and stopwords describe what to look for, not content
`terms`: The content words of a query, normalized as keyword search keeps its text.
Kind words and stopwords describe what to look for, not what's in it.

#### Prefix patterns only for languages that attach endings
`patterns`: FTS5 patterns for the query's words: quoted, and as prefixes for words of
languages that attach endings.

#### Codes and IDs mean nothing to embeddings: weight words double, meaning half
`is_lookup`: Codes and IDs ("K7Q2LM") and long numbers mean nothing to an embedding but
everything to keyword search: such a query weighs words double and meaning
half.

#### Kind words are a soft boost, not a filter
`kind_hints`: Kinds the query asks for: a soft boost, not a filter.

#### Vectors stay in memory 600 s after a meaning search
`VECTOR_IDLE_SECONDS`: How long vectors stay in memory after a search by meaning.

#### Own connection so search never waits for indexing; shared by app, Ask, engine
`FileReader`: Owns the searcher: its own connection, so a search never waits for indexing
(`FileSearchReader`). Shared between the app's search, Ask and the engine.

#### Results limited to chosen folders and existing files; words-only without vector
`FileReader::search`: Files that match `query`, best first, only under `folders` and only ones
that still exist. With a query vector it searches by meaning and by words;
without one, by words only.

#### Walk reports real paths so match both folder spellings
`FileReader::search`: A walk reports a folder as its real path, so a file matches either.

#### Fetch 4x limit when date filter is on to fill the list
`FileReader::search`: Ask enough to fill the list after the date filter drops some.

#### Cited passage returns None once its file left the index
`FileReader::hit`: A passage cited by an earlier answer; `None` once its file left the index.

#### Newly indexed files are read on the next search
`FileReader::mark_stale`: New files were indexed: the next search reads them.

#### Connection must be released before the index is deleted
`FileReader::close`: Lets go of the connection, before the index is deleted.

#### Name counts triple the body in keyword order; ties by file
`words_find_passages_and_quote_them test`: The name counts three times the body in the keyword order; equal scores
then go by file.

#### Test inserts rows as the Mac's DigUpKit writes them: raw SQL, hand-made blobs
`reads_the_macs_format test`: A row the way the Mac's DigUpKit writes it: raw SQL and hand-made blobs.

### `LinuxWindows/crates/lokalbot-core/src/files/text.rs`

#### NFKC, drop invisible formatting, normalize Arabic as typed
`normalized`: NFKC, invisible formatting dropped (zero-width joiners, direction marks),
and Arabic the way people type it: no tatweel, no short vowels, one alef.

#### Scripts that attach endings are matched as prefixes
`inflects`: Words of scripts that attach endings are matched as prefixes.

#### Needs a fifth of non-space characters to be letters; data dumps get keyword search only
`has_words`: At least a fifth of what isn't space is letters. A data dump or a table of
numbers isn't, and gets keyword search only.

#### Vector needs has_words plus at least four lettered words
`has_prose`: Enough prose for a vector: `has_words`, and at least four words with a
letter in them.

#### Matches as keyword search would, returned as ranges in original text
`matches`: Where `word` is in `text` as keyword search would find it, as char ranges of
the text as written (`SearchText.matches`).

#### Marks terms with « » as SQLite snippet() does; None if absent
`snippet`: One line around the first of `terms` it has, the terms marked « » as SQLite's
`snippet()` marks them; `None` when none of them is in it.

#### Only the start is cleaned because pages can be thousands of characters
`excerpt`: One line, at most `limit` characters (`excerpt`): only the start is cleaned
up, since a page or a chunk can be thousands of characters.

#### About 1,800-character overlapping chunks cut deterministically so long files resume
`chunks`: About 1,800-character pieces (~450 tokens) that overlap a little, breaking
at whitespace (`DocExtractor.chunks`). The same text is always cut the same
way, so a later step of a long file goes on where the last one stopped.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
