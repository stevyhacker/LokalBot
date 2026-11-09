---
name: lokalbot-recall
description: Find what the user said, saw, agreed, or saved in LokalBot, and answer with a citation for every claim. Use when they ask about a past meeting, a decision, a commitment, a person, or a file in their own folders.
---

# Recall from LokalBot

Answer the user's question from their local LokalBot library, with real evidence and a citation for every claim. The `lokalbot-cli` skill has the full command reference.

## Choose the source

Pick the source that fits the question, and try the next one when it comes back empty:

- **Something said in a meeting**: `lokalbot-cli search "<words>" --limit 10`, then `lokalbot-cli get <id> --include metadata,summary` for the top hits. Add `transcript` only when the summary doesn't settle the question. For what a stretch of meetings covered, use `lokalbot-cli list --since <YYYY-MM-DD> --include summary` instead of reading transcripts one by one.
- **A commitment** (what the user owes, what is overdue, one meeting's next steps): `lokalbot-cli actions`, with `--owner me`, `--owner <name>`, `--status all`, or `--meeting <id>`.
- **A person** (what they owe the user, what the user owes them, decisions made together): `lokalbot-cli people "<name>"`.
- **A document, PDF, screenshot, or picture in the user's folders**: `lokalbot-cli search-files "<words>"`, with `--kind` and `--after`/`--before` to narrow it.
- **Advice that depends on the user's own goals or preferences**: `lokalbot-cli personal-context --task "<the task>"`.
- **Something seen on screen**: screen memory is reachable only through LokalBot's MCP server (`search_screen`, `get_timeline`), which this plugin doesn't include. If those tools aren't available, say so instead of guessing.

Search matches words, not meaning, so use words the source would contain and rephrase once or twice when nothing comes back. For a synthesized answer rather than quotes, `lokalbot-cli ask "<question>"` has LokalBot's local model answer from the matching meetings; it needs the app running.

## Citations

- Meetings: title and date, plus the transcript timestamp for an exact moment.
- Action items: the meeting they came from, and the due date when one is given.
- Files: the path, and the page for a PDF.
- Quote only text a command returned, and keep your own synthesis apart from what was recorded.

## Guardrails

- Never invent content. If nothing turns up, say what you searched.
- Reading is all this needs. Never write into LokalBot's meetings folder, and never change, move, or delete the user's files.
- Retrieve only what the question needs. Summarize rather than pasting transcripts unless the user asks for one, and don't send results to any other service. LokalBot sends library content off this computer only to a remote model server the user approved, but this chat processes what the commands return.
- Each kind of data has its own permission in LokalBot. `[access_disabled]` means meetings are off, `[files_access_disabled]` Files, and `[personal_context_disabled]` what the user shared about themselves. Tell the user which one it is and where to find it: on a Mac, LokalBot → Settings → External Agents → "Allow external agents to read your LokalBot data", then the matching box; on Windows and Linux, its own switch under External agents in Settings → Privacy & Data. Don't work around it.
- If `lokalbot-cli` isn't on PATH, use `/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli` on a Mac, `~/.local/bin/lokalbot-cli` on Linux, or `%LOCALAPPDATA%\Programs\LokalBot\bin\lokalbot-cli.exe` on Windows. If LokalBot isn't installed at all, offer the `lokalbot-setup` skill.
