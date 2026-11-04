# Landing page demos

The short clips at the top of the home page and in its feature cards. Each one is
the real app doing the real thing on a fictional library, filmed on a Mac, then framed
and retimed here. Nothing inside a window is redrawn.

| Clip | Where | Take |
| --- | --- | --- |
| `meetings` | Hero | `live`, then `notes`; the tall cut ends on `notes-tall` |
| `search` | Hero | `search` |
| `autocomplete` | Hero | `autocomplete`, `autocomplete-tall` |
| `dictation` | Hero | `dictation`, `dictation-tall` |
| `ask` | Hero | `ask`, `ask-tall` |
| `agents` | Hero | `agents/`, a terminal recording |
| `today`, `files`, `timeline`, `people` | Feature cards | The take of the same name |
| `projects` | Feature card | `projects`, then `projects-note` |

Hero clips come as `wide` (16:10, 1920×1200) and `tall` (4:5, 1080×1350), in `light`
and `dark`, as `web/assets/demos/<clip>-<cut>-<appearance>.mp4` with a `.webp` poster.
Cards are wide only. The page picks the file for the viewer's width and appearance.
The `-tall` takes film a narrow window, so text wraps to the phone cut instead of
running off its edge.

## What is real

- **The app:** a Debug build of `master` at the commit in the apps run, the same build
  on every Mac. `meetings`, `search`, `today`, `timeline`, `people`, `projects`, `ask` and
  `dictation` run the UI Test Host; `files` and `autocomplete` run `LokalBot.app`, because
  the host never reads folders.
- **The Macs:** `meetings` and `ask` on an M4 Max MacBook on macOS 27 (`film-local.sh`),
  the rest on GitHub's hosted Macs on macOS 26.
- **The models:** Parakeet, Qwen3.5 4B, Gemma 4 E2B and EmbeddingGemma 2, on the
  filming Mac. The live transcript, the `Spring campaign` notes, the Ask answer, the
  notes in `projects`, the dictated message, the autocomplete suggestion and the Files
  results are what they produced. Nothing reaches a remote model.
- **The input:** real pointer and key events from `Scripts/readme-gif/rig.swift`. The
  pointer, click ripples and keycaps in the clips are drawn by `compose.py` at the
  times and points the rig logged.
- **The audio:** a call of two synthesized voices, played into the app through its test
  microphone and call-audio inputs (`LOKALBOT_UI_TEST_AUDIO`), with a replayed capture
  trace saying a Google Meet call is open (`film/call-trace.json`).
- **The data:** fictional. `film/stage.py` seeds the libraries and writes the call, the
  dictation and the files.

## What is not

- **Waits are cut.** A hosted Mac is a 7 GB virtual M1 with no GPU acceleration: an Ask
  answer takes 10 to 30 minutes there. On the MacBook it takes about 20 seconds, and notes
  about 20 more after a call. `edit.json` cuts those waits, and the page says so under
  each clip. Typing is sped up in some clips.
- **The seeded screens are seeded.** `search`, `today`, `timeline`, `people` and the
  meetings behind them are written by `Scripts/seed_demo_library.py`, not generated.
  `film/stage.py track` sets the projects `projects` opens with. The take tracks the
  suggested one and the model writes its note. That's two takes of one launch, since
  recording slows a hosted Mac's model too much, and the clip dissolves across the wait.
- **One title is typed by hand.** `film/stage.py polish` names the recorded call
  `Spring campaign`, as a person would after the meeting.

## Rebuild

Film on GitHub's Macs by dispatching `.github/workflows/landing-demos.yml`. Each line of
`film/takes.txt` is one Mac and the takes it films; `ask@dark` films one appearance, and
the others use `film/appearances.txt`. Set `film/probe.txt` to `1` to save the
accessibility tree at each `mark`. `film/apps-run.txt` names an earlier run to reuse its
apps; empty builds them again, which is what you want after an app change. Each Mac's
takes land in a `landing-demos-footage-<n>` artifact. GitHub drops a job it can't find a
runner for within about 15 minutes, so rerun those.

`film/film-local.sh` films `live`, `notes` and `ask` on your own Mac in about 10 minutes.
It leaves system settings and other apps alone; its header says what it needs.

Local models vary from take to take. An Ask answer without a citation fails the take, and
so does dictation that writes the window's title into the message, and both are filmed
again. Check the notes on a contact sheet before cutting.

Hosted Macs vary too, by about 3x. The app gives a model request 10 minutes, which a slow
Mac can miss, so a take that needs the model can go on several lines of `film/takes.txt`.
The first Mac to finish is enough, and the run can then be cancelled.

Capture leaves other apps' windows out, so a system dialog never shows in a take but
still catches its clicks. `UserNotificationCenter` is the one seen so far. On hosted Macs
`rig windows kill` runs throughout a pass to close them, and `logs/windows.txt` lists what
was on the display before each take.

Cut on a machine with ffmpeg, GNU parallel and Pillow, away from a laptop, with every
Mac's `clips` gathered in one folder:

```sh
gh run download <run> -R stevyhacker/LokalBot -n landing-demos-footage-1 -D footage
LANDING_FONT=<a copy of SF, off macOS> Video/lokalbot-landing-demos/build.sh footage out
```

`edit.json` is the edit: which parts of which takes play at what speed, and where the
camera looks. Its times are anchors from each take's events, so one edit fits light and
dark. `compose.py`'s docstring has the format. Check the output on contact sheets, then
copy it to `web/assets/demos/`.

`agents/` holds the terminal clip: `prepare.sh` sets up Claude Code on a Linux box with
the released `lokalbot-cli` on a fictional library, `record.py` records a take with
asciinema, and `cut.sh` renders it with `render.js` (xterm.js in headless Chromium, with
the ANSI colors remapped per appearance).
