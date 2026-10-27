---
description: Install and set up LokalBot on this Mac, with the user's approval
---

# Set up LokalBot

The user's request: $ARGUMENTS

Install LokalBot and set it up for the user by following [AGENT_SETUP.md](../../../AGENT_SETUP.md). The user approves access and consent changes in LokalBot; you do the rest from the terminal.

## Steps

These steps are for a Mac. On Windows or Linux, agent-driven setup isn't available yet: follow the Windows and Linux section of AGENT_SETUP.md with the user instead, and stop there.

1. If `/Applications/LokalBot.app` is missing, run `brew install --cask stevyhacker/tap/lokalbot`. Never remove the quarantine attribute.
2. Use `CLI=/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli`. Run `$CLI setup start --wait 300` and tell the user to click Allow in LokalBot. Add `--meeting-library` or `--screen-memory` only if they want you to read those.
3. Run `$CLI setup plan` and talk through it with the user: automatic recording, calendar, notes language, Day Memory detail, dictation, autocomplete, and launch at login. Explain each setting listed in `notes.needsApproval` before asking for it. Use `$CLI config describe <key>` for the choices.
4. Save the agreed plan and run `$CLI setup apply plan.json --wait 300`. Tell the user one approval card is waiting for them in LokalBot.
5. Poll `$CLI models status` until `meetingReady` is true.
6. Run `$CLI permissions`. For each permission an enabled feature needs, run `$CLI permissions request <name>`, tell the user exactly what to click, and poll until it shows as granted. Run `$CLI restart` if macOS asks for one.
7. Run `$CLI setup finish`, then `$CLI doctor`, and report what is ready and anything left.

## Guardrails

- Exit code 4 means the user declined: don't ask again unless they say so. Code 5 means the request expired; ask before trying again.
- Never use `defaults write`, and never touch files in LokalBot's `control/` folder.
- Pass API keys only on standard input (`printf %s "$KEY" | $CLI secret set <name>`), and only when the user gives you one for that purpose.
- Change only what the user agreed to.
