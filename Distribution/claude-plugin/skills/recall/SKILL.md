---
description: Find what you said, saw, agreed, or saved in LokalBot, and answer with citations
argument-hint: "<what you want to find or know>"
disable-model-invocation: true
---

# Recall from LokalBot

The user's question: $ARGUMENTS

Answer from the user's local LokalBot library, with real evidence and a citation for every claim. The `lokalbot-cli` skill has the full command reference.

## Choose the source

Pick the source that fits the question, and try the next one when it comes back empty:

- **Something said in a meeting**: `lokalbot-cli search "<words>" --limit 10`, then `lokalbot-cli get <id> --include metadata,summary` for the top hits. Add `transcript` only when the summary doesn't settle the question. For what a stretch of meetings covered, use `lokalbot-cli list --since <YYYY-MM-DD> --include summary` instead of reading transcripts one by one.
- **A commitment** (what the user owes, what is overdue, one meeting's next steps): `lokalbot-cli actions`, with `--owner me`, `--owner <name>`, `--status all`, or `--meeting <id>`.
- **A person** (what they owe the user, what the user owes them, decisions made together): `lokalbot-cli people "<name>"`.
- **Something seen on screen** (a page, an error, an app the user was in): screen memory is reachable only through LokalBot's MCP server (`search_screen`, `get_timeline`, `get_recent_activity`, `get_app_usage`), which this plugin doesn't start. Use those tools when they are available; they return text and metadata, never screenshots. Otherwise, tell the user they can connect the server with `claude mcp add lokalbot -- lokalbot-cli mcp`.
- **A document, PDF, screenshot, or picture in the user's folders**: `lokalbot-cli search-files "<words>"`, with `--kind` and `--after`/`--before` to narrow it.
- **Advice that depends on the user's own goals or preferences**: `lokalbot-cli personal-context --task "<the task>"`.

Search matches words, not meaning, so use words the source would contain and rephrase once or twice when nothing comes back. For a synthesized answer rather than quotes, `lokalbot-cli ask "<question>"` has LokalBot's local model answer from the matching meetings; it needs the app running.

## Citations

- Meetings: title and date, plus the transcript timestamp for an exact moment.
- Action items: the meeting they came from, and the due date when one is given.
- Screen memory: the captured time and the app.
- Files: the path, and the page for a PDF.
- Quote only text a command returned, and keep your own synthesis apart from what was recorded.

## Guardrails

- Never invent content. If nothing turns up, say what you searched.
- Reading is all this needs. Never write into LokalBot's meetings folder, and never change, move, or delete the user's files.
- Retrieve only what the question needs. Summarize rather than pasting transcripts unless the user asks for one, and don't forward results to any other service. LokalBot sends library content off this computer only to a remote model server the user approved, but Claude Code processes tool inputs and results under Anthropic's terms.
- Each kind of data has its own permission in LokalBot. `[access_disabled]` means meetings are off, `[screen_access_disabled]` screen memory, `[files_access_disabled]` Files, and `[personal_context_disabled]` what the user shared about themselves. Tell the user which one it is and where to find it: on a Mac, LokalBot → Settings → External Agents → "Allow external agents to read your LokalBot data", then the matching box; on Windows and Linux, its own switch under External agents in Settings → Privacy & Data. Don't work around it.
- If `lokalbot-cli` isn't on PATH, use `/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli` on a Mac, `~/.local/bin/lokalbot-cli` on Linux, or `%LOCALAPPDATA%\Programs\LokalBot\bin\lokalbot-cli.exe` on Windows.
