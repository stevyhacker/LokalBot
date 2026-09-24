# Website (`web/`)

Static site served by Cloudflare Workers static assets at https://www.lokalbot.com — no build step. `wrangler.jsonc` at the **repo root** points the Worker at `web/` with `html_handling: auto-trailing-slash`, so pages are served extensionless (`/lokalbot-vs-granola`), and `not_found_handling: 404-page` serves `404.html`. Zone redirect rules, the canonical host, and the AI-crawler setting live in Cloudflare, not Wrangler; see [CLOUDFLARE.md](../CLOUDFLARE.md). Canonicals, sitemap entries, and inter-page links must use extensionless URLs; do not make crawlers follow `.html` redirects. `404.html` is served at any missing path, so its links and assets must be root-relative. Preview through a local HTTP server (`Scripts/serve-web.py`) rather than `file://`. Design system lives in `styles.css` (glass panels via `--glass-*` CSS vars, `.reveal` scroll animations); `app.js` is dependency-free and null-safe so any page can include it. New surface styles should be added to both the `prefers-reduced-transparency` and no-`backdrop-filter` fallback lists.

## Generated pages

`Scripts/render_web.py` renders the comparison pages (`lokalbot-vs-*.html`), the guides, `guides.html`, and `sitemap.xml` from `Scripts/*_pages.py`, `Scripts/*.template.html`, and the shared `Scripts/footer.partial.html`. Edit those sources, run `python3 Scripts/render_web.py`, and commit the output; never hand-edit the generated HTML. CI runs `python3 Scripts/render_web.py --check`. Every other page (`index`, `about`, `benchmarks`, `privacy`, `terms`, `support`, `enshittification-proof`, `404`) is hand-written; when you change one, bump its date in `STATIC_PAGES` or `REFERENCES` so the sitemap's `lastmod` stays accurate.

## SEO checklist for a new or changed page

- Unique `<title>` and meta description, an extensionless canonical, and Open Graph and Twitter tags with `og:site_name`, `og:image` dimensions that match the file, and the PNG `apple-touch-icon`.
- JSON-LD that describes only what the page visibly says. Reference the shared `https://www.lokalbot.com/#organization` and `#software` entities by `@id`; FAQ structured data must match the visible questions and answers.
- A visible "updated" or "verified" date whenever the page makes claims that can go stale, such as competitor pricing, model defaults, or benchmarks.
- A sitemap entry (generated pages get one automatically; add hand-written pages to `render_sitemap()`), and links to and from related pages, including the footer and `/guides`.
- Keep `llms.txt` in sync when adding or renaming a page or changing a headline product fact.
- Product facts must match the app and README: the default models, what is opt-in, and what the network is used for.
