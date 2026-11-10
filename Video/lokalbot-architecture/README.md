# The architecture, three ways

Three narrated explainers, about a minute each, of how LokalBot is built and which models it runs
on a Mac. They say the same facts and are three different films, made on 2026-11-10 so they could
be compared side by side.

| Film | Folder | Length | The idea in one line |
| --- | --- | ---: | --- |
| **One Sentence** | `one-sentence/` | 59.8 s | One spoken sentence passes through five models, all running on the Mac. |
| **Inside the Mac** | `inside-the-mac/` | 63.3 s | Open the Mac: five model files, three engines, one folder, and doors that stay shut. |
| **Taking Turns** | `taking-turns/` | 62.9 s | Five models are files on disk that take turns in memory. |

`STORYLINES.md` has the three storylines as they were offered. Each film's `SPEC.md` is the brief
it was built from and its `REVIEW.md` says what was checked. The finished files are
`<film>/renders/<film>.mp4` (1920 × 1080, 30 fps; git ignores `renders/`).

## What is real

- **The facts.** Every model name, size, port, path, timer and speed is in `FACTS.md` with the
  file it comes from: the README's table of Mac defaults, `DEVELOPMENT.md`, the engine sources and
  `Benchmarks/README.md`. Speeds were measured on one M4 Max with 48 GB and say so on screen.
  `python3 kit/check_facts.py` fails on a number that is not in `kit/facts.json`.
- **The app** on the MacBook's screen in Inside the Mac: a frame of the Offsite planning notes from
  the One Decision film's footage (`../lokalbot-one-decision/assets/footage/notes.mp4`).
- **The voice.** ElevenLabs `eleven_v4` in Stevan's cloned voice, one take a line, each checked by
  a local transcription (`kit/tts.py`, `kit/voicecheck.py`, `<film>/voice/`). The takes are under
  `<film>/assets/voice/`, which git ignores, so a fresh checkout voices them again (about 2,500
  characters for the three films; the closing line is voiced once and shared).

## What is drawn

Everything else. These are diagrams, not footage: the call window, the tracks, the pages, the
MacBook, the model files and the clock are drawn for the films. The example sentence, "The offsite
is in Lisbon, May 12 to 14.", and the people saying it are fictional, as in One Decision. Times
under words, the vector's numbers and the neighbours on the meaning map are illustrative. The day in
Taking Turns is an example day: the waits (120 s, 600 s) are the app's own, the clock times are not
measurements. It also draws the language model coming in after the speech models have left; in
the app the notes start while the speech models are still counting down their two idle minutes.

## How they are built

`kit/` is shared. Each film's `build.py` is a table: its scenes, the voice lines with the pause
before each, and the effects. `python3 build.py` places the lines one after another, writes
`index.html`, and writes the voice's timings into the scene file, so the picture is animated
against spoken words (`W("a04", "words")`) and a new take moves it. The shared end card is
`kit/endcard.html`.

```sh
cd one-sentence          # or inside-the-mac, taking-turns
python3 build.py && npx --yes hyperframes@0.8.150 check && python3 ../kit/check_facts.py .
npx --yes hyperframes@0.8.150 render --quality high --video-frame-format png -o renders/raw.mp4
../kit/master.sh renders/raw.mp4 renders/one-sentence.mp4     # to about -16 LUFS
```

The three films here were rendered on the Ubuntu box, about 20 s each, and match the Mac's
snapshots: copy the folder there, run the same two commands, copy `renders/` back.

The effects are HyperFrames' bundled ones, which git ignores under `assets/sfx/`: `pop`,
`click-soft`, `key-press`, `typing`, `whoosh-short`, `whoosh` and `impact-bass-1`
(`npx hyperframes media-use resolve --type sfx --intent "<name>" --project .` restores each). There
is no music bed.
