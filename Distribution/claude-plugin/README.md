# LokalBot plugin for Claude Code

LokalBot is your personal context engine: a private work-memory app for macOS, with a Windows and Linux app in alpha. This plugin lets Claude Code read your local LokalBot library through `lokalbot-cli`: meetings and their action items, the people in them, the folders you chose under Files, and what you shared about yourself. Screen memory needs LokalBot's MCP server, which you connect yourself (see [Screen memory](#screen-memory-and-the-mcp-server)). Each kind of data has its own permission in LokalBot, and all of it is off until you turn it on. Claude Code's own data-handling terms still apply.

## What it gives Claude Code

**Commands**

- **`/lokalbot:brief [focus]`**: a short catch-up on your own work: what's in flight, what you owe and to whom, recent decisions, and which sources were off. See [skills/brief](skills/brief/SKILL.md).
- **`/lokalbot:recall <question>`**: find what you said, saw, agreed, or saved, and answer with citations. It picks the source that fits: meetings, action items, people, Files, what you shared about yourself, or screen memory when the MCP server is connected. See [skills/recall](skills/recall/SKILL.md).
- **`/lokalbot:setup`**: install LokalBot and set it up with you. You allow access, approve consent changes, and grant system permissions in LokalBot; Claude does the rest from the terminal. The full journey is on a Mac; on Windows and Linux, Claude walks you through the install and then uses the same commands. See [skills/setup](skills/setup/SKILL.md) and [AGENT_SETUP.md](https://github.com/stevyhacker/LokalBot/blob/master/AGENT_SETUP.md).

**The `lokalbot-cli` skill** teaches Claude when to check LokalBot (at the start of a session on your own work, and before asking you about past work, decisions, or commitments) and how to use the CLI:

| Area | Commands |
| --- | --- |
| Orientation | `brief` |
| Meetings | `list` (with `--include summary` for many at once), `get`, `search`, `path` |
| Answers and drafts | `ask`, `reply` (LokalBot's local model, from your meetings) |
| Commitments and people | `actions`, `people` |
| Your files | `search-files` |
| What you shared | `personal-context` |
| Settings and setup | `config`, `secret`, `status`, `open`, `setup`, `models`, `permissions`, `doctor`, `restart` |

## Screen memory and the MCP server

The plugin doesn't start LokalBot's MCP server. Anthropic's plugin directory accepts plugins that run an MCP server on your computer only from organizations it has Verified, so the plugin works through `lokalbot-cli` alone, which covers everything except screen memory. To add screen memory, or to use LokalBot in Cowork, connect the server yourself:

```bash
claude mcp add lokalbot -- lokalbot-cli mcp
```

It runs `lokalbot-cli mcp` over stdio, with the same tools on every platform:

| Permission in LokalBot | Tools |
| --- | --- |
| None | `get_briefing`: which sources are on, then a short summary of each one you allowed |
| Meetings | `list_meetings`, `get_meeting`, `search_meetings`, `ask_library`, `get_action_items`, `list_people`, `get_person` |
| Screen memory | `search_screen`, `get_timeline`, `get_recent_activity`, `get_app_usage`, `get_screenshot_detail` (text and metadata only, never screenshots) |
| Files | `search_files` |
| What I shared about myself | `get_personal_context` |

## Install

From within Claude Code:

```
/plugin marketplace add stevyhacker/lokalbot
/plugin install lokalbot@lokalbot
/reload-plugins
```

The first command adds the LokalBot repository as a plugin marketplace (the catalog is [.claude-plugin/marketplace.json](https://github.com/stevyhacker/LokalBot/blob/master/.claude-plugin/marketplace.json)); the second installs the plugin, which is the `Distribution/claude-plugin` folder. Claude Code namespaces plugin commands, so they appear as `/lokalbot:brief`, `/lokalbot:recall`, and `/lokalbot:setup`.

If you also ran `lokalbot-cli install-skill`, Claude Code sees the skill twice, as `lokalbot-cli` and `lokalbot:lokalbot-cli`. Either one works.

## Permissions

Reading needs an explicit opt-in in the LokalBot app, and each kind of data needs its own:

- **Mac**: Settings → External Agents → **Allow external agents to read your LokalBot data**, then tick Meetings, Screen memory, What I shared about myself, or Files. Screen memory is further limited to today, the last seven days, or all retained history.
- **Windows and Linux**: Settings → Privacy & Data, where each has its own switch under External agents: meeting library, screen memory, files, and What I shared about myself.

When something is off, a tool returns `[access_disabled]` (meetings), `[screen_access_disabled]`, `[files_access_disabled]`, or `[personal_context_disabled]`, and the plugin tells you where to turn it on rather than working around it.

Changing settings is a separate permission: **Allow external agents to change LokalBot settings**, in the same place. With it, Claude can apply preferences directly. Anything that widens what LokalBot captures, reads, records, or sends, and every API key, goes to an approval card in LokalBot and waits for you. `/lokalbot:setup` asks for this permission with `setup start`, which you approve with one click.

## Privacy boundary

LokalBot does not upload your library. The plugin's commands run `lokalbot-cli` on your computer, but Claude Code may send what they return to Anthropic under its terms. Allow only what you want Claude to read; the skills tell Claude to retrieve only what a question needs. The CLI and MCP tools never change your meetings or your files.

## CLI availability

The commands run `lokalbot-cli` from your PATH, and so does the MCP server if you connect it. **Settings → External Agents → Agent CLI** in LokalBot (Settings → Advanced on Windows and Linux) installs it: at `~/.local/bin/lokalbot-cli` on macOS and Linux, and at `%LOCALAPPDATA%\Programs\LokalBot\bin\lokalbot-cli.exe` on Windows, whose folder you add to PATH yourself ([how](https://github.com/stevyhacker/LokalBot/blob/master/LinuxWindows/README.md#coding-agents)). On a Mac, the embedded copy also works: `/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli`.

## For maintainers

- The plugin is the `Distribution/claude-plugin` folder of [stevyhacker/LokalBot](https://github.com/stevyhacker/LokalBot), so an install copies only these files. `skills/lokalbot-cli/SKILL.md` is a copy of [.agents/skills/lokalbot-cli/SKILL.md](https://github.com/stevyhacker/LokalBot/blob/master/.agents/skills/lokalbot-cli/SKILL.md), which the Mac app bundles; `Scripts/tests/test_claude_plugin.py` fails when they differ, so copy the file after editing the original.
- [stevyhacker/lokalbot-claude-plugin](https://github.com/stevyhacker/lokalbot-claude-plugin) holds a copy of this folder for the Claude plugin directory, which can't download the LokalBot repository (its limit is 50 MiB compressed). The `Claude plugin sync` workflow pushes each change on LokalBot's master there, and the directory picks it up from that repository's default branch. Edit the plugin in LokalBot, never in that repository: the next sync overwrites it.
- Bump `version` in [.claude-plugin/plugin.json](.claude-plugin/plugin.json) whenever anything in this folder changes, the skill copy included. Installs stay on their cached copy until that string changes. The marketplace entry carries no version of its own.
- Don't add `mcpServers` or an `.mcp.json` here: the directory refused 0.2.1 because the plugin started a local MCP server and LokalBot's organization isn't Verified. `Scripts/tests/test_claude_plugin.py` checks this.
- The directory listing icon is the full-bleed 1024 px app icon, in `.claude-plugin/`, where the directory finds it without a manifest field. The directory takes the icon only from the first submission, so changing it later does nothing there.
- Check changes with `claude plugin validate Distribution/claude-plugin --strict` and `claude plugin validate . --strict` from the repository root.
- Field references: [plugin manifest](https://code.claude.com/docs/en/plugins-reference), [marketplaces](https://code.claude.com/docs/en/plugin-marketplaces), and [publishing](https://code.claude.com/docs/en/plugins/publish), checked 2026-11-09.
