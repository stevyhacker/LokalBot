# Terminal take

The terminal segment is a real `codex exec` run against the same demo library,
recorded with `asciinema` and rendered with `agg`. Two conditions matter:

1. **Use a throwaway HOME** containing only `auth.json` and a minimal
   `config.toml`. Without it, the harness loads the operator's global skills
   and SessionStart memory hook, and that private data can reach a frame.
2. **Pin `LOKALBOT_STORAGE_ROOT`** for the MCP server and for the agent's
   shell. Confirm with `lokalbot-cli list --table` before recording; a
   briefing that mentions real projects means the wrong library is in use.

The shoot wrapped the agent so the terminal shows the question, the completed
`lokalbot` tool calls, and the final answer, with the harness noise removed:

```sh
asciinema rec --headless --window-size 100x30 \
  -c "LOKALBOT_STORAGE_ROOT=\"$lib\" ./ask.py \
      'Why did we pick Redis, and should the cache start in cluster mode?' \
      'Two sentences. Cite as plain text like Design review, 23 Oct 2026, 00:00. No markdown links.'" \
  q1.cast
asciinema rec --headless --window-size 100x30 \
  -c "LOKALBOT_STORAGE_ROOT=\"$lib\" ./ask.py \
      'List the caching decisions from the Design review as three short bullets.' \
      'Plain text citation only. No markdown links.'" \
  q2.cast
```

Render at a readable size and hold the answer:

```sh
agg --font-size 24 --theme monokai --speed 0.9 --idle-time-limit 1 \
  --last-frame-duration 5 q1.cast q1.gif
```

The wrapper's `ask.py` lives only in the throwaway filming copy; it needs the
operator's CLI path and the demo home. Keep it out of the app.
