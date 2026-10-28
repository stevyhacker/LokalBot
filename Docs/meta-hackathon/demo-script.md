# Demo script: From meeting to done

A three-minute video for the Meta Global AI Developer Hackathon. The judges weigh impact 30%, use of Meta tooling 25%, technical depth 20%, and the demo 25%, and they ask whether the video is "genuinely cool to watch". The rules allow showing only hackathon-built work, so every shot is a hackathon feature. Recording, transcription, and screen memory appear only as the setting.

The video is built around three moments:

1. **An answer from your screen.** A question asked out loud is answered seconds later with a crop of a page you looked at earlier.
2. **A contradiction with the record.** A changed launch date is flagged against what an earlier meeting agreed.
3. **A commitment closed with proof.** After the call, the commitment is marked done with the screenshot that shows it was done.

Moment 3's final version, where LokalBot marks the commitment done by itself, depends on the Muse Glimmer test on the Mac. Until then, it ends with Follow-through opening the email in Mail.

## Before recording

1. **Build.** Build the hackathon branch. A release-identity build run from Xcode's build products uses its own library (`~/Library/Application Support/me.dotenv.LokalBot.local-build`), so the demo never touches real meetings. Install the default Think and search models there.
2. **Connect Muse.** In Settings → Meetings → Meta Muse:
   - save the Meta Model API key;
   - turn on the api.meta.ai approval;
   - turn on fast live text, which sends meeting audio to Muse Voice Transcribe;
   - turn on screen answers, which sends cropped screenshots to Muse Spark.

   Set your name in Settings → Writing, so drafts are signed.
3. **Calendar entry.** Create a calendar event "Launch sync" with your partner as an invitee, so Follow-through can fill in their address.
4. **Earlier meeting.** Give the library an earlier meeting for the radar to contradict. Record or import a one-minute "Launch planning" call a few days before, with these lines:
   - Partner: "So we agreed: the launch is Monday, November 3rd, and the pricing page ships the Friday before."
   - You: "And the free tier keeps three projects, that's settled."
   - Partner: "Marko can review the onboarding emails once the copy is final."

   Let it finish processing so its notes and search entries exist.
5. **Screen history.** With screen memory on in the demo library, spend a minute on two synthetic pages so they are captured and indexed:
   - a metrics dashboard showing "Trial to paid, September: 4.1%";
   - a launch plan document showing "Launch: Monday, November 3".
6. **Consent.** Everyone recorded must agree. While you are on free Meta credits, Meta may use what is sent to improve its products.

## The live call (about 2 minutes)

You on your microphone, your partner on a Google Meet or Zoom call. Speak naturally; with fast live text, each turn is sent when it ends.

- Partner: "Hi! Okay, launch checklist. The pricing page is almost done, I just need the final numbers."
- You: "I'll send the revised pricing deck to Marko by Friday."
- Partner: "Great. What was our trial-to-paid conversion last month, by the way?"
- You: "Let me think… I saw it on the dashboard."
- Partner: "Also, the launch is Friday the seventh now, right? Marketing told me Friday."
- You: "Hm, I thought it was the Monday. Let me check."
- Partner: "And sales wants the free tier limited to one project."
- You: "Okay, let's decide that with Ana tomorrow."
- Partner: "Marko will review the onboarding emails before Wednesday."
- You: "Perfect. Let's go with twenty percent off for annual plans."
- Partner: "Agreed, twenty percent. Talk tomorrow!"

## Shot list (3:00)

| Time | Shot | Say |
|---|---|---|
| 0:00–0:12 | Cold open: the partner asks about conversion, and three seconds later the radar shows "4.1% in September" with the dashboard crop | Someone asks a number in a meeting. LokalBot saw it on your screen on Tuesday, and answers before you've found the tab. |
| 0:12–0:25 | LokalBot recording a call; Settings → Meta Muse with its switches. Caption: "Built during the hackathon" | LokalBot already records meetings and remembers your screen, on your Mac. For this hackathon we connected that memory to four Meta models. |
| 0:25–1:25 | The live meeting: Start Radar. Commitments and the decision appear seconds after they are said. The contradiction card for the launch date shows the earlier meeting's quote; click it to jump to the passage. | Muse Voice Transcribe turns each turn into text as it ends, and Muse Spark reads it. Commitments, decisions, and questions land within seconds. When the launch date changes, it shows what you agreed last week, with the quote. Every item must quote a line just said, every answer must match the screenshot's own text, and a contradiction must cite a passage local search found, so nothing is invented. |
| 1:25–2:05 | After the call: Follow Through on "Send the revised pricing deck to Marko". Muse Wonder's reads appear, then the email card. Edit one word, Open in Mail, send it. | Follow-through hands the commitment to Muse Wonder. It reads the meeting and earlier ones, and writes the email, flagging the two open conflicts instead of guessing. Nothing is sent until you approve it. |
| 2:05–2:30 | A few minutes later, the commitment flips to Done with a crop of the sent email (if the Glimmer test passes) | Then LokalBot checks your screen for proof. Muse Glimmer, running on this Mac, looks at the capture and marks it done. Your screen never leaves the machine for this. |
| 2:30–2:50 | One diagram: Voice Transcribe → Spark → Wonder, and Glimmer on the Mac, with what each one receives | Four Meta models, each where it's best: realtime speech, fast reasoning over text and images, planning, and an open model for the private part. |
| 2:50–3:00 | LokalBot icon, repo link | LokalBot: from meeting to done. |

## Facts to keep straight

- **Models.**
  - Muse Voice Transcribe 1.0: live meeting text, opt-in. Speaker identity comes from the tracks (your microphone is you), not from its labels, which measured less accurate than local Nemotron.
  - Muse Spark 1.3: Live Radar (minimal reasoning, strict JSON schema) and screen answers (images of cropped captures).
  - Muse Wonder 1.0: Follow-through (tool calling, low reasoning).
  - Muse Glimmer 30B: the on-device check that a commitment was done, if the Mac test passes.
- **Earlier work.** Recording, transcription, speaker separation, screen memory and its search, notes, actions, and the "looks done" hints existed before the hackathon (LokalBot v0.11.4). Show them only as the setting.
- **Measurements stay in the repo.** The AMI evaluation and the Voice Transcribe speaker-label comparison are in [Benchmarks/MuseRadar](../../Benchmarks/MuseRadar/README.md) and [Benchmarks/MuseVoiceTranscribe](../../Benchmarks/MuseVoiceTranscribe/README.md), not in the video.
