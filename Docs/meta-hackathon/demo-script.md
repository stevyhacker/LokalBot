# Demo script: From meeting to done

A three-minute video for the Meta Global AI Developer Hackathon. The judges weigh impact 30%, use of Meta tooling 25%, technical depth 20%, and the demo 25%, and they ask whether the video is "genuinely cool to watch". The rules allow showing only hackathon-built work, so every shot is a hackathon feature. Recording, transcription, and screen memory appear only as the setting.

The video is built around four moments:

1. **An answer from your screen.** A question asked out loud is answered seconds later with a crop of a page you looked at earlier.
2. **An answer from your work.** A question about the pricing sheet is answered from the sheet, and a question about the product from its code, while the card shows where it looked.
3. **A contradiction with the record.** A changed launch date is flagged against what an earlier meeting agreed.
4. **A commitment handed off.** After the call, Follow-through writes the email for "Send the revised pricing deck to Marko", and nothing is sent until you approve it.

## Before recording

Follow [recording-checklist.md](recording-checklist.md). [`Scripts/meta-hackathon-demo.sh`](../../Scripts/meta-hackathon-demo.sh) runs LokalBot Dev on a separate demo library and settings. That library already holds the earlier "Launch planning" meeting the radar contradicts, and the two folders live answers read: the Northwind pricing sheet and launch brief, and a copy of the LokalBot repository. The checklist covers:
- the permissions and the Meta key;
- capturing the two synthetic pages in [demo-pages/](demo-pages/) into screen memory;
- keeping the floating panel visible to the screen recording;
- consent from everyone recorded.

## The live call (about 2 minutes)

You on your microphone, your partner on a Google Meet or Zoom call. Speak naturally; with fast live text, each turn is sent when it ends. Don't answer the questions yourself: an answered question is left off the radar. After the two questions it looks up, wait until the answer is the panel's top card before the next line (10 to 15 seconds); in the CI film, the next items took the top spot a few seconds after each answer landed.

- Partner: "Hi! Okay, launch checklist. The pricing page is almost done, I just need the final numbers."
- You: "I'll send the revised pricing deck to Marko by Friday."
- Partner: "Great. What did we put as the Team plan price in the pricing sheet?"
- You: "One second, it's in the sheet." *(Wait for the answer.)*
- Partner: "And what was our trial-to-paid conversion last month, by the way?"
- You: "Let me think, I saw it on the dashboard."
- Partner: "Also, the launch is Friday the seventh now, right? Marketing told me Friday."
- You: "Hm, I thought it was the Monday. Let me check."
- Partner: "And sales wants the free tier limited to one project."
- You: "Okay, let's decide that with Ana tomorrow."
- Partner: "Unrelated, but I'm showing LokalBot to a journalist on Friday. Is the radar panel hidden when I share my screen?"
- You: "Hm, good question." *(Wait for the answer.)*
- Partner: "Marko will review the onboarding emails before Wednesday."
- You: "Perfect. Let's go with twenty percent off for annual plans."
- Partner: "Agreed, twenty percent. Talk tomorrow!"

## Shot list (3:00)

| Time | Shot | Say |
|---|---|---|
| 0:00–0:12 | Cold open: the partner asks about conversion, and three seconds later the radar shows "4.1% in September" with the dashboard crop | Someone asks a number in a meeting. LokalBot saw it on your screen on Tuesday, and answers before you've found the tab. |
| 0:12–0:25 | LokalBot recording a call; Settings → Meta Muse with its switches. Caption: "Built during the hackathon" | LokalBot already records meetings and remembers your screen, on your Mac. For this hackathon we connected that memory to three Meta models. |
| 0:25–1:15 | The Meet window full screen, with the floating Live Radar panel in its corner: press Start Radar in the panel without leaving the call. Each new item lands in the panel's large card seconds after it is said; the launch-date contradiction shows the earlier meeting's quote, and the conversion answer shows the dashboard crop. | Muse Voice Transcribe turns each turn into text as it ends, and Muse Spark reads it. Commitments, decisions, and questions land within seconds. When the launch date changes, it shows what you agreed last week, with the quote. Every item must quote a line just said, and a contradiction must cite a passage local search found, so nothing is invented. |
| 1:15–1:50 | Close on the panel's card for the Team plan question: the steps tick by ("Checking what LokalBot remembers…", "Searching your documents…", "Reading Northwind pricing v2.xlsx…"), then the answer with the sheet's row. Then the panel question: "Searching the code…", and the answer citing `AppSettings.swift`. Click the source; GitHub opens on that line. Cut once to LokalBot's main window, where the same items fill the board. | When the screen can't answer, Muse Wonder looks it up. It starts from what LokalBot remembers, your projects and open actions, then opens the sheets, PDFs, and code you allowed. The answer is kept only if the line it quotes is really in the file it read. |
| 1:50–2:30 | After the call: Follow Through on "Send the revised pricing deck to Marko". Muse Wonder's reads appear, then the email card. Edit one word, Open in Mail, send it. | Follow-through hands the commitment to Muse Wonder. It reads the meeting and earlier ones, and writes the email, flagging the two open conflicts instead of guessing. Nothing is sent until you approve it. |
| 2:30–2:50 | One diagram: Voice Transcribe → Spark → Wonder, with what each one receives | Three Meta models, each where it's best: realtime speech, fast reasoning over text and images, and careful lookups and plans. |
| 2:50–3:00 | LokalBot icon, repo link | LokalBot: from meeting to done. |

## Facts to keep straight

- **Models.**
  - Muse Voice Transcribe 1.0: live meeting text, opt-in. Speaker identity comes from the tracks (your microphone is you), not from its labels, which measured less accurate than local Nemotron.
  - Muse Spark 1.3: Live Radar (minimal reasoning, strict JSON schema) and screen answers (images of cropped captures).
  - Muse Wonder 1.0: live answers and Follow-through (tool calling, low reasoning).
- **What live answers read.** What LokalBot remembers comes first; then meetings, screen text, and only the folders chosen in Settings. In a repository it reads tracked files only, never hidden files or secrets, and pull requests and issues through the GitHub CLI.
- **Earlier work.** Recording, transcription, speaker separation, screen memory and its search, notes, actions, projects, and the "looks done" hints existed before the hackathon (LokalBot v0.11.4). Show them only as the setting.
- **Measurements stay in the repo.** The AMI evaluation, the live-answers replays, and the Voice Transcribe speaker-label comparison are in [Benchmarks/MuseRadar](../../Benchmarks/MuseRadar/README.md) and [Benchmarks/MuseVoiceTranscribe](../../Benchmarks/MuseVoiceTranscribe/README.md), not in the video.
