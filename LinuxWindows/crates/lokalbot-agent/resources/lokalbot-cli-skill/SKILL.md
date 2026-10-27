---
name: lokalbot-library
description: Look up the user's LokalBot memory with lokalbot-cli, which reads recorded meetings (transcripts, summaries, word search), action items, people, current projects, recent work, and what the user shared about themselves. Use it before answering or asking the user about their own work, meetings, decisions, commitments, or plans.
---

# LokalBot library

`lokalbot-cli` is on PATH. It reads the user's LokalBot library and never changes it. Output is JSON; `list`, `search`, `actions`, `people`, and `personal-context` take `--table` for plain text.

## Start here

`lokalbot-cli brief` says which LokalBot sources are on and how the user turns on the others. For the sources that are on, it gives what the user shared about themselves, open action items, current projects and goals, recent Claude Code and Codex work by project, and a timeline with recent days in detail and older weeks and months in a line each. It is short on purpose: use it to orient, then look up the detail.

Items the briefing doesn't list are unknown, not false. Cite meetings from `get`, `search`, or `actions` results, not from the briefing's summary lines.

## Choose the command

- `list` for candidate meeting ids, titles, and dates.
- `get` when you know the meeting; `latest` works without listing first.
- `search` when the user remembers a phrase or wants every meeting that mentions something.
- `actions` for commitments: what the user owes, what is overdue, one meeting's next steps.
- `people` for one person: what the user owes them, what they owe the user, decisions made together, and shared meetings.
- `personal-context` before advising on a personal decision or tailoring work to the user.

## Meetings

```bash
lokalbot-cli list --limit 10 --table
lokalbot-cli list --since 2026-06-01 --until 2026-06-30 --query "design"
lokalbot-cli get latest --include metadata,summary
lokalbot-cli get 4f7c2a91 --include metadata,transcript
lokalbot-cli search "auth refactor" --limit 20
```

- The `id` in each `list` entry is an 8-character prefix that the other commands accept.
- `--include` takes `metadata`, `summary`, and `transcript`, comma-separated; the default is all three. Transcripts can be very long, so start with the summary and fetch the transcript only for exact wording.
- `--since` and `--until` take a local day (`YYYY-MM-DD`). The environment section gives today's date.
- `search` matches meetings that contain every word, in any order, ignoring case and accents; when none does, the closest partial matches follow. Words of up to three letters or digits (`API`, `Q3`) match only whole words. Quote a phrase inside the query (`'"auth refactor"'`) to match only that phrase. Transcript hits include a `timestamp` (HH:MM:SS).

## Action items and people

```bash
lokalbot-cli actions --owner me --table
lokalbot-cli actions --owner ana --status all --days 90
lokalbot-cli actions --meeting 4f7c2a91
lokalbot-cli people --query ana
lokalbot-cli people "Ana Petrović"
```

Actions use the user's saved corrections and status, with overdue and soon-due work first. `due_date` (YYYY-MM-DD) appears only when the spoken due phrase resolves unambiguously; otherwise use `due` as said. People come from calendar attendees, speaker names, and action owners, with the names, merges, and hidden entries from LokalBot's People page applied. Only names are returned; never ask for or infer email addresses.

## Personal context

```bash
lokalbot-cli personal-context --task "Plan next quarter"
lokalbot-cli personal-context --task "Evaluate a job offer in Berlin" --kind goal --kind principle --limit 5
```

Items are the user's own statements, shared for agents, most relevant to the task first. Use them only when they bear on the task, and say which ones shaped your answer. Items not returned are unknown, not false, and they are not evidence about meetings or other people. The Windows and Linux app has no About you page yet, so these items exist only in a library that came from a Mac.

## When access is off

Each source has its own switch under Settings → Privacy in LokalBot. `[access_disabled]` means meeting access is off. `[personal_context_disabled]` means sharing what the user wrote about themselves is off; that switch is in the Mac app. Tell the user which switch it is and let them decide. Don't work around it, and never create or edit files in LokalBot's `control` folder.

Screen history has no command here. The user can attach saved screen moments to a task from the composer.

## LokalBot's settings

The command line can't read or change LokalBot's settings on Windows and Linux. When the user asks how LokalBot is set up, tell them where the setting is in LokalBot's Settings and let them change it there.

## Evidence and privacy

- Answer from what the commands return. Quote exact wording only from retrieved text, and keep your own synthesis apart from what was said.
- Name meetings by title and date, with transcript timestamps for exact moments.
- Fetch only what the task needs, and summarize rather than pasting whole transcripts unless the user asks.
- The library is private. Read it with `lokalbot-cli` and never write into it. Use `lokalbot-cli path <id>` only when the task needs a meeting's files or audio; opening them asks the user first.
