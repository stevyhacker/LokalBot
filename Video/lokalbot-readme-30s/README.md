# LokalBot — 30-second README demo

A fast walkthrough of the native app for the root README: Quick Recall, cited meeting decisions, transcript search, Ask with sources, Today, Timeline, and local autocomplete. 1920×1080, 30 fps, 30 s, with a male Breeze TTS 2 narrator.

- `index.html` — the HyperFrames composition (pinned CLI `hyperframes@0.8.82`).
- `BRIEF.md`, `STORYBOARD.md`, `SCRIPT.md` — intent, shot list with source ranges, narration cues.
- `prepare_media.sh` — cuts recorded takes into `assets/clips/` and mixes `assets/voice/narration.wav`.
- `filming/` — how the footage was filmed: `filming-host.patch`, `film.sh`, and one script per take.
- Generated media (`assets/clips`, `assets/voice`, `renders`, `snapshots`) is not committed. The delivered cut is `Assets/videos/lokalbot-readme-demo.mp4` at the repository root.

## Footage

Every clip is a real recording of the native SwiftUI app driven by real AppKit input events. The filming host is the repository's **LokalBot UI Test Host** built from a throwaway copy of the source with `filming/filming-host.patch` applied. The patch is never committed to the app. It adds:

- `FilmDirector.swift` — records the host window with `cacheDisplay` at 1.5× (2100×1320 at about 30 fps) and replays a take script of clicks, keystrokes and key presses into the window, logging each event's time and position.
- a filming-only active-appearance override, so the window draws its key/active chrome while the Mac is locked or another app is frontmost;
- a filming-only default that starts the workspace sidebar hidden, a normal app state that avoids `cacheDisplay`'s black sidebar-selection artifact.

The library is `Scripts/seed_demo_library.py` fictional data. The capture host suppresses background capture and inference, so transcripts, outcomes, the Ask answer and the autocomplete suggestion are fixtures; the footage shows the interface and navigation, not live transcription or model performance. `cacheDisplay` still draws the selected toolbar segment in Meetings as a dark pill.

To re-film: copy the source (for example `git archive HEAD`), apply the patch, run `xcodegen generate`, build the `LokalBot UI Test Host` scheme, seed a library, then run `filming/film.sh` for each script in `filming/scripts/` (environment per take is listed in `STORYBOARD.md`: Quick Recall uses `LOKALBOT_UI_TEST_WINDOW=quick-recall LOKALBOT_CAPTURE_SIZE=660x480`; the others use `LOKALBOT_FILM_HIDE_SIDEBAR=1` with `LOKALBOT_INITIAL_SECTION=meetings|search|today|timeline|cotyping`, plus `LOKALBOT_SELECT_INDEX=0 LOKALBOT_DETAIL_TAB=summary` for Meetings and `LOKALBOT_COTYPING_DEMO=1` for Writing).

## Narration

Breeze TTS 2 Q8_0 through audio.cpp v0.7.3 (hashes as in `Benchmarks/Breeze/2026-09-09/environment.json`), loopback-only. A male voice was designed from an instruction, then each line was cloned from that sample for consistency; lines were checked with a local faster-whisper transcript and pitch estimate. Breeze's license (BreezeBlue Research and Non-Commercial License v1.1) requires a separate commercial license for commercial use of outputs.

## Rebuild

```sh
TAKES=<takes dir> VOICE=<selected narration WAVs v1..v8> ./prepare_media.sh
npx --yes hyperframes@0.8.82 lint
npx --yes hyperframes@0.8.82 check
npx --yes hyperframes@0.8.82 render --quality high --fps 30 --output renders/video.mp4
```

These commands run headless Chrome; this render was made locally with the owner's approval as an exception to `Video/AGENTS.md`'s remote-runner default.
