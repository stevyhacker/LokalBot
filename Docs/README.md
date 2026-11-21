# Documentation map

The repository keeps public documentation focused on the product, its privacy
boundary, reproducible development workflows, and current release behavior.

- Root documents such as `README.md`, `PRIVACY.md`, `SECURITY.md`,
  `DEVELOPMENT.md` and `RELEASING.md` are the public source of truth.
- [`decisions/`](decisions/) holds the architecture decision records: why the
  code is the way it is, by area. Code carries no comments, so this is where a
  non-obvious decision is written; [`decisions/README.md`](decisions/README.md)
  is the index.
- [`development/`](development/) holds one page per topic of the development
  guide; [`DEVELOPMENT.md`](../DEVELOPMENT.md) is its index.
- [`releasing/`](releasing/) holds the one-time release setup and the channels
  beyond the Mac app (Linux and Windows, package repositories, Android,
  Homebrew, the MCP Registry); [`RELEASING.md`](../RELEASING.md) is the runbook.
- [`guides/`](guides/) describes repeatable work: the screenshot and demo-film
  kits, the AI assistants page's screenshots, Google OAuth verification, and the
  autocomplete parity checklist.
- [`explainers/`](explainers/) holds the sources of the release explainers the
  website serves.
- [`meta-hackathon/`](meta-hackathon/) is the historical Meta hackathon write-up
  and demo script referenced by the Muse Radar benchmark and test transport.
- `Video/lokalbot-promo/` is the canonical 16:9, 30-second promo source.
  Generated audio, fonts, snapshots, and renders stay ignored.

The dated files (`<name>-YYYY-MM-DD.md`) are sorted by kind:
[`designs/`](designs/) for active or referenced designs and RFCs,
[`plans/`](plans/) for in-progress implementation plans, and
[`reports/`](reports/) for current or benchmark-referenced reports. Once work
ships and its durable behavior is recorded in `Docs/development/` or
`PRIVACY.md`, delete the temporary plan or report rather than archiving it—git
history keeps the record without polluting agent context.

New launch copy, channel plans, and other private working notes go under the
repository's `Local/` folder, which git ignores, and must never contain
credentials.
