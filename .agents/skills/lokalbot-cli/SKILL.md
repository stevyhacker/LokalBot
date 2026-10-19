---
name: lokalbot-cli
description: The user's local memory of their meetings, screen, coding-agent work, and what they shared about themselves. Run `lokalbot-cli brief` at the start of a session on the user's own work, and check LokalBot before asking the user about past work, decisions, commitments, or where something stands. Also use it to look up how LokalBot is configured.
---

# LokalBot CLI Skill

LokalBot is a private work-memory app for macOS. Its read-only CLI retrieves recorded meetings; separately authorized MCP tools retrieve screen-memory text and metadata. Use this skill for evidence from the user's recorded work, not for scheduling meetings or answering general questions about a topic.

If `lokalbot-cli` isn't on PATH, use the embedded copy directly:
`/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli`.

## Start here

```bash
lokalbot-cli brief
```

Run this once at the start of a session (MCP: `get_briefing`). It says which LokalBot sources are on and how the user would turn on the others, then gives what each permission covers: what the user shared about themselves, their open action items, current projects and goals, recent Claude Code and Codex work by project, and a timeline with recent days in detail and older weeks and months in a line each. It is short on purpose. Use it to orient, then search for detail.

Before asking the user about past work, a decision, a commitment, or where something stands, search LokalBot first. Ask only when LokalBot has nothing, and say what you checked. Items the briefing doesn't list are unknown, not false. Cite meetings from `get`, `search`, or `actions` results, not from the briefing's summary lines.

## Choose the source

- Use `list` when you need candidate meeting ids, titles, and dates.
- Use `get` when the meeting is known; `latest` works without listing first. Request `metadata,summary` for a cited summary; include `transcript` when the question needs exact wording.
- Use `search` directly when the user remembers a phrase or wants cross-meeting mentions.
- Use `actions` for commitments: what the user owes, overdue work, or one meeting's next steps.
- Use `people` for everything about one person: what the user owes them, what they owe the user, decisions made together, and shared meetings.
- Use `path` only when the task needs an on-disk folder or audio file.
- For viewed screen text or app activity, use the screen-memory MCP tools within the user's separate permission and history scope.
- Use `personal-context` (MCP: `get_personal_context`) before advising on a personal decision or tailoring work to the user: it returns the facts, preferences, goals, and principles the user chose to share, most relevant to your task first.

## Discovery

```bash
lokalbot-cli list --limit 10
lokalbot-cli list --limit 10 --table
lokalbot-cli list --since 2026-06-01 --query "design"
```

The `id` field in each list entry is an 8-character prefix that the other commands accept.

## Reading a single meeting

```bash
lokalbot-cli get latest --include metadata,summary
lokalbot-cli get 4f7c2a91 --include metadata,summary --format json
lokalbot-cli get 4f7c2a91 --include metadata,transcript
```

`--include` accepts a comma-separated list of `metadata`, `summary`, `transcript`. Default is all three.

## Cross-meeting search

```bash
lokalbot-cli search "auth refactor"
lokalbot-cli search "auth refactor" --table --limit 20
```

A meeting matches when it contains every word, in any order, ignoring case and accents; when none does, the closest partial matches follow. Words of up to three letters or digits (`API`, `Q3`) match only whole words. Quote an exact phrase inside the query (`'"auth refactor"'`) to match only that phrase. Transcript hits include a `timestamp` (HH:MM:SS) so the user can jump to that moment in the in-app player.

## Answers and reply drafts

```bash
lokalbot-cli ask "What did we decide about the caching layer?"
lokalbot-cli reply "Did you pick a caching layer yet?" --instruction "keep it short"
pbpaste | lokalbot-cli reply
```

`ask` is the command-line form of `ask_library` (below): LokalBot's local model answers from the matching meetings. `reply` drafts the user's reply to a message they received from what the matching meetings say, without inventing facts; a message no meeting matches gets no draft. Both need the LokalBot app running, and the first call after a cold start can take up to a minute. JSON by default: `{"status", "text", "sources"}`, where `status` is `answered`, `not_found`, or `error` (with a `code` such as `access_disabled`); errors also exit with status 1. Show a draft to the user before sending it anywhere.

## Action items

```bash
lokalbot-cli actions
lokalbot-cli actions --owner me --table
lokalbot-cli actions --owner ana --status all --days 90
lokalbot-cli actions --meeting 4f7c2a91
```

Actions use the user's saved corrections and status. `due_date` (YYYY-MM-DD) appears only when the spoken due phrase resolves unambiguously; otherwise use `due` as said. Overdue and soon-due work comes first.

## People

```bash
lokalbot-cli people --table
lokalbot-cli people --query ana
lokalbot-cli people "Ana Petrović"
```

People are joined from calendar attendee names, speaker names applied in LokalBot, and action owners. Names chosen, people merged, and entries hidden on the app's People page apply here too, and `meeting_count` counts a call recorded in several parts once. Only names are returned; never ask for or infer email addresses.

## Personal context

```bash
lokalbot-cli personal-context --task "Evaluate a job offer in Berlin"
lokalbot-cli personal-context --task "Plan next quarter" --kind goal --kind principle --limit 5
```

Items are the user's own statements (`authority: "stated"`), shared by them for agents. Use them only when they bear on the task, and say which ones shaped your answer. Items not returned are unknown, not false, so don't infer the user's values from their absence. They are not evidence about meetings or other people. A `[personal_context_disabled]` error means the user hasn't turned on "Allow external agents to read what I shared about myself" in Settings → Privacy. Explain that, and don't work around it.

## Path lookup

```bash
lokalbot-cli path
lokalbot-cli path latest
cd "$(lokalbot-cli path latest)"
```

## Settings and status

Use these when the user asks how LokalBot is set up, why something is or isn't happening (recording, capture, models), or wants a setting changed.

```bash
lokalbot-cli config search "dark mode"           # find a setting's key by plain words
lokalbot-cli config describe autoRecordMode      # type, allowed values, tier
lokalbot-cli config get autoRecordMode
lokalbot-cli config list --changed --table
lokalbot-cli config set noteTemplate=lecture summaryLanguage=en
lokalbot-cli config set trackingEnabled=false --dry-run
lokalbot-cli config reset dayDigestHour
lokalbot-cli config export --changed > settings.json
lokalbot-cli config import settings.json --dry-run
lokalbot-cli config set calendarDetectionEnabled=true --wait 120   # waits for the user's approval
lokalbot-cli config request <id> --wait 120      # answer to an earlier needs_approval
lokalbot-cli secret list                         # which API keys are saved (never their values)
printf %s "$KEY" | lokalbot-cli secret set openai-compatible --wait 120
lokalbot-cli status                              # version, recording, models, permissions, agent access
lokalbot-cli open settings dictationShortcut     # show the user a setting in LokalBot
lokalbot-cli open settings permissions           # or a section
```

`search`, `describe`, and `config schema` work any time. Everything else needs the separate "Allow external agents to change LokalBot settings" toggle in LokalBot → Settings → Privacy. If a command returns `[settings_access_disabled]`, explain that setting and let the user choose. These commands start LokalBot in the background when it isn't running; pass `--no-launch` when the user doesn't want it started.

Changing settings:

- Change only what the user asked for. Run `describe` first so you use the right tokens, and `--dry-run` when you are unsure. A `set` applies all of its pairs or none of them.
- Preferences (tier `preference`), and changes that narrow what LokalBot captures or sends (turning capture off, adding an exclusion), apply right away. The user can undo them under the toggle.
- Turning on capture, a data source, autocomplete or dictation, approving a server, removing an exclusion, or changing retention (tier `consent`) sends the whole request to the user in LokalBot and returns `[needs_approval]` (exit 3) with the request in `details`: its `id`, every change, and, for a shorter retention policy, what the cleanup deletes. Nothing is applied yet. Ask the user before making such a request, tell them a card is waiting in LokalBot, and pass `--wait <seconds>` (up to 300) or run `config request <id> --wait <seconds>` for the answer: exit 0 approved, 4 declined, 5 expired. Don't resend a declined request unless the user asks; an identical request still waiting is reused rather than asked twice.
- API keys: `secret set <name>` reads the key from standard input and always waits for approval the same way. Never put a key on the command line, never echo it back, and never ask to read one; `secret list` only says whether each is saved. `secret clear <name>` removes one right away.
- `[read_only]` settings can't be changed from the terminal.
- Never write LokalBot's preferences with `defaults write`, and never create or edit files in its `control/` folder: a partial preferences write silently resets other settings (it can turn automatic recording on), and the running app overwrites it anyway.

## Setting up LokalBot

When the user wants LokalBot installed or set up, follow [AGENT_SETUP.md](https://github.com/stevyhacker/lokalbot/blob/master/AGENT_SETUP.md):

```bash
lokalbot-cli setup start --wait 300        # the user clicks Allow in LokalBot; the only way to get access
lokalbot-cli setup plan > plan.json        # talk it through, then edit to the user's answers
lokalbot-cli setup apply plan.json --wait 300
lokalbot-cli models status                 # poll until meetingReady
lokalbot-cli permissions                   # then: permissions request <name>, restart if macOS asks
lokalbot-cli setup finish
lokalbot-cli doctor                        # exit 0 when ready; nextSteps otherwise
```

- Ask before adding `--meeting-library` or `--screen-memory` to `setup start`, and before requesting any setting in the plan's `notes.needsApproval`.
- Exit 3 means the user hasn't answered yet, 4 means they declined (don't ask again unless they say so), and 5 means the request expired.
- For permissions, tell the user exactly what to click, then poll `permissions` until it shows the grant.
- Never install by removing the quarantine attribute, and never write LokalBot's preferences or files in `control/` yourself.

## MCP alternative (and ask_library)

The same library is available over MCP for GUI clients and anything else that speaks it: `lokalbot-cli mcp` serves `get_briefing` (call it first; same text as `brief`), `list_meetings`, `get_meeting`, `search_meetings`, `ask_library`, `get_action_items`, `list_people`, and `get_person` on stdio. It also advertises `search_screen`, `get_timeline`, `get_recent_activity`, `get_app_usage`, and `get_screenshot_detail`; those return OCR and metadata only, never decrypted pixels or screenshot paths. `get_personal_context` returns what the user shared about themselves under its own permission.

```bash
claude mcp add lokalbot -- /Applications/LokalBot.app/Contents/Helpers/lokalbot-cli mcp
```

`ask_library` is the synthesis tool: it sends the question to LokalBot's **local** model, which reads the library and returns only an answer with meeting citations — useful when the user wants a conclusion rather than quotes. It needs the LokalBot app running, and the first call can take up to a minute while the model loads. Prefer `search`/`get` when the user wants exact wording.

Meeting tools require the user's consent toggle: LokalBot → Settings → Privacy → "Allow external agents to read your meeting library". If a tool returns `[access_disabled]`, explain the setting and let the user choose whether to enable it. Do not change consent markers or work around disabled access.

LokalBot itself does not upload library content. An external agent or MCP client may transmit tool inputs and results under its own privacy terms, so connect only clients the user trusts and retrieve the minimum meeting content needed.

Screen-memory tools require the separate "Allow external agents to read screen memory" toggle. A meeting-library grant never implies a screen-memory grant. If a screen tool returns `[screen_access_disabled]`, explain that separate choice and do not work around it.

## Evidence and privacy

- Answer from returned evidence. Quote exact wording only from retrieved text; distinguish your synthesis from the recorded content. If there are no hits, say so.
- Cite meetings by title and date, adding transcript timestamps for exact moments. Identify the captured time and app for screen-memory evidence when provided.
- Never write into the meetings folder. Audio, transcripts, and summaries live under `~/Library/Application Support/me.dotenv.LokalBot/meetings/`.
- Retrieve only the content needed. Summarize instead of pasting full transcripts unless explicitly asked.
- Do not forward transcripts, summaries, or tool results to any additional service beyond the client the user deliberately connected.
