# Review

Delivered 2026-11-10: `renders/lokalbot-one-decision.mp4`, 48.4 s, 1920×1080, 30 fps, H.264 + AAC,
with a voiceover and two more scenes (dictation, Timeline) than the first 30-second cut of
2026-11-09, which is kept as `renders/lokalbot-one-decision-30s-silent.mp4`.

## Creative calls

- **One decision, seven places.** The film follows a single sentence instead of listing features.
  The amber highlighter (the robot's antenna colour) is the only accent, and it ends as the
  antenna light on the end card.
- **One screen.** Every scene plays on the same dark screen under a one-line title. The scenes
  change by what would change on a Mac: the window's content, a panel opening over it, a swipe to
  another app, a new page, a terminal coming up.
- **The call-to-notes cut is a match cut.** The transcript line and the notes' decision sit within
  8 px of each other in the app's own window, so the sentence holds while the window changes.
- **The voice is the clock.** Each scene runs as long as its line and its action need. The titles
  stay, for viewers with the sound off, and never repeat the voice's sentence word for word.
- **Dictation is heard.** The narrator says "Or just say it." and the same voice dictates the
  request; that audio is the take the app heard, so what is said and what the panel previews agree.
- **The Timeline closes the film.** It shows the day the story happened in: the venue research,
  the call, the update typed after it, the agent's terminal. Its highlight is the one that becomes
  the antenna light.
- **Not built:** "Monday, 9:02" and "The sentence is the film" (`STORYLINES.md`).
- **Left out:** Ask, Today, People, Projects and Files.

## Measured

- `hyperframes check`: no errors. Two warnings kept on purpose (`nested_media_start_basis_ambiguous`
  on the search and autocomplete videos): their `data-start` values are scene-local, as intended.
- Contrast: 35 of 35 sampled text pairs pass.
- Voice: every take transcribes to its script with a local Whisper (which writes "Localbot"), and
  a transcription of the finished mix finds all nine lines in order under the effects.
- Loudness of the finished file: integrated −16.3 LUFS, true peak −1.5 dBFS (`master.sh`).
- Duration 48.400 s; the scene starts and frame numbers are in `SPEC.md`.

## Looked at

Contact sheets across the whole film, strips across the seams, and full-size frames at the QA
times in `SPEC.md`, from the rendered file.

## Not checked

- Nobody has listened to it. The voice's delivery, the balance between the voice and the effects,
  and whether the dictated request reads as a different moment from the narration are unheard.
- Not watched on a phone. In the whole-window framings (the first second, the notes, the Timeline's
  first two seconds) the app's body text is 19 to 25 px; the lines that matter are shown closer.
- No music, and no vertical or square cut.

## Weakest shots

- **The Timeline's close-up** is the window enlarged 1.9 times, the softest footage in the film.
  A take with a narrower window, or the sessions column filmed at a larger text size, would fix it.
- **The search.** Its meeting row shows the call's first line ("Lisbon or Porto?"), not the
  decision, because that is the line the app matched, so the highlighter marks the decision in
  the mail above it.
- **The dictated sentence** is the same sentence autocomplete has just written. It makes the
  film's point, but a viewer may read it as a repeat.

## Found while filming

- `ask_library` over MCP waits 63 s before answering `app_not_running`. The first agent takes
  sat for a minute on it; the read tools answer in milliseconds.
- Dictation's Compose mode inserts "Tell the team where the offsite is, and when." word for word:
  only a request that opens with a writing verb ("Write…", "Draft…") is composed from memory
  (`DictationGrounding`, by design). The film's request was reworded to open with "Write".
- The UI Test Host can film autocomplete and dictation in another app when it is started as a
  child of a shell that has Accessibility (`DIRECT=1` in `film/film.sh`).
- macOS's notification-permission alert for the host comes to the front on the first recording
  and aborts the take; the second attempt runs. One dictation attempt aborted the same way when
  a LokalBot window, most likely the host's own, came forward.
- The Timeline's hover tooltip appears 1.7 s after the pointer rests on a session row and covers
  the row below it.
