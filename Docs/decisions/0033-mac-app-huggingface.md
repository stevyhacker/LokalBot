# 0033. Mac app: HuggingFace

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Services/HuggingFace/`.

## Decisions

### `LokalBot/Services/HuggingFace/HuggingFaceAPIClient.swift`

#### Short-timeout non-caching session; decoupled from download policy
`HuggingFaceAPIClient`: Stateless client for HuggingFace's public model REST API. Holds one
short-timeout, non-caching `URLSession` so the browse flow always shows a
fresh model list and a stalled network can never hang the UI for long.

Decoupled from `ModelCatalog`/`ModelDownloadManager` on purpose: it returns
plain value types and a directly-downloadable URL, leaving download policy
(destination, naming, progress) to the existing download manager.

#### LocalizedError so errorDescription publishes straight to errorMessage
`HuggingFaceAPIClient.APIError`: Failure surfaced to the browse UI. `LocalizedError` so the search
service can publish `errorDescription` straight into `errorMessage`.

#### Ephemeral, cache-defeating, 20 s timeout to avoid stale lists and wedging
`HuggingFaceAPIClient.defaultSession`: Ephemeral + cache-defeating so model lists are never stale; the 20 s
request timeout keeps a slow network from wedging the browse sheet.

#### direction=-1 required or sort=downloads returns ascending
`HuggingFaceAPIClient.searchModels`: Search GGUF model repositories, most-downloaded first.

`direction=-1` is required: `sort=downloads` alone returns ascending
(least-popular) results, which is the opposite of what a "find a model"
browse wants — so popular repos would never surface without it.

#### Blob metadata supplies LFS SHA-256 for integrity policy
`HuggingFaceAPIClient.files`: List the `.gguf` files in a repository.

Requests blob metadata so every downloadable file carries its immutable
LFS SHA-256 and can satisfy ModelDownloadManager's integrity policy.
Files are returned in natural filename order so quantization variants
group sensibly in the UI.

#### Set owner/repo via path so its slash stays a separator
`HuggingFaceAPIClient.files`: modelID is "owner/repo"; its slash is a real path separator, so set it
via `path` (URLComponents percent-encodes only the unsafe characters).

#### Cancelled errors surface as transport; caller checks Task.isCancelled
`HuggingFaceAPIClient.fetch`: URLError.cancelled lands here too; the caller distinguishes it via
Task.isCancelled so a superseded request stays silent.

#### User agent makes traffic attributable and less rate-limited
`HuggingFaceAPIClient.userAgent`: Identifies the app to HuggingFace so anonymous traffic is attributable
and less likely to hit shared rate limits.

#### Missing counts decode to 0 so one field never fails list
`HFModelSummary`: One repository from `GET /api/models?filter=gguf&search=…&sort=downloads`.
`Decodable` maps the API's `id`/`downloads`/`likes` directly; a missing
count decodes to 0 so one absent field never fails the whole list.

#### Repo-relative path, possibly nested in a subfolder
`HFFile.id`: Repo-relative path (`rfilename`), e.g. `Qwen3.5-0.8B-Q4_K_M.gguf` — or
`gguf/model-Q4_K_M.gguf` when a repo nests files in a subfolder.

#### Immutable commit returned by the model API
`HFFile.revision`: Immutable repository commit returned by the model API.

#### Resolve URL redirects to CDN; URLComponents encodes nested paths
`HFFile.downloadURL`: Direct download URL on HuggingFace's `resolve` endpoint. `URLSession`
follows the CDN redirect automatically, so this is usable as-is by a
`downloadTask`. Built via `URLComponents` so nested paths and unusual
characters are percent-encoded correctly.

#### Digest rides in URL fragment, consumed by ModelDownloadManager, never sent
`HFFile.downloadURL`: URL fragments are never sent to the server. ModelDownloadManager
consumes this integrity hint before constructing its network URL,
so existing UI plumbing carries the LFS digest without a parallel
mutable lookup table.

#### Leaf filename so nested repo files download flat
`HFFile.fileName`: Leaf filename — repos sometimes nest files (e.g. `gguf/model.gguf`), and
downloads should land flat under `<storage>/models/`.

### `LokalBot/Services/HuggingFace/HuggingFaceSearchService.swift`

#### Owns cancellation so UI binds to published state directly
`HuggingFaceSearchService`: Drives the two-step HuggingFace browse flow for the Settings sheet: search
for GGUF repositories, then drill into one to list its `.gguf` files. Owns
cancellation so the UI can bind directly to published state without juggling
async `Task`s of its own.

#### Mutating query doesn't search; view calls search(), typically debounced
`HuggingFaceSearchService.query`: Two-way bound to the search field. Mutating it does not auto-search;
the view decides when to call `search()` (typically debounced).

#### Single error channel for search and file listing
`HuggingFaceSearchService.errorMessage`: Last failure's user-facing text, or nil when the last operation was
clean. The single error channel for both search and file listing.

#### Safe per keystroke; superseded requests cancelled before mutating state
`HuggingFaceSearchService.search`: Run a search for the current `query`, cancelling any prior in-flight one.
Safe to call on every keystroke — superseded requests are cancelled
before they mutate state, so the latest query always wins.

#### Returns empty array and sets errorMessage so caller needs no catch
`HuggingFaceSearchService.ggufFiles`: Fetch a repository's `.gguf` files. Returns an empty array (and sets
`errorMessage`) on failure so the caller never has to catch.

#### Cancelled task leaves isSearching for its successor to clear
`HuggingFaceSearchService.performSearch`: The body of one search. Touches published state only when it is still
the active task: a cancelled task returns without writing, leaving
`isSearching` for its successor (which already set it true) to clear.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
