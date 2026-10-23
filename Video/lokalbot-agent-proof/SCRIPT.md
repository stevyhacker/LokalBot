# Script — 52-second preview

Voice: dry, conversational, one idea per line. No hype. Read at about 145 wpm
with a beat after each full stop. Screen footage runs at 1.5×; the holds carry
the reading time.

| Time | Picture | Voiceover |
| --- | --- | --- |
| 0:00–0:03 | Code editor, cursor on `cache = redis`; push-in | Your agent can read the code. |
| 0:03–0:06 | Hard cut to the transcript line, "I propose Redis for the pub-sub support." | It can't read the meeting. |
| 0:06–0:10 | Transcript search for "failover"; the 00:38 line highlights | This decision lives in a transcript, not a repo. Redis, for pub-sub. Cluster mode, deferred. |
| 0:10–0:17 | Meeting workspace: the Redis and deferred-cluster decisions; hold | LokalBot keeps that meeting on your Mac, and gives your agent a way in. |
| 0:17–0:25 | Terminal: question, tool calls, answer with citations | Ask why Redis, and whether the cache should start in cluster mode. It answers with the line it came from. |
| 0:25–0:34 | Citation close-up: "Please benchmark failover latency…" | Design review. 00:38. |
| 0:34–0:43 | Second prompt; the three caching decisions appear | Then it lists the decisions, ready to use. |
| 0:43–0:52 | End card: icon, install lines, "Local. Cited. No account." | Local. Cited. No account. LokalBot. |

## Terminal take — exact content

The run is recorded, not typed from a script. Use the demo library and verify
the titles before the take.

```text
$ cd ~/demo/lokalbot-cache
$ claude

> why did we pick redis, and should the cache start in cluster mode?

  lokalbot · get_briefing
  lokalbot · search_meetings("redis cluster")
  lokalbot · get_meeting(Design review)

Redis was chosen for its pub-sub support (Design review, 23 Oct 2026, 00:00).
Cluster mode is deferred until failover latency is benchmarked (00:38), and
the session store stays in Postgres for now (01:22).
```

Second prompt:

```text
> draft the eviction-policy note from those decisions

- Redis, single node. Cluster mode deferred pending the failover benchmark.
- Two keyspaces: recaps at a 7-day TTL, search results at a 1-hour TTL, with
  separate eviction.
- Session store stays in Postgres.
```

These lines are grounded in the seeded Design review transcript:

- 00:00 — "Let's lock the caching layer. I propose Redis for the pub-sub support."
- 00:38 — "Please benchmark failover latency before we commit to a cluster."
- 01:22 — "Stay in Postgres for now. One migration at a time."
- 01:36–01:50 — recaps cached for a week, search results for an hour, two
  keyspaces with separate eviction.

## On-screen text

- 0:17 — "read-only MCP · citations · runs on your Mac"
- 0:38 — "00:38 — Design review, 23 Oct 2026"
- 0:50 — `brew install --cask stevyhacker/tap/lokalbot`
- 0:53 — `claude mcp add lokalbot -- /Applications/LokalBot.app/Contents/Helpers/lokalbot-cli mcp`
- 0:57 — "Free and open source · no account"

Keep the install lines on screen for at least five seconds. Both commands are
copied from the README, not paraphrased.
