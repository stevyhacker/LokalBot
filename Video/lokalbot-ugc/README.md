# LokalBot UGC demo, vertical

A faceless, over-the-top creator clip for TikTok, Reels, Shorts and X: a hyped
voice, a trap beat, and big burned-in captions, so it reads muted. The first
cut was calmer; Stevan asked for it over the top (2026-10-29). That cut is in
this folder's history at `bd344f9`. The over-the-top cut first panned over the
README's wide hero loop, which cut the app off; it now shows the app filmed
for this clip in a tall window at 2x, with a camera that follows the pointer
(the first version is at `ef72cd9`).

- Canvas: 1080 × 1920, 30 fps, 23.6 s with Liam and 24.1 s with Jessica.
- Top sticker: "POV: you never take meeting notes again 🤯", with "Real app ·
  fictional demo data" under it.
- Story, five lines (`narration.json`): "Stop taking meeting notes" over Ask
  answering from a meeting; the meeting's recap and decisions ("then boom");
  a decision's citation opening the transcript at the exact second; autocomplete
  finishing a follow-up from that meeting, "Tab, tab, tab"; an end card (free,
  open source, the AI runs on your Mac, lokalbot.com).
- The app: its whole window, on the circuit board, with a camera that works
  like a screen-recording editor's. It follows the pointer and zooms in as it
  heads for a click, pulls back to the whole window when the view changes,
  then settles on what the line is about. Each click dips the pointer and
  sends out a ripple. Between LokalBot and TextEdit one window flies out with
  motion blur and the next flies in.
- The edit: captions pop in a word at a time, with key words colored or boxed
  and an emoji (`emphasis` in `narration.json`); zoom punches, shakes and three
  white flashes on the hits; red marker circles on the recap, the decisions,
  the cited moment in the transcript and the suggestion; a TAB keycap per
  press; an end card that slams in with rays, shockwaves and confetti; a
  progress bar; and small pulses on the beat.
- Only released features are shown.

## What is real

- All footage is the real app, filmed for this clip by the UGC demo footage
  workflow (`.github/workflows/ugc-demo.yml`, `film/`) on a GitHub Actions Mac
  and kept on the branch `pr-assets/ugc-demo-footage`. Window pixels are only
  scaled and moved, nothing in the product UI is redrawn
  (`prepare_footage.py`). The pointer, ripples, circles, stickers and emoji
  sit on top.
  - The hosted Macs only offer 1x screens, so `film/vdisplay.m` adds a
    virtual Retina display (1200 × 1600 pt at 2x) and the rig films there.
  - The renders of 2026-10-29 use the footage from workflow run
    40871574642 (`84ceae8`); each run replaces what is on the branch.
  - `flow`: the LokalBot UI Test Host on the README's fictional library, in a
    680 × 900 pt window. Ask's answer opens its evidence, the first source
    opens the meeting, the Summary tab shows the recap and decisions, and a
    decision's citation opens the transcript at 00:00:14. The rig clicks with
    real mouse events (`Scripts/readme-gif/rig.swift`).
  - `follow-up`: autocomplete in TextEdit with the default on-device model
    and real key events (`Scripts/autocomplete-demo/film.sh`, the shot in
    `film/shots/follow-up.json`). The typing plays at 2×, the wait for the
    suggestion is cut (12.5 s on the hosted Mac's CPU), and the six Tabs land
    two to each spoken "tab"; a "sped up" sticker sits on the picture for that
    whole shot.
- The takes are filmed without the system pointer. The edit draws a pointer
  that rests where the take's pointer rested and glides between the points
  the rig moved to and clicked, so each click happens where and in the order
  it did in the take, timed to its word. After a click the app's reaction
  plays at its recorded speed; while the screen sits still the take holds, or
  skips ahead over frames that look the same, so the next click lands on its
  word.
- The voice is synthetic: ElevenLabs `eleven_v4` with an `[excited]` audio tag,
  speed 1.1, seed 11, one request per line with the neighbouring lines as
  context (`../lokalbot-autocomplete-launch/tts_elevenlabs.py`). Liam
  `TX3LPaxmHKxFdv7VOQHJ` and Jessica `cgSgspJ2msm6clMCkdW9` were made. Commercial
  use of the audio follows the ElevenLabs plan of the account that generated it.
- The beat and the effects are ElevenLabs music and sound generations from the
  prompts in `sound.json` (`eleven_sound.py`); no bells. `mix.py` synthesizes
  any effect whose file is missing.
- Emoji are the system's color emoji font (Noto Color Emoji on Linux, Apple
  Color Emoji on a Mac). The background is the website's circuit board
  (`web/assets/circuit-board.svg`).

## Timing

`build_edit.py` places every cue on a spoken word, from ElevenLabs'
per-character alignment (`production/eleven-generation.json`, audio tags
skipped): the beat's drop and a boom on "Stop", the evidence opening on
"remembers", the meeting opening as "LokalBot" is said, the recap on "boom"
(circled on "recap", then the decisions on "decision"), the transcript
opening on "jumps", a bass hit and circle on "exact", the suggestion on
"already", and two Tabs on each "tab". The circles sit on the elements'
frames from the takes' accessibility probes, and on the transcript's
highlighted segment as found in the frame. The drop and the beat grid are measured
from the music file, with the tempo from `sound.json`. Each line's speech ends
where its audio falls below −40 dBFS.

## Make it

```sh
python3 prepare_footage.py                     # footage/ (gitignored), from git
# To film again: run the "UGC demo footage" workflow (it also runs on a push
# that changes film/), then prepare_footage.py again.
# Voice, beat and effects, only when the lines or prompts change. Load
# ELEVEN_LABS_API_KEY from the main checkout's .env on the Mac; never copy the
# key anywhere else.
for v in liam:TX3LPaxmHKxFdv7VOQHJ jessica:cgSgspJ2msm6clMCkdW9; do
  CUT_DIR="$PWD" python3 ../lokalbot-autocomplete-launch/tts_elevenlabs.py \
    --voice "${v#*:}" --name "${v%%:*}-ott" --seeds 11 --speed 1.1
done
mv assets/voice/eleven/*.mp3 assets/voice/
python3 eleven_sound.py --env-file ../../.env  # assets/sound/eleven/
VOICE=liam-ott MUSIC=hype-a WORKERS=4 ./make.sh   # renders/lokalbot-ugc-liam-ott.{mp4,srt} and poster
```

`make.sh` runs `build_edit.py` (writes `edit.json`), `mix.py` (soundtrack),
`render.cjs` (headless Chromium, one PNG per frame from `comp.html`), then
encodes H.264 with the soundtrack normalized to −14 LUFS and limited, writes
an SRT per voice line and copies the poster frame. Needs Node with Playwright,
Python 3 with numpy, and ffmpeg. Opening `comp.html` from a local server plays
the cut in a browser.

`footage/`, `renders/`, `assets/voice/`, `assets/music/` and `assets/sound/`
are gitignored. The voice takes, beat and effects are kept with the renders in
the project files (`demos/ugc/`).

## Files

- `narration.json`: the lines (`spoken` for ElevenLabs, `caption` for the
  screen and the SRT) and each line's emphasized words.
- `sound.json`, `eleven_sound.py`: the beat and effect prompts, and their
  generator.
- `film/`: the footage rig: `film.sh` (CI only), the shots, the virtual
  display, and `probes.py` (an accessibility tree and a still at each `mark`).
- `prepare_footage.py`: the takes as frames plus their logs, in `footage/`.
- `build_edit.py`: the timeline (`edit.json`): shots, footage time maps, the
  drawn pointer, camera moves, hits, circles, captions, emoji, music
  placement, effects.
- `comp.html`, `comp.js`: the composition; `window.__seek(t)` lays out one
  frame deterministically.
- `mix.py`: the soundtrack.
- `render.cjs`: frame renderer (`frames <dir> --workers n`, `stills <dir> t…`).
- `vendor/`: Inter (OFL, see `vendor/FONTS.md`); `assets/brand/`: the app icon
  and the circuit board.
