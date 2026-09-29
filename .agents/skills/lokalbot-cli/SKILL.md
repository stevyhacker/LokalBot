---
name: lokalbot-cli
description: Retrieve meeting or screen-memory evidence from LokalBot when the user asks about their recorded work.
---

# LokalBot CLI Skill

LokalBot is a private work-memory app for macOS. Its read-only CLI retrieves recorded meetings; separately authorized MCP tools retrieve screen-memory text and metadata. Use this skill for evidence from the user's recorded work, not for scheduling meetings or answering general questions about a topic.

If `lokalbot-cli` isn't on PATH, use the embedded copy directly:
`/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli`.

## Choose the source

- Use `list` when you need candidate meeting ids, titles, and dates.
- Use `get` when the meeting is known; `latest` works without listing first. Request `metadata,summary` for a cited summary; include `transcript` when the question needs exact wording.
- Use `search` directly when the user remembers a phrase or wants cross-meeting mentions.
- Use `actions` for commitments: what the user owes, overdue work, or one meeting's next steps.
- Use `people` for everything about one person: what the user owes them, what they owe the user, decisions made together, and shared meetings.
- Use `path` only when the task needs an on-disk folder or audio file.
- For viewed screen text or app activity, use the screen-memory MCP tools within the user's separate permission and history scope.

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

Transcript hits include a `timestamp` (HH:MM:SS) so the user can jump to that moment in the in-app player.

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

People are joined from calendar attendee names, speaker names applied in LokalBot, and action owners. Only names are returned; never ask for or infer email addresses.

## Path lookup

```bash
lokalbot-cli path
lokalbot-cli path latest
cd "$(lokalbot-cli path latest)"
```

## MCP alternative (and ask_library)

The same library is available over MCP for GUI clients and anything else that speaks it: `lokalbot-cli mcp` serves `list_meetings`, `get_meeting`, `search_meetings`, `ask_library`, `get_action_items`, `list_people`, and `get_person` on stdio. It also advertises `search_screen`, `get_timeline`, `get_recent_activity`, `get_app_usage`, and `get_screenshot_detail`; those return OCR and metadata only, never decrypted pixels or screenshot paths.

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
