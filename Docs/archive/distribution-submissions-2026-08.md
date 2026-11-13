# Distribution Submissions — August 2026

Copy-paste-ready submission kits for four surfaces. Every field below is either an exact value to paste or a file path verified to exist in this repo on 2026-08-21. Each section is executable end-to-end in under 20 minutes.

> Sections 1 to 3 are the August kit, written for v0.6.2. Their copy still says Granite Speech 4.1 is the default transcription model, names v0.6.2, and describes a Mac-only app. Correct those from the shared facts below and the [README](../../README.md) before pasting any of it. Sections 4b and 4c were written in November and are current.

Shared facts used across all sections (do not embellish): GPLv3 · Apple Silicon M1+ · macOS 15.0+ (Windows and Linux in alpha) · no account, no telemetry, no LokalBot cloud · Developer ID signed, notarized, stapled · Sparkle updates · bot-free two-track capture via Core Audio process tap ("Me" = mic, "Them" = meeting-app tap) · local transcription (Qwen3-ASR 1.7B default; Parakeet ~190x realtime; Whisper 99 languages; Granite Speech) · local summaries/chat with citations · Dictation (hold Option-Space) · Cotyping ghost-text autocomplete in any app · day Timeline · `lokalbot-cli` read-only CLI + stdio MCP server · LokalBot.mcpb one-click MCP bundle. External-client boundary: LokalBot does not upload library content, but Claude Code, Cursor, and other MCP clients may transmit tool inputs and results under their own privacy terms; connect only trusted clients. Latest release: see https://github.com/stevyhacker/lokalbot/releases/latest (the kit was written for v0.6.2, 2026-08-20).

Canonical links:

- Repo: https://github.com/stevyhacker/lokalbot
- Site: https://www.lokalbot.com
- DMG: `LokalBot-<version>-macos-arm64.dmg` at https://github.com/stevyhacker/lokalbot/releases/latest

---

## 1. Uneed.best

Form: https://www.uneed.best/submit-a-tool — note their flow scrapes the link you give it first, then asks you to sign up to save and complete the listing. Paste these values over/into whatever the scrape pre-fills.

| Field | Value to paste |
| --- | --- |
| Name | `LokalBot` |
| Tagline (<=60 chars) | `A local LLM that remembers your workday. Private, on-device.` |
| Link | `https://github.com/stevyhacker/lokalbot` |
| Pricing | `Free / Open source` |
| Topics / categories | `Artificial Intelligence`, `Productivity`, `Developer Tools` |

**Description (~2 paragraphs, maker voice):**

```text
LokalBot is a local-first AI workspace for macOS that records, transcribes,
and summarizes your meetings entirely on your machine. It captures both
sides of every call with a Core Audio process tap — your mic is "Me", the
meeting app's audio is "Them" — so there is no bot joining your calls and
nothing leaving your device. Transcription runs locally too: IBM Granite
Speech by default, Parakeet when you want ~190x realtime, Whisper when you
need 99 languages, Qwen3-ASR as another engine. Summaries and chat answers
cite the transcript, so you can trust (and check) every claim.

Beyond meetings, LokalBot gives you Dictation (hold Option-Space anywhere),
Cotyping ghost-text autocomplete in any app, and a day Timeline of what you
worked on. Developers get lokalbot-cli: a read-only CLI plus a stdio MCP
server, shipped as a one-click .mcpb bundle, so your agent can answer
"what did we decide last Tuesday?" through an opt-in local bridge. LokalBot
does not upload library content; the connected agent may process tool data
under its own privacy terms. GPLv3, Apple Silicon M1+, macOS 15.0+, signed,
notarized, Sparkle updates.
```

**Gallery assets (all verified in-repo):**

- Hero GIF: `Assets/screenshots/hero.gif`
- Recap demo GIF: `Assets/screenshots/recap.gif`
- Search GIF: `Assets/screenshots/search.gif`
- Screens: `Assets/screenshots/timeline.png`, `Assets/screenshots/meetings-summary.png`, `Assets/screenshots/meetings-transcript.png`, `Assets/screenshots/chat.png`, `Assets/screenshots/dictation.png`, `Assets/screenshots/cotyping.png`
- Video: `Website/public/assets/demos/meetings-wide-light.mp4` (poster: `Website/public/assets/demos/meetings-wide-light.webp`)

Upload order suggestion: hero.gif first (thumbnail), then the meetings clip, then the five strongest screens.

**Maker comment draft (post as the first comment right after launch goes live):**

```text
Hey! I built LokalBot because I wanted meeting notes that never leave my
Mac. Two things I'm proudest of: the two-track capture — one process tap,
both sides of the call, zero bots in your calendar invites — and citations
on every summary, so the AI has to show its work against the real
transcript. Everything runs on-device (Granite Speech / Parakeet /
Whisper), and if you're a terminal person, lokalbot-cli + its MCP server
let a coding agent query your on-device meeting library through an opt-in
read-only bridge. The agent client's privacy terms still apply. Happy to
answer anything about the architecture or the models.
```

**Launch-day note:** Uneed runs launches through a daily queue; a paid fast-track exists to skip it. Decide before launch day whether to take the free slot (pick a date you can be online all day replying) or pay for fast-track positioning. Either way: post the maker comment immediately when the listing flips live, and answer every question within the day — Uneed's audience rewards engaged makers.

---

## 2. Console.dev

Console.dev is editorial: there is no form — they ask you to **email hello@console.dev** with the details (verified on their selection-criteria page). The newsletter ships **every Thursday** and features 2–3 tools per issue, so send Monday–Tuesday to land in that week's curation window. Their criteria favor tools where the primary user is a developer, with a CLI, self-service install, good docs, active maintenance, and no privacy downsides — all of which play to LokalBot.

**Pitch email — To:** `hello@console.dev`

**Subject:** `LokalBot — local-first meeting memory with a read-only CLI and MCP server (GPLv3)`

```text
Hi Console team,

LokalBot is a local-first AI workspace for macOS (Apple Silicon M1+,
macOS 15.0+, GPLv3) that keeps a private memory of your workday: it
records and transcribes meetings entirely on-device using a Core Audio
process tap — mic for "Me", the meeting app's tap for "Them" — so no bot
ever joins the call and no audio leaves the machine. Transcription engines
are swappable local models: IBM Granite Speech 4.1 by default, Parakeet at
roughly 190x realtime, Whisper for 99 languages, Qwen3-ASR. BYO GGUF via
Ollama works too. Summaries and chat cite the transcript line they came
from.

Why I think it fits Console: the developer story isn't the GUI — it's
lokalbot-cli, a read-only CLI (list / search / get) plus a stdio MCP
server, also shipped as a one-click LokalBot.mcpb bundle, so an agent in
your editor can answer questions about yesterday's meetings through an
opt-in local bridge. LokalBot does not upload the library; the editor or
agent may process tool data under its own privacy terms. You can build from
source; releases are Developer ID signed, notarized, and stapled with
Sparkle updates.

Links:
- Repo: https://github.com/stevyhacker/lokalbot
- Site: https://www.lokalbot.com
- CLI skill docs: https://github.com/stevyhacker/lokalbot/blob/master/.agents/skills/lokalbot-cli/SKILL.md

Latest release is v0.6.2 (pre-1.0, so eligible for your betas section as
well). Happy to answer anything.

Best,
<name>
```

Before sending: replace `<name>`, skim the current week's issue (https://console.dev) so the reply-to thread references something real, and send Mon/Tue for the Thursday cadence.

---

## 3. DevHunt

Site: https://devhunt.org — sign in with GitHub, then "Submit your tool"; launches are scheduled into daily slots and voted up by comments.

| Field | Value to paste |
| --- | --- |
| Name | `LokalBot` |
| Tagline | `Local meeting notes, private workday memory` |
| One-liner | `A local LLM workhorse that keeps a private memory of your workday.` |
| Link | `https://github.com/stevyhacker/lokalbot` |
| Topics | `AI`, `Productivity`, `Developer Tools`, `Privacy` |

**Description:**

```text
LokalBot records, transcribes, and summarizes your meetings entirely
on-device on macOS (Apple Silicon M1+, macOS 15.0+, GPLv3). Capture is
bot-free: a Core Audio process tap grabs both tracks — your mic is "Me",
the meeting app is "Them". Transcription is local (IBM Granite Speech 4.1
default, Parakeet ~190x realtime, Whisper 99 languages, Qwen3-ASR), and
summaries/chat always cite the transcript.

For developers: lokalbot-cli is a read-only CLI and stdio MCP server
(one-click LokalBot.mcpb bundle), so your agent can query your meeting
history through an opt-in local bridge. LokalBot does not upload library
content; the connected client's privacy terms apply. Also includes Dictation
(hold Option-Space), Cotyping ghost-text autocomplete in any app, and a day
Timeline. No account, no telemetry, no LokalBot cloud. Signed, notarized,
Sparkle updates.
```

**Gallery asset paths (verified in-repo):**

- `Assets/screenshots/hero.gif`
- `Assets/screenshots/timeline.png`
- `Assets/screenshots/meetings-transcript.png`
- `Assets/screenshots/dictation.png`
- `Assets/screenshots/cotyping.png`
- Video (if a video field is offered): `Website/public/assets/demos/meetings-wide-light.mp4`

**Launch-day comment draft (post as maker first thing on launch day):**

```text
Maker here. The idea: your meetings are already on your machine — the
notes should be too. LokalBot taps both audio tracks locally (no bot in
your calls), transcribes with local models, and cites every summary
against the transcript. Terminal folks: lokalbot-cli speaks JSON by
default, has --table, and doubles as a stdio MCP server, so Claude Code or
another MCP client can ask "what did we decide on Tuesday?" through an
opt-in local bridge. LokalBot itself does not upload the library; the client
may process tool data under its own privacy terms. GPLv3, M1+, macOS 15+.
Ask me anything.
```

---

## 4. Skill registries

Two real registries exist today; both were verified on 2026-08-21. The in-repo skill is `.agents/skills/lokalbot-cli/SKILL.md`. The Claude Code plugin is the self-contained folder `Distribution/claude-plugin/` (manifest in its `.claude-plugin/plugin.json`), listed by `.claude-plugin/marketplace.json` at the repository root.

### 4a. skills.sh (Vercel)

Verified: **skills.sh has no submission form and takes no PRs.** It is a leaderboard auto-indexing public GitHub repos whose skills get installed through the open-source `skills` CLI (`npx skills add <owner/repo>`); rankings come from anonymous install telemetry. Your skill appears once people install it from your repo.

Submission step (≈5 minutes):

1. Confirm `.agents/skills/lokalbot-cli/SKILL.md` has valid frontmatter (`name:` + `description:`) — it does (verified: `name: lokalbot-cli`).
2. Verify discoverability once by running:
   ```
   npx skills add stevyhacker/lokalbot
   ```
   and confirm `lokalbot-cli` is offered/installed.
3. Add the official install-count badge to the README (this is the Registries agent's one allowed README edit — coordinate):
   ```markdown
   [![skills.sh](https://skills.sh/b/stevyhacker/lokalbot)](https://skills.sh/stevyhacker/lokalbot)
   ```
4. Seed discovery: share the one-line install command wherever LokalBot is announced — installs are what rank the skill.

Ready promo text (paste anywhere skills are discussed):

```text
Give your coding agent a private memory of your workday:

npx skills add stevyhacker/lokalbot

The lokalbot-cli skill teaches Claude Code, Cursor, Codex, and friends to
query your on-device LokalBot meeting library — list, search, get with
citations — over a read-only CLI and stdio MCP server. LokalBot does not
upload the library; connect only clients you trust because their privacy
terms govern tool data. Works with any agent that reads SKILL.md files.
```

### 4b. Anthropic community plugin directory (Claude Code / Cowork)

Verified 2026-08-21, updated 2026-11-09: the directory lives at `anthropics/claude-plugins-community`, a read-only mirror synced from Anthropic's review pipeline after a safety scan and a policy review. **PRs opened directly against the repo are closed automatically.** As of 2026-11-09, LokalBot is in neither `claude-plugins-community` (2,283 plugins) nor `claude-plugins-official` (317), and Anthropic's docs send submissions to https://claude.ai/directory/manage, which needs a paid claude.ai plan. The portal downloads the whole repository to validate it and refuses anything over 50 MiB compressed (256 MiB uncompressed), which rules out the LokalBot repository. The plugin is therefore submitted from [stevyhacker/lokalbot-claude-plugin](https://github.com/stevyhacker/lokalbot-claude-plugin), a copy of `Distribution/claude-plugin` that the `Claude plugin sync` workflow keeps current from LokalBot's master.

Submission steps (≈15 minutes, owner-only because of the login):

1. From the repository root, run `claude plugin validate Distribution/claude-plugin --strict` and `claude plugin validate . --strict`. Both passed on 2026-11-09 with no warnings.
2. Make sure the plugin folder is on public `master`.
   - On 2026-11-09 the directory's automatic policy check refused 0.2.1: "Local MCP servers accepted only from Verified organizations." 0.3.0 starts no MCP server, works through `lokalbot-cli` alone, and is listed for Claude Code only, because Cowork can't run `lokalbot-cli`. Becoming a Verified organization (Anthropic confirms a real company) would allow bundling the server again.
3. Open https://claude.ai/directory/manage → Submit new → Plugin bundle, and give the repository as `stevyhacker/lokalbot-claude-plugin`, with no path and the default branch.
4. The listing icon is `.claude-plugin/icon.png` in the plugin. The directory takes the icon only from the first save or submission.
5. After approval, users install with:
   ```
   claude plugin marketplace add anthropics/claude-plugins-community
   claude plugin install lokalbot@claude-community
   ```

Ready submission text (adapt to whatever free-text fields the form offers):

```text
Plugin: lokalbot (source: github.com/stevyhacker/lokalbot-claude-plugin, a copy of
Distribution/claude-plugin in github.com/stevyhacker/lokalbot)

LokalBot is a personal context engine: a private work-memory app that
records, transcribes, and summarizes meetings and remembers your workday on
your own computer. This plugin lets Claude Code read that library through
lokalbot-cli, which runs on the user's computer: meetings and their action
items, the people in them, the folders the user chose under Files, and what
the user shared about themselves. Each kind of data is off by default and has
its own permission in LokalBot. The plugin starts no MCP server.

Commands: /lokalbot:brief catches the user up on their work,
/lokalbot:recall finds what they said, saw, agreed, or saved with citations,
and /lokalbot:setup installs LokalBot and sets it up with the user. The
lokalbot-cli skill teaches Claude when to check LokalBot and how to cite it.

Settings: with a separate permission, Claude can check and change LokalBot's
settings. Anything that widens what LokalBot captures, reads, records, or
sends, and every API key, waits for the user's approval in the app. The CLI
and MCP tools never change meetings or the user's files.

Privacy: LokalBot does not upload the library. Claude Code may process tool
inputs and results under Anthropic's terms, so the skills retrieve only what
a question needs.

Facts for reviewers: GPLv3; Mac app on Apple Silicon (M1 or later) with
macOS 15+, Developer ID signed, notarized, and stapled; Windows 10/11 x64
and Linux x86_64 apps in alpha; no account, no telemetry, no LokalBot
cloud; latest release v0.12.2 (2026-11-05).
```

### 4c. OpenAI plugin directory (ChatGPT and Codex)

Verified 2026-11-09 from OpenAI's [submission guide](https://developers.openai.com/plugins/deploy/submission): ChatGPT and Codex share one plugin directory, and plugins are submitted as a ZIP at https://platform.openai.com/plugins under a verified developer identity (individual or business verification in organization settings). Local (stdio) MCP servers are accepted only from approved partners, after an OpenAI representative allowlists the organization, so LokalBot submits a skills-only package marked Desktop only (`requires_local_executor`). Skills-only plugins need no reviewer account, test cases, or demo video, but "may be subject to additional eligibility requirements". The relay-based ChatGPT plugin from the closed PR 224 (`mcp.lokalbot.com`) is not part of this.

Submission steps (owner-only because of the login and identity):

1. `bash Scripts/release/build-openai-plugin.sh` builds `dist/lokalbot-openai-plugin-<version>.zip` from `Distribution/openai-plugin/` after its test passes.
2. Sign in at https://platform.openai.com/plugins and pick the organization and project. Complete identity verification first if the portal asks for it.
3. **Upload new or existing plugin** → choose the verified **Developer identity** → **Upload plugin** with the ZIP.
4. Resolve the **Metadata & Skills** findings (upload a corrected ZIP for any change), then **Submit for review** and accept the attestations. After approval, **Publish plugin**.

Listing text, prompts, capabilities, release notes and icon all come from `Distribution/openai-plugin/plugin.json`, so the portal needs nothing typed in beyond the identity and attestations.

### Non-registries checked and ruled out

- **skills.sh**: no manual submissions possible — covered above via install-driven indexing.
- **anthropics/claude-plugins-community**: PRs auto-closed; form-only — covered above.
- No other Anthropic-operated skill/plugin directory accepts third-party listings as of 2026-08-21.

---

## Cross-references

- Homebrew cask + install docs: `Distribution/homebrew/lokalbot.rb`, `Distribution/homebrew/README.md`
- Raycast extension: `Distribution/raycast/`
- Hugging Face presence kit: `Distribution/huggingface/`
- Claude Code plugin packaging: `Distribution/claude-plugin/`, `.claude-plugin/marketplace.json`
