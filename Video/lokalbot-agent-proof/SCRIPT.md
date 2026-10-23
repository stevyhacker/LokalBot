# Script — 60-second director's cut

Voice: dry, conversational, one idea per line. No hype. Read at about 145 wpm
with a beat after each full stop. Screen footage runs at 1.5×; the holds carry
the reading time.

| Time | Picture | Voiceover |
| --- | --- | --- |
| 0:00–0:03 | Cold open on the stage; kinetic title | Your agent can read the code. |
| 0:03–0:06 | Second title beat; teal accent on "can't" | It can't read the meeting. |
| 0:06–0:09 | Transcript search for "failover"; the 00:38 line comes up | This decision lives in a transcript, not a repo. |
| 0:09–0:12 | Push-in on the 00:38 line, boxed | — |
| 0:12–0:15 | Meeting workspace, Design review; slow push | LocalBot keeps that meeting on your Mac. |
| 0:15–0:18 | The Redis decision boxed | And gives your agent a way in. |
| 0:18–0:21 | The open question boxed: "cluster mode?" | Redis, for pub-sub. Cluster mode, deferred. |
| 0:21–0:30 | Terminal: question, tool calls, cited answer | Ask why Redis, and whether the cache should start in cluster mode. It answers with the line it came from. |
| 0:30–0:34 | Citation close-up on 00:38 | Design review. 00:38. |
| 0:34–0:42 | Second prompt; three caching decisions | Then it lists the decisions, ready to use. |
| 0:42–0:46 | Detail of the meeting list | Eighteen meetings. One local library. |
| 0:46–0:50 | Three chips: local library / read-only MCP / no account | Read-only. No account. |
| 0:50–1:00 | End card: icon, install lines | LocalBot. Install with Homebrew. Connect with one command. |

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
