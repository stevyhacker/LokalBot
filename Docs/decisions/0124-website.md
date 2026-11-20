# 0124. Website

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `Website/generator/`, `Website/public/`, `Website/worker/`.

## Decisions

### `Website/generator/assistant_roundup.py`

#### Day every competitor fact was last checked against its source
`VERIFIED`: The day every competitor fact below was last checked against its source.

#### Day apps were installed and screenshotted; moves only when retaken
`TESTED`: The day we installed the apps and took the screenshots. It moves only when they are retaken.

#### Newest first; each month says what changed, even nothing
`UPDATE_LOG`: Newest first. Say what changed on the page each month, even "nothing changed".

#### Order is model runners, then chat apps, then LokalBot
`TOOLS`: Order: model runners, then chat apps, then LokalBot.

#### At-a-glance table columns follow TOOLS order
`GLANCE_COLUMNS`: Columns of the at-a-glance table, in TOOLS order.

### `Website/generator/comparison_pages.py`

#### Tracks LokalBot's own fact changes; moves dateModified and lastmod, not Last verified
`LOKALBOT_UPDATED`: When LokalBot's own facts on these pages last changed (not the competitors').
It moves dateModified and the sitemap's lastmod, but not "Last verified".

#### Language counts are measured for Mac engines; Windows and Linux models differ
`LB_LANGUAGES`: Measured for the Mac engines; the Windows and Linux models differ.

### `Website/generator/guide_pages.py`

#### Hand-written pages are listed but not generated; bump updated on edit
`REFERENCES`: Hand-written reference pages (Website/public/about.html, Website/public/benchmarks.html). The
renderer lists them on /guides and in the sitemap but does not generate them,
so bump "updated" here whenever you edit one of those pages.

### `Website/generator/indexnow.py`

#### IndexNow 200 and 202 both mean accepted; 202 means key still verifying
`main`: 200 and 202 both mean accepted; 202 means the key is still being verified.

### `Website/generator/render_circuit_board.py`

#### Units: pixels per tile and pixels per grid step
`TILE, PITCH`: px per tile, px per grid step

#### Pin furthest along the lean turns first so the bus stays parallel
`board.route`: The pin furthest along the lean turns first, so the bus stays parallel.

### `Website/generator/render_explainer.py`

#### Throwaway Chrome profile avoids interfering with an open Chrome
`render`: A throwaway profile keeps this away from a Chrome you have open.

#### Headless Chrome may not exit after writing output, so poll then kill
`render`: Headless Chrome doesn't always exit after writing its output.

### `Website/generator/render_social_images.py`

#### Throwaway Chrome profile avoids interfering with an open Chrome
`render`: A throwaway profile keeps this away from a Chrome you have open.

#### Headless Chrome may not exit after writing the screenshot
`render`: Headless Chrome doesn't always exit after writing the screenshot.

### `Website/generator/render_web.py`

#### Publish date of original guides; later guides set their own published
`GUIDES_PUBLISHED`: Publish date of the original guides; a guide added later sets "published".

#### Defined fully on home page; other pages reference same @id to merge entity
`ORGANIZATION`: Defined in full by the home page's structured data; other pages reference
the same @id so search engines merge them into one entity.

#### Bump a hand-written page's date on edit so sitemap lastmod stays honest
`STATIC_PAGES`: Hand-written pages outside the generator, with the date each last changed.
Bump a date when you edit that page so the sitemap's lastmod stays honest.

#### Escape literal \</ so it cannot close the script element
`json_ld`: A literal "\</" would close the surrounding \<script> element early.

#### Footer links are root-relative because blog posts are served at /blog/\<slug>
`render_footer`: Root-relative, because blog posts are served one level down at /blog/\<slug>.

#### Structured-data list order matches page: Questions, Guides, Compare, Reference
`guides_index_structured_data`: Same order as the page: Questions, Guides, Compare, Reference.

### `Website/public/app.js`

#### Loops have no controls; stills under reduced motion or Save-Data
`app.js silent loops`: ---------- silent loops: GIFs in all but file format, so no controls; stills under reduced motion or Save-Data ----------

#### With reduced motion or Save-Data nothing autoplays; tabs pick film start
`app.js home hero`

 ---------- home hero: one short film, and the tabs are its chapters ----------
 Loops muted while on screen. With reduced motion or Save-Data nothing starts by itself:
the tabs choose where the film starts and the browser's own controls play it.

#### Low Power Mode refuses autoplay: leave still with a play button
`demo play`: Low Power Mode and some browsers refuse: leave the still up with a play button

#### Appearance change or phone rotation past breakpoint needs its own cut
`app.js demo recut`: a different appearance or a phone rotated past the breakpoint needs its own cut

#### Visible label is the last non-empty text node; icons stay put
`labelNode`: the visible label is the last non-empty text node; icons stay put

#### On phones and tablets hand the download link to a computer
`app.js handheld`: ---------- phones and tablets: an installer is no use here, so hand the link to a computer ----------

#### Filenames carry the version, so links resolve the latest release on click
`RELEASE_PAGE`

 ---------- downloads: each file carries the version in its name ----------
 (LokalBot-0.11.2-macos-arm64.dmg, LokalBot-0.11.2-windows-x86_64-setup.exe), so a link
points at the latest release and a click looks up the current file.

#### On phones the Mac buttons send the site to a computer
`assetUrl click handler`: On a phone the Mac buttons send the site to a computer instead (below).

#### Desktop install lines mean nothing on a phone, so hide them
`app.js handheld`: desktop install lines (Homebrew, other downloads) mean nothing on a phone

#### Clipboard API can be refused; fall back to a selected textarea
`copy button fallback`: the clipboard API can be refused (no focus, permissions); fall back to a selected textarea

#### Without autoplay the film keeps controls; a click permits playing
`data-play-demo handler`: without autoplay the film keeps its controls; a click is permission to play it

#### Full-size screenshot links open the appearance currently on screen
`home-image-link`: ---------- full-size screenshot links open the appearance on screen ----------

#### Filter matches visible card text plus the page's FAQ questions
`haystacks`: visible card text plus the page's FAQ questions

#### Browsers can restore typed filter text when returning to the page
`pageshow handler`: browsers can restore the typed text when you come back to the page

### `Website/public/benchmarks.js`

#### Static HTML fallback in #leaderboard-root stays visible on error
`leaderboard fetch catch`: Static HTML fallback inside #leaderboard-root stays visible on error.

### `Website/public/hardware.js`

#### Catalog mirrors Swift and Rust registries with speeds from benchmarks.json
`MODELS`: Model catalog grounded in LokalBot's shipped macOS (ModelCatalog.swift,
LlamaServer.swift, TranscriptionEngine.swift) and Windows/Linux
(LinuxWindows/crates/lokalbot-ai/src/catalog.rs, lokalbot-speech/src/models.rs)
registries, with measured speeds from Website/public/benchmarks.json.

#### Active memory is weights plus a 768 MiB runtime allowance
`MODELS.qwen3-asr-1.7b.activeGb`: 2.52 GB weights + 768 MiB runtime allowance

#### Short-context fallback fits an 8 GB Mac's 4 GB budget; full KV adds 3.0 GiB
`MODELS summarizer 0.8b activeGb`: Short-context fallback fits comfortably under an 8 GB Mac's 4 GB budget;
full 32K KV cache adds up to 3.0 GiB in LlamaServer.shared.

#### Active memory is weights plus 3.0 GiB LlamaServer allowance
`MODELS qwen3.5-4b activeGb`: 2.74 GB + 3.0 GiB LlamaServer.shared allowance

#### Active memory is weights plus 768 MiB cotyping allowance
`MODELS autocomplete lightweight activeGb`: 0.73 GB + 768 MiB cotyping allowance

#### Active memory is weights plus 768 MiB allowance
`MODELS autocomplete balanced activeGb`: 3.85 GB + 768 MiB

#### Measured 496 MB server peak in QMSum benchmark
`MODELS embedder activeGb`: Measured 496 MB server peak in QMSum benchmark

#### Budget is half of physical memory, matching ModelResidency.swift
`evaluateStack.budgetGb`: Matches ModelResidency.swift (physicalMemory / 2)

#### Memory buckets: warm, capture burst, LLM burst, optional burst
`evaluateStack`: Track memory buckets accurately:
- warmGb: resident models kept warm (autocomplete + search embedder)
- captureBurstGb: post-meeting transcription + diarization phase
- llmBurstGb: Main LLM summarization / Q&A phase
- optionalBurstGb: optional on-demand tools (files mmproj, TTS)

#### LRU eviction keeps unpinned models in budget unless a pinned burst exceeds it
`evaluateStack.lruManagedPeakGb`: With ModelResidency LRU eviction, LokalBot keeps unpinned models inside budgetGb
unless a single pinned burst alone exceeds budgetGb.

### `Website/public/migrate.js`

#### Migrator is client-side and makes zero network requests; works offline
 Zero-dependency, 100% client-side meeting export to Obsidian Markdown converter.
Makes zero network requests. Works offline in any modern browser and can be imported in Node tests.

#### Version-made-by Unix 3 plus ZIP 2.0 so Info-ZIP and macOS honor UTF-8 flag
`buildZip`: Unix (3) + ZIP 2.0 (20) so UTF-8 flag is honored by Info-ZIP/macOS

### `Website/worker/media-ranges.js`

#### Workers static assets ignore byte ranges; Safari needs them to play media
Workers static assets answer byte-range requests with the whole file. Safari
won't play audio or video without ranges, and other browsers can't seek, so
media requests run through here first (see run_worker_first in
wrangler.jsonc). Everything else is served by the assets directly.

#### Media larger than 64 MB is served whole, unranged
`MAX_BYTES`: larger files are served whole, as before

#### Asset response may lack length, so the body is read whole
`fetch`: The asset response doesn't always say how long it is, so read it whole.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
