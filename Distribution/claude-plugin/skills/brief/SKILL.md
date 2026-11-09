---
description: Catch up from LokalBot on what you're working on, what you owe, and your recent days
argument-hint: "[optional focus, such as a project, a person, or this week]"
disable-model-invocation: true
---

# Catch up from LokalBot

The user's focus, if any: $ARGUMENTS

Give the user a short, cited catch-up on their own work from their local LokalBot library. The `lokalbot-cli` skill has the full command reference; the plugin's `lokalbot` MCP server offers the same tools (`get_briefing` is the MCP form of `brief`).

## Steps

1. Run `lokalbot-cli brief`. It says which LokalBot sources are on, then gives what each covers: what the user shared about themselves, open action items, current projects and goals, recent Claude Code and Codex work by project, and a timeline of recent days.
2. Fill in the evidence behind what matters most. Without a focus, cover the next few days: `lokalbot-cli actions --owner me` for what the user owes (overdue and soon-due first), and `lokalbot-cli list --since <date a week ago> --include summary` for what recent meetings decided. With a focus, search for it: `lokalbot-cli search "<focus>"`, `lokalbot-cli people "<name>"` for a person, or the screen-memory MCP tools (`get_timeline`, `search_screen`) for what happened on screen.
3. Report in a few short sections: what's in flight, what the user owes and to whom, decisions and open questions, and anything that looks stuck. Cite meetings by title and date from `get`, `search`, `list`, or `actions` results, not from the briefing's summary lines.
4. End with which sources were off, if any, so the user knows what the catch-up couldn't see.

## Guardrails

- Items the briefing doesn't list are unknown, not false. Don't fill gaps with guesses.
- Retrieve only what the catch-up needs, and summarize rather than quoting transcripts at length. LokalBot itself uploads nothing, but Claude Code processes tool inputs and results under Anthropic's terms.
- Each kind of data has its own permission in LokalBot. When a source is off, the briefing and the error code (`[access_disabled]`, `[screen_access_disabled]`, `[files_access_disabled]`, `[personal_context_disabled]`) say which one and where to turn it on. Tell the user, and don't work around it.
- If `lokalbot-cli` isn't on PATH, use `/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli` on a Mac, `~/.local/bin/lokalbot-cli` on Linux, or `%LOCALAPPDATA%\Programs\LokalBot\bin\lokalbot-cli.exe` on Windows.
