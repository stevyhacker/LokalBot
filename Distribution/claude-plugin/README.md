# LokalBot plugin for Claude Code

This plugin connects Claude Code to your on-device LokalBot meeting library through a read-only local bridge. Claude Code's own data-handling terms still apply.

## What it gives Claude Code

- **`/lokalbot:recall` command** — search your meeting library and get answers with citations (meeting title + date). See [commands/recall.md](commands/recall.md).
- **`/lokalbot:setup` command** (Mac) — install LokalBot and set it up with you: you allow access and approve consent changes in LokalBot, and Claude does the rest from the terminal. See [commands/setup.md](commands/setup.md) and [AGENT_SETUP.md](../../AGENT_SETUP.md).
- **`lokalbot-cli` skill** — teaches Claude when and how to use the CLI (`list`, `get`, `search`, `path`) from [.agents/skills/lokalbot-cli/SKILL.md](../../.agents/skills/lokalbot-cli/SKILL.md).
- **`lokalbot` MCP server** — runs `lokalbot-cli mcp` over stdio, exposing `list_meetings`, `get_meeting`, `search_meetings`, and `ask_library` (plus the separately gated screen-memory tools).

## Install

From within Claude Code:

```
/plugin marketplace add stevyhacker/lokalbot
/plugin install lokalbot@lokalbot
/reload-plugins
```

The first command adds this repository as a plugin marketplace (the catalog lives at [.claude-plugin/marketplace.json](../../.claude-plugin/marketplace.json)); the second installs the plugin from it. After reloading, invoke the command as `/lokalbot:recall <query>` because Claude Code namespaces plugin commands.

## Privacy boundary

LokalBot does not upload library content. This plugin starts the CLI and MCP server locally, but Claude Code may transmit tool inputs and results under Anthropic's terms. Enable access only for a client you trust, request the minimum meeting content needed, and do not forward it to additional services.

## Prerequisite: consent toggle

The MCP tools require an explicit opt-in in the LokalBot app: **Settings > Privacy & Data > "Allow external agents to read your meeting library"**. If a tool returns `[access_disabled]`, flip that toggle — the plugin does not work around it. Screen-memory tools need the separate "Allow external agents to read screen memory" toggle.

## CLI availability

The MCP server and the `/lokalbot:recall` command invoke `lokalbot-cli` from your PATH. **Settings → Advanced → Agent CLI** in LokalBot installs it: at `~/.local/bin/lokalbot-cli` on macOS and Linux, and at `%LOCALAPPDATA%\Programs\LokalBot\bin\lokalbot-cli.exe` on Windows, whose folder you add to PATH yourself ([how](../../LinuxWindows/README.md#coding-agents)). On a Mac, the embedded copy also works directly: `/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli`. The manifests reference the bare `lokalbot-cli` command; adjust your PATH or symlink if you installed LokalBot elsewhere.

## Schema verification

Manifests use only fields verified against the official Claude Code docs (fetched 2026-08-21):

| Field(s) | Verified against |
| --- | --- |
| `plugin.json`: `name`, `description`, `version`, `author`, `homepage`, `repository`, `license`, `keywords`, `commands`, `skills`, `mcpServers` | https://code.claude.com/docs/en/plugins-reference ("Plugin manifest schema": required/metadata/component-path fields; `skills` accepts an array of paths to directories containing `SKILL.md`; `mcpServers` accepts an inline object with `command`/`args`) |
| `marketplace.json`: `name`, `owner` (`name`, `url`), `plugins[]` with `name`, `source` (`"./"` relative path), `description`, `version`, `author`, `homepage`, `keywords` | https://code.claude.com/docs/en/plugin-marketplaces ("Marketplace schema" required/owner/optional fields; "Plugin entries"; relative-path sources resolve against the marketplace root and must start with `./`) |
| Install syntax `/plugin marketplace add owner/repo` and `/plugin install <plugin>@<marketplace>` | https://code.claude.com/docs/en/discover-plugins ("Add from GitHub", install steps) |
| Overview of the plugin system | https://code.claude.com/docs/en/plugins |
