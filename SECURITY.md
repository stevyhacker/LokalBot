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
- The Windows build is not code-signed yet. Download it only from this
  repository's GitHub Releases and compare the published `.sha256`. Automatic
  updates check each archive's size, SHA-256 and release signature before
  installing it.
- Remote inference is optional. Approving a non-loopback endpoint permits it to
  receive the context needed for the requested feature.
- Agent Mode commands execute only after the configured approval policy allows
  them, but approved commands run with the current user's permissions.
- The external-agent CLI/MCP surface is read-only and gated by the Agent Access
  setting; enabling it grants trusted local processes access to the library.
