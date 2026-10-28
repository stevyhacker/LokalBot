# From meeting to done: LokalBot × Meta Muse

This branch is LokalBot's entry to the Meta Global AI Developer Hackathon (26 October – 4 November 2026). It adds two features to LokalBot, a private work-memory app for macOS:

- **Live Radar.** While a meeting is recorded, it catches commitments, decisions, and open questions as they are said. It also flags contradictions with earlier meetings, such as "On 19 Oct you agreed the launch is Monday the 3rd". With fast live text, Muse Voice Transcribe streams the transcript turn by turn, and items appear about 3 seconds after the speaker finishes.
- **Follow-through.** After the meeting, Muse plans the work for one of your commitments. It reads what it needs from your meetings, then proposes an email, a calendar invitation, or a task for a coding agent. You approve each step, and each opens as a draft.

## What is new

Everything on this branch after the tag `v0.11.4` is hackathon work. That tag is LokalBot's last release, merged at 16:52 CET on 26 October, before the 17:00 CET kickoff.

```bash
git diff --stat v0.11.4...meta-hackathon
```

- **Meta Model API client.** [`LokalBot/Engines/MetaModelAPI.swift`](LokalBot/Engines/MetaModelAPI.swift): chat completions with function tools, strict JSON schema, `reasoning_effort`, token use, and cost.
- **Live Radar.**
  - Services: [`LokalBot/Services/MeetingRadar/`](LokalBot/Services/MeetingRadar/). `MeetingRadar` runs the passes, `MeetingRadarAnalyzer` builds the prompt and checks grounding, `LibraryRadarEvidenceSource` searches earlier meetings locally, and `MeetingRadarReplay` is the replay harness.
  - Fast live text: [`MuseLiveText.swift`](LokalBot/Services/MeetingRadar/MuseLiveText.swift) streams each recorded track to Muse Voice Transcribe's realtime endpoint, and `LiveMeetingTranscriber` uses it in place of local chunks when the setting is on.
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
| Muse Spark 1.3 | Live Radar, one structured-output request about every 20 s | Fast enough to keep up with a meeting: median 1.05 s per request on AMI, $0.49 per meeting hour. Wonder is offered for more decisions at 2.5× the cost |
| Muse Wonder 1.0 | Follow-through, tool calling with approval | Plans the work, reads meetings, and writes drafts you can send as they are |
| Muse Voice Transcribe 1.0 | Fast live text (opt-in): the live transcript, streamed turn by turn | Each turn's text arrives within about a second, so radar items land about 3 s after the speaker finishes instead of about 20 s ([check](Benchmarks/MuseRadar/results/2026-10-28-live-text/REPORT.md)). Speakers come from the microphone and call tracks, because its own labels measured less accurate than local diarization ([report](Benchmarks/MuseVoiceTranscribe/results/2026-10-27/REPORT.md)) |

## Privacy design

LokalBot keeps meetings on the Mac by default, and the hackathon features keep that boundary:

- **Text by default.** Voices and search never leave the Mac. Muse receives transcript text and the passages local search found. Audio leaves only with fast live text, a separate switch that is off by default, and only while the live transcript preview runs.
- **Two opt-ins.** Nothing is sent until you approve `https://api.meta.ai` in Settings. Even then, nothing is sent until you press Start Radar or Follow Through for a specific meeting or action.
- **Grounding.** Every radar item must quote a line that was just said, and a contradiction must cite a passage the model was shown. Anything else is dropped.
- **Approval before action.** Follow-through can only propose. Each step waits for approval and opens as a draft in Mail, Calendar, Claude Code or Codex. Email addresses are filled in on the Mac and never sent to Meta.
- **No training rights.** Contributor models, which give Meta training rights in exchange for a discount, are not offered.

## Results so far

- **Synthetic meeting:** the radar caught all 6 planted items, including both contradictions with an earlier meeting, in 6 passes and $0.016 with Spark. Wonder caught the same 6 for $0.033.
- **Voiced synthetic meeting, fast live text:** streamed in real time through Muse Voice Transcribe, the radar caught the same 6 items from audio and showed them a median 8.0 s after each sentence began, about 3 s after the speaker finished ([check](Benchmarks/MuseRadar/results/2026-10-28-live-text/REPORT.md)).
- **Follow-through:** a synthetic case took 4 model turns, 20 s and $0.06 with Wonder. The result was an email draft signed with the user's name and a meeting proposal to settle the two open conflicts.
- **AMI meetings (6.4 hours, 12 meetings, manual transcripts):** run live on Muse Spark, Live Radar caught 22 of AMI's 62 human-annotated decisions and 8 of its 20 actions. LokalBot's post-meeting notes from the local Qwen3.5 4B, on the same text, caught 2 and 3.
  - **Timing and cost:** items appeared a median 23 s after they were said. Requests took a median 1.05 s, with 0 failures in 1,007, at $0.49 per meeting hour.
  - **Muse Wonder:** on six of the meetings it caught 23 of 42 decisions against Spark's 13, at $1.27 per hour.
  - **Contradictions:** all 10 that Spark flagged against an earlier meeting named a real change of plan, by our unblinded review.
  - [Report](Benchmarks/MuseRadar/results/2026-10-27/REPORT.md).

## Try it

1. Build the **LokalBot Dev** scheme ([DEVELOPMENT.md](DEVELOPMENT.md#build-workflows)).
2. Open Settings → Recording → Meta Muse. Save a Meta Model API key, then turn on "Allow sending meeting text to https://api.meta.ai".
3. Start a recording, open the live meeting, and press **Start Radar**.
4. After the meeting, open its page. Choose **Follow Through…** on one of your commitments in the Live Radar section, or **Follow Through with Muse…** in any action's menu.
