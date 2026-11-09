# LokalBot autocomplete, 30 s

A fast social cut for X, YouTube and Reddit: real autocomplete footage first,
then a three.js look at how a suggestion is made.

- Canvas: 1920 × 1080, 30 fps, 30 s. Burned-in titles, so it reads muted.
- Footage: LokalBot's Debug build in TextEdit on a GitHub Actions Mac, typed
  by real key events and filmed with ScreenCaptureKit
  (`Scripts/autocomplete-demo/`, workflow "Autocomplete demo"). The default
  on-device model wrote every suggestion; nothing in the product UI is
  redrawn. The edit speeds typing up and shortens the wait for each
  suggestion, and the footage carries a "sped up" note.
- Explainer: what goes into the prompt (a saved meeting fact and the text
  before the cursor), the model running in the app, the next-word
  probabilities, and ghost text accepted with Tab. The probabilities are the
  model's own, from the logged prompt replayed through the app's bundled
  llama.cpp on the same runner (`logs/probabilities.json`).
- Sound: synthesized by `audio.py` (music bed and effects), no third-party
  audio.
- The final cut keeps the first version's edit and pace with lighter lights
  (softer bloom and model glow, the shattering window fading before it fills
  the screen), the logo lockup on the opening, and no bells. The background
  is a generated circuit board (chips, buses, traces and vias on three layers
  the camera flies past, with signals running along some traces) in place of
  the first version's sparkles.
  Narrated 64 s and 45 s versions were made too (ElevenLabs voice and music);
  their pipeline is in this folder's history at commit 3b78104.

## Files

- `comp.html`, `comp.js`: the composition. `window.__seek(t)` lays out one
  frame deterministically; opening `comp.html` in a browser plays it.
- `edit.json`: timeline, footage maps and every on-screen number.
- `build_edit.py <footage-dir>`: turns the workflow's published takes into
  `footage/` frames and fills the maps and cues in `edit.json`.
- `audio.py`: the soundtrack from `edit.json` and the composition's cue list.
- `render.cjs`: headless Chromium renderer (frames, stills, cue list).
- `make.sh [out-dir]`: everything after the footage, through MP4, GIF and
  poster in `renders/`.
- `vendor/`: three.js r170 (MIT) with its post-processing passes, and the
  Inter and JetBrains Mono fonts (OFL).

## Make it

```sh
git fetch origin pr-assets/<pr>-autocomplete-demo
mkdir -p /tmp/takes && git archive FETCH_HEAD | tar -x -C /tmp/takes
python3 build_edit.py /tmp/takes light
./make.sh
```

The home page plays a silent copy, `web/assets/lokalbot-autocomplete.mp4`
(poster: the opening frame, `lokalbot-autocomplete-poster.webp`). Make it from
the final MP4 in two passes, just under 10 MB; `aq-mode=3` keeps the dim circuit
board from smearing at this bitrate:

```sh
X='-an -c:v libx264 -preset slower -b:v 2550k -maxrate 5100k -bufsize 10200k -pix_fmt yuv420p -x264-params aq-mode=3:aq-strength=1.0:deblock=-1,-1'
ffmpeg -i renders/lokalbot-autocomplete-demo.mp4 $X -pass 1 -f mp4 /dev/null
ffmpeg -i renders/lokalbot-autocomplete-demo.mp4 $X -pass 2 -movflags +faststart ../../web/assets/lokalbot-autocomplete.mp4
```
