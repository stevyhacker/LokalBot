# Documentation map

The repository keeps public documentation focused on the product, its privacy
boundary, reproducible development workflows, and current release behavior.

- Root documents such as `README.md`, `PRIVACY.md`, `SECURITY.md`, and
  `RELEASING.md` are the public source of truth.
- `Docs/product-roadmap.md` records direction, not dated promises. Its status
  line says when it was last refreshed.
- `Docs/screenshot-kit.md` and `Docs/demo-film-kit.md` describe reproducible
  public-media capture. `Docs/best-ai-assistants-screenshots.md` covers the
  other apps' screenshots on the AI assistants comparison page.
- `Video/lokalbot-promo/` is the canonical 16:9, 30-second promo source.
  Generated audio, fonts, snapshots, and renders stay ignored.

Most other files here are dated plans, designs, and reports
(`<name>-YYYY-MM-DD.md`). Each records a decision or a measurement as of its
date, and a plan's status line says whether the work was built; none is kept
current, so check the code and the root documents before relying on one. A few
earlier working files are tracked as well, such as the August distribution kit
and the autocomplete parity checklist.

New launch copy, channel plans, and other private working notes go under
`Docs/local/`, which git ignores, and must never contain credentials. The
older private drafts that `.gitignore` names one by one stay untracked.
