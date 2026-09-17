# README screenshots

The six app screenshots used by the root [README](../../README.md) were captured
on **September 17, 2026** from the published **v0.8.2** source:
[`540d183d403fa7a4d42b8b3b559f946b1aeac207`](https://github.com/stevyhacker/lokalbot/tree/540d183d403fa7a4d42b8b3b559f946b1aeac207).

| File | Surface |
| --- | --- |
| [quick-recall.png](quick-recall.png) | Redis results from saved screen context and meeting transcripts |
| [meetings-summary.png](meetings-summary.png) | Meeting overview with recap, actions, decisions, and source citations |
| [today.png](today.png) | Outstanding actions and the day's brief |
| [timeline.png](timeline.png) | Day digest, work sessions, and raw-capture entry |
| [cotyping.png](cotyping.png) | Autocomplete preview and rehearsal |
| [models.png](models.png) | Active model roles, readiness, and connections |

These are unedited captures of the native SwiftUI views, with fictional content
from `Scripts/seed_demo_library.py`. They are not composited product mockups.
The isolated capture host suppresses background capture and inference; displayed
transcripts, summaries, suggestions, and permission states are fixture data.
The images show the interface, not proof of live recording or model performance.

The capture used `Scripts/capture-screenshots.sh --stills-only` in a temporary
archive of the release source. It had its own storage root, UserDefaults suite,
and DerivedData. The temporary script used `uv` for fixture seeding and stopped
only the processes it launched. No production app or user library was used,
and no UI tests were run.

Main windows were rendered at 1400 × 880 points and 2× density. Quick Recall
used a 660 × 480 point window, with its title bar included in the resulting
1320 × 1024 PNG. Appearance was pinned to dark. All six frames were visually
reviewed; [readme.source.json](readme.source.json) records dimensions and hashes.

## Demo video

[demo-poster.png](demo-poster.png) is the unchanged poster for the embedded
[43-second real-app video](../videos/lokalbot-database-demo.mp4), recorded
September 15, 2026. It uses separate fictional Northstar meeting data to show a
PostgreSQL versus MongoDB decision and its follow-up. It demonstrates search and
source navigation with prepared content, not live recording or transcription.

## Refreshing the set

Follow the [screenshot capture guide](../../Docs/screenshot-kit.md). For release
documentation, capture the published release source in an isolated checkout.
Review every replacement alongside its caption and alt text, then update the
hashes, dimensions, source revision, and capture date in
[readme.source.json](readme.source.json). Keep [models.source.json](models.source.json)
in sync if replacing the Models image.

Other PNGs and GIFs in this directory are older assets retained for existing
references; they are not part of the current root README set.
