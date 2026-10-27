# From meeting to done: LokalBot × Meta Muse

This branch is LokalBot's entry to the Meta Global AI Developer Hackathon (26 October – 4 November 2026). It adds two features to LokalBot, a private work-memory app for macOS:

- **Live Radar.** While a meeting is recorded, it catches commitments, decisions, and open questions as they are said. It also flags contradictions with earlier meetings, such as "On 19 Oct you agreed the launch is Monday the 3rd".
- **Follow-through.** After the meeting, Muse plans the work for one of your commitments. It reads what it needs from your meetings, then proposes an email, a calendar invitation, or a task for a coding agent. You approve each step, and each opens as a draft.

## What is new

Everything on this branch after the tag `v0.11.4` is hackathon work. That tag is LokalBot's last release, merged at 16:52 CET on 26 October, before the 17:00 CET kickoff.

```bash
git diff --stat v0.11.4...meta-hackathon
```

- **Meta Model API client.** [`LokalBot/Engines/MetaModelAPI.swift`](LokalBot/Engines/MetaModelAPI.swift): chat completions with function tools, strict JSON schema, `reasoning_effort`, token use, and cost.
- **Live Radar.**
  - Services: [`LokalBot/Services/MeetingRadar/`](LokalBot/Services/MeetingRadar/). `MeetingRadar` runs the passes, `MeetingRadarAnalyzer` builds the prompt and checks grounding, `LibraryRadarEvidenceSource` searches earlier meetings locally, and `MeetingRadarReplay` is the replay harness.
  - Views: the live pane and saved-results list in [`MeetingRadarPanel.swift`](LokalBot/Views/MeetingRadarPanel.swift).
- **Follow-through.**
  - Services: [`LokalBot/Services/FollowThrough/`](LokalBot/Services/FollowThrough/). It holds the tool definitions and proposals, the approval-gated agent loop, the app's read tools and hand-offs, and the replay harness.
  - Views: [`FollowThroughSheet.swift`](LokalBot/Views/FollowThroughSheet.swift).
- **Settings.** [`MetaMuseSettingsSection.swift`](LokalBot/Views/MetaMuseSettingsSection.swift) covers the key, approval and models. `lokalbot-cli secret set meta-model-api` also saves the key.
- **Changes to existing code:**
  - wiring in `AppState`, the live meeting view, the meeting page, and the action menus (**Follow Through with Muse…**);
  - two settings and their registry entries;
  - `MeetingChatTools.specs` made static;
  - two headless flags.
- **Tests:** [`LokalBotTests/MeetingRadarTests.swift`](LokalBotTests/MeetingRadarTests.swift) and [`LokalBotTests/FollowThroughTests.swift`](LokalBotTests/FollowThroughTests.swift), 24 tests, offline.
- **Benchmarks.**
  - [`Benchmarks/MuseVoiceTranscribe/`](Benchmarks/MuseVoiceTranscribe/README.md): Muse Voice Transcribe's live speaker labels measured on AMI.
  - [`Benchmarks/MuseRadar/`](Benchmarks/MuseRadar/README.md): Live Radar and Follow-through replays.
- **Docs:** the Meta Muse sections of [PRIVACY.md](PRIVACY.md) and [DEVELOPMENT.md](DEVELOPMENT.md).

Recording, transcription, speaker separation, search, meeting notes, actions, and People were already in LokalBot and are not part of the entry.

## How it uses Meta's models

| Model | Where | Why |
|---|---|---|
| Muse Spark 1.3 | Live Radar, one structured-output request about every 20 s | Fast enough to keep up with a meeting: median 1.5–2.7 s per pass, about $0.47 per meeting hour |
| Muse Wonder 1.0 | Follow-through, tool calling with approval | Plans the work, reads meetings, and writes drafts you can send as they are |
| Muse Voice Transcribe 1.0 | Benchmarked for live speaker labels | Its final text arrived 0.74 s after each turn, but its speaker labels had 60.4% DER (21.7% on speech) against 16.5% (13.9%) for local Nemotron, so labels stay local ([report](Benchmarks/MuseVoiceTranscribe/results/2026-10-27/REPORT.md)) |

## Privacy design

LokalBot keeps meetings on the Mac by default, and the hackathon features keep that boundary:

- **Text only.** Audio, voices, and search never leave the Mac. Muse receives transcript text and the passages local search found.
- **Two opt-ins.** Nothing is sent until you approve `https://api.meta.ai` in Settings. Even then, nothing is sent until you press Start Radar or Follow Through for a specific meeting or action.
- **Grounding.** Every radar item must quote a line that was just said, and a contradiction must cite a passage the model was shown. Anything else is dropped.
- **Approval before action.** Follow-through can only propose. Each step waits for approval and opens as a draft in Mail, Calendar, Claude Code or Codex. Email addresses are filled in on the Mac and never sent to Meta.
- **No training rights.** Contributor models, which give Meta training rights in exchange for a discount, are not offered.

## Results so far

- **Synthetic meeting:** the radar caught all 6 planted items, including both contradictions with an earlier meeting, in 6 passes and $0.016 with Spark. Wonder caught the same 6 for $0.033.
- **Follow-through:** a synthetic case took 4 model turns, 20 s and $0.06 with Wonder. The result was an email draft signed with the user's name and a meeting proposal to settle the two open conflicts.
- **AMI meetings:** see [Benchmarks/MuseRadar](Benchmarks/MuseRadar/README.md).

## Try it

1. Build the **LokalBot Dev** scheme ([DEVELOPMENT.md](DEVELOPMENT.md#build-workflows)).
2. Open Settings → Recording → Meta Muse. Save a Meta Model API key, then turn on "Allow sending meeting text to https://api.meta.ai".
3. Start a recording, open the live meeting, and press **Start Radar**.
4. After the meeting, open its page. Choose **Follow Through…** on one of your commitments in the Live Radar section, or **Follow Through with Muse…** in any action's menu.
