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
- **Decision records** keep an important, non-obvious decision: a reason,
  measured result, platform quirk, privacy boundary or cross-cutting invariant
  that someone changing the code would otherwise get wrong.

Only the last kind was worth keeping, and it was rare. A comment is also a poor
place for it: it can't be found by feature, isn't reviewed as a decision, and
goes stale in silence.

## Decision

Code carries no comments. What a comment would have said goes to one of three places:

- Code first: a clearer name, a named constant, a type, or a test that names the bug it guards.
- A decision record goes into the ADR for its feature under `Docs/decisions/`,
  written as a short decision with the files and symbols it concerns.
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

Every comment was classified and then deleted. 10,046 tautologies and 23 stale
comments went without a trace, and 51 excuses became issue drafts listed in the
pull request that made this change. A first pass took 18,486 comments for
decision records. A stricter second pass found that most of them only described
the code, and kept 1,770 (6% of all comments). Those were condensed into 1,083
decisions in ADRs 0002 to 0024, one per feature, with a decision that the Swift and Rust code
share written once. The baseline started empty.

## Consequences

- Reading a non-obvious line means opening its feature's ADR, found through the
  [index](README.md). Search the ADR for the file or symbol name.
- Changing a recorded decision means changing its ADR entry in the same pull request.
- Xcode's jump bar no longer shows `MARK:` sections.
- A rename or move carries its baseline count with
  `comment-ratchet.py --update --allow-increase`, which reviewers see in the
  baseline diff.
