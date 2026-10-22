# README demo GIF

Records the LokalBot UI Test Host and builds the looping hero GIFs in
`Assets/hero/` (light and dark). What the published files show and which
revision they came from is in [Assets/hero/README.md](../../Assets/hero/README.md).

| File | Role |
| --- | --- |
| `seed_library.py` | Writes the fictional library: a team sets launch pricing on a call after seeing a competitor's page and a pricing sheet. Reuses the writers in `Scripts/seed_demo_library.py`. |
| `shots/*.json` | One take each: window size, setup, and the input to perform (typing, keys, pointer moves and clicks, by position or accessibility element). |
| `rig.swift` | Places the host window on the built-in Retina display, records it with ScreenCaptureKit over a flat fill (other windows and the desktop left out, pointer included), and performs the take with real input events. Writes PNG frames, their times, and the event log. |
| `film.sh` | Seeds one library, then launches the host on a fresh copy of it for every take and appearance, with its own UserDefaults suite, and calls `rig`. |
| `edit.json` | The cut: which part of each take plays, its caption, crop and scale, the canvas, and the per-appearance text colours. |
| `compose.swift` | Lays each frame out on the canvas with its caption, the footer, and a fading ring where a recorded click landed. Window pixels are only cropped or scaled. |
| `build.sh` | Composes both appearances and encodes them with one ffmpeg palette per loop, then `gifsicle -O3 --lossy=20`. |

## Rebuild

Needs Xcode, ffmpeg, gifsicle, and Screen Recording and Accessibility access
for the terminal. Filming takes over the pointer and keyboard for about 90
seconds in total. Each take waits until nobody has touched the keyboard, mouse
or trackpad for four seconds, and starts again if they do.

```sh
WORK=/private/tmp/lokalbot-readme-gif
git archive v0.11.2 | (mkdir -p "$WORK/src" && tar -x -C "$WORK/src")
cp -c -R Vendor/. "$WORK/src/Vendor/"
mkdir -p "$WORK/src/.build" && cp -c -R .build/SourcePackages "$WORK/src/.build/SourcePackages"
(cd "$WORK/src" && xcodegen generate && xcodebuild build -project LokalBot.xcodeproj \
  -scheme "LokalBot UI Test Host" -configuration Release -derivedDataPath "$WORK/DD" \
  -clonedSourcePackagesDirPath "$WORK/src/.build/SourcePackages" -disableAutomaticPackageResolution \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO -quiet)
APP_BUNDLE="$WORK/DD/Build/Products/Release/LokalBot UI Test Host.app" \
  APPEARANCES=light Scripts/readme-gif/film.sh "$WORK/takes"
APPEARANCES=light Scripts/readme-gif/build.sh "$WORK/takes"
```

Re-record every take in one `film.sh` run: each run seeds the library relative
to the current time, so takes from separate runs show different clock times.
After changing a shot, check the event times `film.sh` prints into each
`take.json` against the `from`/`to` ranges in `edit.json`. Then update the
sizes, hashes, revision and date in `Assets/hero/README.md`.

The host suppresses capture and inference, so the transcript, summary and Ask
answer are fixtures. On the Mac this was made on, macOS replaces a window's
controls with a purple sharing indicator when its app is named as the shared
content, so `rig` captures the display and leaves every other window out
instead.

## Autocomplete and dictation

The last two scenes show the same meeting decision reused in another app:
autocomplete in TextEdit finishes "…the Team plan will be $15" with "per seat,
billed annually.", and dictation turns "Write a one-line team update with the
launch pricing." into a line with that price. Both are recorded live, light
only. The shipped GIF is light only and serves both appearances.

| File | Role |
| --- | --- |
| `build_filming_app.sh` | Builds a copy of a release with one change: the autocomplete suggestion panel is visible to screen capture (it ships hidden). It is signed with the installed app's designated requirement so the installed app's Accessibility and Input Monitoring grants apply. Never ship or commit it. |
| `prepare_filming.py` | Seeds the fictional library for the filming copy, clones the models it needs from the installed app (APFS clones), turns on agent access, and writes an isolated settings suite with everything that could capture or learn turned off. |
| `film_live.sh` | Quits the installed LokalBot, runs the filming copy on that library, records the autocomplete and dictation takes in TextEdit, and reopens the installed app, also on failure. Dictation plays its line through the speakers with the `Samantha` voice into the built-in microphone. |
| `shots/autocomplete.json`, `shots/dictation.json` | The takes. Autocomplete pauses after the meeting name so its saved facts are looked up before the price is typed. The TextEdit window is small and `edit.json` scales it up, since plain text types in Menlo 11 pt. |

```sh
Scripts/readme-gif/build_filming_app.sh "$WORK"
FILMING_APP="$WORK/LokalBot.app" APPEARANCES=light Scripts/readme-gif/film_live.sh "$WORK/takes"
APPEARANCES=light Scripts/readme-gif/build.sh "$WORK/takes"
```

Not used yet: `prepare_claude.py`, `claude_scene.sh`, `open_terminal.applescript`
and `shots/claude.json` open an isolated Claude Code session whose only MCP
server is `lokalbot-cli` on the fictional library. An interactive session needs
a Claude account that allows it; the API key tried was refused for lack of
prepaid credit.
