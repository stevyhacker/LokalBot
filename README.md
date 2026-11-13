<div align="center">

<img src="Assets/lokalbot-icon.svg" width="100" alt="LokalBot icon" />

# LokalBot

**Your personal context engine.**

Notes from every call with no bot. One search for everything you saw and heard.<br />
Autocomplete and dictation in any app. Local by default.<br />
Your AI agents can search it too, from Claude Code, Codex, or any MCP client.

<a id="see-it-in-action"></a>

<picture><source media="(prefers-color-scheme: dark)" srcset="Assets/hero/lokalbot-demo-dark.gif" /><img src="Assets/hero/lokalbot-demo-light.gif" width="920" alt="LokalBot in use, in six looping scenes with fictional demo data, each under a caption. Notes from every call, with no bot: a Google Chrome call is recorded, its live transcript fills in, the notes appear, and clicking an action item's citation opens the transcript at that line. One search for everything you saw and heard: typing &quot;demo pres&quot; finds a Keynote deck and a Mail reply seen on screen, and two meetings. Autocomplete that knows what your meetings decided: in TextEdit, it finishes &quot;the Team plan will be $15&quot; with &quot;per seat, billed annually.&quot; and Tab accepts it. Say what you need, and it writes at your cursor: holding Option-Space writes a short team update into an empty document. Ask your own work, then check the source: an answer about a holiday shoot cites a meeting, and clicking the citation opens it. Your AI agents can search it too: in a terminal, Claude Code calls LokalBot and lists what a design review decided and what is still owed." /></picture>

<sub>The real app on fictional data. Waits are cut and some typing is sped up.</sub>

**Free and open source. No account.**

[![Download LokalBot for macOS](https://img.shields.io/badge/%E2%80%82Download%20for%20macOS%E2%80%82-Apple%20Silicon-0969da?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/stevyhacker/lokalbot/releases/latest)
[![Download LokalBot for Windows (alpha)](https://img.shields.io/badge/%E2%80%82Download%20for%20Windows%E2%80%82-alpha-0969da?style=for-the-badge&logo=data%3Aimage%2Fsvg%2Bxml%3Bbase64%2CPHN2ZyB4bWxucz0naHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmcnIHZpZXdCb3g9JzAgMCAxNiAxNic%2BPHBhdGggZmlsbD0nd2hpdGUnIGQ9J00wIDBoNy41djcuNUgwek04LjUgMEgxNnY3LjVIOC41ek0wIDguNWg3LjVWMTZIMHpNOC41IDguNUgxNlYxNkg4LjV6Jy8%2BPC9zdmc%2B)](https://github.com/stevyhacker/lokalbot/releases/latest)
[![Download LokalBot for Linux (alpha)](https://img.shields.io/badge/%E2%80%82Download%20for%20Linux%E2%80%82-alpha-0969da?style=for-the-badge&logo=linux&logoColor=white)](https://github.com/stevyhacker/lokalbot/releases/latest)
[![Get the LokalBot companion app for Android on Google Play](https://img.shields.io/badge/%E2%80%82Get%20it%20on%20Google%20Play%E2%80%82-Android-0969da?style=for-the-badge&logo=googleplay&logoColor=white)](https://play.google.com/store/apps/details?id=me.dotenv.lokalbot.companion)

<sub>Apple Silicon (M1 or later) with macOS 15+ · Windows 10/11 x64 (alpha) · Linux x86_64 (alpha) · Android 10+ companion · on Mac, also <code>brew install --cask stevyhacker/tap/lokalbot</code></sub>

[![Latest release](https://img.shields.io/github/v/release/stevyhacker/lokalbot?color=1f6feb&label=release)](https://github.com/stevyhacker/lokalbot/releases/latest)
[![License: GPLv3](https://img.shields.io/badge/license-GPLv3-2ea043)](LICENSE)
[![MCP: read-only server](https://img.shields.io/badge/MCP-read--only%20server-8250df)](#for-developers--agents)

<sub>⭐ If LokalBot is useful to you, star the repo. It's built by one developer, and stars are how other people find it.</sub>

**English** · [简体中文](README.zh-CN.md)

[Features](#features) · [Agents & CLI](#for-developers--agents) · [Windows & Linux](#windows-and-linux) · [Android](#on-your-phone) · [Compare](#how-it-compares) · [Privacy](#privacy) · [Get started](#get-started) · [Models](#local-ai-your-choice) · [Website](https://www.lokalbot.com/)

</div>

## Features

### Remember what was agreed

Record microphone and meeting-app audio without a bot joining. Get local transcripts, recaps, decisions, and action items, with citations back to the discussion. You can also import audio and video files as meetings.

<div align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="Assets/readme/meetings-dark.png" /><img src="Assets/readme/meetings-light.png" width="800" alt="A recorded call's notes: audio playback, a recap of what was decided, and action items, each with the time it was said" /></picture></div>

### Find something you saw

One search across your meeting transcripts and, if you turn it on, what you saw on screen. Search by keyword or by meaning, then open the matching passage or screen moment instead of hunting through apps. The same window (**⌃⇧ Space**, or **Ctrl+Shift+Space** on Windows and Linux, once you turn on the shortcut in **Settings → Ask**, or **Settings → General** on Windows and Linux) also runs app commands such as **Record now** or **Start dictation** from whatever app you're in.

<div align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="Assets/readme/search-dark.png" /><img src="Assets/readme/search-light.png" width="640" alt="Quick Recall finding a Keynote deck and a Mail reply seen on screen, and two meetings that mention the demo presentation" /></picture></div>

### Finish the sentence

As you type in other apps, gray text suggests how your sentence ends. Press **Tab** to take the next word, **\`** to take the rest, or keep typing.

<div align="center"><img src="Assets/screenshots/autocomplete-memory.gif" alt="Typing an update in TextEdit after a call with John: after &quot;the Harbor beta ships&quot;, autocomplete suggests &quot;Thursday morning, after the accessibility review.&quot; and Tab accepts it word by word" width="920" /></div>

<div align="center"><sub>Live suggestions in TextEdit, in real time. The ship date and condition come from the meeting with John. Fictional demo meeting.</sub></div>

- **Knows what you're answering.** It reads the message or page above the field, so a reply fits the thread.
- **Remembers your meetings, if you let it.** Turn on meeting and work memory, and it can bring in what was decided, like the ship date above.
- **Writes in your language.** The same small model keeps up in German, French, Italian, Spanish, and more.
- **Stays on your computer.** A small model runs inside the app: Gemma 4 E2B on Mac, Windows and Linux. What you type and the context it reads stay on your computer, unless you choose an autocomplete server and approve it.

Turn it on in **Settings → Autocomplete**, where you can try it on a sample conversation first and later see how much it wrote for you.

### Pick up where you left off

<table>
  <tr>
    <td width="50%" valign="top"><strong>What do I still need to do?</strong><br />
      Today shows the day's summary and every open action, each linked to the meeting it came from. Each morning the overnight review adds a look back at yesterday.</td>
    <td width="50%" valign="top"><strong>Where did the day go?</strong><br />
      Retrace your day session by session. Tracking starts with app and window activity; screen text and screenshots are opt-in. If you use Claude Code or Codex, it can name the work by project and show related pull requests and commits.</td>
  </tr>
  <tr>
    <td><picture><source media="(prefers-color-scheme: dark)" srcset="Assets/readme/today-dark.gif" /><img src="Assets/readme/today-light.gif" width="420" alt="Today listing the actions that need attention, each linked to its meeting; ticking one off leaves the rest, then the day digest scrolls in" /></picture></td>
    <td><picture><source media="(prefers-color-scheme: dark)" srcset="Assets/readme/timeline-dark.gif" /><img src="Assets/readme/timeline-light.gif" width="420" alt="Timeline showing the hours tracked and the day's sessions; clicking a session opens its evidence and the documents and windows behind it" /></picture></td>
  </tr>
  <tr>
    <td width="50%" valign="top"><strong>What's open with Maya?</strong><br />
      See what's waiting on you and what you decided together. Name a speaker once, and LokalBot recognizes their voice in later meetings.</td>
    <td width="50%" valign="top"><strong>Where did I save that?</strong><br />
      Search the folders you choose by what's in them: documents, PDF pages, pictures, and moments in recordings and video.</td>
  </tr>
  <tr>
    <td><picture><source media="(prefers-color-scheme: dark)" srcset="Assets/readme/people-dark.gif" /><img src="Assets/readme/people-light.gif" width="420" alt="People showing Maya's page: an action waiting on you, a suggested project, and decisions made together with links to the meeting" /></picture></td>
    <td><picture><source media="(prefers-color-scheme: dark)" srcset="Assets/readme/files-dark.gif" /><img src="Assets/readme/files-light.gif" width="420" alt="Searching for the clause about pets in the lease finds a page of a PDF, and searching for where they talk about sleep finds a moment in a podcast recording" /></picture></td>
  </tr>
  <tr>
    <td colspan="2" align="center">
      <strong>Where does this project stand?</strong><br />
      Track a project, and LokalBot gathers the meetings, actions, and decisions that name it. Open it for a short note on where it stands, with links back to the meetings behind it. Not sure what to track? It suggests names that keep coming up in your meetings.<br /><br />
      <picture><source media="(prefers-color-scheme: dark)" srcset="Assets/readme/projects-dark.gif" /><img src="Assets/readme/projects-light.gif" width="640" alt="Projects suggesting Northwind, which came up in four meetings; tracking it starts a note, which then says where the holiday cut stands with a link back to each meeting" /></picture>
    </td>
  </tr>
</table>

### Ask, then check the source

Ask your own work a question. Answers cite their sources, and say so when one can't be verified. Follow a citation back to the transcript or audio. Generated notes are a starting point, not a substitute for the discussion.

<div align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="Assets/readme/ask-dark.gif" /><img src="Assets/readme/ask-light.gif" width="720" alt="Asking what was decided about the shoot: the answer streams in with numbered citations and an evidence list, and clicking the source opens the Holiday shoot planning meeting" /></picture></div>

### Talk instead of typing

Turn on Dictation in **Settings → Dictation**, then hold **⌥ Space** (**Alt+Space** on Windows and Linux, or a shortcut you choose there), speak, and release to insert text at your cursor in any app. Transcription runs on your computer, and your recent dictations are kept so you can copy one again. In Compose mode, say what you need and LokalBot writes it at your cursor, from your meetings if you let it. On Wayland, bind `lokalbot dictate` to a shortcut in your desktop's settings.

<div align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="Assets/readme/dictation-dark.gif" /><img src="Assets/readme/dictation-light.gif" width="720" alt="Holding Option-Space to dictate into an empty document: a small panel listens, then a short team update with the launch pricing appears at the cursor" /></picture></div>

### Rewrite what you selected

Turn on selection actions in **Settings → Ask** (**Settings → General** on Windows and Linux), select text in any app, and press **⌃⇧ W**. Fix the grammar, make it shorter, translate it, summarize it, or type your own instruction, then replace the selection or copy the result. **Draft a reply with my memory** also searches your meetings, so the reply can use what was actually agreed, and lists the meetings it used. It runs on your Think model, which stays on your computer unless you chose and approved a server. On Windows and Linux the shortcut is **Ctrl+Alt+Space**, because ⌃⇧ W closes tabs and windows there; on Wayland, bind `lokalbot selection-actions` to a shortcut in your desktop's settings.

### It remembers how you work

Personal Context is an encrypted list of your facts, preferences, goals, and principles. Tell Ask "Remember I want the agenda the day before," add items in Settings, or let the overnight review pick up facts and preferences from your own words in meetings. Ask uses what it holds, so answers fit your work.

- **Only your own words.** It learns from your lines, never other speakers'. The model that reads them stays on your computer unless you approve a server.
- **You see where it came from.** Every learned item shows the line behind it. Preferences, and anything from what you typed, wait for you to keep or dismiss them. Facts and goals from meetings are saved directly.
- **Yours to turn off.** Learning is on by default, at up to three items a night. One switch in Settings stops it.
- **Private from agents.** Agents read only the items you choose to share, under a separate permission.

### Draft the follow-up

Prepare local follow-up drafts. Also keep a note for every meeting in your Obsidian or Logseq folder, and get daily briefs and weekly work logs. You review and send them yourself.

<sub>The clips show the real Mac app on fictional data, with waits cut and some typing sped up. Search, Today, Timeline and People use a seeded library; the notes, Ask answers, dictation, autocomplete and Files results come from the on-device models. <a href="Video/lokalbot-landing-demos/README.md">How they were made</a>.</sub>

<a id="windows-and-linux"></a>

### Also on Windows and Linux (alpha)

A native Windows and Linux app, written in Rust, has the same pages and reads the same library, so a library moves between computers. Encrypted items, such as Ask history, Personal Context, screenshots, and remembered voices, open only on the computer that saved them. Meetings, transcription, Ask, search, day memory, screen context, dictation, autocomplete, selection actions, spoken summaries, Files, overnight review, Personal Context, calendar, Agent Mode, and the CLI and MCP server all work. It's an alpha: the Windows build isn't code-signed yet, some features depend on your Linux desktop (Wayland support is partial), and Gmail in meeting briefs hasn't been ported. See [what works where](LinuxWindows/README.md#what-works-where) and [screenshots](LinuxWindows/docs/screenshots).

<a id="on-your-phone"></a>

### On your phone (Android)

The Android app keeps an end-to-end encrypted copy of the meetings, actions, Timeline, Day Digests, people, and projects you choose to share, so you can read and search them offline. Ask sends your question to your computer, which answers with its own AI settings; away from it, queue the question for later. Pair it with a QR code under **Settings → Phones & tablets** on a Mac, Windows, or Linux computer. The phone syncs straight from your computer over your local network or Tailscale, with no LokalBot server in between.

<div align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="Assets/readme/android-today-dark.png" /><img src="Assets/readme/android-today-light.png" width="300" alt="LokalBot on Android showing Today: open action items with their meetings and yesterday's Day Digest, from the sample library" /></picture></div>

[Get it on Google Play](https://play.google.com/store/apps/details?id=me.dotenv.lokalbot.companion) (Android 10 or later), or install the APK from the [latest release](https://github.com/stevyhacker/lokalbot/releases/latest). They're signed with different keys, so pick one: switching later means uninstalling, which removes the phone's copy and its pairing. You can try the sample library before you pair. The iPhone and iPad app isn't in the App Store yet.

## For developers & agents

Claude Code, Codex, or any MCP client can search your meetings through the bundled **`lokalbot-cli`** or its stdio **Model Context Protocol (MCP)** server. Ask what was decided, who owns an action item, or where a topic came up. Agents can read your library but can't change it.

<div align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="Assets/readme/agents-dark.gif" /><img src="Assets/readme/agents-light.gif" width="720" alt="In a terminal, Claude Code is asked what today's design review decided about caching and what is still owed; it calls LokalBot twice and lists the decisions and the open actions" /></picture></div>

Connect Claude Code with one command, or install the [Claude Code plugin](Distribution/claude-plugin/README.md):

```bash
# macOS
claude mcp add lokalbot -- /Applications/LokalBot.app/Contents/Helpers/lokalbot-cli mcp
# Windows and Linux, with lokalbot-cli on your PATH
claude mcp add lokalbot -- lokalbot-cli mcp
```

Access is off by default. On a Mac, turn on **Allow external agents to read your LokalBot data** in **Settings → External Agents** and tick what agents may read: Meetings, Screen memory, What I shared about myself, Files, or Agent notes. On Windows and Linux, each has its own switch under External agents in **Settings → Privacy & Data**: meeting library, files, agent notes, screen memory, and What I shared about myself. Then install the CLI from **Settings → External Agents → Agent CLI** on a Mac, or **Settings → Advanced → Agent CLI** on Windows and Linux.

**Ready to act on a meeting?** Open any action item in Claude Code or Codex, and the prompt is already typed in with the task and where it came from, for you to review and send.

Or use the CLI from any shell or agent:

```bash
lokalbot-cli search "database decision"
lokalbot-cli get latest --include metadata,summary
lokalbot-cli search-files "lease renewal" --kind pdf   # with Files access on
lokalbot-cli search-notes "release steps"              # notes your coding agents saved (with Agent notes access on)
lokalbot-cli mcp
```

Without a PATH installation, use `/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli` on Mac. On Windows and Linux, **Settings → Advanced → Agent CLI** installs it too; see [Coding agents](LinuxWindows/README.md#coding-agents) for where it goes and how to add it to your PATH. The commands and MCP tools are the same on every platform.

Screen-memory MCP tools require separate permission scoped to today, the last seven days, or all retained history. They return text and metadata, not decrypted screenshots. `search_files` searches the folders you chose under Files by their words and returns file paths, excerpts, and the matched passages; it needs Files access and never changes your files. `search_agent_notes` searches the notes Claude Code and Codex saved for their own later sessions, once you turn on **Read coding agent notes** (**Settings → Screen & Activity** on a Mac, **Settings → Day Memory** on Windows and Linux) and allow Agent notes for external agents, so one agent can find what another wrote down. External clients may send results to their own model providers.

The app also has an optional **Agent Mode** for working with reviewed context. File and shell actions follow its approval settings; it is separate from the read-only CLI/MCP interface.

[CLI examples](.agents/skills/lokalbot-cli/SKILL.md) · [Claude Code plugin](Distribution/claude-plugin/README.md) · [MCP architecture](Docs/development/agent-cli.md)

## How it compares

| Coming from… | What's different with LokalBot |
| --- | --- |
| [Granola](https://www.lokalbot.com/lokalbot-vs-granola) | The same bot-free capture, but transcription and summaries run on your computer by default. No account and no subscription. |
| [Apple Notes](https://www.lokalbot.com/lokalbot-vs-apple-notes) | Notes records your microphone, so with headphones on it misses the other side of a Zoom or Teams call. LokalBot records both sides and keeps every meeting searchable, with notes that cite the discussion. |
| [Otter](https://www.lokalbot.com/lokalbot-vs-otter) · [Fireflies](https://www.lokalbot.com/lokalbot-vs-fireflies) | Nothing joins your call, audio stays on your computer, and there are no minute caps. |
| [Hyprnote (anarlog)](https://www.lokalbot.com/lokalbot-vs-hyprnote) | Local AI ships built in, with no separate model runner or API keys to set up. Dictation, a day timeline, and autocomplete come in the same app. |
| [Meetily](https://www.lokalbot.com/lokalbot-vs-meetily) | Both are open source and run locally. Speaker separation, meeting detection, and MCP access are free here rather than Pro features, and dictation, a day timeline, and autocomplete come in the same app. |
| [Screenpipe](https://www.lokalbot.com/lokalbot-vs-screenpipe) | Starts with app and window activity. Screen text and screenshots are opt-in and deleted after 14 days by default. GPLv3 rather than source-available. |
| [Rewind](https://www.lokalbot.com/lokalbot-vs-rewind) | Rewind's Mac app is discontinued. LokalBot's timeline is open source and actively developed. |
| [MacWhisper](https://www.lokalbot.com/lokalbot-vs-macwhisper) · [Superwhisper](https://www.lokalbot.com/lokalbot-vs-superwhisper) | Dictation comes alongside meeting notes, recall, and autocomplete, for free. For transcribing files you already have, MacWhisper is the better tool. |
| [Wispr Flow](https://www.lokalbot.com/lokalbot-vs-wispr-flow) | Dictation and bot-free meeting notes run on your computer, with no account, word cap, or connection required. Wispr Flow transcribes both in its cloud. |

<sub>Competitor details were last verified on September 24, 2026, and October 1, 2026 for Apple Notes, Meetily, and Wispr Flow; each link has the full comparison and sources. Trademarks belong to their owners.</sub>

<a id="privacy--verify-it"></a>

## Privacy

**Your work is personal. Keeping it local should be the starting point.**

Recording and built-in AI processing happen on your computer. LokalBot has no account system, analytics service, or telemetry backend. Your library lives in local files and SQLite under your user account.

```mermaid
flowchart LR
  subgraph mac [Your computer]
    direction LR
    audio["Mic + meeting-app audio"] --> asr["On-device<br/>transcription"]
    asr --> llm["Local summaries<br/>built-in llama.cpp"]
    screen["Opt-in screen text"] --> db[("Local library<br/>full-text + vector search")]
    asr --> db
    llm --> db
    db --> use["Search · Ask · Today · Timeline"]
    db -.->|read-only, off by default| cli["lokalbot-cli · MCP"]
  end
```

- **You choose what to retain.** Activity-only tracking is the default. Visible screen text and encrypted screenshots are opt-in. Pause capture or exclude apps and domains at any time. Detection has limits; exclude anything you never want retained.
- **You control retention.** Captured screen text and screenshots expire after 14 days by default. Adjust the window or explicitly save a moment to keep it until you unsave or delete it.
- **Network access has boundaries.** Models, updates, and optional agent runtimes need downloads. Automatic update checks can be disabled. A remote model server receives context only after you approve its origin; optional Agent Mode and external CLI/MCP clients have separate permissions and data handling.
- **Your phone gets a copy only if you pair it.** Settings → Phones & tablets is off by default. When you turn it on, the Mac sends the phones and tablets you pair an end-to-end encrypted copy of the data you choose, over your local network or Tailscale, with no LokalBot server in between. Screenshots, screen text, attendee emails, and voice profiles are never shared. A paired phone can also record a meeting and send it the same way; your Mac processes it, and the phone then deletes its copy.

To check the local processing path, download the models, select the built-in backend, disable automatic update checks, and observe network traffic while recording, transcribing, and summarizing. Approved agent commands and external clients are separate paths.

[Read the full privacy policy](PRIVACY.md) · [Report a security issue privately](SECURITY.md)

<a id="download"></a>

## Get started

LokalBot runs on Apple Silicon Macs with macOS 15 or later. Windows and Linux are in alpha. You'll also need space for your selected models: **Settings → Models** shows download sizes and readiness, and storage and memory needs depend on the models you choose.

| | macOS | Windows (alpha) | Linux (alpha) |
| --- | --- | --- | --- |
| Runs on | Apple Silicon (M1 or later), macOS 15+ | Windows 10 or 11, x64 | x86_64 with glibc 2.39 or later (Ubuntu 24.04, Debian 13, Fedora 40 or newer), PulseAudio or PipeWire, and a Vulkan or OpenGL driver |
| Install | [`LokalBot-<version>-macos-arm64.dmg`](https://github.com/stevyhacker/lokalbot/releases/latest): drag LokalBot to Applications. Or `brew install --cask stevyhacker/tap/lokalbot`. | [`LokalBot-<version>-windows-x86_64-setup.exe`](https://github.com/stevyhacker/lokalbot/releases/latest): run it to install LokalBot for your user, with a Start menu shortcut and no administrator rights. It isn't code-signed yet, so SmartScreen asks first: **More info → Run anyway**. The same release has a portable zip. | [`LokalBot-<version>-linux-x86_64.tar.gz`](https://github.com/stevyhacker/lokalbot/releases/latest): extract it and run `./install.sh`, which adds LokalBot to your applications menu. Or install the `.deb` (Debian, Ubuntu), `.rpm` (Fedora, openSUSE) or Arch package from the same release. The `.deb`, and the `.rpm` on Fedora, add the LokalBot repository, so `sudo apt upgrade` or `sudo dnf upgrade` brings later versions; with the Arch package, LokalBot tells you about updates instead of installing them. |
| Your library | `~/Library/Application Support/me.dotenv.LokalBot` | `%LOCALAPPDATA%\LokalBot` | `~/.local/share/LokalBot` |

A library recorded on one platform opens on the others. Not every Mac feature is on Windows and Linux yet; see [what works where](LinuxWindows/README.md#what-works-where).

**On your phone:** get the Android companion app on [Google Play](https://play.google.com/store/apps/details?id=me.dotenv.lokalbot.companion) (Android 10 or later) and pair it under **Settings → Phones & tablets**. See [On your phone](#on-your-phone).

1. **Install the app** for your platform and open it.
2. **Choose what to capture.** Review recording settings: automatic detection, ask-first, or manual recording. Day tracking starts with activity only; saving screen text or screenshots is a separate opt-in. Grant only the permissions for the features you enable.
3. **Let the models download.** Built-in transcription, search, summaries, and writing can then work offline. No model server to set up and no API key to bring.

**Try this first:** make a short test recording, let it transcribe, then search for a phrase you said and open the matching passage. Add screen memory or writing tools when you're ready.

Let meeting participants know before recording and get their consent.

[Release notes](https://github.com/stevyhacker/lokalbot/releases) · [Setup help](SUPPORT.md) · [Homebrew options](Distribution/homebrew/README.md) · [Windows and Linux guide](LinuxWindows/README.md)

## FAQ

<details>
<summary><strong>Does a bot join my meetings?</strong></summary>

No. LokalBot records your microphone and the meeting app's audio on your computer. On Windows and Linux it records the meeting app alone where it can, and otherwise everything the computer plays. Audio sources are separate from individual speaker identification. When system-audio capture is unavailable, the app warns that recording is microphone-only. Always record with participants' consent.

</details>

<details>
<summary><strong>Does it record everything on my screen?</strong></summary>

No. New installs use activity-only tracking, which you can turn off. Saving visible text or screenshots requires a separate choice and the relevant macOS permissions (on Linux, your desktop's accessibility and screenshot support). Excluded apps and domains and secure fields are skipped; private browser windows are captured unless you exclude the browser or site. Detected credentials are redacted and associated pixels are dropped, but detection is not perfect. See [PRIVACY.md](PRIVACY.md).

</details>

<details>
<summary><strong>Can I take my notes elsewhere?</strong></summary>

Yes. Turn on **Meeting note export** to keep a Markdown note for every meeting in a folder you choose, such as an Obsidian vault or a Logseq graph: the summary, action items, the people and projects involved, and the transcript. You can also export a single meeting, write a daily memory note, or let local routines save drafts. These are ordinary, unencrypted files; any service you sync them with has its own privacy settings. See [Meeting transcripts in Obsidian](https://www.lokalbot.com/meeting-transcripts-obsidian-markdown).

</details>

<details>
<summary><strong>Does it run on Windows or Linux?</strong></summary>

Yes, as an alpha. The Windows and Linux app is a native Rust app with the same pages, the same models for summaries and search, and the same library format, so a library moves between computers. Encrypted items, such as Ask history, Personal Context, screenshots, and remembered voices, open only on the computer that saved them. Gmail in meeting briefs is Mac only for now, and on Wayland some features depend on your desktop. See [what works where](LinuxWindows/README.md#what-works-where).

</details>

<details>
<summary><strong>Is there a phone app?</strong></summary>

Yes, for Android 10 or later, on [Google Play](https://play.google.com/store/apps/details?id=me.dotenv.lokalbot.companion). It's a companion to LokalBot on your computer: it reads the meetings, actions, and Day Digests your computer shares, searches them offline, and sends your questions to your computer. Sharing is off until you turn on **Settings → Phones & tablets**, and the copy travels end-to-end encrypted over your local network or Tailscale, never through a LokalBot server. The iPhone and iPad app isn't in the App Store yet.

</details>

## Local AI, your choice

Start with the built-in models, then change them in **Settings → Models**. LokalBot supports its bundled llama.cpp runtime, Ollama, OpenAI-compatible servers, and Apple Intelligence on supported Macs running macOS 26 or later. Think can also run on your own ChatGPT plan (Sign in with ChatGPT) or Claude plan (through your signed-in Claude Code), without an API key, and Agent Mode can run on the ChatGPT plan. Remote servers and plans require approval before receiving context.

Different jobs use different models. These are the Mac defaults on a fresh install, about 9.6 GB of model files if you use every role. They are not a RAM requirement:

| Role | Default model | Format | Approx. model files |
| --- | --- | --- | ---: |
| Transcription | Qwen3-ASR 1.7B | MLX 8-bit | 2.47 GB |
| Summaries and chat | Qwen3.5 4B | `Q4_K_M` | 2.74 GB |
| Autocomplete | Gemma 4 E2B Base | `Q6_K` | 3.85 GB |
| Semantic search | EmbeddingGemma 2 | `Q8_0` | 0.31 GB |
| Speaker diarization | Nemotron 3 (preview) via FluidAudio | Core ML | ~0.20 GB |

The table leaves out helper models, which download when a feature first needs them: with Qwen3-ASR, speaker separation adds a word-timing model of about 1 GB, and turning on Files adds a 555 MB image and audio projector.

Qwen3-ASR covers 52 languages and dialects. Transcription alternatives include Parakeet, Granite Speech, Whisper large-v3 turbo, SenseVoice for Chinese, Japanese, and Korean, and GigaAM for Russian; Pyannote Community-1 remains available for diarization. The Lightweight preset swaps in smaller models, including LFM2.5 1.2B Instruct (0.73 GB) for autocomplete. Model choices can vary by release; Settings shows the active selections and available presets. Speed and memory use depend on your computer, model, context length, and other workloads.

On Windows and Linux, transcription uses Qwen3-ASR 0.6B through sherpa-onnx (Parakeet v3 and v2, SenseVoice, GigaAM Russian, and Whisper turbo are optional), speakers are separated with pyannote segmentation and TitaNet, and autocomplete uses Gemma 4 E2B by default, as on Mac. Summaries (Qwen3.5 4B) and search (EmbeddingGemma 2) use the same models as on Mac. The default download is about 4 GB, and llama.cpp runs on a Vulkan GPU or the CPU.

[Project benchmarks](Benchmarks/README.md) · [Model catalog](LokalBot/Engines/ModelCatalog.swift) · [Search implementation](LokalBot/Services/Search/EmbeddingIndex.swift) · [Model and runtime details](Docs/development/llm-runtime.md)

## Build from source

For the Mac app, use an Apple Silicon Mac with full Xcode installed; the [build workflow](.github/workflows/build.yml) pins the CI toolchain. With Homebrew available:

```bash
brew install xcodegen cmake
# Rust (https://rustup.rs) builds the phone and tablet sync library; the repo
# pins the toolchain, which rustup installs on first use.
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain none

git clone https://github.com/stevyhacker/lokalbot.git
cd lokalbot

# XcodeGen needs these paths before the first build fetches the runtimes.
mkdir -p Vendor/llama-cpp Vendor/sherpa-onnx
# The phone and tablet sync library (Rust), as a local Swift package.
Scripts/build/build-sync-xcframework.sh
xcodegen generate
open LokalBot.xcodeproj
```

Select **LokalBot Dev**, set your signing team, and run. The Dev app has its own identity, macOS permission grants, library, model storage, and Keychain namespace, so it can live alongside the installed release without applying development retention settings to release data. The first build prepares pinned native runtimes; model downloads happen separately.

For the Windows and Linux app, see [Build from source](LinuxWindows/README.md#build-from-source) in its README (Rust).

[Build and test commands](Docs/development/build-workflows.md) · [Testing guide](Docs/development/testing.md) · [Screenshot guide](Docs/guides/screenshot-kit.md)

<details>
<summary><strong>Find your way around the code</strong></summary>

```text
LokalBot/
├── Views/       # Native SwiftUI screens, settings, and onboarding
├── Services/    # Recording, search, storage, and workday memory
├── Engines/     # Transcription, model catalog, and local inference
├── Cotyping/    # System-wide autocomplete
├── Dictation/   # Voice typing
└── Agent/       # Optional Agent Mode and approval flow
CLI/             # Command-line interface and MCP entry points
LinuxWindows/    # Windows and Linux app (Rust + GPUI)
LokalBotTests/   # Unit tests
Scripts/         # Build, verification, capture, and release tooling
project.yml      # XcodeGen source of truth
```

</details>

<a id="contributing--security"></a>

## Contributing

Bug reports, documentation improvements, and code contributions are welcome. [Report an issue](https://github.com/stevyhacker/lokalbot/issues/new/choose) with steps to reproduce, expected and actual behavior, the app version, your OS and its version (on Linux, also the distribution, desktop, and X11 or Wayland), your chip or CPU and GPU, RAM, and selected models. Keep private recordings and transcripts out of reports.

For larger changes, [open an issue](https://github.com/stevyhacker/lokalbot/issues) to discuss the approach first. Follow the [working agreements](AGENTS.md) and [development guide](DEVELOPMENT.md), keep pull requests focused, and record your checks in the [PR template](.github/PULL_REQUEST_TEMPLATE.md). Include screenshots for UI changes; run UI tests on hosted CI or a remote runner.

## License & acknowledgements

LokalBot is free software under [GPLv3](LICENSE). Code in the Autocomplete engine that was ported from [Cotabby](https://github.com/FuJacob/cotabby) stays under [AGPLv3](LICENSES/AGPL-3.0.txt). Other third-party components and models retain their own licenses; see [third-party notices](THIRD_PARTY_NOTICES.md).

Built with [llama.cpp](https://github.com/ggml-org/llama.cpp), [MLX Swift](https://github.com/ml-explore/mlx-swift), [speech-swift](https://github.com/soniqo/speech-swift), [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx), [WhisperKit](https://github.com/argmaxinc/WhisperKit), [FluidAudio](https://github.com/FluidInference/FluidAudio), [Sparkle](https://github.com/sparkle-project/Sparkle), [XcodeGen](https://github.com/yonaskolb/XcodeGen), [GPUI](https://github.com/zed-industries/zed/tree/main/crates/gpui), [GPUI Kit](https://github.com/longbridge/gpui-kit), and [ONNX Runtime](https://github.com/microsoft/onnxruntime), with models including [Qwen3-ASR](https://huggingface.co/Qwen), [IBM Granite Speech](https://huggingface.co/ibm-granite), [Parakeet](https://huggingface.co/nvidia), and [LFM2.5](https://huggingface.co/LiquidAI). The Autocomplete engine started from [Cotabby](https://cotabby.app)'s open-source code.
