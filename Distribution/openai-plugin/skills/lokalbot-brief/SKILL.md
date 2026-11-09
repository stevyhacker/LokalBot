---
name: lokalbot-brief
description: Catch the user up from LokalBot on their own work, with citations - what's in flight, what they owe and to whom, recent decisions, and which LokalBot sources are off. Use when they ask for a catch-up, a standup summary, or what they were working on.
---

# Catch up from LokalBot

Give the user a short, cited catch-up on their own work from their local LokalBot library. If they named a focus, such as a project, a person, or a time span, narrow the catch-up to it. The `lokalbot-cli` skill has the full command reference.

## Steps

1. Run `lokalbot-cli brief`. It says which LokalBot sources are on, then gives what each covers: what the user shared about themselves, open action items, current projects and goals, recent coding-agent work by project, and a timeline of recent days.
2. Fill in the evidence behind what matters most. Without a focus, cover the next few days: `lokalbot-cli actions --owner me` for what the user owes (overdue and soon-due first), and `lokalbot-cli list --since <date a week ago> --include summary` for what recent meetings decided. With a focus, search for it: `lokalbot-cli search "<focus>"`, or `lokalbot-cli people "<name>"` for a person.
3. Report in a few short sections: what's in flight, what the user owes and to whom, decisions and open questions, and anything that looks stuck. Cite meetings by title and date from `get`, `search`, `list`, or `actions` results, not from the briefing's summary lines.
4. End with which sources were off, if any, so the user knows what the catch-up couldn't see.

## Guardrails

- Items the briefing doesn't list are unknown, not false. Don't fill gaps with guesses.
- Retrieve only what the catch-up needs, and summarize rather than quoting transcripts at length. LokalBot sends library content off this computer only to a remote model server the user approved, but this chat processes what the commands return.
- Each kind of data has its own permission in LokalBot. When a source is off, the briefing and the error code (`[access_disabled]`, `[files_access_disabled]`, `[personal_context_disabled]`) say which one and where to turn it on. Tell the user, and don't work around it.
- If `lokalbot-cli` isn't on PATH, use `/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli` on a Mac, `~/.local/bin/lokalbot-cli` on Linux, or `%LOCALAPPDATA%\Programs\LokalBot\bin\lokalbot-cli.exe` on Windows. If LokalBot isn't installed at all, offer the `lokalbot-setup` skill.
