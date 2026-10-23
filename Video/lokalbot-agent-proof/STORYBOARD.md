---
duration: 60
format: 1920x1080
fps: 30
music: none
---

# Storyboard

## Look

- Deep gradient stage (`#070b11` to `#0e1622`) with a teal top-left and
  indigo bottom-right glow, fine noise, and a soft shadow under the card.
- Footage sits in a 1680×945 rounded card (30 px radius, 1 px light border)
  with 120 px side margins. The app content is the hero; no browser chrome.
- A 23 px caption pill floats under each card: "Design review · 23 Oct 2026",
  "one search · the exact line", "read-only MCP · citations",
  "00:38 · the line it came from", "same library · ready to use".
- Title beats run 3 s with a slow push and a teal rule. Scenes are joined by
  0.3 s crossfades; the close holds for 9.6 s.
- Narration is OpenAI `cedar` at 1.05×.

| # | Time (s) | Picture | Source |
| - | --- | --- | --- |
| 1 | 0.0–2.9 | Cold open: "Your agent can read the code." | title card |
| 2 | 2.9–5.6 | "It can't read the meeting." | title card |
| 3 | 5.6–8.9 | Transcript search; 00:38 appears | `t-transcript` |
| 4 | 8.9–11.8 | Push-in; 00:38 boxed | transcript still |
| 5 | 11.8–15.1 | Design review wide; push | summary still |
| 6 | 15.1–18.4 | Redis decision boxed | summary still |
| 7 | 18.4–21.3 | Open question boxed | summary still |
| 8 | 21.3–29.6 | Terminal Q1, cited answer | `q1` |
| 9 | 29.6–33.9 | Citation close-up, 00:38 | transcript still |
| 10 | 33.9–42.6 | Terminal Q2, three decisions | `q2` |
| 11 | 42.6–46.5 | Meeting-list detail, 18 meetings | summary still |
| 12 | 46.5–50.4 | Three chips | type on stage |
| 13 | 50.4–60.0 | End card | type + icon |

No fabricated UI or model output. Cursor and click ripples are editorial
overlays placed at positions from the recorder's `*.events.json`.

## Capture plan

### 1. Demo library

```sh
lib=$(mktemp -d /private/tmp/lokalbot-agent-proof-XXXXXX)
python3 Scripts/seed_demo_library.py --profile demo "$lib"
export LOKALBOT_STORAGE_ROOT="$lib"
lokalbot-cli list --table | head
```

Expect 19 meetings, with **Design review** first and dated today. The
transcript must contain the four lines quoted in `SCRIPT.md`. If it does not,
stop: the take would not match the citations.

The seeded library is a fixture. Creating `control/agent-access-enabled` in
that throwaway root is what the CLI's access gate expects; never write that
marker into the real library.

### 2. App takes (authorized macOS runner)

Use `Video/lokalbot-readme-30s/filming/` as the harness:

The shared `filming-host.patch` in that folder was refreshed for current
master in this change; the previous hunk predated the reduce-motion environment
value and no longer applied.

```sh
# in a throwaway source copy, with the filming patch applied
LOKALBOT_STORAGE_ROOT="$lib" LOKALBOT_FILM_HIDE_SIDEBAR=1 \
  LOKALBOT_INITIAL_SECTION=meetings LOKALBOT_SELECT_INDEX=0 \
  LOKALBOT_DETAIL_TAB=summary ./filming/film.sh t-meeting
```

Then `t-transcript` with `failover` as the typed query. Rehearse once and
check that the decisions card and the timestamps are in frame before the
recorded take. The take scripts are starting points: keep the mouse still and
let the scroll do the work.

### 3. Terminal take

```sh
export LOKALBOT_STORAGE_ROOT="$lib"
claude mcp add lokalbot -- "$(command -v lokalbot-cli)" mcp
cd "$(mktemp -d)/lokalbot-cache" && printf 'cache = redis\n' > cache.py
claude
```

Before the take, run `lokalbot-cli list --table` in the same shell and confirm
the demo titles. A briefing that mentions personal projects means the wrong
library is in use; stop and fix the environment.

Record the terminal at 1920×1080 with a dark theme and 18 pt type. Show the
tool calls, not just the answer. The run is real; do not pre-write the reply.

### 4. Editor take

A plain screen capture of a scratch repository with `cache.py` open. No
terminal history, secrets, or real project paths.

## Preflight

- [ ] Notifications off; unrelated windows and desktop hidden.
- [ ] `LOKALBOT_STORAGE_ROOT` identical for the app, the shell, and the MCP
      server.
- [ ] `lokalbot-cli list --table` shows only demo titles.
- [ ] Models ready; agent access enabled for the demo root.
- [ ] Terminal font at 18 pt or larger; answer legible at 720p.
- [ ] Install commands copied from the README.

## Open items

- The app takes and the terminal run were recorded on 23 October 2026 on the
  operator's Mac at their explicit request, overriding the runner default for
  this preview.
- The timestamp-click take did not navigate in the filming host; the cut uses
  the transcript search for the cited 00:38 line instead. Re-test the click on
  the next shoot.
- The rough cut uses OpenAI TTS (`cedar`, 1.05×). Eleven v4 is the project
  voice but its key is over quota; re-check before publishing.
