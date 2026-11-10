# SPEC: Inside the Mac

```text
GOAL:    The viewer knows what is physically in there: five named model files with their sizes,
         three engines, one library folder, and an edge whose doors stay shut until they open
         them. They stop asking "which cloud?".
OUTPUT:  HyperFrames 0.8.150, 1920 x 1080, 30 fps
TIME:    63.3 s; the voice is the clock (build.py prints the exact length, cues.txt every
         word). The world scene has 55.6 s, the shared end card 7.7 s. Pauses between lines
         are 0.2 to 0.25 s; the last line has 1.0 s after it so its three parts can be read.
LOOK:    Ground #f1faf7, flat. The Mac and everything structural in slate: #0e151d bodies,
         #17222d faces, #222e3d edges. The five model files in the robot's mint (#6ef2dc to
         #23c4ae, the icon's own gradient) with ink #0e141c type. Engines in slate with a teal
         #3a7d72 edge and paper #eafffa type; the library is paper white with ink type. Quiet
         lines and leaders #3a7d72, 4 px.
         Amber #fbbf24 is "your work" and nothing else: the meeting that does not go to the
         cloud, the files the models write, the dot at the doors. Never an outline or a focus ring.
         Type: Inter 900 for the opening question (84 px), the 9.6 GB (120 px) and the last
         line (76 px), -0.04em; Inter 800 for layer and model names (38 to 54 px); JetBrains
         Mono 500 for file names, paths, ports, formats and sizes (28 to 46 px).
         Medium: an exploded product drawing: flat faces, a darker side face for thickness (10
         to 24 px), one soft shadow under a lifted layer (rgba(14,21,29,0.2), 34 px blur, 34 px
         below). No gradients but the mint one, no glow.
OBJECTS: the MacBook (isometric: base with a key grid and trackpad, display with the real app);
         a cloud (dashed outline with a question mark, struck through);
         four layers the size of the base: the app, the model board, the engines, the library;
         five model files as slabs whose widths are their file sizes;
         three engine rails and a chip under them;
         the library's folder, opened into its tree;
         the edge: a wall named `your Mac`, two arrows in, three shut doors with switches.
MOTION:  layers lift and settle power2.inOut 0.7 s; a face turns in 0.8 s power2.inOut; model
         slabs drop in with back.out(1.4) 0.45 s; the tree is typed in steps, one character a
         step; labels arrive with a 6 px blur, 0.15 s, never slid; exits power3.in 0.3 s.
         A landed label is dead still. One hero move per beat.
BANNED:  three cards in a row (the model slabs are one bar, to scale, not cards); a legend;
         icons in circles; everything fading and sliding up; pill chips; glow; a dark void;
         the voice's sentence repeated on screen; amber as a highlight colour; Apple's logo;
         a label under the chip (it reads as a claim about the chip); "bundled" said of all three
         engines (only llama.cpp is in FACTS.md as bundled).
QA:      listed at the end.
```

## Isometric, in 2D

No CSS 3D. A face is a plain div under a 2D transform, so type on it stays sharp and nothing
z-fights; paint order is DOM order.

- Top face (lying flat): `rotate(30deg) skewX(-30deg) scaleY(0.866)`, origin at the face's back
  corner. In GSAP: `{ rotation: 30, skewX: -30, scaleY: 0.866 }` (GSAP writes
  `rotate() skew() scale()` for an HTML element, so the numbers are the CSS ones). Its width runs
  down-right, its depth down-left.
- A wall standing along the width: `skewY(30deg) scaleX(0.866)`; along the depth:
  `skewY(-30deg) scaleX(0.866)`.
- Height is plain screen `y`: a layer lifted by 140 is the same face moved up 140 px.
- A face turns to the camera by tweening `rotation` and `skewX` to 0 and the scales to 1. The
  app's window swings between the display (a wall) and the top layer (a top face): both share
  their top edge, so it is one tween of `skewY`, `rotation`, `skewX` and the scales.
- A static face carries its transform in CSS and is moved through a wrapper; a face GSAP turns
  (`#m-appface`, `#m-shell`, `#m-board`) gets its whole transform from `gsap.set`.

The base is 660 × 420 (width × depth): about 935 px wide and 540 px tall on screen. Exploded
heights: library 0, engines 140, models 280, the app 420. What a lower layer carries sits in its
front strip, the part the layer above leaves visible.

The model board exists twice: a small one inside the isometric Mac (`#m-L-models`), and the one
that turns to face the camera (`#m-board`, 1680 × 560, drawn flat and squeezed onto the same
footprint). They are swapped on the frame the turn starts.

## Shots (times from `cues.txt`; every time in the scene is `L()`, `E()`, `W()`)

| Line | What happens, and on which word |
| --- | --- |
| b01 "People ask which cloud LokalBot sends their meetings to. By default, none. It all runs inside your Mac, so let's open it." | Frame 0: the open MacBook, isometric, right of centre and large; on its display the real app (`assets/app-notes.png`, the Offsite planning notes). Top left, already there: `Where do your meetings go?`. On "ask" an amber dot, a meeting, shows on the screen. On "cloud" a dashed cloud with a question mark draws at the top right. On "sends" the dot leaves the display toward it and stops short. On "none" a slate stroke strikes the cloud through, the cloud fades to 25%, and under it: `no account, no telemetry` (mono 28 px). On "inside" the dot drops back into the Mac. On "open" the app's window swings up off the display and lies flat as the top layer; the lid folds down, the key deck slides off, and the base is an open tray with the model board in it. The Mac moves left to make room for the names. |
| b02 "Under the app, there are three layers: the models, the engines that run them, and your library." | Each layer is named at the right with a leader (Inter 800, 54 px): `the app` on "app". On "three" the two layers lying in the tray lift a little, so three can be counted. `models` rises on "models" (a board with the five mint files), `engines` on "engines" (three teal rails), and under it the `library` is found: a paper folder with the amber dot resting on it, named on "library". |
| b03 "Five models, each with one job: turning speech into text, telling speakers apart, writing your notes, finishing your sentences, and searching by meaning." | After b02 the names go, the app leaves upward, the engines and the base downward, and the model board turns to face the camera, mid-frame. On "five" its five empty sockets are outlined one after another; on "each": `five model files, widths to scale` (mono 28 px). Then one slab seats on each phrase, left to right, 167 px a GB: `Qwen3-ASR 1.7B` (413 px) on "speech"; `Nemotron 3` (33 px, its name on a flag above) on "speakers"; `Qwen3.5 4B` (458 px) on "notes"; `Gemma 4 E2B` (644 px) on "sentences"; `EmbeddingGemma 2` (52 px, a flag) on "meaning". As each lands a small drawing of its job plays once: bars becoming lines of text; two rows of speaker turns; lines becoming three bullets; `The offsite is in` typed and ` Lisbon, May 12 to 14.` offered; a dot joining a cluster. |
| b05 "Together, nine point six gigabytes of files, downloaded once." | The board moves up. On "together" each slab's size lands under it (mono 30 px): `2.47 GB` `0.20 GB` `2.74 GB` `3.85 GB` `0.31 GB`. On "nine" a bracket spans the bar and `9.6 GB` lands under it (Inter 900, 120 px). On "files" each file's format shows on it: `8-bit`, `Q4_K_M`, `Q6_K`, `Q8_0`. On "downloaded": `from Hugging Face, each file checked by SHA-256` (mono 28 px). |
| b06 "Three engines run them on your Mac's own chip, with nothing else to install." | The sizes and the bracket leave; the board grows downward and three rails rise in the new strip, each as wide as the files it carries, and the slabs settle onto them on "engines": `MLX` under Qwen3-ASR; `Core ML` under Nemotron 3 (its name below the rail); `llama.cpp · Metal` under the last three. On "run": `:17872` (Qwen3.5 4B), `:17873` (EmbeddingGemma 2), `in-process` (Gemma 4 E2B). On "chip" one wide slate chip, `Apple silicon`, draws under the board, joined to it by pins. On "nothing", at the right of the llama.cpp rail: `bundled with the app` (it is the engine the app ships; Core ML is part of macOS). |
| b07 "Whatever they produce lands in one folder: plain files, and a single database for search." | The board leaves upward and the library rises to fill the frame: a paper folder, its tree typed in ink (mono 46 px): `~/Library/Application Support/me.dotenv.LokalBot/`, then on "lands" `├── meetings/2026/11/09-offsite-planning/`, and four amber dots fall onto the next row and become its files: `mic.m4a  system.m4a  transcript.md  summary.md`. From "folder": `├── journal/2026-11-09.md`, `├── models/`, `└── lokalbotv3.sqlite`. On "plain" the four file names take an amber block. On "database" `lokalbotv3.sqlite` takes one too, with `keywords (FTS5) + vectors (768-d)` beside it (mono 28 px). |
| b08 "Model files and updates come in. Your work goes out only where you send it: a remote model, an agent, your phone." | The camera pulls back from the folder to the whole Mac: the open stack, smaller, inside a wall named `your Mac`. On "model" and "updates" two mint arrows come in from the left, `model files` and `updates`. On "work" the amber dot shows on the library; on "out" it goes to the wall and stops. On "only" three shut doors draw on the right of the wall, each with a switch at off; on "send": `off until you turn it on` (mono 28 px). The doors are named as the voice names them, `a remote model`, `an agent (MCP)`, `your phone` (Inter 700, 40 px), and the dot goes to each and stops at it. |
| b09 "Close it up, and it's all still in there." | On "close" the layers sink into the base; a moment later the wall and its doors go, the lid stands, the app's window swings back onto it, the deck slides home, and the Mac comes forward. The line lands under it in three parts (Inter 900, 76 px): `Five models.`, `9.6 GB.` on "it's", `Inside your Mac.` on "still", and the amber dot shows on the display. |
| hand-off | The dot lifts off the Mac and moves to left 751, top 625.5 (50 px) as the Mac and the line fade down (power3.in, 0.4 s). From `SLOT` only the dot is left, and the end card's mint opens from it. |

The end card's small print is this film's own (`NOTE` in `build.py`): it shows no speeds, so it says
the app on the screen is real, on fictional data.

## Sound (in `build.py`)

`whoosh-short` once, when the Mac opens; a soft landing on each of the five slabs (`pop` and
`click-soft` alternating, 0.22 to 0.25); `pop` on `9.6 GB`; a typing loop under each typed line of
the tree, never two at once; `whoosh` when it closes. The end card brings `impact-bass-1`.

## QA frames

- 0.0 s: the MacBook with the real app on its display, and the question: a full frame.
- "none" + 0.6 s: the cloud struck through, the amber dot beside it, the two-word caption.
- the end of b02: four layers apart, four names, leaders touching their layers, the dot on the folder.
- the turn: 0.15 s, 0.4 s and 0.7 s after it starts: one board, no jump at the swap.
- after each of the five phrases in b03: one more slab seated, its name readable, widths to scale.
- "nine" + 0.6 s: five sizes, the bracket, `9.6 GB`.
- "chip" + 0.5 s: three rails under the right slabs, the chip, the port tags.
- the end of b07: the whole tree typed, five amber marks, nothing clipped at the right edge.
- "phone" + 0.4 s: two arrows in, three shut doors, one amber dot at the third.
- the end of b09: the Mac closed, the line complete, the dot on the display.
- `SLOT`: the dot at left 751, top 625.5, nothing else.
