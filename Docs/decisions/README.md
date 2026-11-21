# Decisions

Architecture decision records: the important, non-obvious decisions behind the
code, such as reasons, measured results, platform quirks, privacy boundaries and
invariants that someone changing the code would otherwise get wrong. Code
carries no comments ([ADR 0001](0001-code-carries-no-comments.md)), so a
decision like that is written here, in the ADR for its feature.

To find why a line is the way it is, open its feature's ADR and search for the
file or symbol: each decision ends with a `Where:` line. To record a decision,
add a `###` entry under the right topic that states the decision, gives the
reason and any numbers in a few sentences, and lists where it applies. A
decision that changes an earlier one replaces its entry. A new feature, or a
decision that cuts across features, gets the next free number. The
[`/delete-comment` skill](../../.claude/skills/delete-comment/SKILL.md) describes
the bar a decision has to clear.

| ADR | Feature | Decisions |
| --- | --- | ---: |
| [0001](0001-code-carries-no-comments.md) | Code carries no comments | — |
| [0002](0002-autocomplete.md) | Autocomplete | 101 |
| [0003](0003-dictation.md) | Dictation | 38 |
| [0004](0004-recording.md) | Recording | 48 |
| [0005](0005-transcription-and-speakers.md) | Transcription and speakers | 81 |
| [0006](0006-meetings-and-notes.md) | Meetings and notes | 57 |
| [0007](0007-meeting-detection-and-calendar-matching.md) | Meeting detection and calendar matching | 35 |
| [0008](0008-screen-memory.md) | Screen memory | 57 |
| [0009](0009-timeline-today-and-the-dream-review.md) | Timeline, Today and the Dream review | 48 |
| [0010](0010-ask-and-search.md) | Ask and search | 43 |
| [0011](0011-agent-mode.md) | Agent Mode | 58 |
| [0012](0012-models-and-inference.md) | Models and inference | 80 |
| [0013](0013-coding-agent-sessions.md) | Coding-agent sessions | 39 |
| [0014](0014-file-search.md) | File search | 22 |
| [0015](0015-people-personal-model-projects-and-actions.md) | People, personal model, projects and actions | 34 |
| [0016](0016-email-and-calendar-access.md) | Email and calendar access | 29 |
| [0017](0017-phone-and-tablet-companion-and-sync.md) | Phone and tablet companion and sync | 40 |
| [0018](0018-cli-mcp-and-app-control.md) | CLI, MCP and app control | 44 |
| [0019](0019-settings-onboarding-and-permissions.md) | Settings, onboarding and permissions | 22 |
| [0020](0020-app-shell-and-ui.md) | App shell and UI | 31 |
| [0021](0021-storage-sealing-and-retention.md) | Storage, sealing and retention | 63 |
| [0022](0022-platform-integration.md) | Platform integration | 45 |
| [0023](0023-updates-packaging-and-release.md) | Updates, packaging and release | 47 |
| [0024](0024-testing.md) | Testing | 24 |
