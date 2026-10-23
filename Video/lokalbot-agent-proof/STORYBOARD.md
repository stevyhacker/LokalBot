---
duration: 60
format: 1920x1080
fps: 30
music: none
---

# Storyboard

| # | Time (s) | Picture | Source |
| - | --- | --- | --- |
| 1 | 0.0–4.0 | Code editor, `cache = redis` selected; 4% push-in over four seconds | editor capture |
| 2 | 4.0–8.0 | Hard cut to the transcript: "I propose Redis for the pub-sub support." Cursor rests on the line | `t-transcript` (00:00 line) |
| 3 | 8.0–17.0 | Meeting workspace, Design review. The Redis decision and the deferred cluster decision are both visible; slow pan from summary to decisions | `t-meeting` (index 0, summary) |
| 4 | 17.0–24.0 | Pull back to the full window; badge "read-only MCP · citations" lands bottom-left | same take, hold |
| 5 | 24.0–32.0 | Terminal at 18 pt, Claude Code prompt; question typed live | terminal take, 0:00–0:08 of the run |
| 6 | 32.0–42.0 | Tool calls resolve in the transcript pane; answer streams; cursor opens the 00:38 citation | terminal take, 0:08–0:18 |
| 7 | 42.0–50.0 | Second prompt; the eviction note appears with three bullets | terminal take, 0:18–0:26 |
| 8 | 50.0–60.0 | End card: icon, install lines, "Local. Cited. No account." | type + `assets/lokalbot-icon.svg` |

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
- The rough cut uses macOS `say` (Daniel) for timing. Replace it with the
  Eleven v4 voice before publishing.
