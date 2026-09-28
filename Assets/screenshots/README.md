# README screenshots

The five app screenshots used by the root [README](../../README.md) were captured
on **September 28, 2026** in light appearance from `master`, commit
[`769068eab523eb158d74c4657d29934287a336bf`](https://github.com/stevyhacker/lokalbot/tree/769068eab523eb158d74c4657d29934287a336bf),
plus the capture fixes described below.

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

The capture ran `Scripts/capture-screenshots.sh --stills-only` in a temporary
`git archive` of the commit above, with two later edits applied: the script's
light default and the scripted-capture sidebar selection in
`LokalBot/Views/MainWindowView.swift`. Prebuilt native runtimes were copied
into its `Vendor/` directory. It had its own storage root, UserDefaults suite,
and DerivedData. No production app or user library was used, and no UI tests
were run.

Main windows were rendered at 1400 × 880 points and 2× density. Quick Recall
used a 660 × 480 point window, producing a 1320 × 1024 PNG. Appearance was
pinned to light, the script's default. All five frames were visually reviewed;
[readme.source.json](readme.source.json) records dimensions and hashes.

`cacheDisplay` cannot draw some native selection materials. The selected
toolbar segment in `meetings-summary.png` renders as a blank white pill. The
native sidebar highlight renders solid black, so scripted captures draw the
selected row in AppKit's unemphasized selection color instead. The host did not
take focus from the app in front, so the window chrome and switches show the
inactive appearance: gray traffic lights, and a gray track on the enabled
Autocomplete switch. Judge those controls in a live window.

The README no longer shows [models.png](models.png). The isolated host has no
downloaded models, so a fresh Models capture shows "Download required" on every
role; the README's model table covers the same information. The committed
`models.png` remains the v0.8.2 capture described in
[models.source.json](models.source.json).

## Demo video

The README embeds a [45-second demo](../videos/lokalbot-readme-demo.mp4), the
light cut of [Video/lokalbot-readme-45s](../../Video/lokalbot-readme-45s/README.md).
The first 15 seconds are motion graphics drawn in the composition: the problem,
the promise, and the default local models by name. The last 30 seconds are
recordings of the native app from `master` at
[`769068e`](https://github.com/stevyhacker/lokalbot/tree/769068e), made on
September 28, 2026 in light appearance and driven by real input events in the
isolated UI test host, with the same fictional seed library as these stills.
Cursor, click ripples, headlines and model chips are editorial overlays; screen
pixels are unchanged. The footage shows the interface and navigation, not live
transcription or model inference. The narration is synthetic (ElevenLabs
Eleven v4).

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
