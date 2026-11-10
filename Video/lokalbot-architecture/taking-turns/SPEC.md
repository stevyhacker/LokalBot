# SPEC: Taking Turns

```text
GOAL:    The viewer understands the mechanism: the five models are files on disk, each comes
         into memory only while its job runs, and a broker decides who is in. They can say why
         five models do not need five models' worth of memory.
OUTPUT:  HyperFrames 0.8.150, 1920 x 1080, 30 fps
TIME:    62.9 s; the voice is the clock (build.py prints the exact length, cues.txt every
         word). The world scene has 55.2 s, the shared end card 7.7 s. Line pauses are 0.25 s,
         and 0.35 s where the clock's tape jumps ahead.
LOOK:    Ground #143a35 (deep teal), flat. The desk (memory) #1b4a44 with a 4 px #3a7d72 edge;
         the shelf (disk) a #0e151d ledge. Model files in the robot's mint (#6ef2dc to #23c4ae)
         with ink #0e141c type. Type on the ground #eafffa. Quiet lines #3a7d72, 4 px; quiet
         type #8fc9bd.
         Amber #fbbf24 means "working right now" and nothing else: a 16 px top edge on the one
         model that is running, and the thing it is producing (a transcript line while it is
         written, the notes' lines, the suggested text, the answer). At most one model is amber.
         Type: Inter 900 for the question, the 9.6 GB and the last line (84 to 230 px, -0.04em),
         Inter 800 for names (28 to 44 px), JetBrains Mono 500/700 for the clock, timers, file
         names and sizes (28 to 52 px). Medium: a flat stage diagram: solid fills, 20 px radii,
         a darker 12 px side face under each block so it reads as a thing with weight. No glow,
         no gradients but the mint one, no particles.
OBJECTS: five model files (blocks whose widths are their file sizes);
         a laptop (front view: display with LokalBot's mark on it, base), whose screen grows
         past the frame: from then on the film is inside the Mac;
         the shelf: a ledge the files stand on (the disk), there from the first frame;
         the desk: a wide surface above it (memory), blocks docked at its left, the job's
         material at its right;
         the clock: a tape of minute ticks sliding under a fixed playhead, with a time readout;
         timers: a countdown and a draining bar over a block;
         two tickets in a queue; the budgeted half of the desk, tinted, up to a dashed line.
MOTION:  a copy comes into memory in 0.6 s, across first and then up (x power3.out, y
         power2.inOut), so it runs along under the desk and rises into its place without
         crossing what the desk shows; it leaves with power3.in 0.35 s; the tape
         slides linearly while time passes and whips (0.4 s, power3.inOut) on a jump; countdown
         digits change in steps; big type arrives word by word (blur 6 px to 0), labels by
         opacity alone (0.15 s), text is typed; a landed label is dead still.
         Every model makes the same move (up, work, wait, down): the repetition is the point,
         so the framing changes between them (wide, then 1.15x on the desk, then wide).
BANNED:  a memory bar with gigabytes on it (9.6 GB is files, never memory, and it leaves the
         frame before the desk is drawn); a legend; a Gantt chart; three cards in a row; pill
         chips; glow; everything fading and sliding up; the voice's sentence repeated on
         screen; amber on anything that is not working right now; any hint that all five are
         never loaded together (they take turns; on a big Mac several can be in at once).
QA:      listed at the end.
```

## The stage

- **Clock**, a band across the top 150 px that stays put while the camera moves under it, drawn in
  with c03: a tape of minute ticks (28 px a minute, a time every ten minutes) sliding left under a
  fixed playhead at x 960; beside the playhead the time (mono 700, 52 px). Events are printed on
  the tape as their time comes: a `call` bar from 10:00 to 10:26, `hang up`, `typing` at 11:40,
  `a question` at 15:10.
- **Desk** (memory), (120, 176) 1680 × 464, named `memory` (Inter 800, 40 px) at its top left. It
  is drawn in c02, when the voice gets to memory. Loaded blocks stand at its left, 260 px tall,
  widths at 105 px per GB of file; from x 520 it is the work area: what the running model is
  reading or writing.
- **Shelf** (disk), a ledge at y 952 from x 120, 1680 wide; the five files stand on it, 190 px
  tall, widths at 125 px per GB: `Qwen3-ASR 1.7B` 309 px, `Nemotron 3` 25 px, `Qwen3.5 4B` 343 px,
  `Gemma 4 E2B` 481 px, `EmbeddingGemma 2` 39 px. Wide blocks carry their name (Inter 800, 32 px,
  ink) and size (mono 28 px); the two thin ones carry them on a flag above, with a leader. Named
  `disk` at its left, and from c02 `9.6 GB of model files` under it.
- A file that loads stays on the shelf: a copy rises from it to the desk and later drops back into
  it. The file never leaves the disk.
- **Camera**: wide for c01 to c03 and c07 to c08; for c04 to c06 it goes to 1.15× on the desk
  (`x -64, y -44`), which still holds the whole shelf.

## Shots (times from `cues.txt`; every time is written as `L()`, `E()`, `W()`)

| Line | What happens, and on which word |
| --- | --- |
| c01 "LokalBot runs five AI models on your Mac. So how does one laptop hold them all?" | Frame 0: three files stacked on the shelf with their names on them (`Gemma 4 E2B`, `Qwen3.5 4B`, `Qwen3-ASR 1.7B`), the two thin ones falling onto the top and named as they land (`Nemotron 3`, `EmbeddingGemma 2`), all within the first second; right of the tower a laptop with LokalBot's mark on its screen, half the tower's height. On "five", top right: `Five models.` (Inter 900, 110 px). On "Mac" a dashed line carries the laptop's height across to the tower. On "one", under the first line: `One laptop?`. |
| c02 "It doesn't have to. The models are files on your disk, under ten gigabytes, and they take turns in memory." | On "doesn't" the question, the two labels and the line leave, and the laptop's screen grows past the frame and settles into the ground: the film is inside the Mac. The shelf widens to the full stage. From "the" the tower comes apart, one file after another flying to its place on the shelf, the last landing on "disk"; the shelf is named `disk`. On "ten" the sizes land in the files and, large in the open space above them, `9.6 GB` (Inter 900, 230 px) with `of model files` under it. On "and" the number leaves, `9.6 GB of model files` settles beside `disk`, and the desk is drawn above the shelf; two files show the move once (up to the desk, down again, about 0.6 s each); on "memory" the desk is named `memory`. |
| c03 "During a call, LokalBot only records. Transcription waits until you hang up, and autocomplete pauses." | The clock draws in at `10:00` and the tape slides; a `call` bar grows on it and the time runs to `10:26` by the end of the line. In the desk's work area `recording` and two tracks draw as it records, `mic.m4a` and `system.m4a` (mono 30 px); no model is on the desk. On "transcription" the Qwen3-ASR file on the shelf gets a tag, `after the call`; on "autocomplete" the Gemma 4 E2B file gets a pause mark and `paused while recording` (mono 28 px on slate tags). |
| c04 "Then the speech models load, turn the sound into a transcript with speakers, and two minutes after they finish, they unload." | The tags leave, the tape prints `hang up`, the camera goes to the desk. On "load" copies of Nemotron 3 and Qwen3-ASR 1.7B rise to the desk, 0.1 s apart. On "turn" Nemotron works (amber): turn segments mark the two tracks. On "transcript" Qwen3-ASR works (amber): the tracks give way to four transcript lines (34 px), each amber while it is written, the last `The offsite is in Lisbon, May 12 to 14.`; on "speakers" each line gets its speaker (`You`, `Maya`). On "two" the amber goes out, a countdown `2:00` with a draining bar appears over both blocks beside `unload after 120 s idle`, and the clock runs two minutes. On "unload" both copies drop back into their files. |
| c05 "The language model comes in next and writes the notes. It stays ten minutes, in case you ask a follow-up, then leaves." | On "language" a copy of Qwen3.5 4B rises and works (amber). On "writes" a notes page draws at the right of the work area, `summary.md`, its headings arriving in turn with an amber line under each: `Decisions`, `Action items`, `Open questions`. On "notes": `26-minute meeting: 33 s warm, 60 s with the load · M4 Max` (mono 28 px; the model has just loaded, so the second number is this case). On "stays" the amber goes out, a countdown `10:00` and its bar appear beside `stays 600 s after its last request`, and the clock runs ten minutes. On "follow-up" a small outlined question bubble shows by the block and goes. On "leaves" the copy drops back, and the transcript and the notes leave. |
| c06 "The autocomplete model stays loaded while there's room, because it answers every keystroke in about fifty milliseconds." | Before the line the tape whips to `11:40`, `typing`. On "autocomplete" a copy of Gemma 4 E2B rises. On "stays": `no timer` (mono 28 px) where the countdown was for the others. After "room" a text field opens in the work area; from "because" it types `The offsite is in`, key by key (17 keys, the last 0.75 s after "keystroke"); at each key the block's amber edge flashes, and from the first key on the rest of the sentence stands after the caret as the suggestion, in dim amber, ending on ` Lisbon, May 12 to 14.` On "fifty": `56 ms median a keystroke · M4 Max`. |
| c07 "A broker budgets half your memory for loaded models, and what you're waiting for goes ahead of background work." | The tape whips to `15:10`, `a question`, and the camera goes wide; Gemma 4 E2B is still on the desk. On "half" the left half of the desk is tinted up to a dashed line, `budget: half of memory`. After "models" a `queue` forms in the right half: `day digest · background` first, then, on "what", `your question` behind it. On "goes" `your question` passes it, and a copy of Qwen3.5 4B rises to answer (amber), an arrow from the ticket to it and an amber line growing under the ticket. Both loaded blocks sit inside the budget. |
| c08 "Five models, one Mac, taking turns." | Everything on the desk drops back to the shelf and the tape runs on to `18:00`. The line lands in the empty desk, part by part on "five", "one", "taking": `Five models.` `One Mac.` `Taking turns.` (Inter 900, 84 px). From "taking" the five files make the move once more, one after another from right to left, 0.2 s each, a short hop, each amber while it is up. |
| hand-off | The last file's amber edge (Qwen3-ASR's) closes into one dot, which moves to left 751, top 625.5 (50 px) and is there 0.1 s before `SLOT`. The stage holds still. At `SLOT` the end card's mint opens from the dot. |

One simplification is deliberate: the film shows the language model coming in after the speech
models have unloaded, as the voice tells it. In the app the notes start as soon as the transcript
is written, while the speech models are still inside their two minutes.

## Sound (in `build.py`)

`whoosh-short` when the tower comes apart; `pop` when `9.6 GB` lands; a soft landing each time a
copy reaches the desk (`pop` and `click-soft` alternating, 0.22 to 0.3); two runs of the typing loop
and one `key-press` on the last key of c06; `whoosh-short` on the two tape whips at 0.16. The end
card brings `impact-bass-1`.

## QA frames

- 0.0 s: three named files stacked, two falling, the laptop: a full frame.
- "one" + 0.6 s: all five named, the question complete, the dashed line.
- "ten" + 0.5 s: five files on the shelf with names and sizes, `9.6 GB` large above them, no desk.
- the end of c02: `9.6 GB of model files` beside `disk`, an empty desk named `memory`.
- the middle of c03: the clock running, `recording`, two tracks, both tags on the shelf.
- "transcript" + 1 s: two copies on the desk, one amber, transcript lines with speakers.
- "two" + 1 s: the countdown over both, the clock two minutes on.
- "writes" + 1.5 s: the notes page with its three headings.
- "keystroke" + 0.5 s: the text field mid-sentence with the suggestion after the caret.
- "goes" + 1.2 s: the tinted half, the tickets swapped, Qwen3.5 4B amber, the arrow.
- the end of c08: the line complete, the shelf full.
- `SLOT`: the dot at left 751, top 625.5.
