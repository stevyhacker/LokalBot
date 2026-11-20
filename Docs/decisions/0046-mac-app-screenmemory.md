# 0046. Mac app: ScreenMemory

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Models/ScreenMemory/`, `LokalBot/Services/ScreenMemory/`, `LokalBot/Views/ScreenMemory/`, `LokalBotTests/Models/ScreenMemory/`, `LokalBotTests/Services/ScreenMemory/`.

## Decisions

### `LokalBot/Models/ScreenMemory/CaptureSetupDraft.swift`

#### Welcome choices are staged; apply updates only fields the wizard owns
`CaptureSetupDraft`: Welcome choices are staged. Back/Continue and reopening the wizard do not
change capture settings; applying updates only the fields this wizard owns.

#### Master switch only; per-agent switches and exclusions stay in Settings
`CaptureSetupDraft.codingAgentSessions`: The master switch for reading Claude Code and Codex sessions. The
per-agent switches and folder exclusions stay with Settings.

#### Remember detected-call choice so switch off and on keeps it
`CaptureSetupDraft.detectedCallMode`: What a detected call does while Meeting notes is on. Setup's switch
returns to it, so turning the switch off and on keeps the choice.

#### Use a new install's own choice; setup never picks another
`CaptureSetupDraft.defaultDetectedCallMode`: A new install's own choice; setup never picks a different one.

#### Off means recording happens only on Record
`CaptureSetupDraft.recordsDetectedCalls`: Setup's Meeting notes switch. Off records only on Record.

#### Keep selected detail level when memory is off, for next explicit enable
`CaptureSetupDraft.applying`: The master switch gates capture independently. Turning memory off,
or reopening setup while it is off, must retain the selected detail
level for the next explicit enable action.

### `LokalBot/Models/ScreenMemory/CaptureState.swift`

#### Meeting selection wins over block, then overview; stale block must not outrank empty state on Meetings
`CaptureInspectorState`: What the Timeline/Meetings detail pane shows, resolved from the two
selection sources (spec §2.2): meeting selection wins, then an activity
block, then the day overview. Multi-selected meetings keep the
bulk-delete card.

`allowsBlockSelection` is false on surfaces without a block list
(Meetings): the shared model keeps whatever block was last picked in
Timeline, and that leftover must not outrank the empty state there —
while still being selected again when the user returns to Timeline.

### `LokalBot/Models/ScreenMemory/CaptureTrackItem.swift`

#### Meetings render as first-class blocks; pure so interleaving and end rule are testable
`CaptureTrackItem`: One block in the Capture day track: an app activity block, or a meeting
rendered as a first-class teal block (spec §2.2). Pure so the
interleaving and the in-progress-meeting end rule are unit-testable.

#### End is endedAt, recorded length, or now, at least a minute past start
`CaptureTrackItem.meetingEnd`: A meeting's track end: `endedAt`, else the recorded audio length,
else "now" for a live meeting — never less than a minute past start
so a just-started meeting still gets a visible block.

### `LokalBot/Models/ScreenMemory/RetentionReview.swift`

#### Burst requests and reports are text, so expire with screen text
`RetentionReview.CodingAgentBurst`: A stored coding-agent burst. Its requests and reports are text, so
they expire with screen text.

#### Reduce to one date per local/UTC day pair; consumers key on those days
`RetentionReview.distinctEvidenceDays`: `evidenceDates` (plus `extra`) reduced to one date per distinct pair of
local day and UTC day, sorted. Evidence consumers key only on those
days: Dream invalidation by UTC day, digests and exports by local day.
A pass after a long gap would otherwise hand them a date per row.

#### Shrinking a review is safe; new data, paths or text need fresh review
`RetentionReview.covers`: A disappearing file or newly saved moment may shrink a review safely.
Additional data, changed paths or new text require a fresh review.

### `LokalBot/Models/ScreenMemory/ScreenMemoryUIState.swift`

#### Keep OCR excerpt with snapshot id to avoid a second text query
`ScreenAskContext`: A screen result explicitly attached to the next Ask question. Keeping the
OCR excerpt with the stable snapshot id avoids a second text query and lets
the local text model reason over the selected pixels' captured text.

### `LokalBot/Models/ScreenMemory/ScreenRewindState.swift`

#### Similar adjacent captures collapse to one frame but keep every snapshot for counts and deletion
`ScreenRewindFrame`: One visual scene in Rewind. Adjacent perceptually similar captures collapse
into a single frame while retaining every underlying snapshot for counts and
range deletion.

#### Collapse only adjacent captures in the same persisted similarity group
`ScreenRewindSequence.frames`: Oldest-first visual scenes, collapsing only adjacent captures in the
same persisted similarity group.

#### Tiny trailing epsilon includes final capture in half-open end queries
`ScreenRewindSequence.deletionInterval`: Half-open interval covering the selected frame range. The tiny trailing
epsilon includes the final capture in ActivityStore's `< end` queries.

### `LokalBot/Services/ScreenMemory/OCRMetadataIndex.swift`

#### FTS lacks indexed identity columns; ordinary index maps row IDs to snapshots
`OCRMetadataIndex`: FTS indexes words, not its UNINDEXED identity/timestamp columns. Keep an
ordinary index of FTS row IDs; historical row IDs are not screenshot IDs.

#### Run in FTS-delete transaction; stale identities must not outlive retention
`OCRMetadataIndex.removeDeletedRows`: Called inside the same transaction as FTS deletion. No text is retained
here, and stale identities must not outlive retention or explicit delete.

#### Bounded batches preserve substring matching and earliest-row semantics
`ActivityStore.matchingSnapshotIDs`: Bounded batches preserve substring matching and the earliest FTS row
semantics of point lookup, including migrated libraries with duplicate rows.

### `LokalBot/Services/ScreenMemory/ScreenAccessibilityReader.swift`

#### Only whole-document reads keep selected text
`ScreenAccessibilitySnapshot.selectedText`: The focused element's selected text. Only whole-document reads keep it.

#### Whole AX values may hide documents; only visible text qualifies
`ScreenVisibleTextPolicy`: Whole AXValue/selected-text/help strings can contain a complete hidden
document. Only visible-range text or fully visible static labels qualify.
Whether `text` can return anything, checked before reading the
element's text from the other app.

#### Hand-off reads whole document on explicit press; screen memory never
`ScreenDocumentTextPolicy`: Hand off reads a whole document on an explicit press: every text element
of the focused window, including what is scrolled out of view, in reading
order. Screen memory never uses it.

#### Single-flight worker keeps cross-process AX off main actor and bounded
`ScreenAccessibilityReader`: A bounded, single-flight reader for visible Accessibility text. Cross-process
AX calls never run on the main actor, and a wedged target can occupy only one
worker rather than creating an unbounded queue of blocked snapshots.

#### Activity-only sampling reads privacy metadata, never document text
`ScreenAccessibilityReader.metadataOnly`: Activity-only sampling inspects privacy metadata, never document text.

#### Skips web page walk when no site exclusions need address
`ScreenAccessibilityReader.windowOnly`: Metadata without the walk for web pages, for samples that need no page
address (no site exclusions are configured).

#### Recheck reads secure fields and addresses, no text, node-limited
`ScreenAccessibilityReader.privacyRecheck`: Rechecks a capture's window: secure fields and page addresses, no text,
over at most `nodeLimit()` elements.

#### Own-process AX runs in-process and traps off main; never record own window
`ScreenAccessibilityReader.isOwnProcess`: macOS answers an app's accessibility queries about itself in-process,
on the calling thread. From these background workers that walks
LokalBot's SwiftUI hierarchy off the main actor, which traps. LokalBot
never records its own window as screen context anyway.

#### Failure reason names the failed check, never window contents
`ScreenAccessibilityReader.TextReadFailure`: Why a text read produced no snapshot. Names the failed check, never
window contents.

#### Transient means window changed mid-read; a later read can succeed
`ScreenAccessibilityReader.TextReadFailure.isTransient`: The window was readable but changed while it was read, as during
a tab switch or page load; a read moments later can succeed.

#### Replay and recording report failures like live reads so retry logic sees them
`ScreenAccessibilityReader.recordTextReadFailure`: Replay and recording environments report a read's failure reason the
same way a live read does, so capture retry logic sees it.

#### Only screen-capture reads are diagnosed, not frequent metadata sampling
`ScreenAccessibilityReader.noteTextReadFailure`: Metadata-only activity sampling runs every few seconds; only the
screen-capture read is diagnosed.

#### Text reading covers visible text, secure fields and web pages
`ScreenAccessibilityReader.Reading.text`: Visible text, secure fields and web pages: what a capture stores.

#### Privacy reading rechecks secure fields and pages after pixels were taken
`ScreenAccessibilityReader.Reading.privacy`: Secure fields and web pages without any text, to recheck a
capture's window after its pixels were taken.

#### Metadata reading is web pages only, for site exclusion samples
`ScreenAccessibilityReader.Reading.metadata`: Web pages only: activity samples that apply site exclusions.

#### Window reading skips walking contents
`ScreenAccessibilityReader.Reading.window`: The window and its focused element, without walking its contents.

#### Document reading is hand-off only, reading order, includes scrolled-out text
`ScreenAccessibilityReader.Reading.document`: Hand off, on an explicit press: every text element of the focused
window in reading order, including what is scrolled out of view.
Screen memory never uses it.

#### One cross-process call per element; large values read separately
`ScreenAccessibilityReader.Reading.nodeAttributes`: Read in one cross-process call per element. Values a node rarely
needs or that can be large (`AXValue`, `AXChildren`) stay separate.

#### Document read fetches children separately because it walks every child
`ScreenAccessibilityReader.Reading.nodeAttributes`: A document read walks every child, which it reads separately.

#### Recheck node limit matches capture's read; document reads visit 6,000
`ScreenAccessibilityReader.resolve`: `nodeLimit` caps the elements visited; a privacy recheck passes the
count the capture's own read inspected, so both judge the same part
of the window even though the recheck reads faster. A document read
visits up to 6,000 elements instead.

#### Document walked depth first to keep reading order
`ScreenAccessibilityReader.resolve`: A document is read depth first, so its text keeps reading order.

#### Only text roles get a separate value call
`ScreenAccessibilityReader.resolve`: Only text roles are worth a separate call for their value.

#### Only a web area's own URL establishes document origin
`ScreenAccessibilityReader.resolve`: A link URL is not the document's origin. Only a web area's
own URL (or the window document) can establish that origin.

#### Only document reads walk children that are out of view
`ScreenAccessibilityReader.resolve`: Only a document read walks children that are out of view.

#### Reversed push so popping from end reads first child first
`ScreenAccessibilityReader.resolve`: Popped from the end, so the first child is read first.

#### AX is async to target app; never attach text to another window
`ScreenAccessibilityReader.resolve`: AX calls are asynchronous with respect to the other application.
Never attach one window's text to a different focused window.

#### Single batched attribute call replaces 12-14 round trips per element
`ScreenAccessibilityReader.NodeAttributes`: One element's attributes from a single cross-process call. A walk used
to make 12–14 separate calls per element, each a round trip to the
other app. Attributes the element lacks come back as errors.

#### Decoding half is separate so tests need no target app
`ScreenAccessibilityReader.NodeAttributes.init(names:values:)`: The decoding half, separate so tests can check it without a target app.

#### Chrome exposes frames as web areas; document or outermost is the page
`ScreenAccessibilityReader.pageAddress`: Chrome exposes every frame of a page as its own web area: the page,
about:blank editors, and other sites' embeds. The window's document,
else the outermost web area, is the page; other addresses are kept for
site exclusions instead of making the page's own address unknown.
`webAreaURLs` lists web areas outermost first.

#### about and srcdoc frames take embedder origin; data frames are embedder content
`ScreenAccessibilityReader.pageAddress`: about:blank and about:srcdoc frames take their embedder's
origin, and a data: frame holds content its embedder supplied.

#### blob address carries the origin that created it
`ScreenAccessibilityReader.pageAddress`: A blob: address carries the origin that created it.

#### Chrome reports no focus until read; unknown to plain field keeps read
`ScreenAccessibilityReader.settledFocus`: The focused-field state across one read. Chrome reports no focused
element until reading its page builds its accessibility tree, so an
unknown focus that turns out to be a plain field keeps the read. Any
other change, including into or out of a secure field, discards it.

#### Only inputs hold secrets; secure-looking labels must not flag whole window
`ScreenAccessibilityReader.isTextEntry`: Only an input can hold a secret. The secure-field markers also match
labels and buttons such as a browser's "Connection is secure" site
information or "Manage passwords"; those stay out of captured text but
do not make the whole window count as showing a password field.

#### Unknown unless role read; failed read must never look like plain field
`ScreenAccessibilityReader.secureFieldStatus`: Nil (unknown) unless the role was read and the subrole was read or is
absent; a failed read must never look like a plain field.

### `LokalBot/Services/ScreenMemory/ScreenContextEventMonitor.swift`

#### Coalesce noisy input events off main actor into one callback
`ScreenContextEventCoalescer`: Coalesces noisy global input events away from the main actor. A key-repeat
or trackpad gesture can produce hundreds of events per second; only the
settled boundary is relevant to context capture, so raw events stay on this
private serial queue and at most one main-actor callback is emitted.

#### Monitor never reads key codes, text, mouse position or clipboard contents
`ScreenContextEventMonitor`: Converts coarse interaction boundaries into capture hints. It never reads a
key code, typed string, mouse location, or clipboard contents; only the fact
that typing/scrolling/clicking/copying settled is retained as a trigger name.

#### Global event monitor registered during finishLaunching breaks app mouse events
`ScreenContextEventMonitor.start`: AppState (and therefore this monitor) is built while AppKit is still
inside `finishLaunching`. Registering a global event monitor that
early corrupts this app's own window-server event subscription: its
windows keep rendering and hit-testing, but never receive another
mouse event. Defer installation until the run loop is actually
pumping events (`isRunning` flips after `finishLaunching` returns).

#### Install one turn after launch notification, which never fires again
`ScreenContextEventMonitor.start`: One more turn so `run()` has entered its event loop, then
install unconditionally — the notification never fires again.

### `LokalBot/Services/ScreenMemory/ScreenContextPrivacy.swift`

#### Privacy rules favor false positives; persisted credentials cannot be recalled
`ScreenContextPrivacy`: Deterministic privacy rules applied before screen-derived text reaches FTS,
embeddings, exports, or an external read-only client. The rules intentionally
favor false positives: a redacted capture remains useful, while a persisted
credential cannot be taken back.

#### Only inspected focused windows supply content; missing AX value is unknown
`ScreenContextPrivacy.Observation`: Only a successfully inspected focused window can supply retained
content. A missing AX value is unknown, not evidence of a safe field.

#### Chrome hides focus; capture only while no secure field visible
`ScreenContextPrivacy.focusPermitsCapture`: Whether the focused-field state allows screen capture. Some apps
(Chrome) never expose keyboard focus through Accessibility; for them,
capture only while no secure field is visible in the inspected window,
so sign-in forms stay out of screen memory.

#### allowsUnknownFocus is for screen capture only; dictation needs known focus
`ScreenContextPrivacy.permitsContent`: `allowsUnknownFocus` is for screen capture only. Dictation and other
consumers that act on the focused field keep requiring a known,
non-secure focus.

#### Every window tracked; exclusions and secure fields are the boundaries
`ScreenContextPrivacy.permitsContent`: Every window is tracked, including browser, web-app, and private
windows. App and domain exclusions and focused secure fields are
the boundaries; credential text is redacted separately.

#### Framed pages are captured too, so excluded embed excludes whole window
`ScreenContextPrivacy.permitsContent`: Framed pages' text and pixels are captured with the window, so an
excluded site keeps the whole window out wherever it appears.

#### Unreadable browser address cannot prove exclusion safety; native documents need none
`ScreenContextPrivacy.permitsContent`: A browser with an unreadable address, its own or a framed page's,
cannot establish that it is outside a configured exclusion. Native
documents need no web URL.

#### Page address needed only when a site exclusion is configured
`ScreenContextPrivacy.hasDomainRules`: Whether any site exclusion is configured; only then does a sample or
capture need the page's address.

#### Activity keeps app unless excluded; title dropped only for secure or exclusion risk
`ScreenContextPrivacy.ActivityDisposition`: What activity tracking may store for one sample. Every window keeps
its app name and duration unless the app or its known address is
excluded. The title is dropped only when a secure field is focused or
a configured site exclusion cannot be ruled out; unknown Accessibility
state no longer turns ordinary time into "Private".

#### Password managers never captured regardless of language or editable list
`ScreenContextPrivacy.passwordManagerBundleIdentifiers`: Password managers are never captured, whatever their name in the
user's language ("Passwörter", "Trousseaux d'accès") and whatever the
editable list says.

#### Rule matches display name; dotted rule also matches bundle prefix
`ScreenContextPrivacy.isExcluded`: A rule matches the app's display name. A rule with a dot also matches
that bundle identifier and the ones beneath it ("com.agilebits" covers
"com.agilebits.onepassword7"), which stay the same in every language.

#### Match names too, covering development and channel builds with other bundle IDs
`ScreenContextPrivacy.isBrowser`: Includes development/channel builds with a different bundle ID.

#### Secret names may carry underscore prefixes where word boundary fails
`ScreenContextPrivacy.redactionRules`: The name may carry a prefix ("DB_PASSWORD", "aws_secret_access_key",
"GITHUB_TOKEN"); a word boundary alone never matches after "_".

#### Connection string redaction keeps user and host
`ScreenContextPrivacy.redactionRules`: "postgres://admin:hunter22@db:5432" keeps its user and host.

#### Checksum-validated card and IBAN redaction keeps order and phone numbers readable
`ScreenContextPrivacy.checkedRules`: Numbers whose checksum makes them almost certainly a payment card
(a known issuer prefix and Luhn) or an IBAN (mod 97). The checksum
keeps order, tracking, and phone numbers readable.

#### Accepted issuer prefixes: Visa, Mastercard, Amex, Diners, Discover, JCB, UnionPay
`ScreenContextPrivacy.isPaymentCardNumber`: Visa, Mastercard, Amex, Diners, Discover, JCB, UnionPay.

#### Strip credentials, queries and fragments; keep path for context
`ScreenContextPrivacy.sanitizedURL`: Removes credentials, queries, and fragments before URL provenance is
persisted. The path is useful context and domain exclusions still work,
while common session tokens never become metadata.

#### Keep file name only; full paths disclose user names and structure
`ScreenContextPrivacy.sanitizedDocumentName`: Full local paths disclose user names and folder structure. The document
name preserves citation context without retaining that provenance.

#### Web addresses are no document name; would keep dropped query and fragment
`ScreenContextPrivacy.sanitizedDocumentName`: A web or app address is kept, sanitized, as the source URL. Its last
path piece is no document name and would keep the query and fragment
("search?q=…", "#inbox") that the source URL drops.

### `LokalBot/Services/ScreenMemory/ScreenImageEmbeddings.swift`

#### Picture vectors for screen search; benchmark, opt-in conditions, pacing, battery limit
`ScreenImageEmbeddings`: Vectors of what retained screen captures show, so screen search finds a
screen by its picture as well as its text. EmbeddingGemma 2's image encoder
runs on the media embedder Files uses (`FileMediaEmbedderRuntime`). A
capture is decrypted in memory, sized for a 280-token budget
(`FileImageSizing`) and never written to disk.

On the 13 October run over a real library, picture vectors found the right
screen first for 71 of 138 queries, against 52 for screen-text vectors and
44 for the shipped search (Benchmarks/search/EmbeddingGemma2/2026-10-13-screen-images).

It runs only while search by meaning is on and pictures are captured (Text
+ visual context), and only once screens have been searched by meaning, so
nobody downloads the image model for a search they never make. A vector
goes with its pixels: retention clears both (`ActivityStore.clearScreenshotPath`),
and deleting a capture deletes both.

The first pass over a library is a big read, so it is paced while the
person uses the Mac (`IndexPacing`), and on battery a pass stops after the
newest few dozen captures: the rest wait for a charger.

#### Changing model, sizing or request shapes re-embeds every capture
`ScreenImageEmbeddings.modelID`: Model, projector, sizing and request shapes. Any change embeds every
retained capture again.

#### On battery a pass reads at most this many captures, newest first
`ScreenImageEmbeddings.batteryLimit`: On battery, a pass reads at most this many captures, newest first.

#### Embed blocks and runs off main actor; end releases model
`ScreenImageEmbeddings.Session`: One pass's embedder: a sized PNG in, a vector out. `embed` blocks; it
runs off the main actor. `end` lets the model go.

#### Decrypts capture pixels off the main actor
`ScreenImageEmbeddings.LoadImage`: Decrypts a capture's pixels into an image; runs off the main actor.

#### On battery with captures left past battery limit
`ScreenImageEmbeddings.PassOutcome.waitingForPower`: On battery, with more left after the newest `batteryLimit`.

#### Enabled when search by meaning is on and pictures captured
`ScreenImageEmbeddings.isEnabled`: Search by meaning is on and pictures are captured.

#### In use once screens have been searched by meaning
`ScreenImageEmbeddings.isInUse`: Screens have been searched by meaning on this library.

#### New captures trigger one batched later pass covering them all
`ScreenImageEmbeddings.capturesDidArrive`: New captures were stored: one batched pass later covers them all.

#### Called at launch or first meaning search to catch up
`ScreenImageEmbeddings.resume`: Launch, or the first search by meaning: catch up on what is waiting.

#### Settings, recording, power or heat changes stop or schedule passes
`ScreenImageEmbeddings.conditionsDidChange`: Settings, recording, power or heat changed.

#### Embeds newest first until none left, paused, failure, or battery limit
`ScreenImageEmbeddings.runPass`: Embeds retained captures without a picture vector, newest first, until
none are left, a pause condition appears, the embedder fails, or, on
battery, `batteryLimit` captures are through.

#### Mark unreadable captures so they are not retried every pass
`ScreenImageEmbeddings.ItemResult.unreadable`: The pixels could not be read or the server rejected them: marked,
so a broken capture isn't tried on every pass.

#### Never store vector for pixels deleted or replaced during embedding
`ScreenImageEmbeddings.performPass`: The pixels may have been deleted or replaced while
this batch was embedded: never store a vector for
pixels that are gone.

### `LokalBot/Services/ScreenMemory/ScreenSearch.swift`

#### Keyword and meaning matches ranked like DigUp; shared by Ask, Quick Recall, assistant
`ScreenSearch`: Ranked screen search: keyword hits from the screen-text index and meaning
matches from text and picture vectors (`EmbeddingIndex.screenMeanings`),
ranked together the way DigUp ranks files (`ScreenSearchRanking`). Ask,
Quick Recall and the assistant's `search_screen` share it.

#### Only first 100 OR-fallback hits get full text read for coverage
`ScreenSearch.fullTextLimit`: How many OR-fallback hits get their full text read to count the
query's words; the rest are counted from their snippet and title.

#### Coverage is share of query words; all-words hits hold all; stopword queries count all
`ScreenSearch.coverage`: The share of the query's words each keyword hit holds. Hits found by
the all-words search hold them all; for the OR fallback the capture's
text is read. A query of only stopwords counts every hit it found.

#### Meaning-only hits get best passage or window title; fetched once
`ScreenSearch.ranked`: Keyword hits and meaning matches as one ranked list. A capture found
only by meaning gets its text's best passage as the snippet, or its
window title when it has no text (a picture-only match), and is marked
`isSemantic`. `screenshots` and `texts` are asked once each, for the
captures found by meaning alone (Ask asks off the main actor).

### `LokalBot/Services/ScreenMemory/ScreenSearchRanking.swift`

#### DigUp-style ranking replaces reciprocal-rank fusion, which hurt descriptive queries
`ScreenSearchRanking`: Screen search ranking the way DigUp ranks files (`Searcher.search`,
github.com/ARahim3/DigUp, MIT): meaning is how far a capture stands out for
this query among all stored vectors of its kind, and the query's words add a
bonus that grows with how many of them the capture holds.

It replaces reciprocal-rank fusion. Fusion gave the long OR-fallback keyword
list (any one word) the same weight as meaning, and on descriptive queries
it pulled the right screen down: 44 of 138 found first against 52 for text
meaning alone (Benchmarks/search/EmbeddingGemma2/2026-10-13-screen-images). Here a
capture qualifies by standing out in meaning or by holding at least half of
the query's words, so one common word can't outrank a clear meaning match,
while all the words of an exact lookup ("INV-2041") usually win.

#### 1-based place in keyword results, if words found it
`ScreenSearchRanking.Ranked.keywordRank`: 1-based place in the keyword results, if the words found it.

#### Meaning needs z of 2 above query average, giving honest nothing-found
`ScreenSearchRanking.zGate`: How far above this query's average a capture must score to count by
meaning: DigUp's gate, which also gives an honest "nothing found".

#### Fewer than 20 vectors of a kind use all-kind average
`ScreenSearchRanking.modalityMinimumCount`: Fewer vectors of a kind than this take the average of all kinds.

#### Center scores per kind; use all vectors so scale ignores filters
`ScreenSearchRanking.meaning`: Each capture's best vector on this query's scale. Scores are centred per
kind first, because text scores higher than pictures for the same topic
(DigUp measured 0.75–0.86 against 0.67–0.78), then put on one z scale.
Pass every stored vector, not only those in the date or app scope: the
scale must not depend on the filter.

#### Terms are DigUp's content words without stopwords and kind words
`ScreenSearchRanking.terms`: The query's content words, as DigUp's keyword search sees them:
normalized, with stopwords and kind words ("screenshot") dropped.

#### Exact lookup when every word carries digits; words outweigh meaning
`ScreenSearchRanking.isLookup`: An exact lookup: every word carries digits, like an invoice number or a
version. Words then count for more than meaning (DigUp's `isLookup`).

#### Coverage ignores case and diacritics; word matches as prefix of longer word
`ScreenSearchRanking.coverage`: The share of `terms` that occur in any of `texts`, ignoring case and
diacritics as the screen-text index does. A word matches as the start
of a longer word ("deploy" in "deployment"), as keyword search does.

#### Qualify by z or half the words; lookup doubles word weight; tie order
`ScreenSearchRanking.rank`: Captures that stand out in meaning (z ≥ `zGate`) or hold at least half
of the query's words, best first. Score: meaning z plus a word bonus
that grows with coverage; for a lookup, words weigh double and meaning
half. Ties go to word matches, then to keyword order, then to the newer
capture.

### `LokalBot/Services/ScreenMemory/ScreenshotService.swift`

#### Kept as free function so call sites unchanged while routing to AppLog
`lokalbotLog`: Plain-line diagnostics, now routed through swift-log (`AppLog`) which fans
out to stdout + the rotating `<storage>/debug.log`. Kept as a free function
so every existing call site stays unchanged.

#### Raw values are stored in capture_trigger column and shown to consumers
`ScreenCaptureTrigger`: What caused a screen context capture. Raw values are stored in the
`screenshots.capture_trigger` column and shown to search/chat consumers.

#### Click retains no coordinates or button identity
`ScreenCaptureTrigger.click`: A click completed; coordinates and button identity are never retained.

#### Typing pause observes no key code or typed string
`ScreenCaptureTrigger.typingPause`: Typing stopped briefly; no key code or typed string is observed here.

#### Scroll settled retains no deltas or pointer position
`ScreenCaptureTrigger.scrollSettled`: Scrolling settled; deltas and pointer position are not retained.

#### Clipboard trigger reads generation only, never contents
`ScreenCaptureTrigger.clipboardChange`: The pasteboard generation changed; clipboard contents are never read.

#### Idle fallback when nothing captured for configured interval
`ScreenCaptureTrigger.interval`: Idle fallback: nothing captured for the configured interval.

#### Unchecked Sendable because older SDKs do not mark CGImage Sendable
`ScreenThumbnailImage`: A fully decoded, size-bounded image that can safely cross back from the
detached thumbnail worker. CGImage is immutable, but older SDK annotations
do not consistently mark it Sendable.

#### Event captures cooled down; interval only after idle window; manual always wins
`ScreenCapturePolicy`: Pure rate-limiting policy for event-driven capture. Event triggers respect
a short cooldown so interaction bursts cannot spam extraction; the interval
trigger fires only after the user-configured idle window; manual always wins.

#### Includes dedup-confirmed unchanged screens, not just stored captures
`ScreenCapturePolicy.lastCheck`: When a capture (or dedup-confirmed unchanged screen) was last recorded.

#### Retention pass at most daily unless privacy change forces; pure for tests
`ScreenshotRetentionSchedule`: Bounds retention work to once per day during normal operation while still
allowing explicit privacy changes to force an immediate pass. Keeping this
policy pure makes sleep/wake and clock-adjustment behavior deterministic in
tests; the service owns only the lightweight timer that asks it periodically.

#### Retry slightly under check interval so due-in-an-hour does not slip
`ScreenshotRetentionSchedule.retryInterval`: How soon a pass that reported an error runs again: by the next check.
It is a little under the check interval, because the check after a
failed pass comes exactly one interval later or a few minutes late,
and "due in an hour" then slipped to the check after that.

#### Limit failed-pass retries so failures don't repeat library-wide pass hourly
`ScreenshotRetentionSchedule.maximumRetries`: Failed passes retried in a row before the daily rhythm resumes. A
failure that never clears must not repeat the library-wide pass, and
the memory it revokes, every hour.

#### Marker file stops every launch re-running library-wide pass
`ScreenshotRetentionSchedule.markerURL`: Where the last pass is remembered. Without it every launch ran a
library-wide pass on the main actor and revoked derived journals and
Dream reports again, however recently the previous pass had run. Nil
keeps the schedule in memory.

#### Failed pass retries in an hour so expired data doesn't linger a day
`ScreenshotRetentionSchedule.passFailed`: The pass `shouldPrune` allowed left something undone (a busy database,
a file that would not delete). Expired screen data would otherwise
stay a whole day longer, across relaunches too, so the next pass is
due in an hour.

#### Marker write is best effort; failure only means next launch prunes again
`ScreenshotRetentionSchedule.record`: Best effort: a failed write only means the next launch prunes again.

#### ScreenCaptureKit objects reduced to value types so selection is unit-testable
`ScreenshotCaptureLayout`: Pure capture-layout selection. ScreenCaptureKit objects cannot be created
in unit tests, so production metadata is reduced to these value types before
binding pixels to the one focused window whose privacy metadata was read.

#### AX frame identifies window; SCK title lags in Chrome
`ScreenshotCaptureLayout.selection`: The Accessibility-checked frame identifies the window. The window
title ScreenCaptureKit reports can lag the live one (Chrome), so a
title only tells apart windows that share that exact frame.

#### Never guess another window or fall back to display when binding fails
`ScreenshotCaptureLayout.selection`: Never guess another window or fall back to the display when AX
cannot bind the source.

#### Mismatch summary uses counts only, never titles
`ScreenshotCaptureLayout.mismatchSummary`: Why `selection` found no single window, as counts only: never titles.

#### Bound first ScreenCaptureKit allocation so retina displays don't spike memory
`ScreenshotCaptureDimensions`: ScreenCaptureKit allocates the requested frame before the background worker
can downsample it. Bound that first allocation so large/retina displays do
not briefly consume hundreds of megabytes on every context event.

#### Gate prevents overlapping ScreenCaptureKit requests from clicks and sampler events
`ScreenshotCaptureGate`: Main-actor gate that prevents repeated menu clicks and simultaneous sampler
events from launching overlapping ScreenCaptureKit requests.

#### Names failed precondition without window contents for debug log
`ScreenshotService.accessibilitySkipReason`: Names which capture precondition failed, without window contents, so
a skipped app can be diagnosed from the debug log.

#### Set on main actor before recheck, read on worker; captures serial
`RecheckNodeLimit`: Set on the main actor right before a recheck starts, read on the
reader's worker; captures run one at a time.

#### Unchecked Sendable: CGImage is immutable but not Sendable on all SDKs
`ScreenshotProcessingRequest`: Immutable inputs passed across the main-actor/worker boundary. `CGImage` is
an immutable Core Foundation value and is safe to read concurrently, but it
is not annotated `Sendable` by every supported SDK, so the wrapper records
that invariant explicitly.

#### Injectable operations for test determinism; recognizeText runs on recognition queue
`ScreenshotProcessingDependencies`: Injectable image/file operations keep the serial worker deterministic under
test without weakening the production path. Every closure runs only for
`ScreenshotProcessingWorker`; `recognizeText` runs on the text-recognition
queue, which the worker waits for.

#### Actor order and no suspension points keep hash comparison and writes serial
`ScreenshotProcessingWorker`: CPU- and I/O-heavy screenshot processing. Actor isolation gives captures one
total order, so the content hash always compares with the last image that was
successfully encrypted and written. There are no suspension points inside
`process`, preventing actor reentrancy from interleaving two capture writes.

#### Missed OCR keeps accessibility text and no pixels, which are unchecked
`ScreenshotProcessingWorker.StoredCapture.missedOCR`: Text recognition was asked for the image's text and did not answer
in time. The capture holds what Accessibility read, and no pixels:
nothing checked them for credentials.

#### Nothing readable means nothing kept; same frame is read again
`ScreenshotProcessingWorker.Outcome.unreadable`: Accessibility read no text and recognition gave no answer: there
is nothing to keep. The same frame is read again next time.

#### 20 s limit; 99.9% of 23,000 captures recognized within 15 s
`ScreenshotProcessingWorker.textRecognitionLimit`: How long a capture waits for the text in its pixels. Of 23,000 captures
in one Mac's log, 99.9% had it within 15 s.

#### Skip near-duplicate frames with same text; about 7% of captures were
`ScreenshotProcessingWorker.lastStored`: The last stored capture, for skipping a frame of the same window that
differs only by a blinking caret or similar: same text, and at most
`nearDuplicateDistance` bits apart visually. About 7% of a real
library's captures were such frames, each encoded, written and indexed.

#### Capture never waits on recognition past limit; hung request blocked later captures
`ScreenshotProcessingWorker.process`: A capture never waits for recognition past its limit: one request
that did not return held every capture after it (2026-11-09).

#### Drop whole pixels if credential found or text recognition never read them
`ScreenshotProcessingWorker.process`: If extracted text reveals a credential, retain only its deterministic
redacted form. Dropping the entire pixel payload is safer than trying
to infer a precise on-screen rectangle from a text-only observation.
Pixels whose text recognition never read are unchecked, and dropped
too: thin accessible text says little about what they show.

#### Actor thread waits for recognition so captures cannot interleave
`ScreenshotProcessingWorker.recognizeText`: The text in `image`, or nil when recognition gave no answer in time.
The actor's thread waits here, as it always has for the recognition
itself, so two captures still cannot interleave.

#### Failed SQLite commit lets identical screen retry
`ScreenshotProcessingWorker.discardStored`: A file write is not a completed capture until its SQLite rows commit.
Let an identical screen retry when that later persistence step fails.

#### dHash groups similar frames; worker's tighter distance skips only same-text autos
`ScreenPerceptualHash`: 64-bit difference hash (dHash) for visually similar-frame detection.
Unlike a byte SHA, this remains stable across tiny cursor/animation/codec
changes. Stored captures within `defaultDistanceThreshold` share a
similarity group. The worker above skips an automatic capture only when it
has the same text and is within its own, tighter `nearDuplicateDistance`;
explicit manual captures always bypass that decision.

#### Image transforms live outside MainActor so Vision and ImageIO avoid SwiftUI executor
`ScreenshotImageProcessing`: Pure image transforms used by the background worker. Keeping these outside
the `@MainActor` service is what makes Vision, Core Graphics, and ImageIO run
away from SwiftUI's executor.

#### Exact hash only; perceptual hash must not discard changed OCR evidence
`ScreenshotImageProcessing.contentHash`: Hash the downscaled pixels before HEIC/OCR. Only byte-identical frames
are suppressed here; the much coarser perceptual hash must never discard
changed OCR evidence, so the worker uses it only between captures whose
text is identical.

#### Hash pixels in place to avoid copying about 6 MB
`ScreenshotImageProcessing.contentHash`: Hash the pixels in place rather than copying ~6 MB into a buffer.

#### Accurate level because fast is useless on dense UI text
`ScreenshotImageProcessing.recognizeText`: .fast is useless on dense UI text

#### Language correction off so code and URLs are not corrected
`ScreenshotImageProcessing.recognizeText`: code/URLs shouldn't be "corrected"

#### Automatic language detection fixed Chinese and Japanese OCR noise
`ScreenshotImageProcessing.recognizeText`: Without this Vision reads with its en-US default: Chinese and
Japanese came back as noise (0.00 vs 0.98 character similarity),
while English, German, and Serbian Latin/Cyrillic were unchanged.

#### Accessibility text first, OCR only if thin; privacy checks fail closed
`ScreenshotService`: Event-driven screen context: read bounded visible Accessibility text first,
optionally pair it with an encrypted focused-window image, and invoke local
OCR only when the accessible text is thin. Captured text is indexed; pixels
and, by default, text are retention-pruned. Privacy checks fail closed for
idle/lock states, excluded sources, secure fields, and detected credentials.

#### AppState revokes derived evidence first; throwing leaves pixels and text untouched
`ScreenshotService.mutateEvidence`: AppState revokes derived evidence before the synchronous deletion runs.
Throwing here leaves both pixels and retained text untouched.

#### Called after searchable text stored so AppState queues semantic search
`ScreenshotService.onTextStored`: Called after a capture stored searchable text, so AppState can queue
it for semantic search.

#### Capture's own read sets how many elements recheck inspects
`ScreenshotService.recheckNodeLimit`: The capture's own read sets how many elements its recheck inspects.

#### Captures ride sampler's 5 s boundary events instead of a fixed clock
`ScreenshotService.start`: Event-driven path: the sampler already detects app/window boundaries
every 5 s; captures ride those events instead of a fixed clock.

#### 60 s idle tick captures only after configured interval of nothing
`ScreenshotService.start`: Idle fallback: a 60 s tick that only captures when nothing has been
captured for the configured interval (the old slider semantics
become "at least every N minutes").

#### First capture shortly after launch, not a full interval later
`ScreenshotService.start`: First capture shortly after launch, not a full interval later.

#### Retention maintenance stays alive even when capture is disabled
`ScreenshotService.restart`: Retention is a privacy lifecycle, not a capture lifecycle. Keep its
daily maintenance alive even when tracking/capture is disabled.

#### Log repeated skip reason once so log keeps lines explaining missing captures
`ScreenshotService.lastRepeatedSkip`: Every click, typing pause and scroll ends in `captureIfAppropriate`,
and while capture is off, paused, held back by a recording or cooling
down, each one is skipped for the same reason. That reason is logged
once until a capture gets past these checks, so the log keeps the
lines that explain a missing capture.

#### Recheck needs no text, only what privacy checks read
`ScreenshotService.capture`: The recheck needs no text, only what the privacy checks below read.

#### Discard pixels if focused source or privacy state changed during capture
`ScreenshotService.capture`: The focused window, browser URL or secure-field state can change
while ScreenCaptureKit suspends. Discard its pixels on any change.

#### Worker keeps hash, text selection, OCR, redaction and write serial off main
`ScreenshotService.capture`: The worker keeps hash → text-source selection → optional OCR →
redaction → encryption/write serial and off the main actor.

#### Processing stages encrypted bytes in memory so revocation leaves no file
`ScreenshotService.capture`: Processing stages encrypted bytes only in memory. Revocation
cannot leave a file behind while the worker finishes its work.

#### Short synchronous commit cannot interleave with main-actor settings change
`ScreenshotService.capture`: This short synchronous commit cannot interleave with a main-
actor settings/pause change between the check and persistence.

#### Manual capture is the one non-onboarding place allowed to prompt
`ScreenshotService.captureNow`: Manual trigger (menu bar) — the one non-onboarding place allowed to
prompt, because the user explicitly asked for a capture.

#### Nonisolated pure decrypt so thumbnail worker does I/O and AES off main
`ScreenshotService.decryptedData`: Decrypt a stored screenshot to raw image bytes. `nonisolated` and pure
given the key, so the thumbnail worker can run file I/O and AES opening
off the main actor before immediately downsampling the result.

#### Immediate cache option finishes decoding on worker, not during SwiftUI draw
`ScreenshotService.downsampledThumbnail`: Decode only the pixels needed by the destination view. The immediate
cache option forces HEIF/PNG decoding to finish on the detached worker
instead of being deferred until SwiftUI draws on the main actor.

#### Callers with metadata skip SQLite lookup; only bounded CGImage returns to main
`ScreenshotService.decryptedThumbnail`: Callers that already hold screenshot metadata avoid another synchronous
SQLite lookup. File I/O, AES opening, and image decoding all stay off the
main actor and only the bounded CGImage returns to SwiftUI.

#### Delete pixels first, then row and linked OCR, bookmark and vector atomically
`ScreenshotService.deleteCapture`: User-requested deletion removes pixels first, then the screenshot row
and all linked OCR, bookmark, and semantic-vector state atomically.

#### Keep successful deletions consistent on failure; saved moments need explicit scope
`ScreenshotService.applyCaptureDeletionReview`: Manual cleanup keeps successful row/file deletions consistent even if
another item fails. Saved moments require an explicit reviewed scope.

#### Files past retention deleted; OCR text follows unless user keeps it
`ScreenshotService.applyRetentionReview`: Files older than the retention window are deleted. OCR text follows
the same cutoff unless the user explicitly opted into keeping it —
screen text can be as sensitive as the pixels it came from.
Execute only the reviewed data set. Regular maintenance is separate.

#### Re-check saved moments immediately before irreversible file steps
`ScreenshotService.applyRetentionReview`: Re-check saving immediately before the irreversible file steps. The
pass is synchronous on the main actor, so one read stays current.

#### Hourly timer calls it; real pass runs at most daily unless forced
`ScreenshotService.runRetentionMaintenanceIfNeeded`: Called by the hourly maintenance timer. The schedule guarantees the
actual filesystem/SQLite pass runs at most daily unless a retention
reduction or explicit privacy action forces it.

#### Hand-off packages have 7-day limit; daily pass covers idle days
`ScreenshotService.runRetentionMaintenanceIfNeeded`: Hand off packages have their own 7-day limit. Writing one prunes the
folder; this daily pass covers the days when nothing is handed off.

#### Establish affected timestamps before revoking; failed read must not look empty
`ScreenshotService.performRetentionPrune`: Establish the exact affected source timestamps before revoking
memory or removing files. A failed read must never look empty.

#### Single saved-moments read stays current since main actor is blocked
`ScreenshotService.performRetentionPrune`: One read of saved moments; nothing else runs on the main
actor until this pass returns, so it stays current.

#### Delete only reviewed IDs; broad cutoff could remove unrevoked evidence
`ScreenshotService.performRetentionPrune`: Delete only the reviewed IDs; a broad cutoff query could
remove additional evidence whose days were not revoked.

#### Keep failed file references for retry; text follows own retention
`ScreenshotService.performRetentionPrune`: Preserve failed file references for retry;
text still follows its own retention policy.

#### Per-install AES-256 key in Keychain, shared with chat history sealing
`ScreenshotService.encryptionKey`: Per-install AES-256 key in the user Keychain (design §3.4), via the
shared scheme also used to seal chat history.

### `LokalBot/Services/ScreenMemory/TextRecognitionQueue.swift`

#### Serialize Vision text recognition with time limits after a 2026-11-09 stall
`TextRecognitionQueue`: Runs every Vision text-recognition request in the app, one at a time on its
own queue, and lets no caller wait past its time limit.

Vision sends all text recognition in a process through one serial queue.
On 2026-11-09 a request never came back from it, so every later one waited
behind it for good, and so did its caller: screen capture kept its turn and
stored nothing for the rest of the day, and each caret lookup parked a
Swift concurrency thread until none was left for the rest of the app.

A caller that has no answer at its limit goes on without the text. Work
that had not started is dropped; work under way finishes, since Vision
cannot be interrupted, and its result is thrown away. Once a request has
run for `stallLimit`, recognition counts as stalled: callers are turned
away at once and `observeStalls` hears of it, until that request returns.

#### Urgency picks next request; same urgency runs in order
`TextRecognitionQueue.Urgency`: Which waiting request runs next. Requests of one urgency run in order.

#### Interactive urgency is for typing or dictating callers waiting
`TextRecognitionQueue.Urgency.interactive`: Someone typing or dictating waits for this text.

#### Stall records purpose and elapsed seconds when noticed
`TextRecognitionQueue.Stall`: Recognition that stopped answering: what it was reading for, and how
long that had taken when it was noticed.

#### Job.answered is guarded by the queue lock
`TextRecognitionQueue.Job.answered`: Guarded by the queue's lock.

#### Cancelled callers stop waiting whether cancelled before or after submit
`TextRecognitionQueue.Ticket`: Lets a cancelled caller stop waiting, whether it is cancelled before or
after its request went in.

#### Stall limit 120 s exceeds slowest observed request, 86 s across sleep
`TextRecognitionQueue.defaultStallLimit`: Longer than any request that came back: the slowest in six weeks of
one Mac's log took 86 s, across a sleep.

#### Observer gets stall, then nil on recovery; one observer only
`TextRecognitionQueue.observeStalls`: Called with the stall when recognition stops answering, and with nil
when it answers again. One observer at a time.

#### run returns nil after deadline from now or when stalled; never blocks thread
`TextRecognitionQueue.run`: What `work` returns, or nil when there is no answer within `seconds`
(counted from now, waiting for earlier requests included) or
recognition is stalled. Never blocks the caller's thread.

#### Non-suspending variant blocks its thread for at most the limit
`TextRecognitionQueue.runAndWait`: The same for a caller that cannot suspend. Its thread waits, for at
most `seconds`.

#### Limit's own timer answers; extra second covers a late timer
`TextRecognitionQueue.runAndWait`: The limit's own timer answers; the extra second is for a late timer.

#### One runNext call per request; abandoned requests leave nothing to run
`TextRecognitionQueue.runNext`: One call per request. A request whose caller stopped waiting before its
turn is gone by then, so a call can find nothing to run.

### `LokalBot/Views/ScreenMemory/CaptureDetailView.swift`

#### No identifier on wrapper; each page title carries its identifier
`TimelineContextPanel.body`: No identifier here: this wrapper and the pane around it reach
assistive tools as one element, which keeps the pane's. Each page's
title carries the page's identifier instead.

#### Toggle keeps its name while range controls open; avoids ambiguous second Cancel
`TimelineContextPanel.rawCapturePage`: A toggle, so it keeps its name while the range controls
are open and reads as on; a second "Cancel" beside the
review sheet's own would say nothing about what it cancels.

#### Opening a title row lists the activity behind it for inspection
`TimelineContextPanel.titleRow`: A window or document the session had open, with its time. Opening the
row lists the activity behind the title, which stays inspectable.

#### Nil for a page opened inside another, which has its own back
`TimelinePage.onShowDigest`: Shows "Day digest" above the page. Nil for a page opened inside
another, which has its own way back.

#### Identifier goes on title alone, not copied onto all header text
`TimelinePageHeader.identifier`: Names the page for UI tests. It goes on the title alone: on the whole
header it would be copied onto every text inside.

#### Heading stays plain text; selectable text with header trait loses its words in assistive tools
`TimelinePageHeader.body`: A heading stays plain text: selectable text with the
header trait reaches assistive tools without its words.

#### Full phrase is tooltip and VoiceOver label; destination alone is visible
`TimelineBackLink.label`: "Back to work session": the full phrase is the tooltip and the
VoiceOver label, and the destination alone is the visible text.

#### Preview stays short at six rows; the meeting has the rest
`TimelineMeetingPreview.rowLimit`: The preview stays short; the meeting has the rest.

#### Read the saved summary once per render for recap and empty state
`TimelineMeetingPreview.body`: One read per render: the recap and the empty state both need it.

#### Show recap only since decisions and actions follow as panels
`TimelineMeetingPreview.body`: The recap only: decisions and actions follow as their own
panels, so the full summary would repeat them.

#### Count is all decisions; preview lists only the first few
`TimelineDecisionsPanel.count`: The meeting's decisions in all; the preview lists the first few.

#### Recorded actions come from commands run; agent's own report omitted as only a claim
`TimelineAgentPanel`: What the agents did in a work session, one task after another: the
request that started it and the pull requests and commits it recorded,
with when it ran in the panel's footer. Recorded actions come from the
commands the agent ran; its own report is left out because it is only a
claim.

#### Task named like its session needs no second title
`TimelineAgentPanel.sessionTitle`: One task named like its session needs no second title.

#### Show at most three pull request links as repository #number
`TimelineAgentTaskBlock.links`: The pull requests the agent session linked, at most three, as
"repository #number".

### `LokalBot/Views/ScreenMemory/CaptureRangeDeletionView.swift`

#### Range times snap to scenes; review sheet lists exact removals before delete
`CaptureRangeDeletionView`: Deletes the screen captures retained in a time range of one day. Times snap
to captured scenes, and a review sheet lists exactly what will be removed
before anything is deleted. The page's "Delete screen moments…" button
opens and closes it.

### `LokalBot/Views/ScreenMemory/CaptureView.swift`

#### Timeline groups blocks into work sessions; raw activity stays under All captured activity
`CaptureModel`: The Timeline section groups low-level capture blocks into human-scale Work
sessions and interleaves meetings as first-class events. The lossless raw
activity remains available under All captured activity.

#### Set agentBursts before blocks, whose change recomputes sessions from both
`CaptureModel.agentBursts`: The day's settled coding-agent bursts. Set before `blocks`, whose
change recomputes the sessions from both.

#### Project split is empty without coding-agent evidence
`CaptureModel.projectSplit`: Tracked time by project; empty without coding-agent evidence.

#### Scheduled agent runs are left out of day outcomes like sessions
`CaptureModel.dayOutcomes`: What the day's agents recorded, scheduled runs left out like in the
sessions.

#### Clear previous day immediately and publish only the latest load
`CaptureModel.selectDay`: Clear the previous day immediately, then publish only the latest load.

#### Refresh without resetting generation state or hiding last generation error
`CaptureModel.refreshOverview`: Updates a mounted overview without resetting its generation state or
hiding an error from the last explicit generation attempt.

#### Re-read blocks after generation because it takes a minute and earlier blocks are stale
`CaptureModel.generateDigest`: Read now, not before the model ran: generation can take a
minute, and blocks from before it replaced newer ones.

#### Digest is already autosaved to journal/\<date>.md; export is a shareable copy
`CaptureModel.exportDigest`: Export the digest to a user-chosen `.md` file via the standard save
panel. The digest is already auto-saved to `journal/<date>.md`; this
drops a shareable copy wherever the user picks.

#### Refresh every 30 seconds while a recording grows
`TimelineContentView.body`: A recording grows; its row and bar follow it.

#### A day with expired captures can still have its digest
`TimelineContentView.dayBody`: A day whose captures have expired can still have its digest.

#### Native split; initial rail width follows window and text size, then remembered
`TimelineContentView.dayBody`: A native split, like Meetings and Actions: drag the divider to give
the rail more or less room. Its first width follows the window and
the text size; after a drag the split remembers the width.

#### Keep pane size independent of page intrinsic width so selecting does not re-divide split
`TimelineContentView.dayBody`: Keep the pane's size independent of the page's intrinsic
width so selecting a session cannot re-divide the split.

#### Without system title, add spacer so actions sit at trailing edge
`TimelineContentView.toolbar`: Without the system title nothing pushes the actions to the
trailing edge, so they sat against the date.

#### Selection lives in CaptureModel and app meeting selection to survive page visits
`TimelineSelection`: Reads and changes what the rail has selected. The selection lives in the
shared `CaptureModel` and the app's meeting selection, so it survives a
visit to another page.

#### Menu observes the sampler itself because it publishes too often for the page
`TimelineDayMenu`: The … menu: write, update or rewrite the digest, copy or export it, pause
or resume day memory, and reload the day. It observes the sampler itself,
which publishes too often for the whole page to follow.

#### Meetings get their own lane so they never occlude overlapping activity blocks
`CaptureTrackView`: Raw vertical, hour-indexed track. Meetings get a
dedicated teal lane on the left edge of the block area so they never
occlude the activity blocks they overlap (a meeting and its app's
activity cover the same minutes); activity blocks keep the remaining lane
width. With no meetings, activity blocks span the full lane as before.

### `LokalBot/Views/ScreenMemory/ExclusionRulesEditor.swift`

#### Use plain symbol fallback; an empty rounded square read as a checkbox
`ExclusionRulesEditor.ruleIcon`: The real app icon when LokalBot can resolve it; a plain symbol otherwise.
An empty rounded square read as an unchecked checkbox.

#### Use bundle identifier since file name differs from running name in some languages
`ExclusionRulesEditor.chooseApplication`: The file name ("Passwords") is not the name the app runs under in
every language ("Passwörter"); its bundle identifier is.

### `LokalBot/Views/ScreenMemory/ScreenImageViewer.swift`

#### Full-resolution pixels stay in memory only; nothing decrypted is written to disk
`ScreenImageViewer`: Full-resolution pixels live only in this sheet's memory. Closing releases
the decoded image; no decrypted file is exported or written to disk.

### `LokalBot/Views/ScreenMemory/ScreenMemoryViews.swift`

#### Bounded NSCache of downsampled pixels; encrypted file stays source of truth
`ScreenThumbnailCache`: Session-local cache for bounded, downsampled screen-memory pixels. The
encrypted file stays the source of truth and NSCache can evict under memory
pressure instead of retaining every full-resolution capture indefinitely.

#### Pixels load via ScreenshotService so views never see encrypted file paths
`ScreenThumbnailView`: A reusable private screenshot thumbnail. Pixel loading goes through
`ScreenshotService`, so views never learn or expose an encrypted file path.

#### Render pixels in an overlay so fill crops cannot inflate layout size
`ScreenThumbnailView.body`: The pixels render in an overlay: a `.fill` crop wider than the
proposed width must never inflate this view's layout size, or the
centered overflow paints over horizontal neighbors. Out-of-bounds
paint ends at the clip shape instead.

### `LokalBotTests/Models/ScreenMemory/CaptureStateTests.swift`

#### A Timeline block selection lingers in shared model; Meetings must show empty state
`CaptureStateTests.testStaleBlockSelectionIgnoredWhereBlocksAreNotShown`: A block picked in Timeline lingers in the shared model; on a surface
without a block list (Meetings) it must not outrank the empty state.

### `LokalBotTests/Models/ScreenMemory/CaptureTrackItemTests.swift`

#### A just-started meeting gets a minimum 60 s span, never zero height
`CaptureTrackItemTests.testLiveMeetingGetsMinimumVisibleSpan`: A meeting that just started must not produce a zero-height block.

### `LokalBotTests/Models/ScreenMemory/RetentionReviewTests.swift`

#### 2026-10-01 scale check: startup sweep blocked main thread 2.3 s, one revocation per row
`RetentionReviewTests.testScheduledSweepRevokesEachDayOnceRatherThanEachRow`: Nightly scale check 2026-10-01: the startup sweep blocked the main
thread for 2.3 s on a 180-day library, in part by handing evidence
revocation one date per row (101,521 for 166 days).

#### Every fifth block runs 30 hours crossing local midnights
`RetentionReviewTests.testDistinctEvidenceDaysInvalidateTheSameLocalAndUTCDays`: Every fifth block runs for 30 hours and crosses local midnights.

### `LokalBotTests/Services/ScreenMemory/ScreenContextPrivacyTests.swift`

#### Token-shaped literals assembled at run time so source holds none
`ScreenContextPrivacyTests.testRedactsEnvStyleNames`: Assembled at run time so the source never holds a token-shaped literal.

#### Chrome exposes window titles and text but not keyboard focus
`ScreenContextPrivacy.permitsContent`: Chrome exposes window titles and text but not keyboard focus.

#### Chrome exposes every frame as a web area; page address must survive
`ScreenAccessibilityReader.pageAddress`: Since the 2026-09-24 privacy fixes, any second web area or one without
an address made the page's own address unknown. Chrome exposes every
frame as a web area, so almost no Chrome capture kept its URL.

#### Unreadable subrole leaves secure-field state unknown, never plain
`ScreenAccessibilityReader.secureFieldAttributes`: Walks read each element's attributes in one call; an attribute the
element lacks comes back as an error value. A subrole that could not be
read must leave the secure-field state unknown, never plain.

#### Text reads are skipped where visible-text policy would drop them
`ScreenVisibleTextPolicy`: Text reads are skipped where the visible-text policy would drop them.

#### Own-app AX queries run in-process off main actor and trap; never resolve LokalBot
`ScreenAccessibilityReader`: macOS answers an app's accessibility queries about itself in-process on
the calling thread, which runs SwiftUI off the main actor and traps.
Sampling while LokalBot is frontmost must never reach the resolver.

### `LokalBotTests/Services/ScreenMemory/ScreenImageSearchTests.swift`

#### Picture vectors never outlive pixels and rank with text and keyword hits
`ScreenImageEmbeddings`: Picture vectors for retained screen captures: what is embedded, that a
vector never outlives its pixels, and how text and picture vectors rank
together with the keyword hits.

#### Retention removes file and clears path, row stays; vector leaves
`ScreenImageEmbeddings`: Retention removes the file and clears the path; the row stays.

#### Scoring leaves text unread; ranking reads it once for meaning-only hits
`EmbeddingIndex.screenTexts`: Scoring leaves every capture's text unread; ranking reads it once, for
the captures found by meaning alone, and shows their best passage.

### `LokalBotTests/Services/ScreenMemory/ScreenSearchRankingTests.swift`

#### Meaning scored on query scale per vector kind plus word bonus, DigUp style
`ScreenSearchRanking`: Screen search ranks DigUp's way: meaning on the query's scale per kind of
vector, plus a bonus for the query's words; one common word no longer
outranks a clear meaning match.

#### Text vectors score higher than picture vectors, so scale is per modality
`ScreenSearchRanking.meaning`: Text vectors score higher than picture vectors for the same topic; a
picture that stands out among pictures must still win.

#### OR fallback keyword rows no longer outrank a clear meaning match
`ScreenSearchRanking.rank`: The OR fallback found five captures sharing one of three words; a
sixth capture stands out by meaning alone. Fusion put the keyword
rows first; this ranking puts the meaning match first.

#### DigUp splits INV-2041; a code written as one word is a lookup
`ScreenSearchRanking.isLookup`: DigUp splits "INV-2041" into "inv" and "2041"; a code written as one word is a lookup.

### `LokalBotTests/Services/ScreenMemory/ScreenshotProcessingWorkerTests.swift`

#### Last retention pass persists across relaunch; each pass revoked derived journals
`ScreenshotRetentionSchedule`: Every relaunch used to run a full retention pass, and each pass
revoked derived journals and Dream reports. The last pass now survives
a relaunch, so the daily bound holds across restarts.

#### A failed pass must not count as the day's pass
`ScreenshotRetentionSchedule`: A pass that hit a busy database used to count as the day's pass, so
expired screen data stayed another 24 hours, across relaunches too.

#### Hourly inexact timer needs retry slack so retries do not slip to two hours
`ScreenshotRetentionSchedule.shouldPrune`: The service checks once an hour, and its timer is not exact: the
check after a failed pass arrives about one interval later, a
moment early or a few minutes late. Due "in an hour" was missed by
the early ones, and the retry slipped to two hours.

#### A persistent failure stops being retried hourly
`ScreenshotRetentionSchedule.maximumRetries`: A failure that never clears stops being retried hourly.

#### Shorter retention is explicit privacy action bypassing daily bound; clock rollback must not suspend cleanup
`ScreenshotRetentionSchedule.shouldPrune`: A shorter retention window is an explicit privacy action, so it can
bypass the daily bound. A clock rollback must also not suspend
cleanup until wall time catches up with the old timestamp.

#### Data found after revocation scope was set waits for its own reviewed pass
`ScreenshotRetention revocation`: Data discovered after the revocation scope was established must
wait for its own reviewed pass, not a broader cutoff deletion.

#### Hand-off packages kept 7 days; daily retention must remove old ones
`ScreenshotRetention handoff packages`: A hand off package is kept 7 days. Only writing the next package used
to remove old ones, so after a single handoff the window's text and
screenshot stayed in the library.

#### Expired orphan rows added after review need their own revocation scope
`ScreenshotRetention revocation`: Even expired orphan rows added after review require their own
revocation scope and cannot be swept into this mutation.

#### After rolled-back persistence the same screen must be allowed to retry
`ScreenshotProcessingWorker.discardStored`: ScreenshotService calls this after its SQLite transaction fails and
removes the encrypted file. The same screen must be allowed to retry.

#### 2026-11-09 a hung OCR request kept its turn and skipped later captures
`TextRecognitionQueue`: 2026-11-09: one text-recognition request never returned. The capture
waiting for it kept its turn, so every capture after it was skipped as
already in flight for the rest of the day.

#### Credential check reads pixels' text; without it pixels are not kept
`ScreenshotProcessingWorker`: The credential check reads the pixels' text. Without it they are not kept.

### `LokalBotTests/Services/ScreenMemory/TextRecognitionQueueTests.swift`

#### 2026-11-09 one non-returning OCR request blocked every later one inside Vision
`TextRecognitionQueue`: 2026-11-09: one text-recognition request never returned. Every later one
waited behind it inside Vision, and every caller waited with it.

#### Callers waiting when a stall is noticed are answered then
`TextRecognitionQueue.currentStall`: Waiting when the stall is noticed: answered then, not at its own limit.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
