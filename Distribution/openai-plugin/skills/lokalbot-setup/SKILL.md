---
name: lokalbot-setup
description: Install LokalBot and set it up with the user, who approves access and changes to what LokalBot captures in the LokalBot app. Use after installing this plugin, or when the user wants LokalBot installed, set up, or checked.
---

# Set up LokalBot

Install LokalBot and set it up for the user, following [AGENT_SETUP.md](https://github.com/stevyhacker/lokalbot/blob/master/AGENT_SETUP.md). The user approves access and changes to what LokalBot captures, reads, or sends, in LokalBot; you do the rest from the terminal. If LokalBot is already installed and set up, run `lokalbot-cli doctor` and report what is ready and anything left.

## On a Mac

Until `lokalbot-cli` is on PATH, run it by its full path, `/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli`. The steps write it as `lokalbot-cli`.

1. If `/Applications/LokalBot.app` is missing, run `brew install --cask stevyhacker/tap/lokalbot`. Never remove the quarantine attribute.
2. Run `lokalbot-cli setup start --wait 300` and tell the user to click Allow in LokalBot. Add `--meeting-library`, `--screen-memory`, or `--files` only if they want you to read their meetings or screen memory, or search the folders they chose under Files.
3. Run `lokalbot-cli setup plan` and talk it through with the user: automatic recording, calendar, notes language, Day Memory detail, dictation, autocomplete, and launch at login. Explain each setting listed in `notes.needsApproval` before asking for it. Use `lokalbot-cli config describe <key>` for the choices.
4. Save the agreed plan and run `lokalbot-cli setup apply plan.json --wait 300`. Tell the user one approval card is waiting for them in LokalBot.
5. Poll `lokalbot-cli models status` until `meetingReady` is true.
6. Run `lokalbot-cli permissions`. For each permission an enabled feature needs, run `lokalbot-cli permissions request <name>`, tell the user exactly what to click, and poll until it shows as granted. Run `lokalbot-cli restart` if macOS asks for one.
7. Run `lokalbot-cli setup finish`, then `lokalbot-cli doctor`, and report what is ready and anything left.
8. So the other LokalBot skills can run it by name, ask the user before running `lokalbot-cli install-skill`, which links the CLI into `~/.local/bin` (and LokalBot's skill into `~/.agents/skills` and `~/.claude/skills`).

## On Windows or Linux (alpha)

Installing differs, and the same commands work once the app is running. Work through it with the user:

1. They install from the [latest release](https://github.com/stevyhacker/lokalbot/releases/latest): on Linux, extract `LokalBot-<version>-linux-x86_64.tar.gz` and run `./install.sh` (the `.deb`, `.rpm`, and Arch packages need their `sudo`); on Windows, they run `LokalBot-<version>-windows-x86_64-setup.exe`, which installs for their user without administrator rights. The Windows build isn't code-signed yet, so SmartScreen asks first. Never unblock the file or turn SmartScreen off for them.
2. They choose what LokalBot remembers and which models to download, in the app's onboarding.
3. If they want you to read their library, they turn on the matching switches under External agents in Settings → Privacy & Data: meeting library, screen memory, files, and what they shared about themselves.
4. Run `lokalbot-cli install-skill`, or have them click **Install for your coding agent…** in Settings → Advanced → Agent CLI. On Windows, the CLI goes to `%LOCALAPPDATA%\Programs\LokalBot\bin`, whose folder they add to PATH.
5. Run `lokalbot-cli brief` to show which sources are on, and `lokalbot-cli doctor` for anything left.

## Guardrails

- Exit code 3 means the user hasn't answered yet, 4 that they declined (don't ask again unless they say so), and 5 that the request expired (ask before trying again).
- Never use `defaults write`, and never create or edit files in LokalBot's `control/` folder.
- Pass an API key only on standard input to `lokalbot-cli secret set <name>`, and only when the user gives you one for that purpose. Never put it on the command line or echo it back.
- Change only what the user agreed to.
