# LokalBot UGC demo, vertical

A faceless, over-the-top creator clip for TikTok, Reels, Shorts and X: a hyped
voice, a trap beat, and big burned-in captions, so it reads muted. The first
cut was calmer; Stevan asked for it over the top (2026-10-29). That cut is in
this folder's history at `bd344f9`.

- Canvas: 1080 × 1920, 30 fps, about 20–23 s depending on the voice.
- Top sticker: "POV: you never take meeting notes again 🤯", with "Real app ·
  fictional demo data" under it.
- Story, five lines (`narration.json`): "Stop taking meeting notes" over Ask
  answering from a meeting; the meeting's recap and decisions ("then boom");
  a decision's citation opening the transcript at the exact second; autocomplete
  finishing a follow-up from that meeting, "Tab, tab, tab"; an end card (free,
  open source, the AI runs on your Mac, lokalbot.com).
- The edit: captions pop in a word at a time, with key words colored or boxed
  and an emoji (`emphasis` in `narration.json`); zoom punches, shakes and three
  white flashes on the hits; whip pans with motion blur between shots; red
  marker circles on the answer, the citation and the suggestion; a TAB keycap
  per press; an end card that slams in with rays, shockwaves and confetti; a
  progress bar; and small pulses on the beat.
- Only released features are shown.

## What is real

- All footage is the real app; window pixels are only cropped, panned and
  zoomed, nothing in the product UI is redrawn (`prepare_footage.py`). The
  circles, stickers and emoji sit on top.
  - Ask and the meeting: the README hero loop at `43d72b9`
    (`Assets/hero/lokalbot-demo-light.gif`), recorded from the app with the
    fictional launch-pricing library. Its own 20 fps; the meeting's still
    opening is held until the voice reaches it.
  - Autocomplete: the live take `light-memory` from
    `pr-assets/392-autocomplete-demo` (TextEdit on a GitHub Actions Mac, the
    default on-device model, real key events). The typing plays at 2×, the
    wait for the suggestion is cut, and the six Tabs land two to each spoken
    "tab"; a "sped up" sticker sits on the picture for that whole shot.
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
skipped): the beat's drop and a boom on "Stop", the evidence opening and the
answer circled on "remembers", a punch and flash on "boom", the transcript
opening on "jumps", a bass hit and circle on "exact", the suggestion on
"already", and two Tabs on each "tab". The drop and the beat grid are measured
from the music file, with the tempo from `sound.json`. Each line's speech ends
where its audio falls below −40 dBFS.

## Make it

```sh
python3 prepare_footage.py                     # footage/ (gitignored), from git
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
- `build_edit.py`: the timeline (`edit.json`): shots, footage time maps,
  camera keyframes, hits, circles, captions, emoji, music placement, effects.
- `comp.html`, `comp.js`: the composition; `window.__seek(t)` lays out one
  frame deterministically.
- `mix.py`: the soundtrack.
- `render.cjs`: frame renderer (`frames <dir> --workers n`, `stills <dir> t…`).
- `vendor/`: Inter (OFL, see `vendor/FONTS.md`); `assets/brand/`: the app icon
  and the circuit board.
