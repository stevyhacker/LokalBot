# LokalBot: three films about the architecture

Use the [shared video instructions](../AGENTS.md). Three 60-second explainers tell the same facts three
ways; each is its own HyperFrames project in its own folder, with its own `SPEC.md` and `REVIEW.md`:

| Folder | Film | Device |
| --- | --- | --- |
| `one-sentence/` | One Sentence | one spoken sentence travels through every model |
| `inside-the-mac/` | Inside the Mac | the Mac opened into layers, the model files to scale |
| `taking-turns/` | Taking Turns | a day of models coming into memory and leaving it |

`FACTS.md` is the only source for what the films say. `STORYLINES.md` is why there are three.

## Rules for every film

- **Facts.** Nothing goes on screen that is not in `FACTS.md`, in its words. "Five models" are the
  five in its table. A speed carries "M4 Max". Run `python3 kit/check_facts.py` after changing any
  number.
- **The voice is the clock.** Lines live in `<film>/voice/narration.json`; the takes are ElevenLabs
  (`kit/tts.py`, paid, the user's cloned voice): never re-voice without asking. `<film>/build.py`
  places the lines with the pause before each and writes their timings into the scene, so a scene
  animates against `L("a03")`, `E("a03")`, `W("a03", "spoke")`, `LEN` and `SLOT`, never against a
  typed number. A part appears on the word that names it.
- **The screen never repeats the voice.** The voice says the job in plain words; the label on the
  part gives the model's exact name, format and size.
- **Generated blocks.** `index.html`, `cues.txt`, `compositions/endcard.html` and the two marked
  blocks in every scene (`/* kit:begin */ … /* kit:end */`, `/* cues:begin */ … /* cues:end */`)
  are written by `python3 build.py`. Edit `kit/kit.css`, `kit/endcard.html` and the tables instead.
- **The scene file.** One paused GSAP timeline, registered as `window.__timelines["world"]` after
  its tweens and padded with `tl.set({}, {}, LEN)`. Everything visible is a function of timeline
  time: no `Math.random()` without a seed, no `Date`, no timers, no CSS animations or transitions.
  A later tween on a property an earlier tween owns is a `fromTo` with `immediateRender: false`.
  The camera is one wrapper (`data-layout-allow-overflow`) moved with `x`, `y` and `scale`; type
  must still be 28 px or more on screen at the scale it is read at.
- **Type and glyphs.** Inter and JetBrains Mono only. The films render on Linux as well as macOS, so
  no emoji, no system fonts, no symbol a font may lack: draw icons as shapes.
- **Amber** (`--amber`) has one meaning in each film, written in its `SPEC.md`, and is never
  decoration. Each film ends by closing its last amber thing to a 50 px dot at left 751, top 625.5,
  where the shared end card picks it up at `SLOT`.
- **Sound.** Effects are HyperFrames' bundled ones under `assets/sfx/` (git-ignored), placed in
  `build.py` against what the picture shows; few and exact. There is no music bed. `typing.mp3`
  gives 1.05 s of sound a loop entry, so a longer run of typing is two entries, and two loops
  that overlap trip `duplicate_audio_track`.
- **Last words.** The voice's timings can put a line's last word after `E()`, the measured end of
  its speech. Do not hang a hand-off on a last word without capping it: `Math.min(W(…), E(…) - 0.3)`.
- **No callbacks.** HyperFrames seeks the paused timeline, and seeking may not fire `onUpdate` or
  `tl.call`. Text that types, counts or changes is one element per character or state, switched
  with `tl.set`.

## Commands (inside a film's folder)

```sh
python3 build.py                                    # index.html, cues.txt, the generated blocks
npx --yes hyperframes@0.8.150 check                 # lint, layout, contrast
npx --yes hyperframes@0.8.150 snapshot --at 3,9.5 --no-end --describe false -o <a scratch folder>
python3 ../kit/check_facts.py .
npx --yes hyperframes@0.8.150 render --quality high --video-frame-format png -o renders/raw.mp4
../kit/master.sh renders/raw.mp4 renders/<film>.mp4 # to about -16 LUFS
```

Snapshots write a `contact-sheet.jpg` beside the frames. HyperFrames is pinned to 0.8.150, which has
no `snapshot --range` or `--review`: list the times with `--at`.
