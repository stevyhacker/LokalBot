---
workflow: general-video
flow: automation
storyboard: no
message: "LokalBot turns a meeting into done work with three Meta models: it catches what's said, answers from your work, and drafts the follow-up for your approval."
destination: Meta Global AI Developer Hackathon submission (judged on impact, use of Meta tooling, technical depth, demo)
aspect: 16:9
language: en
length: 3:00 or less
voice: ElevenLabs eleven_v4; narration and Stevan's lines in the author's own voice clone, Ana's lines in the "Ana" voice
---

# From meeting to done — the hackathon demo film

## Intent

The user asked to "use the scripted demo but improve it": the film is cut from the CI UI test (`LokalBotUITests/HackathonFilmUITests.swift`, workflow `meta-hackathon-film.yml`), which drives the real app on a hosted Mac with live Muse Spark and Muse Wonder replies. The call's words are scripted, because the runner has no meeting audio; the film says so on screen and on the end card.

Story, in order: a screen answer as the cold open (4.1% from last week's dashboard), the title, the Meta Muse settings, Start Radar over a call, a commitment caught as it's said, a live answer from the pricing sheet, the launch-date contradiction, a live answer from the code, the board after the call, Follow-through drafting for approval, the three models, the end card.

## Customizations

- First-person narration in the author's voice (approved for the autocomplete launch film), and the call voiced by Stevan's clone and the "Ana" voice.
- Dark radar-room look shared with the Live Radar and live answers explainer pages: Big Shoulders Display, Hanken Grotesk, JetBrains Mono, teal accent.
- Camera moves from the wide call to the floating panel and its cards; slowed footage only where the UI is waiting; app footage at 1.25× or faster carries a speed badge.

## Notes

- Check every narration claim against the take in use (answers, sources, which commitment Follow-through ran on): live replies vary between takes.
- Keep `hyperframes@0.8.150`, the pin the other LokalBot films use.
