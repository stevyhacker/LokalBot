# One Decision

A 48-second demo of LokalBot with a voiceover, made on 2026-11-09 and 2026-11-10 from nothing but
the app: new story, new fictional library, new footage, new edit. It follows one decision, "the
offsite is in Lisbon, May 12 to 14", from the call where it is made to every place LokalBot brings
it back. An amber highlighter marks it each time.

| Time | Title on screen | What plays | The voice |
| --- | --- | --- | --- |
| 0.0 | You decide it on a call | The app records a Google Chrome call; the line arrives in the live transcript | You decide something on a call. LokalBot records it on your Mac, and no bot joins. |
| 6.2 | LokalBot writes it down / Every note cites its line | The notes' decision, then a click on its citation opens the transcript at that line | Seconds after you hang up, it's in your notes, linked to the moment it was said. |
| 12.0 | One search brings it back | Quick Recall finds "lisbon" in a mail and a sheet seen on screen, and in the call | Later, one search brings it back, along with what you saw on screen. |
| 17.15 | It finishes your sentence | In TextEdit, autocomplete suggests "Lisbon, May 12 to 14." and Tab accepts it word by word | Start a sentence in any app, and autocomplete finishes it. |
| 22.7 | Say it, and it's written | Dictation hears "Write a note telling the team where the offsite is, and when." and writes the sentence | Or just say it. |
| 29.9 | Your agents can ask too | Claude Code asks LokalBot's MCP server and answers with the decision and its meeting | Your AI agents can ask for it too. |
| 35.1 | Your day, session by session | The Timeline for that Monday: one session opened, then the afternoon with the call | And the timeline keeps the whole day in order. |
| 40.4 | End card | The highlight becomes the robot's antenna light | LokalBot. Your personal context engine. Local by default, free, and open source. |

`renders/lokalbot-one-decision.mp4` is the film (1920×1080, 30 fps). `SPEC.md` is the brief it was
built from, `STORYLINES.md` the three films considered, `REVIEW.md` what was checked.

## What is real

- **The app:** the UI Test Host built from `master` at 133274d, filmed on an M4 Max MacBook on
  macOS 27 with `film/film.sh`. Nothing inside a window is redrawn.
- **The models:** Parakeet wrote the live transcript, the final one and the dictation's live
  preview; Qwen3.5 4B wrote the notes (the recap, the decision, the two action items, the open
  questions) and the dictated sentence; Gemma 4 E2B wrote the autocomplete suggestion from the
  meeting's notes. All ran on the Mac.
- **The call:** two synthesized voices (`say`), played into the app through its test microphone
  and call-audio inputs, with the landing demos' capture trace saying a Google Meet call is open.
- **The dictation:** the test host's dictation shortcut is held (Option-Shift for the take, to
  stay clear of the launchers running on the filming Mac, which commonly take Option-Space), and
  the request you hear is the audio the app heard: an ElevenLabs take, fed in as the test microphone. The sentence was pasted 0.3 s after
  the key came up. Dictation only composes for an explicit writing request, so the line opens
  with "Write"; a first take that began "Tell the team…" was inserted word for word, as designed.
- **The input:** real pointer and key events from `Scripts/readme-gif/rig.swift`. The pointers in
  the notes and Timeline scenes are drawn by the edit, landing on the logged click points at the
  logged times.
- **The agent:** the real Claude Code (Sonnet), in a detached 64-column terminal, with LokalBot's
  installed `lokalbot-cli mcp` as its only tool, on the film's library. The terminal in the film
  is typeset from that session's snapshots, line for line: the same text, wraps and colours.
  It answered 2.4 s after Return; the film shows that in 1.15 s.
- **The data:** fictional. `film/stage.py` seeds a small team's fortnight around the call.

## What is not

- **Waits are cut and typing is sped up.** The notes were ready 14 s after the call ended (13 s
  of that the notes model); the film cuts from the live transcript to the finished notes.
  `film/cut.sh` has every cut, speed and held frame.
- **The seeded screens are seeded.** The mail, the sheet, the map and the web page "seen on
  screen", and the Timeline's work sessions, are rows `film/stage.py` writes. The call in the
  search results and on the Timeline is the recorded one.
- **The Timeline was filmed a day later.** The takes of 2026-11-10 ran on the same library,
  seeded again as of the first session (`STAGE_NOW`) with the recorded call put back, so the page
  is Monday's, opened with the Previous Day button. Its last frame is held early: the take's
  pointer rested on a row and a hover tooltip came up over the next one.
- **One title is typed by hand.** `stage.py polish` names the recorded call `Offsite planning`.
- **The agent has the read tools only.** `ask_library` needs the LokalBot app serving the library,
  and the film's library has no app behind it, so that one tool is denied in the scene's settings.
- **The voice is a clone.** The narration and the dictated request are ElevenLabs `eleven_v4` in
  Stevan's cloned voice (`voice/narration.json`, `voice/tts.py`), two takes a line, each checked
  by a local transcription. The takes live in `assets/voice/`, which git ignores, so a fresh
  checkout voices them again with `voice/tts.py` (about 1,400 characters); `build.py` names the
  ones used and needs them to place the lines.
- **The highlighter, the titles, the Tab key and the terminal window's frame** are the edit's.

## Rebuild

Filming opens windows and takes over the pointer and keyboard for a few minutes, so ask first, and
check that the screen is unlocked. Switch the installed LokalBot's Autocomplete off for the
autocomplete take: two apps would answer the same Tab, and the script skips the take while it is on.

```sh
# Build the host outside ~/Documents, then film one take at a time and look at each.
xcodebuild -project LokalBot.xcodeproj -scheme "LokalBot UI Test Host" -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath <out>/dd CODE_SIGNING_ALLOWED=NO build
export UI_HOST_APP="<out>/dd/Build/Products/Debug/LokalBot UI Test Host.app" RIG_DISPLAY=<a 2x display id>
film/film.sh <out>/film live          # records the call, waits for its notes
film/film.sh <out>/film notes
film/film.sh <out>/film search
film/film.sh <out>/film autocomplete  # a warm-up take, then the take
python3 film/stage.py spoken <out>/film/work/spoken assets/voice/request-s11.mp3
film/film.sh <out>/film dictation     # a warm-up take, then the take
film/film.sh <out>/film timeline
python3 film/agent/record.py <out>/agent <a copy of out/film/work/recorded> "Where is the offsite, and when?"
film/cut.sh <out>/film assets/footage
```

To film more takes on another day against the same story, `film/film.sh <out>/film restore
capture/recorded/09-google-chrome-meeting` with `FILM_TZ=Etc/GMT+5` and
`STAGE_NOW=2026-11-09T14:56:17-05:00` rebuilds the library as it was. The first `live` attempt can
abort when macOS asks whether the host may send notifications, and a dictation attempt aborted
once when a LokalBot window (most likely the host's own) came forward; the next attempt ran both
times. A new take moves
things: read the cut's frame numbers again from `clips/<take>.json`, measure the highlighter
rectangles on the new frames, and copy the new terminal lines into `compositions/agent.html`.
The takes this film was cut from are in `capture/` (not in git).

`build.py` writes `index.html`: the scene order, how long each scene has the screen, and every
voice line and effect in its scene's own time. The effects are HyperFrames' bundled ones, which
git ignores under `assets/sfx/`: `key-press`, `typing`, `click-soft`, `whoosh-short`, `whoosh`,
`pop` and `impact-bass-1` (`npx hyperframes media-use resolve --type sfx --intent "<name>"
--project .` restores each). There is no music bed.

```sh
python3 build.py && npm run check
npx --yes hyperframes@0.8.150 render --quality high --video-frame-format png -o renders/raw.mp4
./master.sh renders/raw.mp4 renders/lokalbot-one-decision.mp4   # to about -16 LUFS
```

For YouTube, add `--resolution landscape-4k` to the render: the titles and the terminal are drawn
at 3840×2160, the footage is enlarged, and YouTube gives an upload of that size its better codec.
`thumbnail/index.html` is the thumbnail (1280×720): the lockup, the film's idea in three lines, and
the live transcript as filmed with the highlighter on the decision. Its header has the command
that renders it.
