# Brief — the agent proof (60 s)

## Job

Prove in one minute that LokalBot gives a coding agent context it cannot get
from the repository, and that every answer is traceable to a real line in a
meeting.

## Audience

Developers and technical founders who already use Claude Code, Codex, or
another coding agent and take meetings on a Mac. They have tried a meeting
note-taker and will not hand another cloud service their recordings.

## Thesis

The agent can read the code. It can't read the room. LokalBot is the local
memory of the meeting behind the code.

## What the cut must show, in order

1. A decision that exists only in a meeting transcript: Redis won on pub-sub
   support, cluster mode is deferred pending a failover benchmark.
2. The same decision in LokalBot's meeting workspace, visibly tied to the
   recording.
3. A coding agent asking for it through the bundled read-only MCP server.
4. An answer with a citation, then the exact transcript line at 00:38.
5. The agent using the decision in a second task — drafting the eviction-policy
   note — rather than only quoting it.
6. The install path, the local boundary, and no account.

## Non-goals

- No feature tour: no autocomplete, dictation, Timeline, Today, Personal
  Context, CUDA, or model picker.
- No cloud, sync, team, or pricing story.
- No latency, accuracy, or benchmark claims.
- No prepared model answer presented as inference.

## Ground rules

- Record the real app and a real agent run. The terminal take uses the bundled
  CLI's MCP server against the same demo library as the app take.
- Use fictional data only: `Scripts/seed_demo_library.py --profile demo` in a
  throwaway root, pinned with `LOKALBOT_STORAGE_ROOT`.
- App takes use the existing UI Test Host and `filming/film.sh`; run them on an
  authorized macOS runner under the repository's UI rule.
- The private library must never appear in frame, in the terminal, or in shell
  history. Run `lokalbot-cli list --table` and confirm the demo titles before
  any recording.

## Success

After one viewing, the person can repeat the claim in a sentence and knows the
install is two commands and one permission. Measure the 60 s cut's
watch-through and release-link clicks in the launch window; treat those as
targets, not a baseline.
