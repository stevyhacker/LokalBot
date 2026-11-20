# 0001. Code carries no comments

- Status: Accepted
- Date: 2026-11-20

## Context

By November 2026 the code held 28,606 comment blocks, about 52,500 lines:
27,600 in the Swift of the Mac and phone apps, 22,400 in the Rust of the
Windows and Linux app, and the rest in Kotlin, JavaScript, shell and Python.
Most were written by coding agents, which keep a comment in step with the code
no better than a person does, and which take an existing comment as permission:
a comment that excuses a shortcut gets the shortcut copied into the next change.

Sorting every comment showed four kinds:

- **Tautologies** repeat what the declaration already says.
- **Stale comments** describe code or behaviour that has since changed.
- **Excuses** explain away a hack instead of fixing it.
- **Decision records** keep a reason, measurement, platform quirk, privacy
  boundary or invariant that the code cannot show.

Only the last kind was worth keeping, and a comment is a poor place for it. A
comment can't be found by area, isn't reviewed as a decision, and goes stale in
silence.

## Decision

Code carries no comments. What a comment would have said goes to one of three places:

- Code first: a clearer name, a named constant, a type, or a test that names the bug it guards.
- A decision record goes into the ADR for its area under `Docs/decisions/`,
  under the file and symbol it concerns.
- A known shortcut becomes a GitHub issue.

`Scripts/ci/comment-ratchet.py --check` runs in the Lint workflow. The files
that still had comments when this was decided are listed with their counts in
`Scripts/ci/comment-baseline.json`. A file may only lose comments, and the
baseline is lowered in the change that removes them. The `/delete-comment`
skill (`.claude/skills/delete-comment/SKILL.md`) is the process for that.

Tool directives are not comments: lint and formatter suppressions, shebangs,
`swift-tools-version`, PEP 723 script metadata, source map URLs, and license
and copyright notices. The AGPL notices on code ported from Cotabby stay, as
the license requires. So do the `///` doc comments that clap turns into
`lokalbot-cli --help` text.

The first pass classified every comment and deleted it: 10,046 tautologies and
23 stale comments went without a trace, 18,486 decision records (78% of the
comment lines) moved into ADRs 0002 to 0124, and 51 excuses became issue
drafts listed in the pull request that made this change. The baseline started
empty.

## Consequences

- Reading a non-obvious line means opening its area's ADR, found through the
  [index](README.md). Search the ADR for the symbol name.
- Changing a recorded decision means changing its ADR entry in the same pull request.
- Xcode's jump bar no longer shows `MARK:` sections.
- A rename or move carries its baseline count with
  `comment-ratchet.py --update --allow-increase`, which reviewers see in the
  baseline diff.
