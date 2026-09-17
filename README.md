<div align="center">


<img src="Assets/lokalbot-icon.svg" width="110" alt="LokalBot icon" />


# LokalBot


**Find what you said or saw on your Mac.**


Find a decision from a call, a page you had open, or what you need to follow up on. LokalBot searches meeting transcripts and screen text you choose to save, with links back to the source.


Free and open source. Runs locally by default. No account required.


[![Download LokalBot for macOS](https://img.shields.io/badge/%E2%80%82Download%20for%20macOS%E2%80%82-LokalBot.dmg-0969da?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/stevyhacker/lokalbot/releases/latest/download/LokalBot.dmg)


<sub>Apple Silicon (M1 or later) · macOS 15+ · <a href="https://github.com/stevyhacker/lokalbot/releases">Release notes</a></sub>


[![Latest release](https://img.shields.io/github/v/release/stevyhacker/lokalbot?color=1f6feb&label=release)](https://github.com/stevyhacker/lokalbot/releases/latest)
[![License: GPLv3](https://img.shields.io/badge/license-GPLv3-2ea043)](LICENSE)


[See it in action](#see-it-in-action) · [Features](#features) · [Privacy](#privacy--verify-it) · [Get started](#download) · [For developers](#for-developers--agents)


</div>


## See it in action


**One search, across meetings and saved screen text.** Quick Recall finds the Redis discussion in a meeting alongside matching Slack and browser context. Open a result to return to the source.


<div align="center"><a href="Assets/screenshots/quick-recall.png"><img src="Assets/screenshots/quick-recall.png" alt="Quick Recall searching for Redis, with results grouped into saved screen context and meeting transcripts" width="660"></a></div>


**Watch the 43-second demo.** Search an engineering discussion, find the database decision, and recover the follow-up to draft the schema.


https://github.com/user-attachments/assets/39cba80c-a0d5-4cf3-9019-b081b287de4f


<sub>The video shows the real app with a prepared fictional meeting. It demonstrates search and source navigation; live recording and transcription are not shown.</sub>


**Find the decision and the discussion behind it.** Open a meeting to review its recap, decisions, and action items, then follow a citation back to the transcript or audio.


<div align="center"><a href="Assets/screenshots/meetings-summary.png"><img src="Assets/screenshots/meetings-summary.png" alt="Meeting workspace showing the Design review recap, decisions, action items, source citations, and audio playback" width="920"></a></div>


**Pick up where you left off.** Today brings the day's summary and outstanding meeting actions together.


<div align="center"><a href="Assets/screenshots/today.png"><img src="Assets/screenshots/today.png" alt="Today showing the day digest and outstanding meeting actions" width="920"></a></div>


<details>
<summary>See your day in Timeline</summary>


Timeline groups captured activity into work sessions, with the underlying context available to inspect.


<div align="center"><a href="Assets/screenshots/timeline.png"><img src="Assets/screenshots/timeline.png" alt="Timeline showing grouped work sessions, meetings, and access to captured context" width="920"></a></div>


</details>


<sub>App screenshots use synthetic demo data captured from v0.8.2. Click an image for the full-resolution view. See the <a href="Assets/screenshots/README.md">capture notes</a> for provenance.</sub>


## Features


| What you want to do | How LokalBot helps |
| --- | --- |
| **Remember a call** | Record microphone and meeting-app audio without adding a bot. Transcribe locally and review the recap, decisions, action items, and open questions. |
| **Find something again** | Search meeting transcripts and optional saved screen text by words or meaning. Open the source behind a result or ask a question with meeting citations. |
| **Keep track of follow-ups** | Review and correct action items, mark them done, and trace them back to the meetings where they came up. |
| **Look back at your day** | Browse work sessions and the day digest. Choose activity-only tracking, visible text, or text with encrypted screenshots. |
| **Write in other apps** | Dictate at the cursor or enable local Autocomplete. Both are optional; Autocomplete has an in-app preview to try before enabling it elsewhere. |
| **Prepare the next step** | Create local follow-up drafts and Markdown exports, or hand reviewed context to the optional Agent Mode. File and shell actions follow its approval settings. |


<details>
<summary>See Autocomplete and model settings</summary>


Try a suggestion before enabling Autocomplete in other apps.


<div align="center"><a href="Assets/screenshots/cotyping.png"><img src="Assets/screenshots/cotyping.png" alt="Autocomplete settings with model readiness, a local suggestion preview, and an acceptance rehearsal" width="920"></a></div>
