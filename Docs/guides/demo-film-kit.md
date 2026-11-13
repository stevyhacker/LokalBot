# Demo and promo capture guide

Use this guide for public motion assets that prove LokalBot's current product
loop without exposing a real library or overstating the privacy boundary.

## Deliverables

| Asset | Length | Purpose | Source |
| --- | ---: | --- | --- |
| Website demo clips | 5–10 s each | Home page hero and feature cards, light and dark, wide and phone cuts | `Video/lokalbot-landing-demos/` |
| Product promo | 29.973 s | Fast listing or social overview | `Video/lokalbot-promo/` |
| Bot-free meeting proof | 40–50 s | Real capture → cited outcomes | consenting test call |
| Built-in processing proof | 45–60 s | Reproducible network boundary | fresh test call + `nettop` |

The home page plays the short clips from `Video/lokalbot-landing-demos/`; see
its README for filming and cutting them. The 30-second promo is a standalone
cut for listings and social posts. The longer `Video/hero-demo/` project is
preserved as a legacy feature showcase.

## Shared preflight

- Use a synthetic meeting or participants who explicitly consent to the public
  recording. Never expose a personal meeting library, calendar, screen memory,
  prompt, token, or remote-backend URL.
- Capture a 16:9 region at 1920×1080 or larger, in dark appearance, with
  notifications and unrelated windows hidden.
- Download the selected local models before filming. A first-run download is a
  separate network path and should not be edited out of a setup demo.
- Keep the uncut take. Short social edits may tighten pauses, but the proof
  sequence should remain available as one continuous file.
- Recording consent and workplace policy remain the operator's responsibility;
  bot-free capture does not remove that obligation.

## 30-second promo

The project uses six scenes: pop quiz, cited recall, bot-free capture, Dictation
and Autocomplete, a scoped built-in network check, and the CTA. Generated voice,
music, effects, licensed fonts, snapshots, and renders remain ignored; source
HTML, script, storyboard, captions, and the media request are tracked.

Review from `Video/lokalbot-promo/`:

```sh
npm run check
npm run dev
```

Inspect the Studio preview and contact sheet. Only after the cut is approved,
render it from the repository root. The site no longer links these files, so
upload the result where it is needed rather than committing it:

```sh
Scripts/media/render-hero-video-short.sh
```

The script writes the MP4, poster and production manifest under `Website/public/assets/`
atomically.

## Demo A: bot-free meeting to cited outcomes

### Setup

1. Create a calendar event covering the call and invite exactly one test
   participant if the speaker-auto-naming proof is part of the shot. LokalBot
   names the remote speaker automatically only in the unambiguous one-speaker,
   one-attendee case.
2. Use a real calling app so the microphone and system-audio tracks remain
   separate. A second device in another room is a safe solo test rig.
3. Start recording from LokalBot and keep the active recording state visible.

### Test dialogue

Use explicit decisions, owners, dates, and one unresolved question so the small
local model has clean evidence to extract:

> **You:** We need to lock the beta date.
>
> **Alex:** I can draft the release notes by Thursday.
>
> **You:** Then the decision is Friday morning. I will pull the usage numbers
> tomorrow.
>
> **Alex:** I will email the pilot customers today.
>
> **You:** Open question: do we change pricing at GA?

### Shot sequence

1. Start recording and show the live state.
2. Show the call with no bot participant.
3. End the call and keep the processing state in frame.
4. Hold on the meeting workspace: action items, decisions, summary, and evidence
   pills.
5. Open one evidence link and replay the exact source moment.

## Demo B: verify the built-in processing path

This is a scoped test, not a claim that LokalBot never uses the network. Before
the take:

- finish model and runtime downloads;
- select the built-in backend;
- turn automatic update checks off for the duration of the test;
- disable approved remote backends and do not run network-capable Agent commands.

Open Terminal beside LokalBot:

```sh
nettop -p LokalBot -p llama-server
```

The bundled llama.cpp servers bind to `127.0.0.1`, so loopback rows are expected
and should remain visible. For a call that needs the internet, end the call first
and only then turn Wi-Fi off before transcription and summarization.

After the recap appears, capture a second check:

```sh
lsof -i -nP | grep -iE 'lokalbot|llama-server'
```

Accurate captions include:

- “Built-in processing, models already downloaded.”
- “Loopback is LokalBot talking to its local model server.”
- “No outbound connection during this processing cycle.”

Do not caption the scene “nothing ever connects.” LokalBot also connects for
model/runtime downloads, optional update checks, explicitly approved remote
inference, and network-capable Agent commands the user approves.

## Review before publishing

1. Watch once muted; captions and visual hierarchy must carry the story.
2. Watch with headphones; narration is intelligible and the music never masks it.
3. Check every claim against `README.md` and `PRIVACY.md`.
4. Verify no personal data, notification, account name, path, or credential is
   visible at full resolution.
5. Keep masters and uncut proof takes outside git; publish large files through
   Releases or the designated media host.
