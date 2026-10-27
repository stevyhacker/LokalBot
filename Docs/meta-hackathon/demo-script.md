# Demo script: From meeting to done

A three-minute video for the Meta Global AI Developer Hackathon. The judges weigh impact 30%, use of Meta tooling 25%, technical depth 20%, and the demo 25%. The rules allow showing only hackathon-built work, so every shot is either Live Radar, Follow-through, or a measurement made for them. Recording and transcription appear only as the setting.

## Before recording

1. **Build.** Build the hackathon branch. A release-identity build run from Xcode's build products uses its own library (`~/Library/Application Support/me.dotenv.LokalBot.local-build`), so the demo never touches real meetings. Install the Qwen3-ASR model there for the live preview, and the default Think and search models.
2. **Connect Muse.** In Settings → Recording → Meta Muse, save the Meta Model API key and turn on the api.meta.ai approval. Set your name in Settings → Writing, so drafts are signed.
3. **Calendar entry.** Create a calendar event "Launch sync" with your partner as an invitee, so Follow-through can fill in their address.
4. **Earlier meeting.** Give the library an earlier meeting for the radar to contradict. Record or import a one-minute "Launch planning" call a few days before, with these lines:
   - Partner: "So we agreed: the launch is Monday, November 3rd, and the pricing page ships the Friday before."
   - You: "And the free tier keeps three projects, that's settled."
   - Partner: "Marko can review the onboarding emails once the copy is final."

   Let it finish processing so its notes and search entries exist.
5. **Consent.** Everyone recorded must agree. While you are on free Meta credits, Meta may use what is sent to improve its products.

## The live call (about 2½ minutes)

You on your microphone, your partner on a Google Meet or Zoom call. Pause a few seconds between turns, so each line lands in its own preview chunk.

- Partner: "Hi! Okay, launch checklist. The pricing page is almost done, I just need the final numbers."
- You: "I'll send the revised pricing deck to Marko by Friday."
- Partner: "Great. Did we decide whether annual plans get a discount?"
- You: "Not yet, let's keep that open."
- Partner: "Also, the launch is Friday the seventh now, right? Marketing told me Friday."
- You: "Hm, I thought it was the Monday. Let me check."
- Partner: "And sales wants the free tier limited to one project."
- You: "Okay, let's decide that with Ana tomorrow."
- Partner: "Marko will review the onboarding emails before Wednesday."
- You: "Perfect. Let's go with twenty percent off for annual plans."
- Partner: "Agreed, twenty percent. Talk tomorrow!"

On the synthetic replay of this script, Live Radar caught all six planned items. Commitments, the question, and the decision appeared 15–25 s after they were said. The two contradictions came with the earlier meeting's passage.

## Shot list (3:00)

| Time | Shot | Say |
|---|---|---|
| 0:00–0:15 | Calendar full of meetings; a crossed-out to-do list | Meetings end and the promises scatter. Last week's decisions get quietly reversed, and nobody notices until launch. |
| 0:15–0:30 | LokalBot recording a call; Settings → Meta Muse with the approval switch | LokalBot already records and transcribes meetings on your Mac. For this hackathon we added two things built on Meta's Muse models, with a privacy boundary: audio never leaves the Mac, only text. |
| 0:30–1:25 | Live meeting: Start Radar, then the radar filling in beside the transcript. Hover the contradiction card, click "Earlier: Launch planning" to jump to the passage. | Live Radar sends Muse Spark only the newest transcript lines, about every 20 seconds. Commitments, decisions, and open questions appear as they are said. When the launch date changes, it shows what you agreed last week, with the quote. Every item must quote a line just said, and a contradiction must cite a passage found by local search, so it cannot invent one. |
| 1:25–1:35 | Stop recording; the meeting page with its Live Radar section | When the call ends, what the radar caught stays with the meeting. |
| 1:35–2:25 | Follow Through on "Send the revised pricing deck to Marko": the reads appear, then the email card. Edit one word, Open in Mail, and Mail opens the draft with Marko's address. Then the invitation card for Ana opens in Calendar. | Follow-through hands the commitment to Muse Wonder. It reads the meeting and earlier ones, then proposes the work: an email that flags the two open conflicts instead of guessing, and a meeting with Ana to settle them. Nothing is sent until you approve it, and approved steps open as drafts. Email addresses come from your calendar on the Mac and never go to Meta. |
| 2:25–2:50 | The AMI numbers and the Voice Transcribe benchmark table | We measured both. On 6.4 hours of AMI meetings, Live Radar on Muse Spark caught 22 of the 62 human-annotated decisions while the meetings were happening. Our existing post-meeting notes caught 2. That costs 49 cents per meeting hour. We also tested Muse Voice Transcribe for live speaker labels. Its text arrives in under a second, but local diarization was more accurate, so speakers stay on the Mac. |
| 2:50–3:00 | LokalBot icon, repo link | LokalBot: from meeting to done, with your meetings staying yours. |

## Facts to keep straight

- **Models.**
  - Muse Spark 1.3 runs Live Radar: minimal reasoning, strict JSON schema.
  - Muse Wonder 1.0 runs Follow-through: tool calling, low reasoning.
  - Muse Voice Transcribe 1.0 was benchmarked, not adopted. Its speaker labels had 60.4% DER against 16.5% for local Nemotron.
- **Earlier work.** Recording, transcription, speaker separation, search, notes, and actions existed before the hackathon (LokalBot v0.11.4). Show them only as the setting.
- **Where the numbers live.** [Benchmarks/MuseRadar](../../Benchmarks/MuseRadar/README.md) and [Benchmarks/MuseVoiceTranscribe](../../Benchmarks/MuseVoiceTranscribe/README.md).
