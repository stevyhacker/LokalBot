# Cloudflare deployment

The website can be deployed as Cloudflare Workers static assets using `wrangler.jsonc`.

- Repository: `stevyhacker/lokalbot`, production branch: `master`.
- Build command: leave empty; `web/` contains the deployable site.
- Deploy command: `npx wrangler@4.131.2 deploy`.
- Custom domains: `www.lokalbot.com` and `lokalbot.com`.
- The apex redirects to `www` using a Cloudflare zone Redirect Rule.
  `cloudflare/redirect-rules.json` records the exact HTTP 308 rule, which preserves
  the path and query string. Zone rules are managed separately from Wrangler.
- Extensionless article URLs are preserved. Workers `_redirects` files cannot
  match a source hostname, so the canonical redirect belongs in the zone rules.
- `.assetsignore` excludes Markdown instructions from public assets.
- No runtime secret is needed; downloads remain on GitHub Releases.

Before switching DNS, verify the Workers URL, article links, CSS, JavaScript,
video range requests and the download link. Keep the Vercel project available
until the custom domains pass the same checks.

Back up and remove only conflicting website A/CNAME records before attaching the
custom domains declared in Wrangler. Preserve mail and TXT records. Enable the
canonical rule after Cloudflare manages the proxied website DNS.

## Redirect rules

`cloudflare/redirect-rules.json` is the full, ordered list of zone Single
Redirect rules. Cloudflare stops at the first matching rule, so keep this order:

1. `/index.html` → `/`
2. `/page.html` → `/page` (except `/404.html`)
3. `/page/` → `/page`
4. `lokalbot.com` → `www.lokalbot.com`

Rules 1–3 target `www` directly, so an apex `.html` URL takes one hop. Without
them, the Worker's `html_handling` still strips `.html` and trailing slashes, but
with a temporary 307. Crawlers treat a 307 as temporary and may keep the old URL,
so the zone rules make these redirects permanent (308).

Zone rules are not deployed by Wrangler. Apply them in the dashboard under
**Rules → Redirect Rules** in the order above, or replace the whole phase with
the API. This call overwrites every existing redirect rule in the zone:

```bash
jq '{rules: .}' cloudflare/redirect-rules.json | curl -sS -X PUT \
  "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/rulesets/phases/http_request_dynamic_redirect/entrypoint" \
  -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" --data @-
```

Check the result:

```bash
curl -sI https://www.lokalbot.com/privacy.html | grep -iE '^(HTTP|location)'
```

Expect `308` and `location: https://www.lokalbot.com/privacy`.

## AI crawlers

`web/robots.txt` allows every crawler. On 2026-09-24 the zone still returned
HTTP 403 to `GPTBot`, `ClaudeBot`, and `CCBot` because Cloudflare's **Block AI
bots** setting was on. `PerplexityBot`, `OAI-SearchBot`, and Googlebot got 200.
Blocking those crawlers keeps LokalBot's pages out of the data that AI assistants
use to answer "what's a private meeting-notes app for Mac?", so it works against
the site's purpose.

To allow them, open the `lokalbot.com` zone in the Cloudflare dashboard:

1. Go to **AI Crawl Control** (older dashboards: **Security → Bots**) and set
   **Block AI bots** to allow, or allow each blocked crawler individually.
2. Turn off Cloudflare's managed `robots.txt` for AI bots, if it is on, so the
   repository's `web/robots.txt` stays the only policy.

Verify with a crawler user agent (expect `200`):

```bash
curl -s -o /dev/null -w '%{http_code}\n' -A 'Mozilla/5.0 (compatible; GPTBot/1.2; +https://openai.com/gptbot)' https://www.lokalbot.com/
```

## IndexNow

`web/<key>.txt` publishes the site's IndexNow key. After a deploy that adds or
changes pages, run `python3 Scripts/indexnow.py` to notify Bing and the other
IndexNow engines, or pass paths such as `about benchmarks` to submit only those.
Use `--dry-run` to see the request first. Keep exactly one key file in `web/`.
