# Agent Wrapped

Your year with Claude Code and Codex, counted from the session logs on your own computer.

```bash
npx lokalbot
```

<img src="https://raw.githubusercontent.com/stevyhacker/LokalBot/master/Distribution/npm/docs/agent-wrapped.png" width="480" alt="An Agent Wrapped card for a made-up year. Titled The Switch Hitter, it draws the year as a grid with one column per day and one row per hour, brightest in the evenings, with one busy October day marked in amber. Below: 588 hours of agent work on 247 days, 1,575 requests, 14,415 tool calls, 2B tokens read, 396 commits and 51 merged pull requests, split 67% Claude Code and 33% Codex." />

<sub>A made-up year, from `npx lokalbot --demo`.</sub>

It prints a card in your terminal and opens a local, offline page in your browser where you can switch between **Portrait (4:5)** and **Wide (16:9)** layouts, toggle options, copy or save a 2× PNG, or copy a post caption. Pass `--no-share` for terminal output only. (`npx lokalbot wrapped` also works.)

## What it reads

Claude Code and Codex each keep a log of every session on your computer. This command reads those files, counts, and prints.

- It makes no network requests. The package has no dependencies, and the source is about 2,200 lines you can read in [`src/`](src).
- It counts what you and the agents wrote, and when. It never keeps or prints the text itself.
- It reads Claude Code's session logs in `~/.claude/projects` and `~/.config/claude/projects`, and Codex's in `~/.codex/sessions` and `~/.codex/archived_sessions`, or wherever `CLAUDE_CONFIG_DIR` and `CODEX_HOME` point. Codex compresses its older logs (`.jsonl.zst`); those are read too. Beside Claude Code's logs it also reads `stats-cache.json`, the per-day counts Claude Code keeps after it deletes old logs. It never opens credentials or settings.
- The image leaves your project names out unless you pass `--projects`. The terminal card shows them, since that is your own screen.

## What the figures mean

| Figure | How it is counted |
| --- | --- |
| Agent hours | Time an agent was working. A run of work ends after ten minutes with no activity, and a pause longer than five minutes inside a run counts as five. Two agents working at once count twice. |
| Requests | Messages you typed, including slash commands. Text the agent's own software adds to your turn is left out. |
| Tool calls | Every tool an agent used, including the ones its subagents used. |
| Tokens read and written | Input tokens, including cached ones, and output tokens. The optional `API value` figure estimates what those tokens would cost at public list API prices (flat-rate subscriptions like Claude Max/Pro or ChatGPT Plus/Pro cost less). |
| Parallelism | Agent hours divided by wall-clock hours (`agentMs / wallClockMs`), shown when you ran agents in parallel (`1.2×` or higher). |
| Commits, pull requests, test runs | Read from the shell commands the agents ran, such as `git commit -m` and `gh pr merge`. A command counts when it was run, whether or not it succeeded. |
| Most at once | The most sessions with work under way at the same moment. A subagent counts as part of the session that started it. |
| The title | The one trait that stands out most in your year, such as how much of it ran at night. |

`--json` prints every figure, for your own charts.

## If your year starts late

Claude Code deletes session logs after 30 days unless you tell it otherwise, so the picture may begin only a month ago. It does keep a count of sessions and tool calls for each day, and Agent Wrapped shows those earlier days as marks under the picture and tells you how many there were. They have no hours, so they stay out of the other figures.

To keep next year's logs, add this to `~/.claude/settings.json`:

```json
{ "cleanupPeriodDays": 3650 }
```

Codex keeps its logs.

## Options

```text
--year <year>       The year to count. Default: this year (last year in January).
--share             Write the shareable image page and open it in your browser (default in a TTY).
--no-share          Print the terminal card only, without opening the image page.
--wide              Open the shareable card in 16:9 wide layout (for X / LinkedIn).
--out <file>        Where the share page is written. Default: your temporary folder.
--no-open           Write the share page without opening your browser.
--projects          Name your three busiest projects on the image.
--no-api-value      Leave the estimated API-rate value off the card.
--json              Print the figures as JSON instead of the card.
--claude-dir <dir>  Read Claude Code projects from here instead of ~/.claude/projects.
--codex-dir <dir>   Read Codex from here instead of ~/.codex.
--demo              Show a made-up year, without reading any logs.
--no-color          Plain text.
```

Needs Node.js 20 or later. Codex's compressed logs need Node.js 22.15 or later; with an older Node.js the card says how many it left out. Tested on macOS, Linux and Windows.

## Where it comes from

[LokalBot](https://www.lokalbot.com/) ([GitHub](https://github.com/stevyhacker/LokalBot)) is a free, open-source (GPLv3) desktop app for macOS, Windows, and Linux that records your meetings with no bot, runs transcription and summaries locally, and gives Claude Code and Codex read-only MCP memory of what was decided. Agent Wrapped reads coding-agent logs the same way LokalBot's timeline does.

If you liked your card, a star on [the repository](https://github.com/stevyhacker/LokalBot) helps other people find it.

## Development

```bash
cd Distribution/npm
npm test                              # the tests read only fixtures they write themselves
node bin/lokalbot.mjs wrapped --demo  # a made-up year
```

GPL-3.0-only, like the rest of LokalBot.
