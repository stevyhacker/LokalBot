# Review: Inside the Mac

Built 2026-11-10 from `SPEC.md`: 63.3 s, 1920 × 1080, 30 fps, one scene (`compositions/world.html`)
and the shared end card. Rendered the same day: `renders/inside-the-mac.mp4`.

## Creative calls

- **The cloud is answered, then left behind.** The film opens on the question people ask and a
  dashed cloud; the amber dot (a meeting) sets off for it, the cloud is struck out, and the dot
  comes back into the Mac. Everything after that is inside.
- **The app really is the top layer.** The real app's window swings up off the display and lies
  flat, so "under the app" is a thing the viewer watches happen.
- **One bar, to scale.** The five model files are one bar at 167 px a GB. Two of them are slivers
  (33 and 52 px), which is the point; their names sit on flags above.
- **One board that grows.** The same board carries the files, then their sizes and formats, then
  grows downward for the engines and the chip. It is on screen for 20 s and never cut away from.
- **Amber is your work.** The meeting, the files the models write, `lokalbotv3.sqlite`, the dot at
  the three shut doors, the dot on the display at the end. Nothing else is amber.
- **Where the film left the first SPEC** (the SPEC now says what was built):
  - `bundled with the app` sat under the chip and read as a claim about Apple silicon. It is on
    the llama.cpp rail now, the engine `FACTS.md` calls bundled (Core ML is part of macOS).
  - The four files of the meeting arrive as falling amber dots instead of being typed; the tree
    starts on "lands", not "folder", so the dots have a row to land on. Tree type is 46 px.
  - The lid folds and the key deck slides off (and back) instead of fading.
  - The board does not lift for the engines; it grows downward.
  - The three doors draw together on "only" and are named on their words; `off until you turn it
    on` comes on "send", so it has four seconds, not one.
  - The last line starts landing on "close" and the scene has 1.0 s after the voice, or the line
    could not be read.
  - Added, all from `FACTS.md`: `no account, no telemetry` under the cloud; `five model files,
    widths to scale` on the board; the formats (`8-bit`, `Q4_K_M`, `Q6_K`, `Q8_0`) with the sizes;
    `your Mac` on the wall; a lift of the two lower layers on "three".
  - The end card's small print is this film's own: it shows no speeds.

## Measured

- `hyperframes check`: no errors. One warning kept: `composition_file_too_large` (the film is one
  world on one timeline; the board's turn and the pull-backs cross what would be the split).
- Layout: no issues at 9 samples. Contrast: 29 of 29 text checks pass.
- `kit/check_facts.py`: every number with a unit is in `kit/facts.json`.
- Length 63.3 s. Line pauses 0.2 to 0.25 s.
- Every time in the scene comes from `L()`, `E()`, `W()` or `SLOT`. The take's last word in b08
  ("phone") is timed after the measured end of the speech, so its cue is capped at 0.45 s before
  the line's end.

## Looked at

Contact sheets every 1.5 s across the film (three runs), the SPEC's QA frames, the turn at three
instants, the frames either side of the board swap, the closing and the hand-off at 0.15 s steps,
and full-size frames of the opening, the exploded stack, the 9.6 GB board, the engines and the edge.

## Rendered

Rendered 2026-11-10 on the Ubuntu box (`render --quality high --video-frame-format png`, about 20 s)
and mastered with `kit/master.sh`: `renders/inside-the-mac.mp4`, 63.3 s, 1920 × 1080, 30 fps, H.264 + AAC.

- A contact sheet every two seconds and strips of ten frames a second across the opening of the Mac, the board's turn, the move to the library, the close and the hand-off were read from
  the rendered file, and match the snapshots.
- Sound, measured: integrated -16.3 LUFS, peak -1.4 dBFS. A local Whisper hears all ten lines of
  the finished mix in order, under the effects.

## Not checked

- Nobody has listened to it: the voice's delivery and its balance against the effects are measured,
  not heard.
- Not looked at at phone width.

## Weakest shots

- **The edge (b08).** The doors are three bars and three small switches; the beat is carried by its
  labels and the dot. Larger doors that visibly have a latch, or one door trying to open and
  staying shut, would make it a picture rather than a diagram with captions.
- **The empty board (the first 2.5 s of b03).** Five outlined sockets and a caption while the voice
  says "each with one job". It is true to the SPEC and a little dead.
- Also soft: the folder shrinking back into the Mac at the start of b08 passes in front of the
  stack for about 0.2 s, and the exploded stack shows only the front strip of each lower layer.

## With more time

Give the two thin files their own moment (a push-in on the 33 px sliver: "this one is 0.20 GB");
draw the engines' pins as the same chip pins on every slab; let the opened doors show what would
pass through each.
