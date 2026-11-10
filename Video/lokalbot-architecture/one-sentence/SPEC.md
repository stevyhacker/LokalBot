# SPEC: One Sentence

```text
GOAL:    The viewer can retell where one spoken sentence goes inside LokalBot (sound, speakers,
         words, notes, the database, a typed sentence, an agent) and knows five named models on
         their own Mac did it.
OUTPUT:  HyperFrames 0.8.150, 1920 x 1080, 30 fps
TIME:    59.8 s; the voice is the clock (build.py prints the exact length and cues.txt every
         word). The world scene has 52.5 s, the shared end card 7.3 s.
LOOK:    Inside the Mac: ground #0e151d, surfaces #17222d, structure lines #3a7d72 at 4 px,
         machine parts in the robot's mint (#6ef2dc to #23c4ae), type #eafffa.
         Outside (the pull-back): ground #c9f1e7, the Mac a slate slab, type #0e141c.
         Amber #fbbf24 is the sentence and nothing else: its level meter, its caption, its
         waveform, its words, its line in the notes, its vector, its dot in the database, its
         ghost text, its answer, the route it has travelled. One amber thing is on screen at
         every moment of the world scene.
         Type: Inter 900 for the opening question (110 px, -0.04em); model plates from the kit
         (.plate: 60 / 34 / 28 px); JetBrains Mono 500 for file names, paths and API names
         (28 to 48 px). Medium: a flat machine diagram: solid fills, 4 px lines, 18 to 28 px
         radii. No gradients but the mint body gradient, no glow, no shadows, no particles.
OBJECTS: the call (a window with two tiles, "Maya" and "You", and a caption bar);
         two audio tracks (lanes with bar waveforms, `mic.m4a` and `system.m4a`);
         speaker turns (coloured segments under the lanes, each with a name);
         the words (the sentence set large, a tick and a time under each word);
         a transcript page and a notes page (`transcript.md`, `summary.md`);
         a vector (a strip of numbered cells) and a field of dots, three of them named;
         the database (`lokalbotv3.sqlite`, two compartments: keywords, vectors);
         a page with a caret, ghost text, a Tab key, and the model as a mint block under it;
         a terminal, and a gate with a switch on the band that leads to it;
         the Mac (a display slab with a base, the whole world inside it).
MOTION:  camera moves power2.inOut, 0.9 s (the pull-back 1.4 s), started in the pause before a
         line; arrivals expo.out 0.5 s; things that drop or dock back.out(1.4) 0.25 to 0.45 s;
         exits power3.in 0.2 to 0.3 s; labels wipe in from their rule (power3.out, 0.38 s);
         text arrives typed or word by word (blur 6 px to 0, 0.13 s, 0.07 s apart), never slid;
         a landed label is dead still. One hero move per station.
BANNED:  a dark void with small things in the middle (every station's machine fills 40% of the
         frame or more, and the route band crosses every frame); glow, particles; three cards
         in a row; every part fading and sliding up; pill chips; numbered station labels;
         corner HUD text; a legend; the voice's sentence repeated on screen; amber on anything
         that is not the sentence.
QA:      listed at the end.
```

## The world

One composition, `compositions/world.html`. The root's background is mint `#c9f1e7` (only seen at
the pull-back). Inside it the camera wrapper `#w-world` holds the inside of the Mac: a slate slab
that runs 200 px past a 5760 × 3240 map on every side (radius 260), so no station's frame ever
shows its corner. The map is 3 × 3 cells of 1920 × 1080; the camera shows one cell at scale 1
(`x = -col * 1920`, `y = -row * 1080`).

```
(0,0) CALL        (1,0) TRACKS      (2,0) SPEAKERS
(0,1) TYPING      (1,1) DATABASE    (2,1) WORDS
(0,2) AGENT       (1,2) MEANING     (2,2) NOTES
```

The route is the spiral CALL → TRACKS → SPEAKERS → WORDS → NOTES → MEANING → DATABASE → TYPING →
AGENT, drawn in the slab as a 120 px band (`#17222d`, round joins) through the cell centres, 12,000
px long. An amber line 8 px wide is drawn along it as the sentence advances (stroke-dashoffset), so
at the pull-back the whole route is traced (a second copy, 44 px wide, sits on top for that shot).
The sentence travels on the band from station to station and stays in frame during every camera
move: it is what the eye follows.

TRACKS and SPEAKERS share one recorder, a panel that runs across both cells, so the camera only
pans 1100 px between them and the SPEAKERS shot sits left of its cell's centre.

Every model's label is a kit plate beside its machine: the model's name, a job in three words or
fewer that the voice does not say, and a mono line with format and size.

## Shots (times from `cues.txt`; every time in the scene is `L()`, `E()`, `W()`)

| Line | Station | What happens, and on which word |
| --- | --- | --- |
| a01 "Someone on your call says one sentence. Let's follow it through LokalBot." | CALL | Frame 0 is the call window filling the frame (the camera opens at 1.45 and settles to 1.3 in 1.4 s): two tiles, Maya's outlined as speaking, her level meter moving in amber. On "says" her caption types in word by word, `The offsite is in Lisbon, May 12 to 14.`, ink on an amber block. On "let's" the camera eases back to scale 1 and the question lands at the right in three lines, `Where does it go?` (Inter 900, 110 px). At the end of the line the caption closes into an amber capsule of bars (512 × 120), slides out of the caption bar, rises to the band and leaves to the right; the camera goes with it. |
| a02 "First it's only sound: two tracks, your microphone and the call app's audio." | TRACKS | The recorder's two lanes are there, empty; the capsule rests on the band between them and a playhead crosses it. On "sound": `No bot joins the call` (Inter 700, 40 px) under the recorder. On "two tracks" both waveforms grow from the left; after "tracks" the capsule drops into the lower lane as its latest stretch, and the recording goes on growing. Just before "microphone" the upper lane is named `mic.m4a` with `AVAudioEngine` under it; just before "call" the lower one `system.m4a` with `Core Audio tap`. |
| a03 "When the call ends, a speaker model marks who spoke when." | SPEAKERS | The camera pans along the lanes. On "ends" the waveforms stop at an end mark. Just before "speaker" the plate wipes in, `Nemotron 3` / `speaker turns` / `Core ML · 0.20 GB`; on "speaker" a mint scan bar crosses both lanes (0.9 s) and leaves turn segments under them, mint for `You`, paper for `Maya`, named on "who" and "spoke". Then the amber stretch leaves the lane, goes right along the band and down; the camera follows it, right then down. |
| a04 "A speech model turns the sound into words, each one pinned to its moment." | WORDS | The capsule arrives on a wide bed with the plate `Qwen3-ASR 1.7B` / `52 languages` / `MLX 8-bit · 2.47 GB`. On "turns" a playhead crosses it; on "words" it widens into a block 1520 px wide, its bars fold away and the words come in left to right, `The offsite is in Lisbon, May 12 to 14.` (Inter 800, 66 px, ink on amber), tagged `Maya`. On "each" a second, smaller plate: `Qwen3 forced aligner 0.6B` / `word timings, 11 languages` (a helper, never counted as a model). On "pinned" a tick and a time land under each word, on two rows so none collide (mono 28 px, `0:10.2` … `0:12.7`, illustrative). |
| a05 "A language model reads the whole transcript and writes the notes: decisions, action items, open questions." | NOTES | The block shrinks to a transcript line and comes down into its row. Left, the transcript (`transcript.md`): eight rows of speaker and line, the amber one fourth. Right, a dashed outline named `summary.md`: the file not yet written. Plate: `Qwen3.5 4B` / `notes and answers` / `llama.cpp Q4_K_M · 2.74 GB` / `26-minute meeting: 33 s · M4 Max`. On "reads" a mint bar reads down the rows (1.25 s). On "writes" the notes page opens in paper white over the outline. The headings arrive on their words, `Decisions`, `Action items`, `Open questions`; the amber line crosses and lands under `Decisions`; under the others, the lines the app really wrote for this meeting: `Pay the venue deposit for the Lisbon rooftop location by Friday.` and `It is undecided whether everyone will fly in on Sunday.` |
| a06 "An embedding model files it by meaning, beside a keyword index, in one database." | MEANING, then DATABASE | The amber line travels left; on "embedding" the plate wipes in, `EmbeddingGemma 2` / `search by meaning` / `llama.cpp Q8_0 · 0.31 GB`, and the line opens from its middle into a strip of ten numbered cells (`0.12  -0.48  0.07 …`, mono 34 px) labelled `768 dimensions`. Before "meaning" the cells close into one amber dot, and the camera rides the band up with it to DATABASE: one large file, `lokalbotv3.sqlite`, with its path `~/Library/Application Support/me.dotenv.LokalBot/` and two compartments. On "keyword": `keywords · FTS5`, a short index; on "index" its `Lisbon` row is marked amber. Then `vectors · 768-d`: the dot lands in a field of paper dots, three neighbours named (`rooftop venue`, `travel budget`, `team dates`). |
| a07 "Days later you start typing, and a model built for speed finishes the sentence." | TYPING | A copy of the dot leaves the database along the band; the camera goes with it. A paper page: before "typing", `The offsite is in` types in (Inter 500, 64 px) with a caret; on "typing" the plate wipes in, `Gemma 4 E2B` / `autocomplete` / `llama.cpp Q6_K · 3.85 GB` / `56 ms median a keystroke · M4 Max` / `memory snippets: opt-in`. On "model" the dot drops into the model, a mint block under the page. On "finishes" it shoots to the caret and the ghost text appears, `Lisbon, May 12 to 14.` (ink at 50% on amber at 32%); on "sentence" the Tab key presses and it turns solid. |
| a08 "And only if you allow it, your coding agent can ask for it too." | AGENT | An amber dot comes down the band to a shut gate. Left of it, `agent access` / `off by default` and a switch at off; right of it, after the switch, `lokalbot-cli mcp · stdio · read-only` (mono 28 px). On "allow" the switch goes on (mint) and the gate opens. Before "agent" `> Where is the offsite?` types in the terminal below; on "ask" `lokalbot · search_meetings("offsite")`; the dot goes through the gate and, on "too", the answer appears on its amber block. |
| a09 "One sentence, five models, under ten gigabytes. All of it running on your Mac." | pull back | Starting 0.3 s before the line, the camera pulls back (1.4 s) to scale 0.225: the slab is a Mac's display (bezel, a base under it) on mint, the amber route traced through it, the station plates gone. Over their cells, in screen space, five plates on slate appear one after another from "five": `Nemotron 3` `0.20 GB`, `Qwen3-ASR 1.7B` `2.47 GB`, `Qwen3.5 4B` `2.74 GB`, `EmbeddingGemma 2` `0.31 GB`, `Gemma 4 E2B` `3.85 GB` (name 40 px, size in mono 28 px). Under the Mac one line lands in four parts (Inter 800, 60 px, ink): `One sentence.` as the pull-back settles, `Five models.` on "five", `9.6 GB.` on "ten", `One Mac.` on "Mac". On "all" a paper bead runs the whole route once. |
| hand-off | | After the line the amber route runs back along itself into its end, a dot leaves it for left 751, top 625.5 (50 px), and the Mac, the plates and the line leave downward (power3.in, 0.45 s). At `SLOT` only mint and the dot are left. |

## Sound (in `build.py`)

A typing loop under the caption, the typed sentence and the terminal; `key-press` on Tab;
`click-soft` on the gate's switch; `whoosh` once, on the pull-back; `pop` on `9.6 GB`. Camera moves
between stations are silent. The end card brings `impact-bass-1`.

## QA frames

For each: the amber sentence is on screen, the station fills the frame, no label is under 28 px.

- 0.0 s: the call window and the speaking tile, a full frame, not black.
- the middle of each line a01 to a08: its station as in the table.
- 0.45 s into each camera move: the sentence in frame, two stations in frame.
- "pinned" + 0.5 s: every word has its tick and time, no overlap.
- "decisions" + 1.4 s: the amber line under `Decisions`.
- the end of a09: the whole Mac, five plates readable, the four-part line complete.
- `SLOT`: mint and the dot only.
