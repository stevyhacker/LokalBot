# Review: One Sentence

Built and rendered 2026-11-10: `renders/one-sentence.mp4`, 59.8 s. The world scene has 52.5 s, the
shared end card 7.3 s. `SPEC.md` describes the film as built.

## Creative calls

- **One take through one map.** The inside of the Mac is a 3 × 3 map and the camera travels it in a
  spiral, so the pull-back at the end shows the route the film has just taken, traced in amber.
- **Amber is the sentence.** It is on screen at every moment of the world scene, in ten forms: a
  level meter, a caption, a waveform, a stretch of a recording, words, a line in the notes, a
  vector, a dot in the database, ghost text, an answer. Nothing else is amber.
- **The voice says the job, the label says the model.** Each model has a plate with its exact name,
  three words the voice does not say, and its format and size. The aligner has a smaller plate and
  is never counted: the film says "five models" and shows five at the pull-back.
- **Tracks and speakers share one recorder,** a panel that runs across two cells of the map, so the
  camera pans along the same two lanes instead of cutting to a second drawing of them.
- **The notes are the ones the app wrote.** The action item and the open question on the notes page
  are the lines Qwen3.5 4B produced for this meeting in the One Decision film; the transcript rows
  around the sentence are written to match them.
- **Nothing says "never leaves".** The agent beat shows a gate that is off by default and opens only
  when the switch is flipped, and the last line counts the models and the gigabytes, no more.

## Measured

- `hyperframes check`: no errors. One lint warning kept: `composition_file_too_large`
  (`compositions/world.html` is one world with one camera, by design). About 40 layout notes at
  information level, all intended layering: the five large plates sit over the stations at the
  pull-back, and the notes line crosses the vector strip for a tenth of a second as it becomes it.
- Contrast: 46 of 46 sampled text pairs pass.
- `kit/check_facts.py`: every number with a unit is in `kit/facts.json`.
- Every time in the scene is a cue (`L`, `E`, `W`) plus an offset; none is typed as a film time.

## Looked at

Contact sheets of the whole film at one frame every 1.5 s (three runs), the middle of every line,
0.45 s into every camera move, three moves sampled at 0.1 s steps (the caption leaving the call, the
sound becoming words, the line becoming a vector), the hand-off to the end card at 0.15 s steps,
and nine frames at full size.

## Rendered

Rendered 2026-11-10 on the Ubuntu box (`render --quality high --video-frame-format png`, about 20 s)
and mastered with `kit/master.sh`: `renders/one-sentence.mp4`, 59.8 s, 1920 × 1080, 30 fps, H.264 + AAC.

- A contact sheet every two seconds and strips of ten frames a second across three camera moves, the pull-back and the hand-off were read from
  the rendered file, and match the snapshots.
- Sound, measured: integrated -16.2 LUFS, peak -1.4 dBFS. A local Whisper hears all ten lines of
  the finished mix in order, under the effects.

After the first review two things changed: `One Mac.` lands on "running", ahead of its word, so the
finished line holds two seconds, and the EmbeddingGemma 2 plate moved 26 px left, clear of its
neighbour.

## Not checked

- Nobody has listened to it: the voice's delivery and its balance against the effects are measured,
  not heard. The effects are placed against the cues: key ticks under the three typed texts, a key
  press on Tab, a click on the switch, one whoosh on the pull-back, a pop on `9.6 GB`.
- Not looked at at phone width. Plate names are 60 px and their mono lines 28 px, so on a phone the
  names read and the format lines do not.

## Weakest shots

- **MEANING (about 29.8 to 31.3 s).** The vector strip on a wide bed is the sparsest station and has
  the screen for a second and a half, because the line gives both it and the database 5.4 s. Its
  plate is on screen about 2.5 s for eight words.
- **The first second and a half of TRACKS (about 5.9 to 7.5 s).** The capsule rests between two
  empty lanes with only a playhead moving and one label arriving, until "two tracks" fills them.

Smaller: the amber line crosses the transcript page for 0.3 s on its way from the notes to MEANING;
at the pull-back the five large plates cover most of three of the stations they name; `One
sentence.` lands half a second after its word, because the Mac is still shrinking under it.

## With more time

- Draw the model in TYPING as more than a block with a window, and give the Tab key a hand or a
  keyboard to belong to.
- A second amber route style for the pull-back that passes over, not under, the plates.
- Give MEANING another second by trimming the pause before a07 and holding the camera.
