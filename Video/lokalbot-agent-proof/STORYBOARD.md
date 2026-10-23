---
duration: 52
format: 1920x1080
fps: 30
music: none
---

# Storyboard

| # | Time (s) | Picture | Source |
| - | --- | --- | --- |
| 1 | 0.0–3.0 | Hook card: "Your agent can read the code." | type |
| 2 | 3.0–6.0 | Hook card: "It can't read the meeting." | type |
| 3 | 6.0–10.0 | Transcript search for "failover"; the 00:38 line highlights | `t-transcript` at 1.5× |
| 4 | 10.0–17.0 | Meeting workspace, Design review; Redis and deferred-cluster decisions held | `t-meeting` at 1.5× + 3.4 s hold |
| 5 | 17.0–25.7 | Terminal: question, tool calls, answer with citations | `q1` at 1.5× + 3.1 s hold |
| 6 | 25.7–33.9 | Citation close-up; slow push-in on the 00:38 line | still from `t-transcript` |
| 7 | 33.9–43.1 | Second prompt; three caching decisions | `q2` at 1.5× + 2.9 s hold |
| 8 | 43.1–52.1 | End card: icon, install lines, "Local. Cited. No account." | type + icon |

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
