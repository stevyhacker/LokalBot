# Security Policy

## Supported versions

Security fixes are made for the latest published LokalBot release, which ships
the Mac app and the Windows and Linux app (alpha) under one version. Upgrade to
the newest release before reporting a problem that may already be fixed.

## Reporting a vulnerability

Please use GitHub's private vulnerability-reporting form:

https://github.com/stevyhacker/lokalbot/security/advisories/new

Include affected versions, impact, reproduction steps, and a minimal proof of
concept. Do not include real meeting data or credentials. If private reporting
is unavailable, open a public issue containing no exploit details and ask for a
private contact channel.

Please allow a reasonable remediation window before public disclosure. You can
expect an acknowledgement when the report is read, an initial severity
assessment, and coordinated release notes for a confirmed fix.

## Security boundaries

- On macOS, LokalBot is not sandboxed because macOS system-audio capture and its optional
  Accessibility features require capabilities that do not work in the App
  Sandbox. On Windows and Linux it runs with your user's permissions, like other
  desktop apps there.
- Windows release signing is transitioning onto Authenticode signing via [SignPath.io](https://signpath.io) with a certificate by the [SignPath Foundation](https://signpath.org) (`lokalbot.exe`, `lokalbot-cli.exe`, and `LokalBot-<version>-windows-x86_64-setup.exe` built in GitHub Actions; production signing requests are manually approved by `@stevyhacker`). Until a release is signed with the production certificate, download Windows binaries only from this repository's GitHub Releases and compare SHA-256 checksums on the release page. Automatic updates verify each archive's size, SHA-256, and Ed25519 release signature before installing it.
- Remote inference is optional. Approving a non-loopback endpoint permits it to
  receive the context needed for the requested feature.
- Agent Mode commands execute only after the configured approval policy allows
  them, but approved commands run with the current user's permissions.
- The external-agent CLI and MCP server can read the library and never change
  it. A separate switch, off by default, lets `lokalbot-cli` read and change
  LokalBot's settings in the running app; a change that widens what LokalBot
  captures or sends, and every API key, waits for approval in the app. On
  macOS, reading is gated by
  **Allow external agents to read your LokalBot data** in Settings → External Agents,
  with a separate grant for each box under it: meetings, screen memory, shared
  Personal Context, and Files. On Windows and Linux, each of the four has its
  own switch in Settings → Privacy & Data. Each grant lets trusted local processes read that
  data; the Files grant returns file paths and extracted text from the folders
  the user chose.
