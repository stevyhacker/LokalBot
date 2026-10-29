# Recording checklist: the Meta hackathon demo

Steps for the live take in [demo-script.md](demo-script.md). The demo runs LokalBot Dev on its own library and its own settings, so your meetings, settings, and screen memory are never read or written. [`Scripts/meta-hackathon-demo.sh`](../../Scripts/meta-hackathon-demo.sh) does the setup.

## Already done

- **Demo library.** `~/Library/Application Support/me.dotenv.LokalBot.meta-demo` holds three earlier meetings:
  - "Launch planning", six days before setup, whose transcript, summary, and decisions say the launch is Monday, November 3rd and the free tier keeps three projects;
  - "Pricing deck review" and "Weekly team sync", which only make the library look used.
- **Models.** Your downloaded model files are linked one by one. A new download lands in the demo library, never in yours.
- **Settings.** The `me.dotenv.LokalBot.meta-demo` settings suite has:
  - the api.meta.ai approval;
  - fast live text, screen answers, and the floating panel on;
  - "Hide the floating panel from screen sharing and recordings" off, so your recording shows the panel;
  - screen memory set to text and screenshots, every minute.
- **Dev app.** LokalBot Dev is built from the `meta-hackathon` branch with the floating panel.

To start over: `Scripts/meta-hackathon-demo.sh reset`, then `setup`.

## Once, at least a day before recording

1. **Open the demo app.** Quit LokalBot Dev if it's running, then run `Scripts/meta-hackathon-demo.sh open`. Always start it this way, never from the Dock or Xcode: those open your normal Dev library. The Meetings list should show "Launch planning", "Pricing deck review", and "Weekly team sync".
2. **Permissions.** Give LokalBot Dev Microphone, Screen & System Audio Recording, and Accessibility in System Settings → Privacy & Security. Screen memory reads window titles and text through Accessibility. If macOS asks you to quit and reopen it, reopen it with `open` again.
3. **Meta key.** Settings → Meetings → Meta Muse: if the API key doesn't say "Saved in Keychain", paste it and press Save key. Check the switches below it match the list above.
4. **Your name.** Settings → Writing → your name, so the Follow-through email is signed.
5. **Screen memory.** Run `Scripts/meta-hackathon-demo.sh pages`, which opens the two synthetic pages in Safari: a Northwind growth dashboard and a Northwind launch plan.
   - Use a normal window, not a private one; private windows are never captured.
   - Keep each page in front for about two minutes, switching between them a few times.
   - Check that they were captured: in LokalBot, Ask → Screen, search "trial to paid". The dashboard should come up with its screenshot.
   - Screen answers show the capture's real date, so capturing a day early lets the line "you saw it on the dashboard on Tuesday" be true.
6. **Calendar (optional).** Create a calendar event "Launch sync" at the recording time with your partner as an invitee, and allow LokalBot Dev calendar access. Follow-through then fills in their email address; without it, you type it into the draft.
7. **Rehearse once.** Do one short call with the script below. Afterwards, delete that meeting in LokalBot so the real take is the only "Launch sync".

## On the day

1. **Quit your everyday LokalBot** (the installed app), so it doesn't also record the call into your real library and its shortcuts don't clash.
2. **Start the demo app** with `Scripts/meta-hackathon-demo.sh open`.
3. **Screen recording.** Press ⌘⇧5 and record the whole screen. The floating panel shows up in it only because its hide setting is off; turn the hiding back on when you're done.
4. **Join the call** in Google Meet or Zoom with your partner. Both of you agree to be recorded.
5. **Start recording** in LokalBot Dev (the menu bar, or the "record this meeting?" prompt).
6. **Start the radar.** The floating Live Radar panel appears in the top-right corner. Press Start Radar in it, then drag it next to the call.
7. **Run the call script** in [demo-script.md](demo-script.md#the-live-call-about-2-minutes). Pause a moment between turns. Expect:
   - your commitment and Marko's, and the 20% decision, about 3 seconds after each is said;
   - "trial-to-paid conversion last month" answered "4.1%" with the dashboard crop;
   - the launch-date and free-tier contradictions, each with the "Launch planning" quote.
8. **Show the main window once.** Switch to LokalBot Dev: the same items fill the board, with what needs attention at the top.
9. **Stop recording.** Open the meeting's page, and choose Follow Through… on "Send the revised pricing deck to Marko". Approve the email (it opens as a draft in Mail), then the invitation.

## If something is missing

| Symptom | Check |
|---|---|
| Start Radar says Set Up… | The key is saved and "Allow sending meeting text to https://api.meta.ai" is on |
| No contradictions | The meeting list includes "Launch planning"; Ask finds "launch Monday November" |
| No screen answer | Ask → Screen finds "trial to paid" with a screenshot; LokalBot Dev has Screen Recording |
| The panel isn't in the recording | "Hide the floating panel from screen sharing and recordings" is off |
| Transcript appears only in 12-second chunks | "Fast live text" is on, and the recording started after you turned it on |
| The app shows your normal Dev meetings | It was opened from the Dock or Xcode; quit and use `open` |

While you use free Meta credits, Meta may use what is sent to improve its products: the call's text and audio (with fast live text) and the screen crops. Record only people who agreed.
