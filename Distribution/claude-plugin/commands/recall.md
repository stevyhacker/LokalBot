---
description: Search the local LokalBot meeting library and answer with citations
---

# Recall from the LokalBot meeting library

The user's query: $ARGUMENTS

Search the user's local LokalBot meeting library and answer their query using real meeting content.

## Steps

1. Run `lokalbot-cli search "<query>" --limit 10` to find candidate meetings. If nothing relevant turns up, try one or two rephrased queries.
2. For the top hits, run `lokalbot-cli get <meeting_id> --include summary` to read each meeting's substance. Pull the transcript (`--include transcript`) only when the summary does not answer the question.
3. Answer the user's question using what the meetings actually say.

## Citation rules

- Cite every claim with its meeting title and date (both appear in CLI output).
- Quote actual snippets from summaries or transcripts rather than paraphrasing beyond them.

## Guardrails

- Never invent meeting content. If the CLI returns no hits, say so plainly.
- The CLI is read-only by design. Never write into the meetings folder.
- Meeting content is sensitive personal data. Retrieve only what is needed, avoid full transcripts unless the user explicitly requests one, and do not forward content to any additional service. LokalBot itself does not upload tool data, but Claude Code may process tool inputs and results under Anthropic's terms.
- If any command returns `[access_disabled]`, tell the user to enable Settings > Privacy & Data > "Allow external agents to read your meeting library" in the LokalBot app. Do not try to work around it.
- If `lokalbot-cli` is not on PATH, use `/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli` on a Mac, `~/.local/bin/lokalbot-cli` on Linux, or `%LOCALAPPDATA%\Programs\LokalBot\bin\lokalbot-cli.exe` on Windows.
