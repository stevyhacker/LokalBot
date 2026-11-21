# 0014. File search

- Status: Accepted
- Date: 2026-11-20

## Context

Files lets the person search the folders they choose by meaning and by keyword, from the app, from Ask and from the command line. The Mac app indexes with DigUp's indexer and a local EmbeddingGemma 2 media embedder on llama-server; the Windows and Linux app has its own Rust crawler, index and search that write the same on-disk layout. These decisions were moved here from code comments when the code stopped carrying comments ([ADR 0001](0001-code-carries-no-comments.md)).

## Consent and scope

### Files reads nothing until the person turns it on, and nothing uses the index while it is off

Nothing is read until the person turns Files on after a notice and chooses a folder. The index is gone while Files is off, so Ask resolves no file citations then, and the engine honours the folders chosen under Files in an Ask scope only while Files is on.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/settings/files.rs`, `LokalBot/Views/Settings/FileSearchSettings.swift`, `LinuxWindows/crates/lokalbot-app/src/state.rs` (`AskScope.include_files`), `LinuxWindows/crates/lokalbot-app/src/pages/ask/transcript.rs` (`AskPage::load_file_citations`).

## Watching folders

### A file change starts a sync only if the crawl could see it, and the filter says yes when in doubt

Every sync walks the chosen folders again (on a developer's Mac 459,000 entries and 18 s of CPU to find nothing), so a change reported by FSEvents or the file watcher that the crawl would leave out never starts one: in a place it doesn't walk, of a type it doesn't read, or inside a code project, where it keeps only screenshots. When in doubt the filter says yes: an extra pass costs seconds, a missed one leaves a new file out of search until something else changes.

Where: `LokalBot/Services/FileSearch/FileChangeFilter.swift` (`FileChangeFilter`), `LinuxWindows/crates/lokalbot-core/src/files/change_filter.rs`.

### Only folders taken off the list leave the index; unreachable folders keep their files

Folders taken off the list leave the index. A folder that is missing (an unplugged drive) or that the system refuses to list (on the Mac, one macOS won't list) keeps its files. A root that went away while it was being walked looks emptier than it is, so its rows are kept rather than taken for deleted.

Where: `LokalBot/Services/FileSearch/FileSearchService.swift` (`FileSearchService.sync`), `LinuxWindows/crates/lokalbot-engine/src/files/mod.rs` (`sync`), `LinuxWindows/crates/lokalbot-core/src/files/index.rs` (`FileIndex::sync`).

## Reading files

### Cloud placeholders are never read

A cloud placeholder whose contents would be downloaded on read is never read.

Where: `LinuxWindows/crates/lokalbot-core/src/files/crawler.rs` (`FileInfo.dataless`).

### Oversized zip entries are not inflated

Zip entries larger than `MAX_ENTRY_BYTES` aren't inflated: such an entry is a zip bomb, or XML far past what the index keeps of a document.

Where: `LinuxWindows/crates/lokalbot-engine/src/files/documents.rs` (`MAX_ENTRY_BYTES`).

### A PDF parser panic fails that file only

A malformed file can make the PDF parser panic while reading every page's text; the panic is contained so it fails that file only.

Where: `LinuxWindows/crates/lokalbot-engine/src/files/pdf.rs` (`pdf::read`).

### Text recognition goes through the app's queue with a time limit, and a file without an answer stays pending

DigUp reads the words in screenshots and scanned PDF pages, and it used to ask Vision itself and wait as long as that took. On 2026-11-09 one screenshot's request never came back: the pass and the media model it had started stayed up until the app quit, and every other text recognition in the app waited behind it. Files' text recognition now goes through the app's one queue for it (`TextRecognitionQueue`) with a time limit, like every other Vision text request. A file whose text gets no answer in time is not read without it, which would settle it for good: DigUp leaves it waiting (a long PDF keeps its place), the pass goes on with the next file, and a later pass reads it.

Where: `LokalBot/Services/FileSearch/FileTextRecognition.swift` (`FileTextRecognition`).

### Sound is embedded in 30-second windows

The model silently ignores sound past 30 s of one input, so audio is cut into windows no longer than that.

Where: `LinuxWindows/crates/lokalbot-core/src/files/mod.rs` (`IndexOptions.audio_window`).

## The index

### One SQLite file holds rows, vectors and keywords, in the Mac's layout

The on-disk index (`IndexStore`) is one SQLite file with files, their segments (with float16 vectors) and an FTS5 table, in schema 5, the layout the Mac's DigUpKit writes. Vectors live with everything else, so a crash can never leave them out of step with the rows that describe them.

Where: `LinuxWindows/crates/lokalbot-core/src/files/index.rs`.

### A newer index schema is refused and an older one is rebuilt from the folders

An index a newer version made is refused. An older schema is rebuilt from the folders, since nothing in it isn't derived from them.

Where: `LinuxWindows/crates/lokalbot-core/src/files/index.rs` (`FileIndex::open`).

### The keyword tokenizer counts marks as letters

Keyword search's tokenizer counts marks as letters, so Bengali vowel signs and Arabic harakat stay inside their words.

Where: `LinuxWindows/crates/lokalbot-core/src/files/index.rs` (`FTS_COLUMNS`).

### An index never mixes vectors from different models or settings

Anything that changes vectors is part of the `IndexOptions` fingerprint; the index is compared with the current model and settings, and a change empties it, since vectors from different settings can't be compared. On the Mac, `FileMediaEmbedder.vectorVersion` names which vectors the pipeline makes (the model files, the llama.cpp build, the image sizing and the request shapes): bump it when any of them changes the vectors (the reference-vector check says when), and every file index embeds again.

Where: `LinuxWindows/crates/lokalbot-core/src/files/mod.rs` (`IndexOptions`), `LinuxWindows/crates/lokalbot-engine/src/files/pass.rs` (`Pass::check_model`), `LokalBot/Services/FileSearch/FileMediaEmbedder.swift` (`FileMediaEmbedder.vectorVersion`).

## Media embedder

### Images are sized exactly as the reference processor sizes them, never by llama.cpp

A picture is sized for EmbeddingGemma 2's vision encoder the way the model's reference processor does (transformers' resize target, then Pillow's bicubic), ported from DigUp's `ImageSizing` (github.com/ARahim3/DigUp, MIT; see THIRD_PARTY_NOTICES.md), so the media embedder sees the pixels DigUp's reference vectors were made from. The media embedder runs llama-server with `--image-min-tokens 1 --image-max-tokens 1120`, so llama.cpp never rescales an image that already has its final size and each image's token budget is set here. Left to size images itself, llama.cpp spends about twice the tokens and the vectors drift from the reference (`Benchmarks/search/EmbeddingGemma2/2026-10-30-media-embedder`). The test fixtures are DigUp's (`Tests/LlamaRuntimeTests/ImageSizingTests.swift`, MIT), made with PIL.

Where: `LokalBot/Services/FileSearch/FileImageSizing.swift` (`FileImageSizing`), `LinuxWindows/crates/lokalbot-engine/src/files/image_sizing.rs`, `LokalBotTests/Services/FileSearch/FileImageSizingTests.swift` (`FileImageSizingTests`).

### A text longer than one batch is cut to its first tokens before it is sent

A text that fits one batch is sent as itself; a longer one goes as its tokens cut the way DigUp's embedder (and transformers) cuts, the first `maxInputTokens - 1` and `<eos>`. llama-server refuses a longer input with HTTP 500 instead of cutting it, and a dense page of Cyrillic or figures passes 2,048 tokens well within the 4,000 characters DigUp sends; sent whole, such a page stopped every indexing pass (1 November). No token is shorter than a byte, so shorter texts skip the tokenizer; tokens and text make the same vector.

Where: `LokalBot/Services/FileSearch/FileMediaEmbedder.swift` (`FileMediaEmbedder.fitted`), `LokalBotTests/Services/FileSearch/FileMediaEmbedderTests.swift` (`testATextLongerThanOneBatchGoesAsItsTokensCutLikeDigUp`).

### Image parts are nested inside the input item

An image goes as a typed content part nested one level inside the input item; a flat `input: [{type: image_url}]` is rejected (ggml-org/llama.cpp#30082).

Where: `LokalBot/Services/FileSearch/FileMediaEmbedder.swift` (`FileMediaEmbedder.imagePart`).

### A bad file fails alone; a server that cannot answer stops the pass and leaves files pending

A file the server cannot read (a broken picture), or an input too large for its batch (which llama-server answers with HTTP 500), fails alone and must not sink its neighbours. A server that cannot answer throws `WorkerError`, and any other HTTP 500 still stops the pass: DigUp's indexer then stops the pass and leaves the files pending for the next one, where any other error would mark the whole batch failed for good.

Where: `LokalBot/Services/FileSearch/FileMediaEmbedder.swift` (`FileMediaEmbedder.embedding`), `LokalBotTests/Services/FileSearch/FileMediaEmbedderTests.swift` (`testAnInputTooLargeForTheBatchFailsThatFileOnly`).

### Every llama.cpp update must reproduce DigUp's reference vectors

DigUp's reference inputs, run through the app's own path (ImageIO decoding, `FileImageSizing`, PNG content parts, the media llama-server with the app's arguments), must reproduce DigUp's reference vectors at cosine ≥ 0.999, the bar DigUp sets for runtimes that agree; JPEG inputs get 0.998, because DigUp's reference decodes them with stb_image and the app with ImageIO, and the two decoders differ on 27% of the photo's pixels (mean 0.2 levels). Measured on 30 October with ImageIO-decoded pixels in Pillow's path too: photo-140 0.99964 and frame-70 0.99860, the same as the test, while text, the PNG screenshot and speech match at 1.0. Run it for every llama.cpp update: a failure means bump `FileMediaEmbedder.vectorVersion` (every file index then reads its files again) or keep the old llama.cpp. It needs `LOKALBOT_MEDIA_EMBEDDER_MODELS` (passed as `TEST_RUNNER_LOKALBOT_MEDIA_EMBEDDER_MODELS` through xcodebuild) set to a folder holding `embeddinggemma-2-Q8_0.gguf` and `mmproj-embeddinggemma-2-Q8_0.gguf`, is skipped otherwise, and its fixtures are DigUp's (MIT; `Fixtures/MediaEmbedderReference/LICENSE.DigUp`).

Where: `LokalBotTests/Services/FileSearch/FileMediaEmbedderReferenceTests.swift` (`FileMediaEmbedderReferenceTests`).

## Ranking

### Meaning scores are centred per modality and scaled by the first pages only

A segment's meaning score is its vector's cosine minus the average of its modality (what made the vector), in standard deviations of all of them together, because text scores higher than images or sound for the same topic. The scale comes from `sets_scale`, so a book's hundreds of later pages don't move it (as in `Searcher.meaning`).

Where: `LinuxWindows/crates/lokalbot-core/src/files/mod.rs` (`Modality`), `LinuxWindows/crates/lokalbot-core/src/files/search.rs` (`meaning`).

### Code and ID queries weigh keywords double and meaning half

Codes and IDs ("K7Q2LM") and long numbers mean nothing to an embedding but everything to keyword search, so such a query weighs words double and meaning half.

Where: `LinuxWindows/crates/lokalbot-core/src/files/search.rs` (`is_lookup`).

### Folder and date filters apply after ranking, so the search looks further until enough results are inside

The folders and dates are applied after ranking, so the best few matches can all fall outside them: forty older invoices hid the one from this month, and with a limit of 1 the search looked at the best four matches only, so when those were all in a folder agents may not search, a match in the chosen folder was never seen and the answer was "nothing". The search looks further down the ranking until enough matches are inside, or there is nothing more to look at. The test puts eight files outside that hold both words of the query and one inside that holds one, so it ranks last.

Where: `LokalBot/CLISupport/FilesAccess.swift` (`FilesSearchTool.report`), `LinuxWindows/crates/lokalbot-cli/src/files.rs` (`files::report`), `LokalBotTests/CLISupport/FilesAccessTests.swift` (`testAMatchRankedBelowOnesOutsideTheChosenFoldersIsStillFound`).

## Moments in recordings and videos

### Only the matched 30 seconds are transcribed, with the person's own model, never while a meeting records

For the Ask assistant, Files finds a recording's or video's 30-second window by meaning, and only that window is transcribed with the person's own transcription model, so the answer can quote what was said instead of only pointing at the moment. It never downloads a transcription model (`ModelReadinessSnapshot`; on the Mac the model must already be on this Mac) and waits while a meeting records so it can't compete with live transcription. On Windows and Linux a remote transcription server receives the clip only if its origin is approved, which `SpeechCache` checks each time.

Where: `LokalBot/Services/FileSearch/FileMomentTranscriber.swift` (`FileMomentTranscriber`), `LokalBot/AppState.swift` (`AppState.fileMoments`), `LinuxWindows/crates/lokalbot-engine/src/files/moments.rs`.

### Moment transcripts are kept only in memory

The transcribed text stays in memory: the tool's observation is not saved with the conversation (`ChatMessage` stores the answer and activity line).

Where: `LokalBot/Services/FileSearch/FileMomentTranscriber.swift` (`FileMomentTranscriber`), `LinuxWindows/crates/lokalbot-engine/src/files/moments.rs`.

## Consequences

- Any change to the model files, llama.cpp build, image sizing, request shapes or vector-affecting `IndexOptions` must invalidate the index (fingerprint or `vectorVersion`), and a llama.cpp update must pass the reference-vector test first.
- A failure must stay with its file or leave files pending for a later pass; never let one bad file, a timeout or a missing folder mark files as read, failed for good, or deleted.
- Files reads only the chosen folders while it is on, never reads cloud placeholders, never downloads a transcription model, and keeps moment transcripts out of saved conversations.
