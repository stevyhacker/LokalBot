# LokalBot

LokalBot is a private work-memory app for macOS, with a Windows and Linux app (`LinuxWindows/`, Rust + GPUI) in alpha. Meetings are one input. Preserve local processing defaults, capture exclusions, retention behavior, and separate consent boundaries for meeting-library access, screen memory, remote inference origins, and Agent Mode actions. [PRIVACY.md](PRIVACY.md) defines the data and network contract.

## Working agreements

- Complete the requested scope through relevant verification and correction of failures caused by the change. Reuse authorization already given; ask when a material decision or action exceeds that scope. Keep reviews and audits read-only unless implementation is requested.
- Open pull requests as drafts while still pushing fixes, and mark them ready for review when complete. The required UI suite (about an hour of macOS runner time) runs only on pull requests that are ready for review.
- Preserve unrelated work. When committing is authorized, stage only task files. Publication, releases, and production changes require authorization covering those actions.
- Run checks relevant to the change and required by the repository. Repeat or broaden them when new changes, failures, or unresolved risks justify it. Documentation-only edits need link and diff checks, not an app build.
- Never run UI tests locally on this MacBook. Use hosted CI or a remote runner; `Scripts/ui-tests.sh --remote` is the explicit remote entry point. Local compilation and non-UI tests are allowed. Verify the tested revision includes the requested changes.
- When a change alters what an existing test expects, list it under the pull request template's **Changed test expectations** with the reason.
- When fixing a bug that reached users, add the check that would have caught it — a capture replay trace, a model scenario, a day-in-the-life assertion, or an upgrade check — and confirm it fails with the fix undone. See the Testing section of [DEVELOPMENT.md](DEVELOPMENT.md).
- When asked to reinstall the installed app, use `Scripts/reinstall-preserve-permissions.sh`. Preserve its identity and permissions; do not use a delete-first installation.
- `project.yml` owns the generated Xcode project. Run `xcodegen generate` after changing project configuration or adding/removing source files. Preserve dependency pins unless the task calls for an update or a verified incompatibility blocks it.

## References by task

Read the relevant sections when the task touches them:

- Build, schemes, CLI packaging, runtime, or tests: [DEVELOPMENT.md](DEVELOPMENT.md).
- Capture, retention, or data leaving the computer: [PRIVACY.md](PRIVACY.md).
- The Windows and Linux app: [LinuxWindows/README.md](LinuxWindows/README.md).
- Signing, release artifacts, or publication: [RELEASING.md](RELEASING.md).
- Website changes: [web/CLAUDE.md](web/CLAUDE.md).
- Video work: [Video/AGENTS.md](Video/AGENTS.md) and the selected project's guide.
- Retrieving recorded work through the CLI or MCP: [.agents/skills/lokalbot-cli/SKILL.md](.agents/skills/lokalbot-cli/SKILL.md).

Report whether the requested result was built, tested, installed, or released, with any concrete blocker and remaining work. A successful build or CI run alone does not establish installation or release completion.
