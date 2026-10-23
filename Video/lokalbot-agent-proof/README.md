# LokalBot — the agent proof (60 s)

The 60-second cut for the agent-memory pitch: a real meeting decision, a real
agent run through LokalBot's MCP server, and a citation that opens the exact
transcript line.

This replaces the feature-tour hero for launch material. The 45-second product
tour stays where it is; this cut answers one question — *why would my coding
agent need my meetings?*

- `BRIEF.md` — audience, thesis, what the cut must prove, non-goals.
- `SCRIPT.md` — voiceover, terminal content, and the real fixture lines the
  citations point to.
- `STORYBOARD.md` — shot list, capture plan, preflight.
- `captions.en.vtt` — English captions for the finished cut.

## Status

Script and storyboard are ready for review. A 60-second director's cut was
recorded on 23 October 2026 at the operator's request and lives in `renders/`
(ignored by git): thirteen shots, real UI Test Host takes at 1.5× in rounded
cards, a wide-to-close camera move through the meeting, motivated crossfades,
a real agent session recorded with `asciinema`, a Three.js memory-field
insert (`Video/agent-proof-motion/`), and an OpenAI TTS (`cedar`) narration. Generated media is not committed.

The shared filming patch under `Video/lokalbot-readme-30s/filming/` now applies
to current master again, so the harness builds without a manual hunk fix.

The finished file belongs at `Assets/videos/lokalbot-agent-proof.mp4`, with a
matching poster and `.vtt`. Generated media stays out of git until the cut is
approved.

## Assembly

1. Record the app takes per `STORYBOARD.md` and keep the uncut files plus
   `*.events.json`.
2. Record the terminal run in the same demo library; keep the whole session.
3. Record the editor insert in a scratch repository.
4. Cut to the timings in the storyboard; put cursor and click overlays at the
   logged events. Do not alter app pixels.
5. Voice: the same ElevenLabs Eric v4 voice as the 30-second README demo, or a
   human read; no synthetic emphasis tags.
6. Burn captions only if the platform requires them; ship the sidecar VTT.

## What this cut may claim

- LokalBot keeps meetings on the Mac and exposes them read-only to an MCP
  client after the person grants access.
- The answer is grounded in the seeded transcript and cites the line.
- Built-in processing is local by default; the agent client may send tool
  results to its own provider.

It may not claim that the agent never sees the data, that inference is always
offline for every configuration, or that retrieval is exhaustive.
