# Safe local routines

Part of the [development guide](../../DEVELOPMENT.md).

- **Curated jobs:** post-meeting follow-up, daily stand-up, weekly work log, unfinished-action rollup, and local journal. Each renderer has a fixed local read scope and accepts no arbitrary prompt, shell command, or network action.
- **Scheduling:** event-driven follow-ups run after processing; daily and weekly jobs catch up after wake. Meeting recording, dictation, cotyping generation, and the meeting pipeline take priority. Fixed calendar scopes and fingerprints of prepared output make corrections, completion, deletion, and reverted edits new durable revisions. Unchanged successful or failed revisions are terminal across relaunch; invalidation cancels stale work. Preparation and writing each have a 30-second bound.
- **Writes:** Markdown goes only under a user-selected destination with `0700` folders and `0600` files. Routines and daily exports share hash-sidecar ownership checks: unchanged output is idempotent, changed generated output is replaced only while its stored hash matches, and user edits or unrelated files are preserved. Legacy files without a sidecar can be adopted only when their bytes already equal the new output. Deterministic secret redaction is applied again before writing.
