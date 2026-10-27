# Setting up LokalBot as an agent

This guide is for AI agents (Claude Code, Codex, and others) that install and
set up [LokalBot](README.md) for the person they work for. Every step runs in
the terminal. The person still makes the choices that need them, in LokalBot:
they allow access, approve changes to what LokalBot captures or shares, and
grant macOS permissions.

The journey below is for the Mac app. The Windows and Linux app (alpha) has no
agent-driven setup yet; see [Windows and Linux](#windows-and-linux-alpha).

## Rules

- **Install safely.** Install with Homebrew or the notarized DMG. Never remove
  the quarantine attribute or otherwise get around Gatekeeper.
- **Use only `setup start` to get access.** Never write LokalBot's preferences
  with `defaults write`, and never create or edit files in its `control/`
  folder.
- **Ask first.** Ask the person before you request read access or a change to
  what LokalBot captures, reads, records, or sends. The approval card should
  confirm choices you already talked about.
- **Accept a no.** Never resend a declined request unless the person asks.
- **Never handle API keys in the open.** Pass them on standard input
  (`secret set`), never as arguments, and never ask to read one back.
- **Check, don't assume.** Run `doctor` to confirm a step worked.

## The journey

```bash
# 1. Install
brew install --cask stevyhacker/tap/lokalbot
CLI=/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli

# 2. Ask for access. LokalBot opens a request window; the person clicks Allow.
#    Add --meeting-library or --screen-memory only if the person wants you to
#    read those too. They appear as separate boxes, off by default.
$CLI setup start --wait 300

# 3. Agree a plan with the person, then apply it.
$CLI setup plan > plan.json      # current values and the model preset suited to this Mac
#    Edit plan.json with the person's answers. "notes.needsApproval" lists the
#    settings whose change needs their approval; `config describe <key>` shows
#    each one's choices.
$CLI setup apply plan.json --wait 300   # preferences apply now; consent changes go to one approval card

# 4. Models download in the background.
$CLI models status               # poll until "meetingReady" is true

# 5. Permissions: the person clicks, you guide and check.
$CLI permissions                 # each permission, whether it is granted, and what needs it
$CLI permissions request microphone
$CLI permissions request accessibility   # opens System Settings with LokalBot's guidance
$CLI restart                     # when macOS asks after Accessibility or Input Monitoring

# 6. Finish and verify.
$CLI setup finish                # closes onboarding; LokalBot runs in the menu bar from now on
$CLI doctor                      # exits 0 when everything the person turned on is ready
```

## Exit codes

Commands that wait for the person (`setup start`, `setup apply`, `config set`,
`config request`, `secret set`) exit with:

| Code | Meaning |
| --- | --- |
| 0 | Done, or approved |
| 3 | Still waiting for the person |
| 4 | The person declined. Don't ask again unless they say so |
| 5 | Nobody answered before the request expired (five minutes) |

Other errors exit 1 with a `[code]` message. For example, `[settings_access_disabled]`
means the person has not allowed access yet; run `setup start`.

## What the person does

1. **Gatekeeper.** The first-open confirmation, if macOS shows one.
2. **Access.** One Allow in LokalBot for `setup start`.
3. **Consent review.** One card for the consent changes in the plan, such as
   capture level, calendar, automatic recording, or a remote server.
4. **macOS permissions.** Allow in the Microphone and Calendar prompts, and
   turn on Accessibility, Screen Recording, or Input Monitoring in System
   Settings when the features they chose need them.

## More

- `lokalbot-cli --help` and `lokalbot-cli <command> --help` describe every command.
- [The bundled skill](.agents/skills/lokalbot-cli/SKILL.md) covers everyday use
  after setup.
- [PRIVACY.md](PRIVACY.md) explains what each access grants.

## Windows and Linux (alpha)

The Windows and Linux CLI has the read-only commands and the MCP server, but not
`setup`, `config`, `secret`, `models`, `permissions`, `status`, `doctor`, `restart`, or
`open`. The person sets LokalBot up in the app, and you help:

1. **Install.** From the [latest release](https://github.com/stevyhacker/lokalbot/releases/latest),
   take `LokalBot-<version>-linux-x86_64.tar.gz`, extract it, and run `./install.sh`
   (Linux; the `.deb`, `.rpm` and Arch packages need the person's `sudo`), or have the person run `LokalBot-<version>-windows-x86_64-setup.exe`, which installs for
   their user without administrator rights (Windows; a portable zip is there too). The Windows build isn't code-signed yet, so
   SmartScreen asks first; the person confirms it. Never unblock the file or turn
   SmartScreen off for them.
2. **Onboarding.** The person chooses what LokalBot remembers and which models to
   download, in the app.
3. **Access.** If the person wants you to read their library, they turn on "Allow
   external agents to read your meeting library" in Settings → Privacy & Data, and
   screen memory separately. Never create LokalBot's `control/` files yourself.
4. **CLI and skill.** Run `lokalbot-cli install-skill`, or have the person click
   **Install for your coding agent…** in Settings → Advanced → Agent CLI. The CLI goes
   to `~/.local/bin` on Linux and `%LOCALAPPDATA%\Programs\LokalBot\bin` on Windows;
   [the Windows and Linux README](LinuxWindows/README.md#coding-agents) shows how to add
   it to PATH.
5. **Check.** `lokalbot-cli brief` shows which sources are on.
