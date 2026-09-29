# LokalBot launch films

Three 30-second launch-film drafts, each built on a different idea, made with the
[onetake](https://github.com/feitangyuan/onetake) skill (commit `36072d3`). They are 1080p30 review renders; an
accepted cut is rendered again at 4K60.

| Film | Idea | Look | Camera | Draft | Source |
| --- | --- | --- | --- | --- | --- |
| 1 · The pull-out | One continuous pull-out from the spoken word "Thursday": the transcript moment folds into its `00:00:26` citation, the action waits on Today, the desktop's screen text lights up, and Quick Recall finds the same moment. | The app's own light theme | One take pulling out, log zoom | [lokalbot-launch-pullout.mp4](drafts/lokalbot-launch-pullout.mp4) | [pullout/](pullout/) |
| 2 · Two streams, one search | What you hear (teal) and what you see (amber, off until you turn it on) run past and dissolve. LokalBot keeps both, braids them into "On this Mac", and one search pulls from both streams into the real results. A click plays the exact moment. | Dusk: night ground, LokalBot teal, amber | Locked wide; the streams move | [lokalbot-launch-streams.mp4](drafts/lokalbot-launch-streams.mp4) | [streams/](streams/) |
| 3 · The desk machine | A tabletop chain reaction. Each default model is a station: Qwen3-ASR prints the transcript, Nemotron stamps who spoke, the Qwen3.5 press ejects a decision and two actions, and each card's timestamp threads back to its moment. Search pulls the Thursday card into the tray; a lever lets screen text in beside it. | Tabletop: warm grey, white objects, red-orange cause | An operator chasing the cause | [lokalbot-launch-machine.mp4](drafts/lokalbot-launch-machine.mp4) | [machine/](machine/) |

## What is on screen

- **Data:** every transcript line, timestamp, decision and action comes from the fictional library in
  `Scripts/seed_demo_library.py` (the Design review meeting). The Quick Recall results are the app's real output for
  "Thursday" and "Redis", captured from the UI test host at `master` `769068e`.
- **Interface:** film 1's LokalBot window is the README's `Assets/screenshots/today.png`; its moment card, desktop and
  Quick Recall panel are rebuilt on the canvas from the app's layout. Films 2 and 3 stylize the interface.
- **Models:** names and roles follow the README's model table: Qwen3-ASR 1.7B transcribes, Nemotron 3 separates
  speakers, Qwen3.5 4B summarizes, Harrier 0.6B indexes for semantic search.
- **Not shown:** live recording or inference. The films are motion graphics built from product data.
- **Narration:** ElevenLabs `eleven_v4` premade voices. Liam narrates all three; Sarah (film 1) and Chris (film 2)
  speak the seeded meeting lines. `vo/lines.txt` is the script; `vo/read.txt` is what is spoken ("LocalBot",
  "Qwen three A S R").

## Checks

onetake's `verify_promo.py` on the committed drafts, plus a faster-whisper transcript of each mix:

| Film | Cadence (CV) | Still frames | Continuity | Loudness | Verdict |
| --- | ---: | ---: | --- | ---: | --- |
| Pull-out | 0.58 | 66 % | 0.83 over 3 boundaries | −16.2 LUFS | PASS |
| Two streams | 0.58 | 51 % | 1.00 over 2 boundaries | −16.3 LUFS | PASS |
| Desk machine | 0.71 | 39 % | 1.00 over 1 boundary | −16.1 LUFS | PASS (no burst: the concept has no hard-cut hits) |

All three pass the curves (180° shutter) and framing legs, with true peak at −3.5 dBTP. Two narration lines were
regenerated after the transcript check heard them wrong. `tools/voice.sh` records their seeds.

## Rebuild

1. Check out onetake at `36072d3` and export its path as `ONETAKE`. Its license is PolyForm Noncommercial 1.0.0.
2. Install `uv` and `ffmpeg`. The tools pin Playwright `1.62.0` (Chromium 1234).
3. `ELEVENLABS_API_KEY=… tools/voice.sh <pullout|streams|machine>` regenerates the narration and rewrites
   `timeline.js` / `timeline.json`. The timelines are committed, so this step is needed only to change the words.
4. `tools/build.sh <film>` writes `look.js`, dumps the sound events, mixes to −16 LUFS, renders
   `<film>/renders/draft.mp4`, and runs `verify_promo.py`. Add `--final` for 3840×2160 at 60 fps. Copy an
   accepted render into `drafts/`.

| Path | What |
| --- | --- |
| `<film>/comp.html` | The composition: one canvas, every value a function of time (`window.__seek`), on onetake's `lib/motion.js` |
| `<film>/look.json` | Palette and faces. `look.js` is generated from it by onetake's `look.py` |
| `<film>/timeline.js`, `timeline.json` | Narration starts, word times, meeting-line waveform. Beats find their words by text |
| `<film>/vo/` | `lines.txt`, `read.txt`, and the meeting line |
| `tools/` | `eleven_vo.py`, `build_timeline.py`, `dump_events.py`, `mix.py`, `voice.sh`, `build.sh` |

## License

onetake is free for noncommercial use only. Its library, scripts, templates and generated `look.js` are not
included here. The files in this folder are LokalBot's own and use onetake as an external tool. Anyone rebuilding
the films accepts onetake's license.
