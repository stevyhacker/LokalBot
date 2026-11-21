# 0008. Screen memory

- Status: Accepted
- Date: 2026-11-20

## Context

Screen memory keeps what the person's screen showed: the focused window's pixels and visible text, read through accessibility and text recognition, filtered by privacy rules, sealed on disk and searchable by words and by meaning. The Mac app does this with ScreenCaptureKit, Accessibility and Vision; the Windows and Linux app with X11, Wayland and GDI capture, AT-SPI and UI Automation, and ocrs, Tesseract or `Windows.Media.Ocr`. These decisions were moved here from code comments when the code stopped carrying comments ([ADR 0001](0001-code-carries-no-comments.md)).

## Capturing the window

### Capture only the focused window, never the display

Only the window in front is captured, never the whole display or a window behind it. On the Mac the ScreenCaptureKit filter holds only the Accessibility-checked window, because display capture, even with app exclusions, can include unchecked background domains. On X11 the client window in `_NET_ACTIVE_WINDOW` is read with `GetImage` rather than the root, so overlapping windows stay out on compositing desktops, and only the part on screen is read.

Where: `LokalBot/Services/Capture/LiveCaptureEnvironment.swift` (`LiveWindowSource.captureImage`), `LinuxWindows/crates/lokalbot-platform/src/screen/mod.rs`, `LinuxWindows/crates/lokalbot-platform/src/screen/x11.rs`.

### Bind the capture to the Accessibility-checked frame and never guess

The Accessibility-checked frame identifies the window. The title ScreenCaptureKit reports can lag the live one (Chrome), so a title only tells apart windows that share that exact frame. When Accessibility cannot bind the source, no other window is guessed and the display is never the fallback.

Where: `LokalBot/Services/ScreenMemory/ScreenshotService.swift` (`ScreenshotCaptureLayout.selection`).

### Discard the pixels when the window changes during the read

The focused window, its browser address or its secure-field state can change while the pixels are read (ScreenCaptureKit suspends meanwhile); any change discards the pixels. The Windows and Linux app also reads the activity sample again, because some backends (the portal) cannot name the window they captured.

Where: `LokalBot/Services/ScreenMemory/ScreenshotService.swift` (`ScreenshotService.capture`), `LinuxWindows/crates/lokalbot-engine/src/screen.rs` (`Worker::capture`).

### Copy Windows windows from the screen with GDI `BitBlt`

On Windows the foreground window's visible bounds (DWM's extended frame, without the drop shadow) are copied from the screen with GDI `BitBlt`: the copy is what the user sees, it works for DirectX and browser windows, and it never waits on the target app, unlike `PrintWindow`, which a hung app can block. The capturing thread is per-monitor DPI aware for each call, so coordinates are physical pixels. Other processes' titles are read without sending `WM_GETTEXT`, so a hung app cannot block that either.

Where: `LinuxWindows/crates/lokalbot-platform/src/screen/win32.rs` (`window_title`).

### On Wayland use `grim` on wlroots, else a non-interactive portal screenshot deleted at once

Wayland has no common way to read another window's pixels. On wlroots compositors (Sway, Hyprland) with `grim` installed, the focused window's rectangle from the compositor's IPC is read with `grim -g` straight into memory. Elsewhere the xdg-desktop-portal Screenshot API runs without a dialog (`interactive: false`): version 3 portals capture just the active window, and otherwise the picture is cropped to the focused window when the compositor reports where it is. The portal saves a copy (often in `~/Pictures`), which is read and then deleted at once.

Where: `LinuxWindows/crates/lokalbot-platform/src/screen/wayland.rs` (`Portal::capture`), `LinuxWindows/crates/lokalbot-platform/src/screen/mod.rs`.

### Do not capture on X11 while a suggestion shows

X11 cannot leave the ghost-text window out of a screen grab (Windows excludes it from capture), so no capture happens while a suggestion shows.

Where: `LinuxWindows/crates/lokalbot-engine/src/screen.rs` (`Worker::capture`).

### Capture hints read no keys, pointer positions or clipboard contents

Interaction boundaries only hint when to capture. The Mac's global event monitor reports when typing, scrolling, clicking or copying settled and keeps only that trigger name. On Windows and Linux the idle timer stands in for all three (input that stops for a moment is one "typing pause" boundary), and a clipboard change is noticed from its sequence number (Windows) or a selection-owner event (X11). No key code, typed string, pointer position, event type or clipboard content is ever read.

Where: `LokalBot/Services/ScreenMemory/ScreenContextEventMonitor.swift` (`ScreenContextEventMonitor`), `LinuxWindows/crates/lokalbot-platform/src/screen/events.rs`.

### Install the Mac event monitor only once the run loop pumps events

`AppState`, and with it this monitor, is built while AppKit is still inside `finishLaunching`. Registering a global event monitor that early corrupts the app's own window-server event subscription: its windows keep rendering and hit-testing but never receive another mouse event. Installation waits until `isRunning` flips after `finishLaunching` returns.

Where: `LokalBot/Services/ScreenMemory/ScreenContextEventMonitor.swift` (`ScreenContextEventMonitor.start`).

## Privacy rules

### Privacy rules favor false positives

Deterministic rules (app and site exclusions, password managers, secret redaction) run before screen-derived text reaches FTS, embeddings, exports or an external read-only client. They err toward false positives on purpose: a redacted capture or title stays useful, while a stored credential cannot be taken back. The Windows and Linux rules are ported from `ScreenContextPrivacy.swift`.

Where: `LokalBot/Services/ScreenMemory/ScreenContextPrivacy.swift` (`ScreenContextPrivacy`), `LinuxWindows/crates/lokalbot-platform/src/privacy.rs`.

### Never capture password managers or credential prompts, and match apps by identifier, not localized name

Password managers and credential prompts are never captured, whatever the editable list says. Apps are matched by an identifier that does not change with the language: on the Mac the bundle identifier, because the file name ("Passwords") is not the name the app runs under in every language ("Passwörter", "Trousseaux d'accès"). Windows and Linux use lowercase desktop-file ids, Wayland app ids, `WM_CLASS` values and Windows executable names; an excluded app is matched by a launcher's window class or command over its window name, and a Windows program by its file name.

Where: `LokalBot/Services/ScreenMemory/ScreenContextPrivacy.swift` (`ScreenContextPrivacy.passwordManagerBundleIdentifiers`), `LokalBot/Views/ScreenMemory/ExclusionRulesEditor.swift` (`ExclusionRulesEditor.chooseApplication`), `LinuxWindows/crates/lokalbot-platform/src/privacy.rs` (`PASSWORD_MANAGER_IDS`), `LinuxWindows/crates/lokalbot-app/src/ui/rule_list.rs` (`application_rule`).

### Store folder rules comma-separated

Folder exclusions are stored with commas between them, like the other two rule kinds, so a folder path cannot contain a comma.

Where: `LinuxWindows/crates/lokalbot-app/src/ui/rule_list.rs` (`RuleKind::Folders`).

### An excluded site in any frame keeps the whole window out

Framed pages' text and pixels are captured with the window, so an excluded site keeps the whole window out wherever it appears.

Where: `LokalBot/Services/ScreenMemory/ScreenContextPrivacy.swift` (`ScreenContextPrivacy.permitsContent`), `LinuxWindows/crates/lokalbot-platform/src/screen/privacy.rs` (`permits_content`).

### A browser whose address can't be read is not shown to be outside an exclusion

A browser with an unreadable address, its own or a framed page's, cannot establish that it is outside a configured site exclusion; on Windows and Linux only its time is kept. Native documents need no web URL.

Where: `LokalBot/Services/ScreenMemory/ScreenContextPrivacy.swift` (`ScreenContextPrivacy.permitsContent`), `LinuxWindows/crates/lokalbot-platform/src/privacy.rs` (`disposition_with_rules`).

### The page address is the window's document, else the outermost web area

Browsers (Chrome) expose every frame as its own web area: the page, `about:blank` editors and other sites' embeds. The window's document, else the outermost web area, is the page; other frames' addresses are kept for site rules instead of making the page's own address unknown. After the 2026-09-24 privacy fixes any second web area, or one without an address, made the page's address unknown, so almost no Chrome capture kept its URL. `webAreaURLs` and `web_area_urls` list web areas outermost first.

Where: `LokalBot/Services/ScreenMemory/ScreenAccessibilityReader.swift` (`ScreenAccessibilityReader.pageAddress`), `LokalBotTests/Services/ScreenMemory/ScreenContextPrivacyTests.swift` (`ScreenAccessibilityReader.pageAddress`), `LinuxWindows/crates/lokalbot-platform/src/screen/privacy.rs` (`page_address`).

### Only a document's own URL establishes the page origin

A link's address is not the page's origin. Only a web area's own URL or the window document establishes it; in UI Automation, a document's own value (its URL in Chromium and Gecko).

Where: `LokalBot/Services/ScreenMemory/ScreenAccessibilityReader.swift` (`ScreenAccessibilityReader.resolve`), `LinuxWindows/crates/lokalbot-platform/src/screen/uia.rs` (`walk`).

### Strip credentials, queries and fragments from stored URLs

URL provenance is stored without credentials, query or fragment. The path stays as useful context and domain exclusions still work, while common session tokens never become metadata.

Where: `LokalBot/Services/ScreenMemory/ScreenContextPrivacy.swift` (`ScreenContextPrivacy.sanitizedURL`).

### Redact only checksum-valid card numbers and IBANs

Numbers are redacted only when their checksum makes them almost certainly a payment card (a known issuer prefix and Luhn) or an IBAN (mod 97); order, tracking and phone numbers stay readable.

Where: `LinuxWindows/crates/lokalbot-core/src/text.rs` (`checked_rules`).

### Drop pixels whose text shows a credential or was never read

When extracted text reveals a credential, only its deterministic redacted text is kept and all the pixels are dropped: that is safer than guessing where on screen the credential was. Pixels whose text recognition never read are unchecked and dropped too, since thin accessible text says little about what they show.

Where: `LokalBot/Services/ScreenMemory/ScreenshotService.swift` (`ScreenshotProcessingWorker.process`), `LokalBotTests/Services/ScreenMemory/ScreenshotProcessingWorkerTests.swift` (`ScreenshotProcessingWorker`), `LinuxWindows/crates/lokalbot-engine/src/screen.rs` (`Processor::process`).

### Read an unparseable screen access marker as the last 7 days

There is no scope (`None`) when screen access is off or the marker cannot be read. An empty (legacy) marker means all retained history, and one that does not parse, including whitespace, means the last 7 days, as in `ScreenMemoryAccessGate.profile`.

Where: `LinuxWindows/crates/lokalbot-core/src/access.rs` (`screen_access_scope`).

## Secure fields and focus

### Never read context from a secure field or while text is selected

Screen and nearby-text context are never read from a secure field or while text is selected.

Where: `LinuxWindows/crates/lokalbot-platform/src/focus.rs` (`FocusSnapshot.blocks_context_capture`).

### An unknown secure-field state is never treated as plain

Text is read only from elements known not to be secure. The state is unknown unless the role was read and the subrole was read or is absent. Walks read each element's attributes in one call, where an attribute the element lacks comes back as an error value, and a subrole that could not be read leaves the state unknown: a failed read must never look like a plain field.

Where: `LokalBot/Services/ScreenMemory/ScreenAccessibilityReader.swift` (`ScreenAccessibilityReader.secureFieldStatus`), `LokalBotTests/Services/ScreenMemory/ScreenContextPrivacyTests.swift` (`ScreenAccessibilityReader.secureFieldAttributes`), `LinuxWindows/crates/lokalbot-platform/src/screen/atspi.rs` (`Walk::visit`).

### Treat every GTK entry as a possible password field

Entries that hide their text (a `GtkEntry` without visibility) still report it in full and as plain text, so no entry is known not to be a password field. An entry that may hide a password counts as one, and with the focus unknown such a window is not captured.

Where: `LinuxWindows/crates/lokalbot-platform/src/screen/atspi.rs` (`Toolkit.reveals_hidden_entries`, `Walk::visit`).

### Capture apps that hide focus only while no password field is visible

Some apps (Chrome) never report keyboard focus through accessibility; they are captured only while no secure field is visible in the inspected window, so sign-in forms stay out of screen memory. This allowance (`allowsUnknownFocus`) is for screen capture only: dictation and other consumers that act on the focused field keep requiring a known, non-secure focus.

Where: `LokalBot/Services/ScreenMemory/ScreenContextPrivacy.swift` (`ScreenContextPrivacy.focusPermitsCapture`, `ScreenContextPrivacy.permitsContent`), `LinuxWindows/crates/lokalbot-platform/src/screen/privacy.rs` (`focus_permits_capture`).

### Keep a Chrome read whose unknown focus settles to a plain field

Chrome reports no focused element until reading its page builds its accessibility tree. An unknown focus that turns out to be a plain field keeps the read; any other change across the read, including into or out of a secure field, discards it.

Where: `LokalBot/Services/ScreenMemory/ScreenAccessibilityReader.swift` (`ScreenAccessibilityReader.settledFocus`).

### Only text inputs count as secure fields

Only an input can hold a secret. The secure-field markers also match labels and buttons such as a browser's "Connection is secure" site information or "Manage passwords"; those stay out of captured text but do not make the whole window count as showing a password field.

Where: `LokalBot/Services/ScreenMemory/ScreenAccessibilityReader.swift` (`ScreenAccessibilityReader.isTextEntry`).

## Reading visible text through accessibility

### Read only visible text, never whole values

Whole `AXValue`, selected-text and help strings, and whole UI Automation control values, can hold a complete hidden document. Only the visible ranges of text controls and the names of labels that lie fully inside their viewport qualify, and nothing is read unless the element is known not to be secure, is on screen and meets the viewport; whether an element can yield text is checked before its text is read from the other app. On Windows the lines of a page that overlap a secure field are dropped too.

Where: `LokalBot/Services/ScreenMemory/ScreenAccessibilityReader.swift` (`ScreenVisibleTextPolicy`), `LinuxWindows/crates/lokalbot-platform/src/screen/uia.rs` (`Node::reads`).

### Never run accessibility queries against LokalBot's own windows

macOS answers an app's accessibility queries about itself in-process, on the calling thread; from the background workers that walks LokalBot's SwiftUI hierarchy off the main actor, which traps, so sampling while LokalBot is frontmost never reaches the resolver. On Windows, UI Automation would answer from LokalBot's own UI thread, which may be waiting on the reading thread. LokalBot never records its own windows anyway.

Where: `LokalBot/Services/ScreenMemory/ScreenAccessibilityReader.swift` (`ScreenAccessibilityReader.isOwnProcess`), `LokalBotTests/Services/ScreenMemory/ScreenContextPrivacyTests.swift` (`ScreenAccessibilityReader`), `LinuxWindows/crates/lokalbot-platform/src/screen/uia.rs` (`UiaReader::read`).

### Check the window and focus again after reading

Accessibility calls are asynchronous with respect to the other app, so the window and focus are checked again after the read; one window's text is never attached to another window or to a different focus.

Where: `LokalBot/Services/ScreenMemory/ScreenAccessibilityReader.swift` (`ScreenAccessibilityReader.resolve`), `LinuxWindows/crates/lokalbot-platform/src/screen/atspi.rs` (`AtspiReader::read_window`).

### Never change Linux accessibility settings or start the accessibility bus

The AT-SPI reader asks for the accessibility bus (`org.a11y.Bus.GetAddress`) only while the bus launcher runs, because asking an unowned name would start it. It never changes accessibility settings (`org.a11y.Status`), so apps that build their tree only for a running screen reader (Chromium, Qt) usually report nothing.

Where: `LinuxWindows/crates/lokalbot-platform/src/screen/atspi.rs` (`accessibility_bus_address`).

### Skip menu items in the AT-SPI walk

A menu's items open in a popup of their own; walking them would spend the node budget on hidden entries (LibreOffice has hundreds).

Where: `LinuxWindows/crates/lokalbot-platform/src/screen/atspi.rs` (`Walk::visit`).

### Find GTK 4's front window by its title

The front top-level window is the one with the ACTIVE state, else the only one titled like the focused window, because GTK 4 marks no window active.

Where: `LinuxWindows/crates/lokalbot-platform/src/screen/atspi.rs` (`AtspiReader::find_window`).

### Treat `G_MININT` coordinates and -1 sizes as no rectangle

GTK reports `G_MININT` coordinates for widgets that are not shown, and applications report -1 sizes; such extents are not taken as a rectangle.

Where: `LinuxWindows/crates/lokalbot-platform/src/screen/atspi.rs` (`rect`).

### Keep one UI Automation client in the MTA and retry its brief refusals

The UI Automation client is kept between reads in the MTA, which stays up while the client exists even when no thread is inside it. UI Automation refuses requests for a moment while another thread of the process is still setting it up, so cache requests are retried for a few milliseconds.

Where: `LinuxWindows/crates/lokalbot-platform/src/screen/uia.rs` (`Client`, `cache_request`).

## Text recognition

### Pick the OCR engine by platform and download models only on request

The Mac runs Vision's `VNRecognizeTextRequest` (`ScreenshotImageProcessing.recognizeText`). Windows and Linux choose from what the computer has (`plan`): ocrs, a pure-Rust engine for unaccented Latin letters, whose two models are pinned by size and SHA-256 and download only when the person asks, into `<library>/models/ocrs/`; Tesseract on Linux for every other script, with the language data it already has or pinned `tessdata_fast` files downloaded only on request into `<library>/models/tesseract/`; and the built-in `Windows.Media.Ocr` on Windows, with the languages installed there.

Where: `LinuxWindows/crates/lokalbot-ai/src/ocr.rs`.

### Keep English with ocrs on Linux and send other scripts to Tesseract

English with the ocrs models stays with ocrs: Tesseract is faster there but reads coloured interfaces worse (83% against 98% measured). Anything else goes to Tesseract, which reads what ocrs can't. Without Tesseract, or the data it needs, whatever can read does so until the person downloads the rest.

Where: `LinuxWindows/crates/lokalbot-ai/src/ocr/plan.rs` (`with_tesseract`).

### Name the recognition languages, with English beside other scripts

With no languages set, Vision reads with its en-US default: Chinese and Japanese came back as noise (0.00 against 0.98 character similarity), while English, German and Serbian Latin and Cyrillic were unchanged. Windows and Linux read the app's language and the system's first one, with English beside any other script, because windows in those languages still show English (on rendered mixed screens Korean read 32% alone and 97% beside English, Arabic 46% and 99%); a script other than Latin comes first.

Where: `LokalBot/Services/ScreenMemory/ScreenshotService.swift` (`ScreenshotImageProcessing.recognizeText`), `LinuxWindows/crates/lokalbot-ai/src/ocr/languages.rs` (`wanted`).

### Run Tesseract over pipes, on one thread, at low priority, with a deadline

Pixels reach Tesseract over a pipe as a grayscale PGM and text comes back over another (`tesseract stdin stdout`); no image file exists at any point and nothing it prints is logged. It runs on one thread, because more threads cost 2.7 times the CPU for a fifth off the time, at low priority, and is killed at a deadline, so a slow read can't take the computer from the person.

Where: `LinuxWindows/crates/lokalbot-ai/src/ocr/tesseract.rs` (`Tesseract::command`).

### Run Tesseract in sparse-text mode

Sparse text suits windows: labels on buttons and in sidebars stay apart, and colourful screens read better (English 77% to 83%).

Where: `LinuxWindows/crates/lokalbot-ai/src/ocr/tesseract.rs` (`Tesseract::command`).

### Enlarge only Chinese, Japanese and Korean, and never pictures

Chinese, Japanese and Korean at 11–14 px read far better at twice the size (Japanese 35% to 96% on a downscaled window) for 20–40% more time; other scripts gain little and take about 80% more, so they stay as they are. A window with at least the `FLAT_SHARE` of one gray is an interface or a page; anything else is a picture and is not enlarged, because enlarging a photo took 6–20 s to find only noise (1–2 s at its size).

Where: `LinuxWindows/crates/lokalbot-ai/src/ocr/tesseract.rs` (`ENLARGED_LANGUAGES`, `FLAT_SHARE`).

### Drop low-confidence words only in pictures

In a picture, words less sure than `PICTURE_CONFIDENCE` are noise: of 364 characters found in pure noise, 9 stay. Real text would lose too much this way (English 99% to 93%), so interfaces and pages keep every word.

Where: `LinuxWindows/crates/lokalbot-ai/src/ocr/tesseract.rs` (`PICTURE_CONFIDENCE`).

### Remove spaces between Chinese, Japanese and Thai words

Tesseract and Windows put spaces between words of Chinese, Japanese and Thai, which are written without them; Vision doesn't, and search needs the words whole. Korean does use spaces, and keeps them.

Where: `LinuxWindows/crates/lokalbot-ai/src/ocr.rs` (`collapse_cjk_spaces`).

### Bound every text recognition with a time limit

Vision sends all text recognition in a process through one serial queue, and on 2026-11-09 one request never came back: every later request and its caller waited for good, so the capture holding its turn left every later capture skipped as "already in flight" for the rest of the day, and each caret lookup parked a Swift concurrency thread until none was left for the rest of the app. Every Vision request now runs one at a time on LokalBot's own queue and no caller waits past its time limit; it goes on without the text, so a window whose accessible text is thin is still captured, and so is the next. Work not yet started is dropped, and work under way finishes, since Vision cannot be interrupted, with its result thrown away. Once a request has run for `stallLimit`, recognition counts as stalled: callers are turned away at once and `observeStalls` hears of it until that request returns.

Where: `LokalBot/Services/ScreenMemory/TextRecognitionQueue.swift` (`TextRecognitionQueue`), `LokalBot/Services/ScreenMemory/ScreenshotService.swift` (`ScreenshotProcessingWorker.process`), `LokalBotTests/Integration/CaptureReplayTests.swift` (`CaptureReplayTests.testCapturesGoOnWhenTextRecognitionNeverAnswers`), `LokalBotTests/Services/ScreenMemory/TextRecognitionQueueTests.swift` (`TextRecognitionQueue`).

## Storing and deleting captures

### Suppress only byte-identical frames, and use the perceptual hash only between identical texts

The downscaled pixels are hashed before HEIC encoding and OCR, and only byte-identical frames are suppressed there. The much coarser perceptual hash that groups near-identical frames must never discard changed OCR evidence, so it is used only between captures whose text is identical.

Where: `LokalBot/Services/ScreenMemory/ScreenshotService.swift` (`ScreenshotImageProcessing.contentHash`), `LinuxWindows/crates/lokalbot-core/src/screen.rs`.

### Seal each frame with a per-install key kept in the credential store

On Windows and Linux each kept frame is `activity/<YYYY-MM-DD>/shots/<epoch ms>-<uuid>.jpg.enc` under the library root, with the day in UTC as on macOS: a JPEG sealed with AES-256-GCM and no associated data, laid out as `nonce (12 bytes) ‖ ciphertext ‖ tag (16 bytes)`, the layout of CryptoKit's `AES.GCM.SealedBox.combined` that the Mac uses for its `.heic.enc` files. The 32-byte key is created once per install and kept in the system credential store (account `screenshot-key`), never in the library; a Mac keeps its own key in its Keychain, so frames captured on one cannot be opened on the other, while their text is unaffected. `screenshots.path` holds the file's absolute path, as macOS writes it, or is empty for text-only moments and after the pixels expire.

Where: `LinuxWindows/crates/lokalbot-core/src/screen.rs`.

### Resolve stored capture paths only inside the library

A stored `screenshots.path` is resolved inside the library root. Paths written on another computer (an absolute Mac or Windows path) are found again under this library's own `activity` folder; text-only moments and anything that would leave the library resolve to nothing.

Where: `LinuxWindows/crates/lokalbot-core/src/screen.rs` (`resolve_capture_path`).

### Keep decrypted pixels in memory only

Thumbnails and full-size viewers decrypt sealed images in memory (thumbnails off the UI thread) and never export or write a decrypted file. Closing a viewer releases the decoded image, and thumbnail textures go when they fall out of the cache or the list's window closes. A moment with no pixels, or one this install can't open, shows a stand-in.

Where: `LokalBot/Views/ScreenMemory/ScreenImageViewer.swift` (`ScreenImageViewer`), `LinuxWindows/crates/lokalbot-app/src/ui/screen_thumbnail.rs`, `LinuxWindows/crates/lokalbot-app/src/windows/screen_image.rs`.

### Delete the file before its rows

A capture's encrypted file is removed first, then its row and every derived and search row in one transaction; a file that cannot be removed keeps its row, so the deletion can be retried. When retention expires pixels, only the row whose file was removed is cleared, so a failed cleanup (permissions, a transient volume error) never loses the sole reference to an encrypted file. Retention does this once per expired capture on the main actor, and a partial path index keeps each call from scanning every capture row.

Where: `LokalBot/Services/Timeline/ActivityTracker.swift` (`ActivityStore.deleteScreenshot`, `ActivityStore.clearScreenshotPath`), `LinuxWindows/crates/lokalbot-core/src/screen.rs` (`Library.remove_screen_moments`), `LinuxWindows/crates/lokalbot-core/src/retention.rs` (`clear_pixels`).

### Remove the picture vector before the pixels' path

A capture's picture vector was made from its pixels and must not outlive them, so it is deleted before the path is cleared. If the update then fails, the pixels stay and are embedded again later.

Where: `LokalBot/Services/Timeline/ActivityTracker.swift` (`ActivityStore.clearScreenshotPath`), `LinuxWindows/crates/lokalbot-core/src/retention.rs` (`clear_pixels`).

### Never store a vector for text or pixels removed while embedding

Retention or deletion may remove a capture's text or pixels while it is being embedded. Pixels deleted or replaced during a batch get no vector, and the exact live text is checked again under the write transaction before text vectors are stored, so a late pass can't bring expired text back.

Where: `LokalBot/Services/ScreenMemory/ScreenImageEmbeddings.swift` (`ScreenImageEmbeddings.performPass`), `LinuxWindows/crates/lokalbot-core/src/screen_search.rs` (`Library.store_screen_vectors`).

### Revoke orphaned screen evidence by exact row identity

Legacy OCR can have `snapshot_id = 0`, or point at a screenshot row that no longer exists; its own timestamp still sets the evidence day. Exact row identities are kept so revocation never authorizes a broad cutoff.

Where: `LokalBot/Services/Timeline/ActivityTracker.swift` (`ActivityStore.OrphanedScreenEvidence`).

### Revoke evidence once per day in the retention sweep

The nightly scale check on 2026-10-01 found the startup sweep blocking the main thread for 2.3 s on a 180-day library, in part by handing evidence revocation one date per row (101,521 for 166 days). The sweep revokes each day once instead.

Where: `LokalBotTests/Models/ScreenMemory/RetentionReviewTests.swift` (`RetentionReviewTests.testScheduledSweepRevokesEachDayOnceRatherThanEachRow`).

### Map legacy FTS rows to their screenshot ids

Empty OCR was never inserted into the legacy FTS table, so an FTS rowid is not the screenshot id (a row's FTS rowid can be 1 while its screenshot id is 2), and the legacy OCR migration maps one to the other.

Where: `LokalBotTests/Services/Timeline/ActivityStoreTests.swift` (`ActivityStore legacy OCR migration`).

### Show exactly what a range delete removes before deleting

Range delete removes the screen captures retained in a time range of one day. Times snap to captured scenes, and a review lists exactly what will be removed before anything is deleted.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/timeline/range_delete.rs`.

## Search by meaning

### Rank screens the way DigUp ranks files

Meaning is how far a capture stands out for the query among all stored vectors of its kind, and the query's words add a bonus that grows with how many of them the capture holds. A capture qualifies by standing out in meaning or by holding at least half of the query's words, so one common word can't outrank a clear meaning match, while all the words of an exact lookup ("INV-2041") usually win.

Where: `LinuxWindows/crates/lokalbot-core/src/screen_search.rs`.

### Centre scores per kind and scale them over every stored vector

Text scores higher than pictures for the same topic, so scores are centred per kind before going on one z scale. The scale is computed over every stored vector, not only those in the date or app scope, so it does not depend on the filter.

Where: `LinuxWindows/crates/lokalbot-core/src/screen_search.rs` (`meaning`).

### Leave capture text unread in the meaning scan

A search shows a few hundred captures at most, and `screen_texts` reads theirs; reading every capture's text was about a third of the scan's time at 30,000 captures.

Where: `LinuxWindows/crates/lokalbot-core/src/screen_search.rs` (`Library.screen_meanings`).

### Add picture vectors, built only on demand, paced and tied to their pixels

On the 13 October run over a real library, picture vectors found the right screen first for 71 of 138 queries, against 52 for screen-text vectors and 44 for the shipped search (`Benchmarks/search/EmbeddingGemma2/2026-10-13-screen-images`). EmbeddingGemma 2's image encoder runs on the media embedder Files uses, only while search by meaning is on and pictures are captured (Text + visual context), and vectors start only once screens have been searched by meaning, so nobody downloads the image model for a search they never make. Each capture is decrypted in memory, sized for a 280-token budget and never written to disk; retention clears a vector with its pixels, and deleting a capture deletes both. The first pass over a library is a big read, so it is paced while the person uses the computer, and on battery a pass stops after the newest few dozen captures, leaving the rest for a charger.

Where: `LokalBot/Services/ScreenMemory/ScreenImageEmbeddings.swift` (`ScreenImageEmbeddings`), `LinuxWindows/crates/lokalbot-engine/src/screen_vectors.rs`.

## Consequences

- Any new capture backend, platform or consumer of screen text goes through the privacy rules and secure-field checks first, and an unknown or unreadable state (focus, subrole, address, unread pixels) stays treated as unsafe.
- Pixels, vectors and decrypted images move together: files go before rows, vectors go before or with their pixels, nothing is stored for content removed mid-pass, and decrypted pixels never reach disk.
- Accessibility reads and text recognition run against other apps that can hang or change underneath them: keep the time limits, the re-checks after each read, and the rule that LokalBot never queries its own windows.
