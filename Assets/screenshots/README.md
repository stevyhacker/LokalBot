# README screenshots

The five app screenshots used by the root [README](../../README.md) were captured
on **September 28, 2026** from the native UI refresh source on
`codex/native-ui-refresh`, commit
[`2fde15dbc0484ac06be593b66c2e512ee0eb7516`](https://github.com/stevyhacker/lokalbot/tree/2fde15dbc0484ac06be593b66c2e512ee0eb7516),
before that UI shipped in a release.

| File | Surface |
| --- | --- |
| [quick-recall.png](quick-recall.png) | Redis results from saved screen context and meeting transcripts |
| [meetings-summary.png](meetings-summary.png) | Meeting overview with recap, actions, decisions, and source citations |
| [today.png](today.png) | Items needing attention and the day digest |
| [timeline.png](timeline.png) | Day overview, digest, open items, and work sessions |
| [cotyping.png](cotyping.png) | Settings → Writing with the Autocomplete preview and rehearsal |

These are unedited captures of the native SwiftUI views, with fictional content
from `Scripts/seed_demo_library.py`. They are not composited product mockups.
The isolated capture host suppresses background capture and inference; displayed
transcripts, summaries, suggestions, and permission states are fixture data.
The images show the interface, not proof of live recording or model performance.

The capture ran `Scripts/capture-screenshots.sh --stills-only` unmodified in a
temporary `git archive` of the commit above, with prebuilt native runtimes copied
into its `Vendor/` directory. It had its own storage root, UserDefaults suite,
and DerivedData. No production app or user library was used, and no UI tests
were run.

Main windows were rendered at 1400 × 880 points and 2× density. Quick Recall
used a 660 × 480 point window, producing a 1320 × 1024 PNG. Appearance was
pinned to dark. All five frames were visually reviewed;
[readme.source.json](readme.source.json) records dimensions and hashes.

`cacheDisplay` cannot draw some native selection materials: the selected
toolbar segment in `meetings-summary.png` renders as a blank light pill, and
selected sidebar rows render solid black. Judge those controls in a live window.

The README no longer shows [models.png](models.png). The isolated host has no
downloaded models, so a fresh Models capture shows "Download required" on every
role; the README's model table covers the same information. The committed
`models.png` remains the v0.8.2 capture described in
[models.source.json](models.source.json).

## Demo video

The README embeds a [30-second real-app demo](../videos/lokalbot-readme-demo.mp4),
recorded September 28, 2026 from `master` at
[`769068e`](https://github.com/stevyhacker/lokalbot/tree/769068e). Its source,
take scripts and narration cues live in
[Video/lokalbot-readme-30s](../../Video/lokalbot-readme-30s/README.md). Every
clip is a recording of the native app driven by real input events in the
isolated UI test host, with the same fictional seed library as these stills.
Cursor, click ripples and headlines are editorial overlays; screen pixels are
unchanged. It shows the interface and navigation, not live transcription or
model inference. The narration is synthetic (ElevenLabs Eleven v4).

The earlier [43-second database demo](../videos/lokalbot-database-demo.mp4) and
its [poster](demo-poster.png) remain for the published YouTube and Product Hunt
copies.

## Refreshing the set

Follow the [screenshot capture guide](../../Docs/screenshot-kit.md). For release
documentation, capture the published release source in an isolated checkout.
Review every replacement alongside its caption and alt text, then update the
hashes, dimensions, source revision, and capture date in
[readme.source.json](readme.source.json). Keep [models.source.json](models.source.json)
in sync if replacing the Models image.

Other PNGs and GIFs in this directory are older assets retained for existing
references; they are not part of the current root README set.
