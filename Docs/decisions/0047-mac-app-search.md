# 0047. Mac app: Search

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Services/Search/`, `LokalBotTests/Services/Search/`.

## Decisions

### `LokalBot/Services/Search/EmbeddingIndex.swift`

#### Shared model preparation never cancelled; later callers rejoin it
`EmbeddingModelPreparationCoordinator`: Coalesces expensive embedding-model preparation by destination. Waiters
can cancel independently; the shared operation is never canceled and runs
to completion even after its last waiter leaves, so one abandoned search
cannot break active indexing and a later caller rejoins it.

#### Keep flight alive with no waiters to avoid racing a second install
`EmbeddingModelPreparationCoordinator.cancel`: Keep the preparation flight alive even when its current waiter set
becomes empty. Download/install cancellation is not guaranteed to be
instantaneous; retaining the flight lets a later caller rejoin it
instead of racing a second install against a still-unwinding first.

#### Embedder runs parallel 1 FIFO; background held while foreground in flight
`EmbeddingRequestGate`: Orders requests to the embedder llama-server. It runs `--parallel 1` and
encodes inputs first in, first out, so a typed query waits for every input
posted before it. Background requests go one at a time and are held while
a foreground request is in flight: a query waits for at most the one
background request already on the server.

#### Brute-force cosine over SQLite vectors is enough at personal scale
`EmbeddingIndex`: M6 semantic layer (design §4.1): transcript/summary chunks embedded with
EmbeddingGemma 2 GGUF, served by the second llama-server instance.
Vectors live in SQLite; query = brute-force cosine (normalized dot) —
instant at personal-library scale, no extra dependency.

#### Background screen-text pass timings; tests shorten them
`EmbeddingIndex.ScreenBackfillSchedule`: When background passes over screen text run. Tests shorten these.

#### New captures wait so one pass embeds a batch
`EmbeddingIndex.ScreenBackfillSchedule.newTextDelay`: New captures wait this long, so one pass embeds a batch of them
instead of waking the embedder for every capture.

#### Retry delay doubles per failure up to max; success resets
`EmbeddingIndex.ScreenBackfillSchedule.firstRetryDelay`: The wait after the first failed pass. Each further failure doubles
it, up to `maximumRetryDelay`; a successful pass resets it.

#### Advance index version on pooling, prompt or chunking change
`EmbeddingIndex.indexVersion`: Persisted separately from the server-facing model name. Any change to
pooling, prompting, or chunking must advance this value so vectors made
under incompatible contracts are discarded before search resumes.

#### Delete old embedder files by exact name after current model verified
`EmbeddingIndex.obsoleteModelFiles`: Embedders this app shipped before. Their files are deleted, by exact
name, once the current model has been verified.

#### Use checkpoint's own retrieval prompts for meetings and screens
`EmbeddingIndex.documentPrefix`: The checkpoint's own retrieval prompts (`SearchQuery` and `Document`).
Meetings and screens share them; the stored text says which it is.

#### Similarity floors 0.61/0.58 calibrated against Harrier; recalibrate on model change
`EmbeddingIndex.meetingSimilarityFloor`: EmbeddingGemma 2 scores unrelated text higher than Harrier did: on a
real library, unrelated meeting chunks had a median of 0.59 and
unrelated screens 0.61. These floors pass the same share of unrelated
pairs as Harrier's 0.45 (32% of meeting chunks, 76% of screens) while
keeping 99.7% and 100% of the passages the queries were written from.
Recalibrate whenever the embedding model changes.

#### Hard chunk ceiling keeps pathological segments below 2K context
`EmbeddingIndex.transcriptChunkHardLimitCharacters`: Preserve the existing chunk shape for normal ASR output while keeping a
single pathological segment safely below the embedder's 2K context.

#### Cap background request size so typed queries wait about 100 ms
`EmbeddingIndex.backgroundRequestMaximumInputs`: Limits for one background embedding request, so a typed query waits
for at most about 100 ms (M4 Max): a 1,500-character OCR row is about
900 tokens and 50 ms, a 500-character transcript chunk about 11 ms.
Splitting costs almost nothing (each input is encoded on its own) and
does not change the vectors.

#### Next automatic pass is set by new text or a failed pass
`EmbeddingIndex.scheduledScreenReindex`: The next automatic pass, set by new screen text or a failed pass.

#### Failure count since last finished pass sets retry delay
`EmbeddingIndex.screenReindexFailures`: Failed passes since the last one that finished; sets the retry delay.

#### Embed new captures only after semantic screen search is first used
`EmbeddingIndex.screenSearchInUse`: Set once this library has searched screens by meaning. Until then new
captures are not embedded, so people who never use the feature do not
download a model or spend background inference time on it.

#### Rebuild discarded screen vectors after meetings if feature was used
`EmbeddingIndex.screenVectorsNeedRebuild`: Startup discarded screen vectors an earlier model made. This library
already used semantic screen search, so they are rebuilt after the
meetings instead of waiting for a search.

#### Cache last query vector; valid because model fixed per index version
`EmbeddingIndex.lastQueryEmbedding`: Ask and Quick Recall search meetings and then screens with the same
query, and search again when only a filter or a trailing space changes.
The model is fixed for an index version, so the last vector stays valid.

#### Starts picture vectors once screens are searched by meaning
`EmbeddingIndex.screenSearchByMeaningDidStart`: Called when screens are searched by meaning, so picture vectors
(`ScreenImageEmbeddings`) can start once they are wanted.

#### App embeds via llama-server; tests inject a recorder
`EmbeddingIndex.Embedder`: Turns texts into vectors. The app sends them to the embedder
llama-server; tests pass a recorder instead.

#### Unit tests use failing embedder to avoid model download
`EmbeddingIndex.unavailableEmbedder`: Fails like an embedder that is not ready, so search keeps its keyword
results and indexing tries again later. Unit tests' `AppState` uses it:
semantic search is on there, and the real embedder would download the
model into the test's temporary library.

#### Use two index ranges instead of != to avoid reading all vectors at launch
`EmbeddingIndex.init`: Two index ranges instead of `!=`, which reads every vector
(41 MB on a large library) at each launch on the main actor.

#### Progress counts only meetings needing work; up-to-date library reports nothing
`EmbeddingIndex.reindexAll`: Re-embeds meetings whose sources changed. `progress` receives
`(done, total)` over only the meetings that need work, starting at
`(0, total)` when any do, so an up-to-date library reports nothing.

#### Prefix marks notes chunks so hits map back to notes
`EmbeddingIndex.notesChunkMarker`: Prefix that identifies a semantic chunk taken from the user's own
meeting notes, so a hit can be mapped back to its notes passage.

#### Keep ~500-char chunks with separate hard ceiling and timestamps preserved
`EmbeddingIndex.transcriptChunks`: Matches the historical ~500-character transcript chunks for ordinary
segments. A malformed or low-quality ASR segment can contain thousands
of characters, so enforce a separate hard ceiling before it reaches the
embedding server. Split pieces preserve every source character and keep
the segment timestamp for deep-linking.

#### Split at whitespace else exact boundary; pieces reconstruct input exactly
`EmbeddingIndex.splitEmbeddingText`: Prefer a nearby whitespace boundary but fall back to an exact character
boundary for very long unbroken tokens. Substrings are not trimmed, so
concatenating the pieces reconstructs the original input byte-for-byte.

#### Returns nil when index has nothing to do for a meeting
`EmbeddingIndex.pendingIndexState`: Sources of a meeting whose vectors are missing or stale; nil when
`index(_:)` has nothing to do.

#### Scan library off main actor on read-only connection, recheck hits
`EmbeddingIndex.meetingsNeedingVectors`: The meetings `index(_:)` has work for. Looking at every meeting's
files and rows (at launch, the whole library) runs off the main actor
on its own read-only connection; only the meetings it finds are checked
again here, so one deleted or changed meanwhile is still judged by
`pendingIndexState`.

#### Without second connection every meeting is checked on main actor
`EmbeddingIndex.meetingsNeedingVectors`: Without the second connection, every meeting is checked here as before.

#### Batch check uses three library queries instead of four per meeting
`EmbeddingIndex.meetingIDsNeedingVectors`: `pendingIndexState`'s answer for many meetings at once: three queries
for the whole library instead of four per meeting.

#### Notes on only one side force re-embedding; clearing notes keeps mtime
`EmbeddingIndex.needsVectors`: Notes joined the semantic corpus after libraries were embedded, and
clearing notes deletes the file without raising the newest mtime.
Either way, notes present on only one side force a fresh embedding.

#### Recheck freshness under BEGIN IMMEDIATE after suspended embedding
`EmbeddingIndex.index`: Embedding can suspend for minutes. Recheck freshness under
BEGIN IMMEDIATE so an older request cannot replace a newer
snapshot after it finally receives vectors.

#### In-memory deletion marker closes rank/delete race without waiting on SQLite
`EmbeddingIndex.noteDeletion`: Immediately closes the async rank/delete race without waiting for a
potentially busy SQLite writer. AppState follows this in-memory marker
with durable utility-worker cleanup.

#### Clear vectors without tombstone, which would hide meeting from keyword search
`EmbeddingIndex.clearVectors`: Drops a live meeting's vectors so the next pass re-embeds its changed
sources. Unlike `remove`, it writes no deletion tombstone: tombstones
are shared with keyword search and would hide the meeting from both.

#### Deletion uses own FULLMUTEX connection so busy timeout never stalls main actor
`EmbeddingIndex.remove`: Utility-worker entry point used by AppState deletion. It deliberately
opens its own FULLMUTEX connection so SQLite's busy timeout can never
stall the main actor.

#### Tombstone stays source of truth while interrupted cleanup is retried
`EmbeddingIndex.reconcileDeletedMeetings`: Completes cleanup for tombstones whose original deletion was
interrupted. The tombstone remains the source of truth and query paths
exclude it while these reconstructible rows are being removed.

#### After launch indexing rebuild discarded screen vectors or schedule pending pass
`EmbeddingIndex.resumeScreenBackfill`: Called once the meetings are indexed at launch. Rebuilds screen vectors
a model change discarded; otherwise schedules a pass for captures made
before launch or left behind by passes that failed.

#### New screen text gets batched background embedding, not wait for search
`EmbeddingIndex.screenTextDidArrive`: New screen text was stored. Libraries that search screens by meaning
get it embedded by a batched background pass instead of waiting for
the next search; a pass already scheduled covers it too.

#### Stopping backfill cancels passes but keeps embedded rows
`EmbeddingIndex.stopScreenBackfill`: Cancels the scheduled and running passes, for example when semantic
search is turned off. Rows already embedded stay.

#### Failed backfill retries with exponential backoff so screens never stay unindexed
`EmbeddingIndex.reindexScreenText`: Backfills immutable OCR rows that do not yet have a vector. Semantic
screen search starts a pass, new captures schedule one
(`screenTextDidArrive`), and a failed pass schedules a retry with
exponential backoff, so a temporary embedder failure never leaves new
screens out of semantic search until someone happens to search again.

#### A running pass covers all pending rows and replaces scheduled one
`EmbeddingIndex.reindexScreenText`: This pass covers every pending row, so it replaces a scheduled one.

#### Recheck live OCR text in write transaction so backfill cannot resurrect expired text
`EmbeddingIndex.performScreenTextReindex`: Retention or explicit deletion may remove OCR while
embedding is suspended. Recheck the exact live text
under the write transaction so an in-flight backfill
cannot resurrect expired plaintext in this table.

#### Only own cancellation ends pass quietly; other errors retry
`EmbeddingIndex.performScreenTextReindex`: Only this pass's own cancellation ends it quietly; anything
else, including a stray CancellationError, is retried.

#### Screen semantic search keeps filter contract and snapshot ID for citations
`EmbeddingIndex.searchScreen`: Semantic retrieval over screen OCR, with the same date/app filter
contract as lexical FTS. Results retain the snapshot ID needed for an
exact citation, thumbnail, saved moment, or timeline jump.

#### Backfill is single-flight, independent of interactive query
`EmbeddingIndex.searchScreen`: Backfill is single-flight and independent of this interactive query.

#### Drop hits deleted during ranking with one query on main actor
`EmbeddingIndex.liveScreenHits`: Drops hits whose capture or screen text was deleted while ranking ran.
One query for all hits: this runs on the main actor.

#### Match text is read only for captures a search keeps
`EmbeddingIndex.ScreenMeaningMatch`: A capture's best meaning match for a query, and what search shows for it.
Its text is read only for the captures a search keeps (`screenTexts`).

#### Score all vectors on one scale so filters never change standout
`EmbeddingIndex.screenMeanings`: Every screen vector, text and picture, scored against the query on one
scale (`ScreenSearchRanking.meaning`), then limited to `filter`. The
scale comes from all vectors, so a date or app filter never changes how
far a capture stands out.

#### Leave text unread in scan; reading it cost a quarter of scan time
`EmbeddingIndex.screenMeanings`: Text stays unread here: a search shows a few hundred captures at
most, and reading every capture's text was about a quarter of this
scan's time at 30,000 captures.

#### Text read lazily for shown captures; picture-only captures have no entry
`EmbeddingIndex.screenTexts`: The text behind each capture's text vector, for the captures a search
shows (`screenMeanings` leaves it unread). A capture with only a
picture vector, or none, has no entry.

#### Trim query like screen search so both share one vector
`EmbeddingIndex.search`: Trimmed like screen search, so both sources share one query vector.

#### Revalidate deletions synchronously after ranking yields main actor
`EmbeddingIndex.search`: Ranking yields the main actor. A meeting can be deleted after the
candidate snapshot but before ranking completes, so validate again
synchronously before publishing any hit.

#### Score rows in SQLite buffer, read text only for kept rows
`EmbeddingIndex.meetingHits`: Score every row straight from SQLite's buffer, then read text only
for the rows kept: copying all chunks' text and vectors first cost
more than the scoring itself.

#### Copy blobs to aligned buffer since SQLite gives no alignment
`EmbeddingIndex.VectorScorer`: Dot products against one query, reading each stored vector through a
reused aligned buffer (SQLite blobs carry no alignment guarantee).

#### Caller must pass byteCount bytes
`EmbeddingIndex.VectorScorer.score`: `bytes` must hold `byteCount` bytes.

#### In-memory ranking must match meetingHits floor and order
`EmbeddingIndex.rank`: In-memory ranking with the same floor and order as `meetingHits`.

#### In-memory ranking must match screenHits floor and order
`EmbeddingIndex.rankScreen`: In-memory ranking with the same floor and order as `screenHits`.

#### Symmetric checkpoint prompt for comparing statements, not ranking
`EmbeddingIndex.similarityPrefix`: The checkpoint's symmetric prompt, for comparing two statements
rather than ranking documents against a query.

#### Similarity vectors never download model; nil if absent or failed
`EmbeddingIndex.similarityVectors`: L2-normalized vectors for a one-off comparison, such as checking that
a learned item means what the person's line says. Waits behind typed
searches. Nil when the embedding model isn't on this Mac (this never
starts a download) or the request fails.

#### Files search shares query cache so a typed query embeds once
`EmbeddingIndex.queryVector`: The query's search vector, for searches outside this index (Files).
Shares the cache with meeting and screen search, so one typed query is
embedded once. Nil when the embedder is not available.

#### Failed or cancelled query embedding is not cached
`EmbeddingIndex.embedQuery`: A failed or cancelled embedding is not kept, so the next search retries.

#### Index documents in small requests, vectors in input order
`EmbeddingIndex.embedInBackground`: Embeds documents for indexing in small requests, returning one vector
per text in input order.

#### Background waits its turn; foreground goes first and holds background
`EmbeddingIndex.embedThroughGate`: Background work waits its turn; anything a person or an agent waits
for goes straight to the server and holds background work back.

#### Group texts within limits; oversized text goes alone
`EmbeddingIndex.backgroundRequestRanges`: Consecutive runs of texts within the background request limits. A text
longer than the character limit goes alone.

#### Disable prompt caching since bidirectional encoder must not reuse prefixes
`EmbeddingIndex.embeddingRequestBody`: EmbeddingGemma is a bidirectional encoder: every token attends to the
whole input, so reusing another input's cached prompt prefix would be
wrong. The bundled llama.cpp already re-encodes each input (vectors were
identical with caching on); turning it off keeps that independent of
server defaults.

#### Order response rows by index, not response order
`EmbeddingIndex.embeddingVectors`: Returns one L2-normalized vector per input, in input order. Rows are
ordered by their `index` rather than trusting the response order.

#### Media embedder for Files loads same model file with projector
`EmbeddingIndex.preparedModel`: The verified text model, downloading it first if needed. The media
embedder for Files loads the same file next to its projector.

#### Remove old embedders only after current model verified
`EmbeddingIndex.removeObsoleteModels`: Previous embedders are never loaded again, and nothing else references
their files. Delete only those exact names, and only after the current
model verified, so a failed download never leaves search without one.

### `LokalBot/Services/Search/QuickRecallHotKeyController.swift`

#### Carbon hot keys avoid event tap and read no other keyboard input
`QuickRecallHotKeyController`: Registers one of LokalBot's opt-in, system-wide shortcuts (Quick Recall, selection
actions, Hand off) without an event tap. Carbon hot keys work while another app is
focused and do not read or retain any other keyboard input.

#### Each controller has own identifier so handlers ignore others
`QuickRecallHotKeyController.askIdentifier`: Each controller registers under its own identifier, so several can be
active at once and each handler ignores the others' presses.

#### Suspend while Settings records a shortcut so recorder gets keys
`QuickRecallHotKeyController.isSuspended`: True while Settings records a new shortcut, so the current one reaches
the recorder instead of opening Quick Recall.

#### False return means system refused; Ask has no shortcut until success
`QuickRecallHotKeyController.setShortcut`: Registers `shortcut`, replacing the previous one, or unregisters for
nil. Returns false when the system refuses the combination; Ask then
has no shortcut until a later call succeeds.

#### Pass other global shortcuts not being edited to detect conflicts
`QuickRecallHotKeyController.problem`: Why `candidate` cannot be a system-wide shortcut, or nil. Pass the
other global shortcuts that are not being edited.

#### Enabled macOS shortcuts take keys before registered hot keys
`QuickRecallHotKeyController.isSystemShortcut`: Enabled macOS keyboard shortcuts, such as ⌘ Space for Spotlight, take
the keys before a hot key registered here would see them.

### `LokalBot/Services/Search/SearchIndex.swift`

#### FTS5 index in lokalbotv3.sqlite, segment rows deep-link, no dependency
`SearchIndex`: SQLite + FTS5 full-text index (design doc §4.1) over meeting titles,
transcript segments, summaries, the user's own notes, and extracted
outcomes with their saved corrections. Lives at \<storage root>/lokalbotv3.sqlite.
Segment-level rows let transcript hits deep-link to their audio timestamp.
macOS ships SQLite with FTS5 enabled, so this adds no dependency.

#### Clear freshness marks once so notes and outcomes get indexed
`SearchIndex.notesOutcomesMigration`: Notes and outcomes were added after libraries were already indexed.
Clearing the freshness marks once makes the next pass include them
even when those files are older than the recorded source mtime.

#### Any newer write to these files reindexes the meeting
`SearchIndex.sourceFileNames`: Files whose contents become documents. Any newer write reindexes.

#### Segment start time for transcript hits, 0 otherwise
`SearchIndex.Hit.start`: Segment start time for transcript hits; 0 otherwise.

#### Snippet marks matched terms with « » delimiters
`SearchIndex.Hit.snippet`: Snippet with « » around matched terms.

#### Keep whole row because snippet can drop a nearby not
`SearchIndex.Hit.sourceText`: The whole stored document row. `snippet` keeps only a few tokens
around the match and can drop a nearby "not".

#### beforeTransaction hook tests older snapshot racing newer connection
`SearchIndex.reindex`: Test seam for deterministically exercising an older snapshot that
reaches its transaction after a newer independent connection.

#### Check tombstone inside write transaction so late indexing is a no-op
`SearchIndex.reindex`: Deletion and indexing use independent SQLite connections. Check
the durable tombstone inside this write transaction so either
indexing commits first and deletion removes it, or deletion
commits first and this late worker becomes a no-op.

#### Repeat freshness check under BEGIN IMMEDIATE so older worker cannot overwrite
`SearchIndex.reindex`: The optimistic check above avoids unnecessary file reads.
Repeat it under BEGIN IMMEDIATE so an older worker cannot
commit after and overwrite a newer snapshot.

#### Clear stale tombstones left by earlier boundary reviews on live meetings
`SearchIndex.clearStaleTombstones`: Deleting a meeting removes its folder before writing its tombstone, so
a tombstone on a meeting that still loads (and is not a merged source)
is stale; earlier boundary reviews wrote such tombstones. Clearing them
lets both indexes cover the meeting again. Returns the cleared IDs.

#### Commit tombstone recovery before clearing merge marker so retry stays possible
`SearchIndex.restoreMergedSource`: Both FTS and embeddings consult this shared tombstone table. Commit
recovery before clearing the source's merge marker in meta.json so an
interrupted/failed repair always retains enough information to retry.

#### Queries exclude tombstones before reconcile succeeds; safe to retry
`SearchIndex.reconcileDeletedMeetings`: Finishes cleanup for durable tombstones left by a prior failed or
interrupted deletion. Queries exclude tombstones even before this pass
succeeds, so reconciliation can safely be retried at startup and in-app.

#### AND terms with last prefix; matchAll false and stop words rescue questions
`SearchIndex.search`: FTS5 search. By default terms are AND-ed and the last gets prefix matching
(search-as-you-type). `matchAll: false` ORs the terms for recall, and
`dropStopWords` strips function words first — both used by the chat tool to
rescue natural-language questions. `kind` nil = all kinds.

#### FTS5 cannot see words inside CJK runs, use substring search
`SearchIndex.search`: FTS5 cannot see words inside a run of CJK text; see `CJKSearch`.

#### Latin word glued to CJK text is part of that token
`SearchIndex.search`: A Latin word glued to CJK text ("比如logo再大") is part of that run's token.

#### List filter returns all matching meetings; ranked search hid older ones
`SearchIndex.matchingMeetingIDs`: Every meeting with a row matching the query. The Meetings list filter
shows all matches; ranked search fetched 2,000 rows and kept the first
40 meetings, so a common word hid older ones.

#### Substring terms follow same AND/OR and stop-word choices as ftsQuery
`SearchIndex.substringTerms`: Search terms for the substring path, honouring the same AND/OR and
stop-word choices as `ftsQuery`.

#### Shared WHERE for substring search and meeting filter
`SearchIndex.substringConditions`: The WHERE clause shared by substring search and the meeting filter:
every term (or, relaxed, any term) occurs in the text, optionally only
in rows that contain CJK text, and the meeting is not deleted.

#### Substring ranking mimics bm25 and builds snippets manually
`SearchIndex.substringSearch`: Substring counterpart of `ftsSearch`. Shorter documents come first, the
way bm25 favours them; relaxed (OR) results rank by how many pieces
matched. Snippets are built here because `snippet()` marks nothing
without MATCH.

#### Embeddings kept 300 chars and lost kind, so recover matching document
`SearchIndex.semanticPassage`: Embeddings historically retained only the first 300 characters and lost
source kind. Recover the matching document before choosing a reading excerpt.

#### Strip stop words so natural-language questions do not AND to nothing
`SearchIndex.stopWords`: Common English function words that carry no retrieval signal. Stripped
from natural-language queries (`dropStopWords`) so a question like
"what did we decide about caching" doesn't AND `what/did/we/about`
against the index and return nothing.

#### Quote terms to avoid FTS5 syntax errors; keep stop words if all
`SearchIndex.ftsQuery`: "fts5 syntax" is user-hostile; quote each term so punctuation can't
produce a syntax error. `matchAll` ANDs the terms and prefix-matches the
final one (search-as-you-type); pass `matchAll: false` to OR them for
recall. `dropStopWords` strips function words first, keeping the originals
only when every term was a stop word.

#### Index one row per outcome using user's saved corrections
`SearchIndex.outcomeTexts`: One searchable row per current decision, action, and open question.
Actions use the user's saved text, owner, and due corrections so a
corrected commitment is found by the words the user chose.

#### Deleted source files cannot raise mtime so check removal explicitly
`SearchIndex.documentSources`: Source file behind each removable document kind. Deleting a file
(clearing notes, archiving outcomes) cannot raise the newest source
modification time, so freshness alone would keep its rows searchable.

### `LokalBotTests/Services/Search/EmbeddingIndexContractTests.swift`

#### Prompts, request options, decoding and floors change together with the model
`EmbeddingIndex`: The embedding contract that has to change together with the model: prompts,
request options, response decoding, score floors, and obsolete-model cleanup.

#### Bidirectional encoder must never reuse another input's cached prompt
`EmbeddingIndex.embeddingRequestBody`: A bidirectional encoder must never reuse another input's cached prompt.

#### EmbeddingGemma 2 scores unrelated chunks ~0.59, above Harrier's 0.45 floor
`EmbeddingIndex score floor`: EmbeddingGemma 2 scores unrelated meeting chunks around 0.59, above
Harrier's 0.45 floor, so the recalibrated floor must drop them.

### `LokalBotTests/Services/Search/EmbeddingIndexIntegrationTests.swift`

#### Opt-in test uses copied library; no fixture means no downloads or reads
`EmbeddingIndexIntegrationTests`: Opt-in, non-UI proof using a copied library and already downloaded model.
No fixture path means no downloads, server launches, or library reads.

#### Reject live-library roots; the test writes vectors and storage may repair metadata
`EmbeddingIndexIntegrationTests`: Reject live-library roots even if a fixture was accidentally pointed
at one. The test writes vectors and StorageManager may repair metadata.

#### Backfill rerun reuses model version without duplicating or erasing vectors
`EmbeddingIndex.index`: Running the backfill again must reuse the same model version,
not duplicate rows or silently erase freshly rebuilt vectors.

### `LokalBotTests/Services/Search/EmbeddingIndexQueryTests.swift`

#### One query embedding at caller priority; indexing in small background requests
`EmbeddingIndex`: Ask and Quick Recall search meetings and then screens on every debounced
keystroke. The typed query is embedded once for both sources, at the
caller's priority, while indexing stays background work, sent in small
requests so the query waits behind at most one of them.

#### Database paths must rank exactly like in-memory rankers, ties and floors included
`EmbeddingIndex database ranking`: The database paths score rows in place and read text only for the rows
they keep; they must rank exactly like the in-memory rankers, ties and
floors included.

#### Typing pauses after a space; padded query is the same query
`EmbeddingIndex query embedding`: Typing pauses after a space; the padded query is the same query.

#### Callers passing no priority keep the previous background lease
`EmbeddingIndex.search`: Callers that pass no priority keep the previous background lease.

### `LokalBotTests/Services/Search/EmbeddingIndexScreenBackfillTests.swift`

#### Screens need backfill without a search; failed pass retried with backoff (2026-10-12)
`EmbeddingIndex screen backfill`: Screen text reaches semantic search without waiting for a screen search,
and a failed backfill pass is retried with backoff. On 2026-10-12 four
days of screens had no vectors: only a search started a pass, and the one
pass that ran failed once (another embedder held port 17873) and stopped.

### `LokalBotTests/Services/Search/IndexPersistenceTests.swift`

#### Old model vectors invalidated by model identity; Qwen and Harrier both 1,024 dims
`EmbeddingIndex migration`: Earlier models' vectors must be invalidated by model identity, not
by vector shape: Qwen and Harrier both produced 1,024 dimensions.

#### Transcript stays newest file so deletions cannot raise newest mtime
`SearchIndex notes outcomes`: The transcript stays the newest file, so deleting notes or outcomes
cannot raise the newest modification time.

#### Launch sweep off main actor must pick exactly the per-meeting check's meetings
`EmbeddingIndex launch sweep`: Launch looks at every meeting off the main actor in one sweep; it must
pick exactly the meetings the per-meeting check embeds.

### `LokalBotTests/Services/Search/QuickRecallShortcutTests.swift`

#### Test shortcuts are combinations nobody presses so registrations cannot fire
`QuickRecallShortcutTests`: Combinations nobody presses, so the brief registrations below cannot
fire while the tests run.

### `LokalBotTests/Services/Search/SnippetCleanerTests.swift`

#### Screen OCR recaptures window chrome so snippet's first line echoes title; drop it, keep markers
`SnippetCleaner`: Screen OCR usually re-captures the window chrome, so an FTS snippet's first
line often just repeats the row title. The cleaner drops that echo and
collapses whitespace while leaving «» match markers for the highlighter.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
