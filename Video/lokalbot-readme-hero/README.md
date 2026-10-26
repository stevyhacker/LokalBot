# LokalBot README hero reel

Builds the 30-second loop at the top of the root README,
[Assets/hero/lokalbot-demo-light.gif](../../Assets/hero/lokalbot-demo-light.gif).
What the published file shows and which revisions it came from is in
[Assets/hero/README.md](../../Assets/hero/README.md).

## Beats

Seven hard cuts and an end card, each with its own example from the fictional
demo libraries, at 15 fps. Times are in the loop.

| # | Seconds | Scene | Source |
| --- | --- | --- | --- |
| 1 | 0.0–3.2 | Quick Recall: "demo presentation" finds Keynote and Mail screen text and two meetings; ↓ moves the selection. Typing plays at 2.5×. | take `t-recall` |
| 2 | 3.2–7.2 | Podcast trailer review: the 00:00:26 citation on an action item opens the transcript at that line. | take `t-meeting` |
| 3 | 7.2–11.0 | Ask: citation 1 in the holiday-shoot answer opens the transcript at its line. | take `t-ask` |
| 4 | 11.0–15.3 | Live autocomplete in TextEdit: after "the Team plan will be $15", it suggests "per seat, billed annually." from the launch-pricing meeting, and Tab accepts it word by word. | previous hero, 12.0–13.2 s and 14.6–17.7 s |
| 5 | 15.3–20.9 | Live dictation: a spoken request, then Compose writes the team update. The Compose wait plays at 2×. | previous hero, 20.2–27.2 s |
| 6 | 20.9–24.3 | Timeline: a work session opens with its evidence. | take `t-timeline` |
| 7 | 24.3–27.3 | People: Maya, then Leo, with what's waiting on you and the decisions made together. | take `t-people` |
| 8 | 27.3–30.0 | End card: tagline, three facts, and the features not shown. | drawn |

The takes are recordings of the LokalBot UI Test Host made by `FilmDirector`
(added by `filming/filming-host.patch`): it draws the host window into a
movie with `cacheDisplay` at 1.5× and plays the take script's clicks and keys
into that window as real AppKit events, logging when and where each landed.
The host suppresses capture and inference, so transcripts, summaries and the
Ask answer are fixtures; the search results are the app's own search over the
library.

Scenes 4 and 5 are live: they are cut from the previous hero,
`Assets/hero/lokalbot-demo-light.gif` at `43d72b9`, recorded by
[Scripts/readme-gif](../../Scripts/readme-gif/README.md) from a filming copy of
v0.11.2. `build.sh` reads that file from git, crops it below its old caption,
and scales it to this canvas.

The cursor, click ripple and keycaps are drawn at the times and points in each
take's `*.events.json`; the keycaps in the live scenes follow that pipeline's
shot files (Tab four times; ⌥ Space held while speaking). Window pixels are
only cropped, scaled, or retimed by whole frames.

## Files

| File | Role |
| --- | --- |
| `filming/filming-host.patch` | Adds `FilmDirector` to a throwaway copy of the source, plus a filming-only active-window appearance and a hidden-sidebar start. Never applied to the app source. |
| `filming/seed_filming_library.py` | Seeds `Scripts/seed_demo_library.py --profile studio` with every meeting on the local clock (see the script). |
| `filming/take.sh` | Records one take on a fresh copy of the library with its own defaults suite, and fails if the host started a recording. |
| `filming/film_all.sh` | Records the five takes with each one's window and section. |
| `filming/scripts/t-*.json` | Each take's input, in window points from the top-left corner, titlebar included. |
| `compose.py` | Lays out every frame: caption band, step dots, footage, cursor, ripple, keycaps, end card. |
| `build.sh` | Decodes the previous hero, runs `compose.py`, and encodes the GIF with one palette and no dithering, then `gifsicle -O3`. |

## Rebuild

Needs Xcode, xcodegen, ffmpeg, gifsicle and Python 3 with Pillow. Build
outside `~/Documents` so the ad-hoc signed host never asks for Documents
access.

```sh
REPO=$PWD
WORK=/private/tmp/lokalbot-readme-hero
git archive HEAD | (mkdir -p "$WORK/src" && tar -x -C "$WORK/src")
cp -c -R Vendor/. "$WORK/src/Vendor/"
mkdir -p "$WORK/src/.build" && cp -c -R .build/SourcePackages "$WORK/src/.build/SourcePackages"
(cd "$WORK/src" && git apply "$REPO/Video/lokalbot-readme-hero/filming/filming-host.patch" \
  && xcodegen generate && xcodebuild build -project LokalBot.xcodeproj \
  -scheme "LokalBot UI Test Host" -configuration Debug -derivedDataPath "$WORK/dd" \
  -clonedSourcePackagesDirPath "$WORK/src/.build/SourcePackages" -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO)
TZ=Asia/Tokyo python3 Video/lokalbot-readme-hero/filming/seed_filming_library.py "$WORK/library"
WORK="$WORK" FILM_TZ=Asia/Tokyo Video/lokalbot-readme-hero/filming/film_all.sh
Video/lokalbot-readme-hero/build.sh "$WORK/takes"
```

- **Time zone:** pick a zone where it is early afternoon, so today's meetings
  and work sessions fall in working hours, and use it for both the seed and
  the takes. The published takes used `Asia/Tokyo` at about 14:00 JST.
- **Filming:** each take opens the host window for about ten seconds and
  activates it, five times in all. Nobody should click it: the host has
  microphone access, and the Record button sits in the meeting list.
  `take.sh` deletes the library copy after each take and exits 3 if a
  recording appeared in it.
- **Changing a take:** run it with only a `wait` action, read the last frame
  of the movie for click positions (pixels ÷ 1.5 = points), then update its
  script and the beat's `segments` in `compose.py`.
- After a rebuild, update the table in `Assets/hero/README.md`.
