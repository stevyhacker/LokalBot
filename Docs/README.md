# Documentation map

The repository keeps public documentation focused on the product, its privacy
boundary, reproducible development workflows, and current release behavior.

- Root documents such as `README.md`, `PRIVACY.md`, `SECURITY.md`,
  `DEVELOPMENT.md` and `RELEASING.md` are the public source of truth.
- [`development/`](development/) holds one page per topic of the development
  guide; [`DEVELOPMENT.md`](../DEVELOPMENT.md) is its index.
- [`releasing/`](releasing/) holds the one-time release setup and the channels
  beyond the Mac app (Linux and Windows, package repositories, Android,
  Homebrew, the MCP Registry); [`RELEASING.md`](../RELEASING.md) is the runbook.
- [`product-roadmap.md`](product-roadmap.md) records direction, not dated
  promises. Its status line says when it was last refreshed.
- [`guides/`](guides/) describes repeatable work: the screenshot and demo-film
  kits, the AI assistants page's screenshots, Google OAuth verification, and the
  autocomplete parity checklist.
- [`explainers/`](explainers/) holds the sources of the release explainers the
  website serves.
- [`meta-hackathon/`](meta-hackathon/) is the Meta hackathon write-up, demo
  script and recording checklist.
- [`ci/`](ci/) records CI benchmark measurements.
- `Video/lokalbot-promo/` is the canonical 16:9, 30-second promo source.
  Generated audio, fonts, snapshots, and renders stay ignored.

The dated files (`<name>-YYYY-MM-DD.md`) are sorted by kind:
[`designs/`](designs/) for designs and RFCs, [`plans/`](plans/) for
implementation plans, and [`reports/`](reports/) for validations, measurements,
fixes and dependency updates. Each records a decision or a measurement as of its
date, and a plan's status line says whether the work was built; none is kept
current, so check the code and the root documents before relying on one.
[`archive/`](archive/) keeps earlier working files, such as the August
distribution kit and the June–July agent plans.

New launch copy, channel plans, and other private working notes go under the
repository's `Local/` folder, which git ignores, and must never contain
credentials.
