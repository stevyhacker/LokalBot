# Review: Taking Turns

Built and rendered 2026-11-10: `renders/taking-turns.mp4`, 62.9 s, 1920 × 1080, 30 fps. The review
below is from `check` and snapshots of the seeked timeline; "Rendered" says what the video file added.

## Creative calls

- **A stage, not a chart.** The disk is a shelf, memory is a desk above it, and loading is a copy
  of a file coming up from the shelf. The file itself never leaves the shelf, which is the fact the
  film is about. Widths are file sizes, on the shelf and on the desk; memory never gets a number.
- **The opening is the wrong picture.** Five files in a tower twice as tall as the laptop, and the
  question. Then the laptop's screen grows past the frame, so the rest of the film is inside the
  Mac, and the tower is taken apart onto the shelf, one file at a time.
- **9.6 GB lands once, large, in open space,** before the desk exists, and leaves before the desk is
  drawn where it stood. Afterwards it is a small label beside `disk`.
- **The clock is a tape.** Minutes slide under a fixed playhead, so "two minutes" and "ten minutes"
  are a distance you watch go by, and the two jumps in the day are whips of the same tape.
- **Amber is "working right now".** A 16 px edge on one model at a time, and what it is producing:
  the transcript line being written, the notes' lines, the suggested text, the answer.
- **Every model makes the same move.** Across under the desk, up into place, work, wait, down.
  The framing goes to the desk (1.15×) for the three jobs and wide again for the broker.

## Where it differs from the first brief

`SPEC.md` now describes the film as built. The changes, and why:

- The laptop does not morph into the desk. Its screen floods the frame instead, and the desk is
  drawn later, on "and they take turns in memory". With the desk up from second 7 the frame was a
  large empty box over a small shelf for six seconds.
- The files carry their names in the tower from frame 0 (a tower of unnamed blocks read as nothing),
  and the question lands in two parts, on "five" and on "one".
- The countdown sits over the blocks, not under them, and one countdown serves both speech models.
- The notes' timing reads `33 s warm, 60 s with the load`: in this scene the model has just loaded,
  so the second number is the true one for what is on screen.
- The budget is a tinted half of the desk up to a dashed line, not a line alone; the queue is in
  the other half.
- The closing "once more" is five short hops one after another, not five trips to the desk, so only
  one model is amber at a time and the line in the desk stays clear.
- Shelf widths are 125 px a gigabyte, so the whole shelf fits the close framing.
- One sound added: a `pop` when `9.6 GB` lands.

## A simplification to know about

The film shows the language model coming in after the speech models have unloaded, as the voice
tells it, and the clock reads 10:29 when it arrives. In the app the notes start as soon as the
transcript is written, while the speech models are still inside their two idle minutes. Nothing on
screen states the wrong order in words, but the picture implies it.

## Measured

- `npx hyperframes check`: 0 errors. One warning kept, `composition_file_too_large`: the film is one
  stage under one camera and one clock, so it is one scene file.
- Contrast: 61 of 61 sampled text pairs pass.
- `python3 ../kit/check_facts.py .`: every number with a unit is in `kit/facts.json`. (Its rule for
  seconds skips a number followed by a lowercase word, so `120 s idle`, `600 s after` and
  `33 s warm, 60 s with` were read by eye against `FACTS.md`, not by the script.)
- The speaker model's two minutes: `Services/NeuralDiarizationEngine.swift:30` (`idleSeconds = 120`),
  which `FACTS.md` does not list yet.
- The amber dot is at left 751, top 625.5 by 55.08 s; the end card takes over at 55.2 s.

## Looked at

Contact sheets of the whole film every 1.5 s, the QA frames in `SPEC.md` at full size, and denser
runs across every seam: the screen flooding the frame, the files landing, the desk being drawn,
both camera moves, each copy's rise and drop, both tape jumps, the last line landing and the dot.

## Rendered

Rendered 2026-11-10 on the Ubuntu box (`render --quality high --video-frame-format png`, about 20 s)
and mastered with `kit/master.sh`: `renders/taking-turns.mp4`, 62.9 s, 1920 × 1080, 30 fps, H.264 + AAC.

- A contact sheet every two seconds and strips of ten frames a second across the laptop becoming the stage, the speech models loading, a clock jump, the queue and the hand-off were read from
  the rendered file, and match the snapshots.
- Sound, measured: integrated -16.2 LUFS, peak -1.4 dBFS. A local Whisper hears all nine lines of
  the finished mix in order, under the effects.

## Not checked

- Nobody has listened to it: the voice against the picture, the eight effects and the two typing
  runs are measured, not heard.
- The film at phone width. The smallest type is 28 px (the shelf tags, the tape's times, `queue`)
  in the wide framing.

## Weakest shots

- **The call (c03).** Seven and a half seconds on the wide stage in which the only things moving
  are the tape, two waveforms and two tags arriving. It is the beat about nothing being loaded, and
  it looks like it. A drawn call (two speakers lighting as each talks) beside the tracks would help.
- **The queue (c07).** The pass is one ticket hopping over another in half a second, in the right
  half of a wide frame; a viewer looking at the tinted budget may miss it. More time, or a closer
  framing on the queue, would make the priority rule land.

## Next turn

Listen to the mix before anything else changes.
