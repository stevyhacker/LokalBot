# LokalBot autocomplete demo

An upbeat, narrated 45 s cut for X, YouTube and Reddit: real autocomplete
footage first, then a three.js look at how a suggestion is made. The voice
starts on the first frame, and every cut, Tab press and model pick lands on
the beat of the music.

- Canvas: 1920 × 1080, 30 fps. lokalbot.com's look: the navy gradient, teal
  accents, glass panels, the logo lockup and Inter. Titles and captions are
  burned in, so it reads muted.
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
- Voice: synthetic, from `narration.json`. `take` picks the engine, voice and
  take: ElevenLabs (`../lokalbot-autocomplete-launch/tts_elevenlabs.py` with
  `CUT_DIR` set to this folder, `--name` for a voice other than the default)
  or OpenAI (`tts.py`). The cut uses Eric, a premade ElevenLabs narrator.
  `tighten.py` shortens the pauses in the chosen takes and quickens them 5%
  (Rubber Band, formants kept). Say it is synthetic where the video is posted.
- Music and effects: ElevenLabs Music and Sound Effects (`eleven_sound.py`,
  prompts in `sound.json`). The 120 BPM bed is re-cut by whole bars
  (`sound.json` "music_edit"): it drops in on the first clip, its one-bar
  break falls on "So how does it work?" and its final hit after the last
  word. Commercial use follows the plan of the ElevenLabs account that made
  them. Under the hook, `synth.py` plays the first cut's intro (a pad that
  opens up, a riser and four kicks into the drop), and it makes the impacts,
  the Tab thock with a bell that climbs the scale, the ghost-text shimmer,
  the swishes, the model's blips and the logo's bells, in the bed's key
  (`sound.json` "synth").

## Files

- `comp.html`, `comp.js`: the composition. `window.__seek(t)` lays out one
  frame deterministically; opening `comp.html` in a browser plays it.
- `edit.json`: timeline, footage maps, voice placement, captions and every
  on-screen number.
- `timeline.py`: times the sections, captions and explainer beats to the
  chosen voice takes (or to estimated line lengths before there is a voice),
  and snaps the cuts to the music's beat.
- `tighten.py`: the quicker versions of the chosen takes, with their word
  timings (`production/tight.json`). Run it before `timeline.py`.
- `build_edit.py <footage-dir>`: turns the workflow's published takes into
  `footage/` frames and fills the maps and cues in `edit.json`. Run it after
  `timeline.py`.
- `tts.py`, `word_timings.py`, `eleven_sound.py`: voice, word timings and
  sound. They call paid APIs (except `word_timings.py`, which runs locally),
  so they run once on a machine with the keys; the results go to the
  `pr-assets/<pr>-autocomplete-voice` branch, not into the repository.
- `audio.py`: mixes voice, music (re-cut to the film and ducked under the
  voice) and effects from `edit.json` and the composition's cue list.
- `synth.py`: the synthesized intro and effects `audio.py` uses.
- `render.cjs`: headless Chromium renderer (frames, stills, cue list).
- `make.sh [out-dir]`: everything after the footage and sound, through MP4,
  GIF and poster in `renders/`.
- `vendor/`: three.js r170 (MIT) and the Inter and JetBrains Mono fonts (OFL).

## Make it

```sh
git fetch origin pr-assets/<pr>-autocomplete-demo
mkdir -p /tmp/takes && git archive FETCH_HEAD | tar -x -C /tmp/takes
git fetch origin pr-assets/<pr>-autocomplete-voice
mkdir -p /tmp/voice && git archive FETCH_HEAD | tar -x -C /tmp/voice
mkdir -p assets/voice assets/sound
cp -r /tmp/voice/openai /tmp/voice/eleven assets/voice/ && cp -r /tmp/voice/sound/eleven assets/sound/
python3 tighten.py
python3 timeline.py
python3 build_edit.py /tmp/takes light
./make.sh
```
