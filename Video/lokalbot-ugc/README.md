# LokalBot UGC demo, vertical

A faceless creator-style clip for TikTok, Reels, Shorts and X: someone showing a
friend what their Mac does after a meeting. Voice and big burned-in captions, so
it reads muted.

- Canvas: 1080 × 1920, 30 fps, about 26–28 s depending on the voice.
- Title band: "POV: your Mac remembers your meetings", with "Real app ·
  fictional demo data" under it.
- Story, five lines (`narration.json`): the hook over Ask answering from a
  meeting; the meeting's recap and decisions; a decision's citation opening
  the transcript at the moment it was said; autocomplete finishing a
  follow-up from that meeting, accepted with Tab; an end card (free, open
  source, the AI runs on your Mac, lokalbot.com).
- Only released features are shown.

## What is real

- All footage is the real app; window pixels are only cropped and panned,
  nothing is redrawn (`prepare_footage.py`).
  - Ask and the meeting: the README hero loop at `43d72b9`
    (`Assets/hero/lokalbot-demo-light.gif`), recorded from the app with the
    fictional launch-pricing library. Its own 20 fps; the meeting's still
    opening is held until the voice reaches it.
  - Autocomplete: the live take `light-memory` from
    `pr-assets/392-autocomplete-demo` (TextEdit on a GitHub Actions Mac, the
    default on-device model, real key events). The typing plays at 1.5×, the
    wait for the suggestion is cut, and the Tabs play at 1.35×; a "sped up"
    pill sits on the picture for that whole shot.
- The voice is synthetic: ElevenLabs `eleven_v4`, seed 11, stability 0.5,
  similarity 0.8, one request per line with the neighbouring lines as
  context, made with `../lokalbot-autocomplete-launch/tts_elevenlabs.py`.
  Four voices were rendered: Liam `TX3LPaxmHKxFdv7VOQHJ`, Jessica
  `cgSgspJ2msm6clMCkdW9`, Chris `iP95p4xoKVk53GoZ742B`, Eric
  `cjVigY5qzO86Huf0OWal`. Commercial use of the audio follows the ElevenLabs
  plan of the account that generated it.
- Music: `bed-d`, the ElevenLabs music bed made for the narrated autocomplete
  demo, ducked under the voice. Pointer, typing and Tab clicks are
  synthesized in `mix.py`.

## Timing

`build_edit.py` places every cue on a spoken word, from ElevenLabs'
per-character alignment (`production/eleven-generation.json`): Ask expands as
the hook says "your", the transcript opens on "links", the suggestion appears
on "already", and the first Tab lands as "Tab" ends. Each line's speech ends
where its audio falls below −40 dBFS, not where the alignment's trailing
silence ends. Captions show up to three words at a time with the spoken word
lit.

## Make it

```sh
python3 prepare_footage.py                     # footage/ (gitignored), from git
# Voice, only when the lines change. Load ELEVEN_LABS_API_KEY from the main
# checkout's .env on the Mac; never copy the key anywhere else.
for v in liam:TX3LPaxmHKxFdv7VOQHJ jessica:cgSgspJ2msm6clMCkdW9; do
  CUT_DIR="$PWD" python3 ../lokalbot-autocomplete-launch/tts_elevenlabs.py \
    --voice "${v#*:}" --name "${v%%:*}" --seeds 11
done
mv assets/voice/eleven/*.mp3 assets/voice/
VOICE=liam WORKERS=4 ./make.sh                 # renders/lokalbot-ugc-liam.{mp4,srt} and poster
```

`make.sh` runs `build_edit.py` (writes `edit.json`), `mix.py` (soundtrack),
`render.cjs` (headless Chromium, one PNG per frame from `comp.html`), then
encodes H.264 with the soundtrack normalized to −14 LUFS and limited, writes
an SRT per voice line and copies the poster frame. Needs Node with Playwright,
Python 3 with numpy, and ffmpeg. Opening `comp.html` from a local server plays
the cut in a browser.

`footage/`, `renders/`, `assets/voice/` and `assets/music/` are gitignored.
The music and the voice takes are kept with the renders in the project files
(`demos/ugc/`).

## Files

- `narration.json`: the lines, also the captions and the SRT text.
- `build_edit.py`: the timeline (`edit.json`): shots, footage time maps,
  camera keyframes, captions, click and Tab times.
- `comp.html`, `comp.js`: the composition; `window.__seek(t)` lays out one
  frame deterministically.
- `mix.py`: the soundtrack.
- `render.cjs`: frame renderer (`frames <dir> --workers n`, `stills <dir> t…`).
- `assets/fonts/`: Inter (OFL, see `FONTS.md`); `assets/brand/`: the app icon.
