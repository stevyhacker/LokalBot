# README screenshots

The five app screenshots used by the root [README](../../README.md) were captured
on **October 9, 2026** in light appearance from the `v0.10.2` release commit
[`1ade074a90510866d8909dc17e2e1dde372831b7`](https://github.com/stevyhacker/lokalbot/tree/1ade074a90510866d8909dc17e2e1dde372831b7)
(build 46).

| File | Surface |
| --- | --- |
| [quick-recall.png](quick-recall.png) | "captions" results from a Pages checklist seen on screen and from meeting transcripts |
| [meetings-summary.png](meetings-summary.png) | Podcast trailer review with recap, actions, decisions, and source citations |
| [today.png](today.png) | Items needing attention and the day digest |
| [timeline.png](timeline.png) | Day overview, digest, open items, and work sessions |
| [cotyping.png](cotyping.png) | Settings → Writing with the Autocomplete preview and rehearsal |

These are unedited captures of the native SwiftUI views, with fictional content
from `Scripts/seed_demo_library.py --profile studio`: a small video studio's
calls and Apple apps, with a different example in each frame. They are not
composited product mockups. The isolated capture host suppresses background
capture and inference; displayed transcripts, summaries, suggestions, and
permission states are fixture data. The images show the interface, not proof
of live recording or model performance. The README's hero image is a separate
composite described in [Assets/hero/README.md](../hero/README.md).

The LokalBot UI Test Host was built from the commit above with
`CODE_SIGNING_ALLOWED=NO` into its own DerivedData. Each frame used the
per-frame settings that `Scripts/capture-screenshots.sh --stills-only` uses at
this revision, run one frame at a time against one seeded library instead of
through the whole script. The Autocomplete frame came from an earlier pass a
few minutes before, with the same build and profile; it does not show library
content. Each run had its own storage root and UserDefaults suite. No
production app or user library was used, and no UI tests were run.

Main windows were rendered at 1400 × 880 points and 2× density. Quick Recall
used a 660 × 480 point window, producing a 1320 × 1024 PNG. Appearance was
pinned to light, the script's default. All five frames were visually reviewed;
[readme.source.json](readme.source.json) records dimensions and hashes.

In 0.10.2, `cacheDisplay` draws the selected toolbar segment correctly. It
still renders the native sidebar highlight solid black, so scripted captures
draw the selected row in AppKit's unemphasized selection color instead. The
host came to the front for these captures, so window chrome and switches show
the active appearance.

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
isolated UI test host, with the default fictional library from
`Scripts/seed_demo_library.py`, not the studio profile these stills now use.
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
