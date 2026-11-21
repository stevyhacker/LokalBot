# 0010. Ask and search

- Status: Accepted
- Date: 2026-11-20

## Context

Ask answers questions from the user's meetings, screen memory, activity, files and agent notes with citations, and search finds the same material by keyword and by meaning. The Mac app implements it in Swift, the Windows and Linux app in Rust, and the iOS companion shows the answers. These decisions were moved here from code comments when the code stopped carrying comments ([ADR 0001](0001-code-carries-no-comments.md)).

## Answering a question

### Capable models answer through a tool loop; CPU-only or small-context models retrieve first

The model answers by calling tools (search, list and read meetings, action items, screen text, app activity) one at a time through a prompt-driven JSON protocol, not native function calling, and writes its answer once it has enough. Output is parsed tolerantly, a garbled tool call gets one schema-constrained retry, after six calls a final answer is forced, and the tool-call schema makes optional fields required-but-nullable because strict Structured Outputs requires that rather than omitted fields. Small local models follow the tool protocol unreliably, so `uses_tool_loop` keeps a CPU-only model or a small context window on a single-turn answer: the app retrieves first (keyword search, meaning search when embeddings exist, title matches and the scoped meetings), hands the model numbered sources with their citation markers and streams one answer.

Where: `LinuxWindows/crates/lokalbot-ai/src/ask_agent.rs` (`uses_tool_loop`), `LinuxWindows/crates/lokalbot-ai/src/ask.rs`, `LokalBot/Services/Chat/ChatAgent.swift` (`ChatPrompt.toolCallSchema`).

### A day or meeting focus is where an answer starts, not a limit

A question asked from a day or a meeting names it as the place to start, and the prompt must not read as a limit: the tools still reach the whole library. "Ask About Today" on a tablet once held the question to that day, and the answer said the library had only one meeting.

Where: `LokalBot/Services/Chat/ChatAgent.swift` (`ChatPrompt.questionFocus`), `LinuxWindows/crates/lokalbot-ai/src/ask.rs` (`QuestionFocus`).

### Keyword hits reach the model as the whole utterance, not the FTS snippet

The model sees the whole transcript utterance or summary line around a keyword match. An FTS snippet keeps about 14 tokens and can cut a nearby "not" out of the observation. A line longer than the cap keeps the snippet.

Where: `LokalBot/Services/Chat/MeetingChatTools.swift` (`MeetingChatFormat.keywordPassage`), `LinuxWindows/crates/lokalbot-ai/src/ask_agent.rs` (`keyword_passage`).

### A search that finds nothing retries on content keywords with OR

A natural-language question ANDs every stop word against the index and misses, so the search tool retries on the content keywords with OR semantics, ranked by FTS, before reporting nothing.

Where: `LokalBot/Services/Chat/MeetingChatTools.swift` (`MeetingChatTools.search`).

### Screen search tools filter by date in SQL before LIMIT

When more hits than the tool's result limit fall on another day, a date filter applied after LIMIT loses the valid hit on the selected day, so the date filter runs in SQL first.

Where: `LokalBotTests/Services/Chat/ChatAgentTests.swift` (`testSearchScreenAndActivitySummaryAgainstPlantedStore`).

### The current time goes in each step's instruction, not the system prompt

The model needs the current time to resolve "yesterday" or "last Tuesday". Anthropic caches whole blocks up to each breakpoint, and a per-minute clock line in the system prompt made every new message miss the cached system prompt and replay history at the cache-write price. The time line opens each step's instruction, after the cached prefix, so the system prompt and history stay identical across messages minutes apart.

Where: `LokalBot/Services/Chat/ChatAgent.swift` (`ChatPrompt.currentTimeLine`), `LokalBotTests/Services/Chat/ChatAgentTests.swift` (`testSystemPromptAndHistoryStayIdenticalAcrossMessagesMinutesApart`).

## Citations and answer provenance

### Every citation marker is verified against the sources the model was given

Only sources a tool returned, or the retrieve-first sources handed to the model, may be cited, and every marker is checked after the answer is written. A marker for a source the model was not given is never rendered as a source link, even for a real but unseen ID; on Windows and Linux it becomes "(source not verified)". Verification runs before partial output is published and before the final output is saved.

Where: `LokalBot/Services/Chat/ChatCitation.swift` (`ChatCitationParser.verified`), `LinuxWindows/crates/lokalbot-ai/src/ask.rs`, `LinuxWindows/crates/lokalbot-ai/src/ask_agent.rs`.

### Labels and grouped markers from small models are read as markers

Small models often cite a source by its label ("[M1]", "[M1@00:00:43]") rather than its marker, and write several meetings in one marker (`[meetings:A, B]`, `[meeting:A; B@00:01:10]`) despite the prompt. Both forms are turned into the markers they stand for.

Where: `LinuxWindows/crates/lokalbot-ai/src/ask.rs` (`GROUPED`).

### Citation seconds are scaled without trapping

The leading time field of a citation has no upper bound and can come from a model's tool call (`get_meeting`'s `from`), so scaling it to seconds must not trap.

Where: `LokalBot/Services/Chat/ChatCitation.swift` (`ChatCitationParser.seconds`).

### An unknown answer location reads as remote

When the companion decodes an answer location it does not know, it treats it as remote, so an answer is never presented as private when it may not be.

Where: `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Models/Ask.swift` (`AnswerLocation.init(from:)`).

## Sources a question may read

### A full question reads every chosen source; a short phrase reads its listed matches

A full question asked from the field reads everything in the sources and dates the two menus show, whether or not matches are listed, while a word or short phrase is a search the person then asks about, so its answer reads the listed matches. A "Remember …" statement is saved as it is and limits nothing, and scope already set on purpose (a meeting handed over, an attached screen, the menu's "Only …" state) is left alone. Anything longer than a short phrase counts as a question in any language, because `AskIntent` and `is_question` only know English question words and a question typed without "?" in Serbian or Japanese would otherwise be answered from its matches alone.

Where: `LokalBot/Models/Ask/AskRouting.swift` (`AskAnswerScope.fullQuestionWordCount`), `LinuxWindows/crates/lokalbot-app/src/pages/ask/model.rs` (`AnswerScope`, `AnswerScope::FULL_QUESTION_WORDS`).

### Files and Agent notes belong to "All sources" whether on or off

Files and Agent notes count as part of "All sources" whether or not they are turned on, so turning one on or off never makes an earlier question look narrowed; each is offered only while it is on. Leaving out agent notes limits nothing while none are being read, so questions asked before that source existed stay as they were.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/ask/scope.rs`, `LinuxWindows/crates/lokalbot-engine/src/ask.rs` (`is_unscoped`).

### Asking about results keeps Activity, Files and Agent notes

"Ask about results" bounds meetings and screen moments to the displayed rows. Activity has no result rows to bound, so a selected Activity source stays; otherwise "How long was I in Figma today?" lost the only tool that answers it whenever the question also matched a result. Files has no per-row bound yet, so a selected Files source stays when file rows were among the results, and Agent notes stay when note rows were.

Where: `LokalBot/Models/Ask/RecallWorkspaceState.swift` (`RecallWorkspaceState.selectResultEvidence`), `LinuxWindows/crates/lokalbot-app/src/pages/ask/scope.rs` (`Evidence.from_results`).

### A single handed-over moment is attached; a session or result collection is a boundary

A single screen moment handed to Ask is attached to the question. A session's or a result list's moments bound retrieval and are never copied into the prompt.

Where: `LokalBot/Views/Ask/AskView.swift` (`AskContent.consumeNavigationHandoff`), `LinuxWindows/crates/lokalbot-app/src/pages/ask/mod.rs` (`AskPage.take_request`).

### An empty scope reads nothing

A scope the host puts on a tool call is nil when the call carries none and an empty list when it is there and holds nothing, and the two must never read alike: `string` reported an empty value as missing, which read a scope of no meetings as every meeting. A saved empty source list would also read as every source, so when nothing is left within a boundary the saved scope names the boundary's own source, which stays empty.

Where: `LokalBot/Services/Chat/ChatAgent.swift` (`ChatToolCall.scope`), `LinuxWindows/crates/lokalbot-app/src/pages/ask/scope.rs` (`ask_scope`).

### Disabled sources are denied when a tool runs, not only hidden from the prompt

Each question gets its own tool catalogue: disabled sources are absent from the agent prompt and are still denied at execution, as a second boundary.

Where: `LokalBot/Models/Ask/AskRouting.swift` (`ScopedChatToolRunner`).

### Scoped questions get no memory distilled from everything

Dream memory, work memory and learned claims are distilled from meetings, activity and screen context, so a question limited to some sources or days does not get them: they would carry content past its source and day boundary even though no tool could. Scoped questions ask for usable claims with `include_evidence_backed: false`. The person's own statements carry no source, so they still apply.

Where: `LokalBot/Services/Chat/ChatViewModel.swift` (`ChatViewModel.run`), `LinuxWindows/crates/lokalbot-engine/src/ask.rs` (`is_unscoped`), `LinuxWindows/crates/lokalbot-core/src/personal/controller.rs` (`Personal::usable_claims`).

## Saved questions and conversations

### Each question saves its scope, and a reopened conversation never widens

The sources and date scope a question may draw on are saved with its turns. Earlier, wider answers stay out of a narrower question's model context, and restoring a saved scope keeps its sources as they were: nothing it excluded comes back, and evidence stays bound.

Where: `LinuxWindows/crates/lokalbot-core/src/model/ask_scope.rs`, `LinuxWindows/crates/lokalbot-app/src/pages/ask/scope.rs` (`restore`), `LokalBot/Services/Chat/ChatViewModel.swift` (`ChatViewModel.QuestionScope`).

### The date scope is saved as a civil day, apart from the sources

A `Date` is an instant, so saving a local midnight and formatting it after a time-zone change can silently move the scope to the previous or next day. The scope is stored as `YYYY-MM-DD` or `YYYY-MM-DD...YYYY-MM-DD` (`AskDateScope.storageKey`), kept apart from the sources so a date filter never grants one.

Where: `LokalBot/Models/Ask/AskRouting.swift` (`AskDayScope`), `LinuxWindows/crates/lokalbot-core/src/model/chat.rs` (`ChatMessage.day_scope_key`).

### Scopes from older builds are dropped or distrusted, never widened

An absolute date from an older build never saved its time zone, so turning it into a civil day could move the boundary; the day is dropped and a retry is kept from silently widening the old request. Version-1 scopes are never trusted for reuse because they omitted pinned-screen provenance, so even a Meetings-only label could have hidden captured text in its prompt.

Where: `LinuxWindows/crates/lokalbot-core/src/model/chat.rs` (`ChatMessage::from`, `ChatMessage::migrated`).

### Attached screen ids stay in memory; only their days are saved

For the latest question of each conversation that attached screens, the screen ids stay in memory for a retry, and only their days reach the saved conversation.

Where: `LinuxWindows/crates/lokalbot-app/src/state.rs` (`AppData.attached_asks`).

### Deleting a conversation removes the legacy copy first and beats an answer in flight

The legacy copy is deleted first: if that fails, the sealed copy is still there and the conversation can be deleted again. What was learned from its questions is deleted too, and an answer still being written never brings back a conversation deleted meanwhile.

Where: `LinuxWindows/crates/lokalbot-core/src/chats.rs` (`Library::conversation_exists`).

## Keyword search

### Chinese, Japanese and Korean queries match by substring

SQLite's `unicode61` tokenizer splits on spaces and punctuation, so an unbroken run of CJK text, and any Latin letters glued to it, is indexed as one token and FTS5 matches a word only at the start of that run: "深色模式" found "深色模式下设置页面…", but "对比度" and "三台设备" found nothing. A query that contains CJK text therefore matches by substring on the stored text, and a query without CJK text that FTS finds nowhere falls back to the same match restricted to rows that contain CJK text, so "logo" still finds "比如logo再大一点" while libraries without CJK text see no change. `CJKSearch` is compiled into the app and `lokalbot-cli`, so meeting search, screen search and the MCP screen reader share one matcher, and the Rust agent notes and sync search follow the same rule.

Where: `LokalBot/CLISupport/CJKSearch.swift` (`CJKSearch`), `LokalBot/Services/Search/SearchIndex.swift` (`SearchIndex.search`), `LokalBotTests/CLISupport/CJKKeywordSearchTests.swift` (`CJKKeywordSearchTests`), `LinuxWindows/crates/lokalbot-core/src/agent_notes/cjk.rs`, `LinuxWindows/crates/lokalbot-sync/src/client/search.rs` (`cjk`).

### Match weights are summed in query order

A set's order changes from run to run, and with it the last bits of the sum, so meetings that match the same words could swap places between two identical searches. `hits` sums match weights in the query's word order.

Where: `LinuxWindows/crates/lokalbot-cli/src/search.rs` (`hits`).

### The keyword prefilter answers "no" only when no word can match

The prefilter lets `hits` skip text that cannot match, and fold the rest faster, without changing a single hit. `fold` decomposes (NFD), drops combining marks, lowercases and collapses whitespace, and `fold_fast` works one character at a time with an ASCII shortcut, handing a text to `fold` when it holds a capital sigma (lowercased to `ς` or `σ` by its neighbours) or a character with a nonzero combining class (reordered by decomposition). The prefilter looks for each search word's skeleton (folded text with every run of non-letters and non-digits as one space and `ς` as `σ`) in a text's skeleton or in a `transcript.json` before it is decoded, and answers "maybe" when it cannot read something (invalid UTF-8, a broken escape), leaving the decoder and matcher to decide.

Where: `LinuxWindows/crates/lokalbot-cli/src/search/prefilter.rs`.

### The Meetings filter fetches every matching meeting

The Meetings list filter shows every meeting with a row matching the query. Ranked search fetched 2,000 rows and kept the first 40 meetings, so a common word hid older ones.

Where: `LokalBot/Services/Search/SearchIndex.swift` (`SearchIndex.matchingMeetingIDs`).

### Index writes recheck deletion and freshness inside their write transaction

Deletion and indexing use independent SQLite connections, and embedding can suspend for minutes. The indexer checks the durable deletion tombstone inside its write transaction, so either indexing commits first and deletion removes it, or deletion commits first and the late worker is a no-op; the embedding index rechecks freshness under `BEGIN IMMEDIATE` so an older request cannot replace a newer snapshot after it finally receives vectors. A deletion that committed first wins, and an older snapshot never overwrites a newer one.

Where: `LokalBot/Services/Search/SearchIndex.swift` (`SearchIndex.reindex`), `LokalBot/Services/Search/EmbeddingIndex.swift` (`EmbeddingIndex.index`), `LinuxWindows/crates/lokalbot-core/src/search.rs` (`Library.reindex_meeting`).

### Removable documents record the source file behind them

Deleting a file (clearing notes, archiving outcomes) cannot raise the newest source modification time, so freshness alone would keep its rows searchable. Each removable document kind records its source file.

Where: `LokalBot/Services/Search/SearchIndex.swift` (`SearchIndex.documentSources`).

### Files found by search open inside LokalBot

A PDF opens in a LokalBot window at the matched page with the query's words marked, and a recording or video plays in a LokalBot window from the matched moment, without QuickTime scripting and so without the Automation permission. Anything else opens in its default app.

Where: `LokalBot/Views/Ask/FileSearchResultRow.swift` (`FileSearchOpener`).

## Meaning search index

### The embedder runs EmbeddingGemma with its own pooling and each input in one micro-batch

The embeddings instance is a small model on a second llama-server port. EmbeddingGemma's GGUF carries its own mean pooling and projection, so no pooling flag is passed (one would override them). As a bidirectional encoder it must see each input in a single micro-batch, and real 1,500-character OCR reaches about 950 tokens, so the server batches at the full context.

Where: `LokalBot/Engines/LlamaServer.swift` (`LlamaServer.embedder`), `LinuxWindows/crates/lokalbot-ai/src/runtime.rs` (`Role::extra_args`).

### Prompt caching is off for embedding requests

EmbeddingGemma is a bidirectional encoder: every token attends to the whole input, so reusing another input's cached prompt prefix would be wrong. The bundled llama.cpp already re-encodes each input (vectors were identical with caching on); turning caching off keeps that independent of server defaults.

Where: `LokalBot/Services/Search/EmbeddingIndex.swift` (`EmbeddingIndex.embeddingRequestBody`), `LokalBotTests/Services/Search/EmbeddingIndexContractTests.swift` (`EmbeddingIndex.embeddingRequestBody`).

### Vectors are versioned by model identity and pipeline, and any change re-embeds

`EmbeddingIndex.indexVersion` is persisted separately from the server-facing model name, and any change to pooling, prompting or chunking advances it so vectors made under incompatible contracts are discarded before search resumes. Earlier models' vectors are invalidated by model identity, not vector shape: Qwen and Harrier both produced 1,024 dimensions. On Windows and Linux, `VECTOR_VERSION` covers the model files, the llama.cpp build, the image sizing and the request shapes, and bumping it makes every file index embed again.

Where: `LokalBot/Services/Search/EmbeddingIndex.swift` (`EmbeddingIndex.indexVersion`), `LokalBotTests/Services/Search/IndexPersistenceTests.swift` (`EmbeddingIndex` migration), `LinuxWindows/crates/lokalbot-ai/src/media_embedder.rs` (`VECTOR_VERSION`).

### Similarity floors are calibrated for EmbeddingGemma 2

EmbeddingGemma 2 scores unrelated text higher than Harrier did: on a real library, unrelated meeting chunks had a median of 0.59 and unrelated screens 0.61, above Harrier's 0.45 floor. The floors pass the same share of unrelated pairs as Harrier's 0.45 (32% of meeting chunks, 76% of screens) while keeping 99.7% and 100% of the passages the queries were written from. Recalibrate them whenever the embedding model changes.

Where: `LokalBot/Services/Search/EmbeddingIndex.swift` (`EmbeddingIndex.meetingSimilarityFloor`), `LokalBotTests/Services/Search/EmbeddingIndexContractTests.swift` (`EmbeddingIndex` score floor).

### Background embedding yields to typed queries

The embedder llama-server runs `--parallel 1` and encodes inputs first in, first out, so a typed query waits for every input posted before it. `EmbeddingRequestGate` sends background requests one at a time and holds them while a foreground request is in flight, so a query waits for at most the one background request already on the server. Background requests are capped so that wait is about 100 ms on an M4 Max (a 1,500-character OCR row is about 900 tokens and 50 ms, a 500-character transcript chunk about 11 ms); splitting costs almost nothing and does not change the vectors, because each input is encoded on its own.

Where: `LokalBot/Services/Search/EmbeddingIndex.swift` (`EmbeddingRequestGate`, `EmbeddingIndex.backgroundRequestMaximumInputs`).

### Captured screens are embedded without waiting for a search

On 2026-10-12, screens captured after 2026-10-08 had no vectors: only a screen search started a backfill, and a pass that failed (another embedder held port 17873) was never retried. A capture in a library that searches screens by meaning must reach semantic search on its own.

Where: `LokalBotTests/Integration/CaptureReplayTests.swift` (`testCapturedTextIsEmbeddedWithoutASearchAfterAFailedPass`).

### Clearing a meeting's vectors writes no tombstone

`clearVectors` drops a live meeting's vectors so the next pass re-embeds its changed sources. Unlike `remove`, it writes no deletion tombstone: tombstones are shared with keyword search and would hide the meeting from both.

Where: `LokalBot/Services/Search/EmbeddingIndex.swift` (`EmbeddingIndex.clearVectors`).

### Removing embeddings uses its own connection

`EmbeddingIndex.remove` runs on a utility worker for AppState's deletions and opens its own FULLMUTEX connection, so SQLite's busy timeout can never stall the main actor.

Where: `LokalBot/Services/Search/EmbeddingIndex.swift` (`EmbeddingIndex.remove`).

## Ranking

### Keyword and meaning results are fused per meeting

Fusion happens at the level of meetings, so a meeting with many keyword rows cannot bury a relevant one found by meaning alone. Keyword excerpts are kept, and one passage found both ways is listed once, deduplicated deterministically.

Where: `LokalBot/Models/Ask/RecallSearch.swift` (`RecallSearch.fusedMeetings`), `LinuxWindows/crates/lokalbot-app/src/pages/ask/search.rs` (`fused_meetings`).

### Screen search ranks the way DigUp ranks files, not by reciprocal-rank fusion

Meaning is how far a capture stands out for this query among all stored vectors of its kind, and the query's words add a bonus that grows with how many of them the capture holds (after DigUp's `Searcher.search`, github.com/ARahim3/DigUp, MIT). Reciprocal-rank fusion gave the long OR-fallback keyword list (any one word) the same weight as meaning and pulled the right screen down on descriptive queries: 44 of 138 found first against 52 for text meaning alone (`Benchmarks/search/EmbeddingGemma2/2026-10-13-screen-images`). A capture qualifies by standing out in meaning or by holding at least half of the query's words, so one common word can't outrank a clear meaning match, while all the words of an exact lookup ("INV-2041") usually win.

Where: `LokalBot/Services/ScreenMemory/ScreenSearchRanking.swift` (`ScreenSearchRanking`).

### Screen meaning scores are scaled per kind over every stored vector

Each capture's best vector counts, and scores are centred per kind first, because text scores higher than pictures for the same topic (DigUp measured 0.75–0.86 against 0.67–0.78), then put on one z scale. The scale is computed from every stored vector, not only those in the date or app scope, so it does not depend on the filter.

Where: `LokalBot/Services/ScreenMemory/ScreenSearchRanking.swift` (`ScreenSearchRanking.meaning`).

## Media embedder on Windows and Linux

### One media embedder serves indexing; searches embed on the text-only embedder

EmbeddingGemma 2 with its image and audio projector runs on the media llama-server (the Mac's `FileMediaEmbedder`) with one caller at a time and one thread, and callers wait: Files' indexer and the picture vectors of saved screens both use it. Searches never use this server; they embed their words on the small text-only embedder and score against the index, so a text's vector from the media embedder must match the text-only embedder's.

Where: `LinuxWindows/crates/lokalbot-ai/src/media_embedder.rs`, `LinuxWindows/crates/lokalbot-engine/tests/e2e_media.rs` (`the_projector_embeds_pictures_sound_and_text_and_a_pass_finds_them`).

### Inputs travel in the shapes the Mac's parity run qualified

Texts go as given, images as PNG sized for their budget, audio as WAV, each medium as a typed content part. The part is nested one level inside the input item, because a flat `input: [{type: image_url}]` is rejected (ggml-org/llama.cpp#30082).

Where: `LinuxWindows/crates/lokalbot-ai/src/media_embedder.rs` (`image_part`).

### Long texts are cut the way transformers cuts, and an oversized input fails alone

llama-server answers an input longer than its batch with HTTP 500 instead of cutting it, though the server is fine. A text that does not fit one batch is cut to its first 2,047 tokens and `<eos>`, the way transformers cuts; no token is shorter than a byte, so shorter texts skip the tokenizer. A picture or recording that still doesn't fit fails alone as a per-file rejection, instead of stopping every pass at the same file.

Where: `LinuxWindows/crates/lokalbot-ai/src/media_embedder.rs` (`MediaEmbedder::fitted`, `classify_status`).

## Consequences

- Anything that narrows what a question reads (sources, dates, result rows, attached screens) has to hold in the prompt, at tool execution and in what is saved for a retry or reopen; distilled memory and earlier, wider answers stay out of scoped questions, and older saved scopes are never widened.
- Changing the embedding model, the llama.cpp build, pooling, prompting, chunking, image sizing or request shapes means advancing the vector version and recalibrating the similarity floors, and the media embedder's text vectors must still match the text-only embedder's.
- The Mac and the Windows and Linux app share these rules (citation verification, CJK substring matching, scope handling, per-meeting fusion), so a change on one side needs the same change on the other.
