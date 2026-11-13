# LokalBot plugin for ChatGPT and Codex

LokalBot is your personal context engine: a private work-memory app for macOS, with a Windows and Linux app in alpha. This plugin lets ChatGPT and Codex read your local LokalBot library through `lokalbot-cli`, which runs on your computer: meetings and their action items, the people in them, the folders you chose under Files, and what you shared about yourself. Each kind of data has its own permission in LokalBot, and all of it is off until you turn it on.

It is a skills-only plugin marked **Desktop only**: it runs in Codex and in ChatGPT desktop threads that run locally, not in ChatGPT on the web or phone. OpenAI accepts local MCP servers in the directory only from approved partners, so this plugin has no MCP server, and screen memory (which only LokalBot's MCP server serves) isn't part of it. The [Claude Code plugin](../claude-plugin/README.md) has the same skills and no MCP server either.

## Skills

| Skill | What it does |
| --- | --- |
| `lokalbot-cli` | Teaches the agent when to check LokalBot and every CLI command: `brief`, `list`, `get`, `search`, `ask`, `reply`, `actions`, `people`, `search-files`, `search-notes`, `personal-context`, and the settings and setup commands. A copy of [.agents/skills/lokalbot-cli/SKILL.md](../../.agents/skills/lokalbot-cli/SKILL.md), which the Mac app bundles. |
| `lokalbot-brief` | A short, cited catch-up: what's in flight, what you owe and to whom, recent decisions, and which sources were off. |
| `lokalbot-recall` | Finds what you said, saw, agreed, or saved, picks the right source, and cites it. |
| `lokalbot-setup` | Installs LokalBot and sets it up with you; you approve access and consent changes in LokalBot. It is the plugin's onboarding skill, so it runs after install. |

## Install

In Codex, from this repository's marketplace ([.agents/plugins/marketplace.json](../../.agents/plugins/marketplace.json)), fetching only the plugin:

```bash
codex plugin marketplace add stevyhacker/lokalbot --sparse .agents/plugins --sparse Distribution/openai-plugin
codex plugin add lokalbot@lokalbot
```

Once the directory listing is approved, install it from the plugin directory in ChatGPT desktop or Codex instead.

## Permissions and privacy

Reading needs an explicit opt-in in LokalBot. On a Mac: Settings → External Agents → **Allow external agents to read your LokalBot data**, then tick Meetings, What I shared about myself, Files, or Agent notes. On Windows and Linux: each has its own switch under External agents in Settings → Privacy & Data. Changing settings is a separate switch, and anything that widens what LokalBot captures, plus every API key, waits for your approval in the app.

LokalBot doesn't upload your library. The commands run on your computer, but ChatGPT and Codex process what they return under OpenAI's terms. The skills retrieve only what a question needs and never change your meetings or files.

## For maintainers

- Build the directory ZIP with `bash Scripts/release/build-openai-plugin.sh`. It runs `Scripts/tests/test_openai_plugin.py` first and writes `dist/lokalbot-openai-plugin-<version>.zip` with `plugin.json`, `skills/` and `assets/` at its root. Upload it at <https://platform.openai.com/plugins> → **Upload new or existing plugin**; skill or metadata changes always need a new ZIP.
- Bump `version` in [plugin.json](plugin.json) for every new ZIP, the skill copy included. `skills/lokalbot-cli/SKILL.md` must match the bundled skill; the test fails when they differ.
- The workflow skills are written for ChatGPT and Codex: no `$ARGUMENTS`, no Claude-only frontmatter, no shell variables (directory scanners read them as credentials), and skill names that match their folders. The test checks all of it, plus OpenAI's listing limits.
- `extensions.com.openai.requires_local_executor` marks the plugin Desktop only. Adding an MCP server later needs OpenAI's local-MCP allowlist, and it can't be added to an existing skills-only plugin: it would be a new submission.
- References: [packaging](https://developers.openai.com/plugins/build/plugins), [submission](https://developers.openai.com/plugins/deploy/submission), [desktop-only plugins](https://developers.openai.com/plugins/deploy/desktop-only), and [guidelines](https://developers.openai.com/plugins/plugin-guidelines), checked 2026-11-09.
