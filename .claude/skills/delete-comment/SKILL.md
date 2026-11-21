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
   - **Decision record:** an important, non-obvious decision. Keep it only if
     all three hold:
     1. It records a choice between real alternatives with its reason, a
        measured result that drove a choice, an OS, API or library quirk and how
        the code copes, a privacy, consent or security boundary, or an invariant
        that spans files, processes, platforms or a protocol.
     2. Someone changing the code, reading only the code and its tests, would
        likely get it wrong without it.
     3. Getting it wrong costs something real: a user-facing bug, data loss, a
        leak, a crash or hang, broken platform support, a measured regression,
        or a repeated investigation.
     → move into an ADR.
   Everything else is a tautology, even when it adds a little: what something
   is or returns, units and defaults, who calls it, UI wording and layout,
   history, a test restating its assertion. Expect about one comment in ten to
   be a decision record; the first full pass kept 12%.

3. **Move decision records** into `Docs/decisions/`, one ADR per feature (the
   [index](../../../Docs/decisions/README.md) lists them). Write each as a short
   decision, not the comment verbatim: a `###` heading that states it, one to
   four sentences with the reason and any numbers, versions or dates from the
   comment, then a `Where:` line with the files and symbols. A decision the
   Swift and Rust code share is written once with both locations. One that
   changes an earlier decision replaces its entry. A new feature or a decision
   that cuts across features gets the next free number; copy an existing ADR's
   layout (Status, Date, Context, Decisions, Consequences) and add it to the index.

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
