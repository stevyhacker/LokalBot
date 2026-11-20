---
name: delete-comment
description: Remove code comments from LokalBot, or from one section of it, without losing what they knew. Tautologies and stale notes are deleted, excuses for hacky code become GitHub issue drafts, and decision records move into Docs/decisions/ ADRs; then the comment ratchet baseline is lowered. Use when asked to delete or clean up comments, when the "Comment ratchet" lint check fails, or before adding a comment to code.
---

# Delete comments

LokalBot code carries no comments ([ADR 0001](../../../Docs/decisions/0001-code-carries-no-comments.md)).
`Scripts/ci/comment-ratchet.py` enforces this. `Scripts/ci/comment-baseline.json`
lists the files that still have comments and how many comment lines each may
keep, and the Lint workflow's **Comment ratchet** job fails when a file goes
above its count. It also fails when a file goes below its count without the
baseline being lowered to match.

Tool directives are not comments, and the script never counts or deletes them:
lint and formatter suppressions (`swiftlint:`, `noqa`, `shellcheck`, `@ts-`…),
shebangs, `swift-tools-version`, PEP 723 script metadata, source map URLs,
license and copyright notices (the AGPL "Contains code ported from Cotabby"
headers must stay), and the `///` doc comments on clap-derived types in
`lokalbot-cli`, which are its `--help` text.

## When the check fails on new code

Don't raise the baseline. Put the comment's content where it belongs (below),
delete the comment, and push again. `--update --allow-increase` is only for a
file that was renamed or moved, so its existing count follows it. Reviewers see
the baseline change.

## Process

1. **List** the comments in scope:
   ```bash
   python3 Scripts/ci/comment-ratchet.py --list LokalBot/Dictation > /tmp/comments.jsonl
   python3 Scripts/ci/comment-ratchet.py --stats LokalBot/Dictation
   ```
   Each line is `{"path", "line", "end", "marker", "full_line", "text"}`. For
   more than a few hundred blocks, split the list by file and classify in
   parallel subagents. Give each one the rubric below and the files to read.

2. **Classify** each block. Read it in place, with its declaration and the code after it:
   - **Tautology:** a reader who sees the declaration and the next few lines
     learns nothing from it. Examples: a restated name or type, a paraphrased
     signature, a `MARK: - Helpers` header. → delete.
   - **Stale:** it names code, files, flags or behaviour that no longer exist
     or no longer match, or it is commented-out code. Confirm with `rg` before
     calling it stale. → delete.
   - **Excuse:** it explains away a workaround, hack, shortcut or known
     limitation in this code that has a better fix, for example "for now",
     "temporary", "TODO", "planned separately", or a sleep to dodge a race. →
     delete, and draft an issue. A constraint forced by an OS, API or
     third-party bug with no better fix is a decision record, not an excuse.
   - **Decision record:** a reason, rejected alternative, measurement, platform
     quirk, privacy or consent boundary, invariant, ordering or threading rule,
     unit, range or default, or something that must stay in step elsewhere
     (the Swift/Rust/Kotlin twin, a protocol doc, a Python seeder). It can also
     be the past bug a line prevents, or why a test exists. → move into an ADR.
   When torn between tautology and decision record, choose decision record.

3. **Move decision records** into `Docs/decisions/`. Find the ADR for the area
   in [Docs/decisions/README.md](../../../Docs/decisions/README.md). Add each
   record under its file heading, as a `####` title that states the decision,
   then the symbol in backticks, then the comment's wording without comment
   markers. A record that changes an earlier decision replaces that entry. Don't
   append a second one. A new area or a new cross-cutting decision gets the
   next free number. Copy the layout of an existing ADR (title, Status, Date,
   Context, Decisions, Consequences) and add a row to the README index.

4. **Draft issues for excuses.** Write one draft per hack: a title naming the
   fix, the file and symbol, the deleted comment, what is hacky, and what a
   proper fix would be. Related excuses for the same hack share one draft. Put
   the drafts in the pull request description. File them on GitHub only when
   the user says so.

5. **Delete** the classified blocks. Every category is deleted from the code:
   ```bash
   python3 Scripts/ci/comment-ratchet.py --delete /tmp/comments.jsonl
   ```
   The file needs only `path` and `line` per row. The script removes whole
   comment lines and cuts trailing comments back to the code. It drops blank
   lines left doubled, and skips anything that does not look like a comment.
   Look at any rows it reports as skipped.

6. **Verify.** Run the checks for each language touched:
   - Rust: `cd LinuxWindows && cargo fmt --all`. Deleting comments changes how
     rustfmt wraps code, and CI runs `cargo fmt --check`. Then build and test
     the touched crates.
   - Swift: build the scheme. A test or tool may read a source file, so run the
     unit tests for the area.
   - Python: `python3 -m py_compile`, then `python3 -m unittest discover -s Scripts/tests`.
   - Shell: `bash -n`. JavaScript and TypeScript: `node --check` or `bun build --no-bundle`.
   - Kotlin: the Companion Android build.
   - Some tests read source files (`LinuxWindows/scripts/tests/test_localizations.py`,
     `Scripts/ci/check-model-pins.py`, `include_str!("main.rs")` in `lokalbot-app`).
     If one depended on a comment, change the test, not the code, and list it
     under **Changed test expectations** in the pull request.

7. **Lower the baseline** and commit it with the deletions:
   ```bash
   python3 Scripts/ci/comment-ratchet.py --update
   python3 Scripts/ci/comment-ratchet.py --check
   ```

## Writing code without comments

Say it in code first: a precise name, a named constant, or a type that makes
the invalid state unrepresentable. A test can name the bug it guards. A
non-obvious decision goes in an ADR entry under the symbol it concerns. A known
shortcut goes in an issue.
