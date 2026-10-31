#!/usr/bin/env python3
"""Render LokalBot's comparison pages, guides, blog, and sitemap, and the home page's latest posts.

Generated HTML stays checked in under web/. Hosting remains fully static and
nothing runs at deploy time.

To change a page:
1. edit the relevant *_pages.py or blog_posts.py content or *.template.html markup
   (footer.partial.html is shared by every generated page)
2. run `python3 Scripts/render_web.py`
3. commit the regenerated files under web/

Usage:
    python3 Scripts/render_web.py            # render into web/
    python3 Scripts/render_web.py --check    # verify web/ is up to date (CI)
"""

from __future__ import annotations

import argparse
import html
import json
import re
import sys
import textwrap
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from comparison_pages import LOKALBOT_UPDATED, PAGES, VERIFIED  # noqa: E402
from guide_pages import GUIDES, GUIDES_INDEX, REFERENCES  # noqa: E402
from blog_posts import BLOG_INDEX, POSTS  # noqa: E402

TOKEN_OPEN = "{{"

CHECK_ICON = '<i class="ph ph-check" aria-hidden="true"></i>'

SITE = "https://www.lokalbot.com"
OG_IMAGE = f"{SITE}/assets/og-image.png"
BLOG_ID = f"{SITE}/blog#blog"
# Publish date of the original guides; a guide added later sets "published".
GUIDES_PUBLISHED = "2026-07-13"

# Defined in full by the home page's structured data; other pages reference
# the same @id so search engines merge them into one entity.
ORGANIZATION = {
    "@type": "Organization",
    "@id": f"{SITE}/#organization",
    "name": "LokalBot project",
    "url": f"{SITE}/",
}

# Hand-written pages outside the generator, with the date each last changed.
# Bump a date when you edit that page so the sitemap's lastmod stays honest.
STATIC_PAGES = {
    "": "2026-10-29",
    "privacy": "2026-10-30",
    "terms": "2026-10-26",
    "support": "2026-10-26",
    "enshittification-proof": "2026-10-26",
}


def repo_root() -> Path:
    """Repo root, derived from this script's location under Scripts/."""

    return Path(__file__).resolve().parent.parent


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Render LokalBot's static SEO pages.")
    parser.add_argument(
        "--check",
        action="store_true",
        help="Verify the checked-in HTML matches the template + data without writing.",
    )
    return parser.parse_args()


def long_date(iso: str) -> str:
    day = date.fromisoformat(iso)
    return f"{day:%B} {day.day}, {day.year}"


def month_year(iso: str) -> str:
    return f"{date.fromisoformat(iso):%B %Y}"


def plain_text(fragment: str) -> str:
    """Strip tags and entities from an HTML fragment for structured data."""

    text = html.unescape(re.sub(r"<[^>]+>", "", fragment))
    return re.sub(r"\s+", " ", text).strip()


def json_ld(graph: list[dict]) -> str:
    data = {"@context": "https://schema.org", "@graph": graph}
    # A literal "</" would close the surrounding <script> element early.
    return json.dumps(data, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")


def breadcrumb_list(items: list[tuple[str, str]]) -> dict:
    return {
        "@type": "BreadcrumbList",
        "itemListElement": [
            {"@type": "ListItem", "position": position, "name": name, "item": url}
            for position, (name, url) in enumerate(items, start=1)
        ],
    }


def faq_page(entries: list[tuple[str, str]], url: str) -> dict:
    return {
        "@type": "FAQPage",
        "@id": f"{url}#faq",
        "mainEntity": [
            {
                "@type": "Question",
                "name": plain_text(question),
                "acceptedAnswer": {"@type": "Answer", "text": plain_text(answer)},
            }
            for question, answer in entries
        ],
    }


def fill_template(template: str, replacements: dict[str, str], label: str) -> str:
    rendered = template
    for token, value in replacements.items():
        if token not in rendered:
            raise SystemExit(f"{label} template is missing the {token} placeholder.")
        rendered = rendered.replace(token, value)
    if TOKEN_OPEN in rendered:
        line = next(line for line in rendered.splitlines() if TOKEN_OPEN in line)
        raise SystemExit(f"Unreplaced placeholder in {label.lower()} output: {line.strip()}")
    return rendered


def render_footer(partial: str) -> str:
    """The shared footer, with a Compare link for every comparison page."""

    # Root-relative, because blog posts are served one level down at /blog/<slug>.
    links = "\n".join(
        f'      <a href="/{page["slug"]}">{page["h1"].removeprefix("LokalBot ")}</a>'
        for page in PAGES
    )
    return fill_template(partial, {"{{COMPARE_LINKS}}": links}, "Footer").rstrip("\n")


def render_table_rows(rows: list[tuple[str, str, str]]) -> str:
    parts = []
    for feature, lokal, competitor in rows:
        parts.append(
            "            <tr>\n"
            f'              <th scope="row">{feature}</th>\n'
            f"              <td>{lokal}</td>\n"
            f"              <td>{competitor}</td>\n"
            "            </tr>"
        )
    return "\n".join(parts)


def render_pick_items(items: list[str]) -> str:
    return "\n".join(f"            <li>{CHECK_ICON} {item}</li>" for item in items)


def render_faq_items(entries: list[tuple[str, str]]) -> str:
    parts = []
    for question, answer in entries:
        parts.append(
            '        <details class="qa">\n'
            f'          <summary>{question}<i class="ph ph-plus" aria-hidden="true"></i></summary>\n'
            f"          <p>{answer}</p>\n"
            "        </details>"
        )
    return "\n".join(parts)


def render_more_links(page: dict) -> str:
    """Links to every other comparison page, in PAGES order."""

    return "\n".join(
        f'        <a href="{other["slug"]}">{other["h1"]}</a>'
        for other in PAGES
        if other["slug"] != page["slug"]
    )


def verified(page: dict) -> str:
    """When this page's competitor details were last checked."""

    return page.get("verified", VERIFIED)


def modified(page: dict) -> str:
    """When anything on this page last changed: its competitor details or LokalBot's own facts."""

    return max(verified(page), LOKALBOT_UPDATED)


def guide_by_slug(slug: str) -> dict:
    try:
        return next(guide for guide in GUIDES if guide["slug"] == slug)
    except StopIteration as error:
        raise SystemExit(f"Unknown related guide slug: {slug}") from error


def render_related_links(page: dict) -> str:
    cards = []
    for slug in page["related"]:
        related = guide_by_slug(slug)
        cards.append(
            f'        <a class="guide-card" href="{related["slug"]}">\n'
            f'          <span class="guide-card__eyebrow">{related["eyebrow"]}</span>\n'
            f'          <strong>{related["h1"]}</strong>\n'
            f'          <span>{related["description"]}</span>\n'
            '        </a>'
        )
    return "\n".join(cards)


def search_terms(page: dict) -> str:
    """Page title and FAQ questions the /guides filter matches beyond the card's visible text."""

    terms = " ".join([page.get("title", "")] + [plain_text(question) for question, _ in page.get("faq", [])]).strip()
    return f' data-terms="{html.escape(terms, quote=True)}"' if terms else ""


def render_guide_cards(kind: str) -> str:
    return "\n".join(
        f'        <a class="guide-card" href="{guide["slug"]}"{search_terms(guide)}>\n'
        f'          <span class="guide-card__eyebrow">{guide["eyebrow"]}</span>\n'
        f'          <strong>{guide["h1"]}</strong>\n'
        f'          <span>{guide["description"]}</span>\n'
        f'          <span class="guide-card__meta">{guide["read_time"]}</span>\n'
        "        </a>"
        for guide in GUIDES
        if guide.get("kind", "guide") == kind
    )


def render_compact_cards(cards: list[tuple[str, str, str, str, str]]) -> str:
    """(slug, eyebrow, heading, description, terms) cards for the /guides sections."""

    return "\n".join(
        f'        <a class="guide-card" href="{slug}"{terms}>\n'
        f'          <span class="guide-card__eyebrow">{eyebrow}</span>\n'
        f"          <strong>{heading}</strong>\n"
        f"          <span>{description}</span>\n"
        "        </a>"
        for slug, eyebrow, heading, description, terms in cards
    )


def guide_structured_data(page: dict) -> str:
    url = f"{SITE}/{page['slug']}"
    return json_ld(
        [
            {
                "@type": "Article",
                "headline": page["h1"],
                "description": page["description"],
                "datePublished": page.get("published", GUIDES_PUBLISHED),
                "dateModified": page.get("updated", GUIDES_PUBLISHED),
                "mainEntityOfPage": url,
                "image": OG_IMAGE,
                "author": ORGANIZATION,
                "publisher": ORGANIZATION,
            },
            breadcrumb_list([("Home", f"{SITE}/"), ("Guides", f"{SITE}/guides"), (page["h1"], url)]),
            faq_page(page["faq"], url),
        ]
    )


def comparison_structured_data(page: dict) -> str:
    url = f"{SITE}/{page['slug']}"
    return json_ld(
        [
            {
                "@type": "Article",
                "headline": page["h1"],
                "description": page["description"],
                "datePublished": page["published"],
                "dateModified": modified(page),
                "mainEntityOfPage": url,
                "image": OG_IMAGE,
                "author": ORGANIZATION,
                "publisher": ORGANIZATION,
                "about": [
                    {
                        "@type": "SoftwareApplication",
                        "@id": f"{SITE}/#software",
                        "name": "LokalBot",
                        "url": f"{SITE}/",
                        "applicationCategory": "BusinessApplication",
                        "operatingSystem": "macOS 15+, Windows 10+, Linux",
                    },
                    {"@type": "SoftwareApplication", "name": page["competitor_name"]},
                ],
            },
            breadcrumb_list([("Home", f"{SITE}/"), ("Guides", f"{SITE}/guides"), (page["h1"], url)]),
            faq_page(page["faq"], url),
        ]
    )


def guides_index_updated() -> str:
    return max(
        [modified(page) for page in PAGES]
        + [guide.get("updated", GUIDES_PUBLISHED) for guide in GUIDES]
        + [reference["updated"] for reference in REFERENCES]
    )


def guides_index_structured_data() -> str:
    url = f"{SITE}/guides"
    # Same order as the page: Questions, Guides, Compare, Reference.
    listed = (
        [(guide["slug"], guide["h1"]) for guide in GUIDES if guide.get("kind") == "question"]
        + [(guide["slug"], guide["h1"]) for guide in GUIDES if guide.get("kind", "guide") == "guide"]
        + [(page["slug"], page["h1"]) for page in PAGES]
        + [(reference["slug"], reference["h1"]) for reference in REFERENCES]
    )
    return json_ld(
        [
            {
                "@type": "CollectionPage",
                "@id": f"{url}#page",
                "url": url,
                "name": GUIDES_INDEX["title"],
                "description": GUIDES_INDEX["description"],
                "dateModified": guides_index_updated(),
                "isPartOf": {"@id": f"{SITE}/#website"},
                "publisher": {"@id": ORGANIZATION["@id"]},
                "mainEntity": {
                    "@type": "ItemList",
                    "numberOfItems": len(listed),
                    "itemListElement": [
                        {"@type": "ListItem", "position": position, "url": f"{SITE}/{slug}", "name": name}
                        for position, (slug, name) in enumerate(listed, start=1)
                    ],
                },
            },
            breadcrumb_list([("Home", f"{SITE}/"), ("Guides", url)]),
        ]
    )


def render_guide_page(template: str, page: dict, footer: str) -> str:
    replacements = {
        "{{SLUG}}": page["slug"],
        "{{TITLE}}": page["title"],
        "{{META_DESCRIPTION}}": page["description"],
        "{{EYEBROW}}": page["eyebrow"],
        "{{H1}}": page["h1"],
        "{{LEAD}}": page["lead"],
        "{{READ_TIME}}": page["read_time"],
        "{{UPDATED_DATE}}": page.get("updated", GUIDES_PUBLISHED),
        "{{UPDATED_LABEL}}": page.get("updated_label", long_date(GUIDES_PUBLISHED)),
        "{{BODY}}": page["body"].strip(),
        "{{FAQ_ITEMS}}": render_faq_items(page["faq"]),
        "{{RELATED_LINKS}}": render_related_links(page),
        "{{STRUCTURED_DATA}}": guide_structured_data(page),
        "{{FOOTER}}": footer,
    }
    return fill_template(template, replacements, "Guide")


def render_guides_index(template: str, footer: str) -> str:
    replacements = {
        "{{TITLE}}": GUIDES_INDEX["title"],
        "{{META_DESCRIPTION}}": GUIDES_INDEX["description"],
        "{{STRUCTURED_DATA}}": guides_index_structured_data(),
        "{{QUESTION_CARDS}}": render_guide_cards("question"),
        "{{GUIDE_CARDS}}": render_guide_cards("guide"),
        "{{COMPARE_CARDS}}": render_compact_cards(
            [(page["slug"], "Compare", page["h1"], page["description"], search_terms(page)) for page in PAGES]
        ),
        "{{REFERENCE_CARDS}}": render_compact_cards(
            [(ref["slug"], ref["eyebrow"], ref["h1"], ref["description"], "") for ref in REFERENCES]
        ),
        "{{FOOTER}}": footer,
    }
    return fill_template(template, replacements, "Guides")


def post_updated(post: dict) -> str:
    return post.get("updated", post["published"])


def blog_updated() -> str:
    return max(post_updated(post) for post in POSTS)


def post_byline(post: dict) -> str:
    parts = [f'<time datetime="{post["published"]}">{long_date(post["published"])}</time>']
    if post_updated(post) != post["published"]:
        parts.append(f'Updated <time datetime="{post_updated(post)}">{long_date(post_updated(post))}</time>')
    parts.append(post["read_time"])
    return " · ".join(parts)


def render_post_cards(posts: list[dict]) -> str:
    return "\n".join(
        f'        <a class="guide-card blog-card" href="/blog/{post["slug"]}">\n'
        f'          <span class="guide-card__eyebrow"><time datetime="{post["published"]}">{long_date(post["published"])}</time> · {post["eyebrow"]}</span>\n'
        f'          <strong>{post["h1"]}</strong>\n'
        f'          <span>{post["description"]}</span>\n'
        f'          <span class="guide-card__meta">{post["read_time"]}</span>\n'
        "        </a>"
        for post in posts
    )


def blog_posting(post: dict) -> dict:
    url = f"{SITE}/blog/{post['slug']}"
    return {
        "@type": "BlogPosting",
        "@id": f"{url}#post",
        "headline": post["h1"],
        "description": post["description"],
        "datePublished": post["published"],
        "dateModified": post_updated(post),
        "url": url,
        "mainEntityOfPage": url,
        "image": f"{SITE}/assets/blog/og/{post['slug']}.png",
        "author": ORGANIZATION,
        "publisher": ORGANIZATION,
        "isPartOf": {"@id": BLOG_ID},
    }


def post_structured_data(post: dict) -> str:
    url = f"{SITE}/blog/{post['slug']}"
    return json_ld(
        [
            blog_posting(post),
            breadcrumb_list([("Home", f"{SITE}/"), ("Blog", f"{SITE}/blog"), (post["h1"], url)]),
        ]
    )


def blog_index_structured_data() -> str:
    url = f"{SITE}/blog"
    return json_ld(
        [
            {
                "@type": "Blog",
                "@id": BLOG_ID,
                "url": url,
                "name": "LokalBot Blog",
                "description": BLOG_INDEX["description"],
                "dateModified": blog_updated(),
                "isPartOf": {"@id": f"{SITE}/#website"},
                "publisher": {"@id": ORGANIZATION["@id"]},
                "blogPost": [
                    {
                        "@type": "BlogPosting",
                        "headline": post["h1"],
                        "url": f"{SITE}/blog/{post['slug']}",
                        "datePublished": post["published"],
                    }
                    for post in POSTS
                ],
            },
            breadcrumb_list([("Home", f"{SITE}/"), ("Blog", url)]),
        ]
    )


def render_blog_index(template: str, footer: str) -> str:
    replacements = {
        "{{TITLE}}": BLOG_INDEX["title"],
        "{{META_DESCRIPTION}}": BLOG_INDEX["description"],
        "{{STRUCTURED_DATA}}": blog_index_structured_data(),
        "{{H1}}": BLOG_INDEX["h1"],
        "{{LEAD}}": BLOG_INDEX["lead"],
        "{{POST_CARDS}}": render_post_cards(POSTS),
        "{{FOOTER}}": footer,
    }
    return fill_template(template, replacements, "Blog")


def render_blog_post(template: str, post: dict, footer: str) -> str:
    others = [other for other in POSTS if other["slug"] != post["slug"]][:3]
    replacements = {
        "{{SLUG}}": post["slug"],
        "{{TITLE}}": f"{post['title']} — LokalBot Blog",
        "{{META_DESCRIPTION}}": post["description"],
        "{{PUBLISHED_DATE}}": post["published"],
        "{{UPDATED_DATE}}": post_updated(post),
        "{{EYEBROW}}": post["eyebrow"],
        "{{H1}}": post["h1"],
        "{{LEAD}}": post["lead"],
        "{{BYLINE}}": post_byline(post),
        "{{BODY}}": post["body"].strip(),
        "{{MORE_POSTS}}": render_post_cards(others),
        "{{STRUCTURED_DATA}}": post_structured_data(post),
        "{{FOOTER}}": footer,
    }
    return fill_template(template, replacements, "Blog post")


LATEST_POSTS_START = "<!-- LATEST-POSTS:START (generated by Scripts/render_web.py) -->"
LATEST_POSTS_END = "<!-- LATEST-POSTS:END -->"


def render_home(index: str) -> str:
    """The hand-written home page, with its "Latest from the blog" cards refreshed."""

    start, end = index.find(LATEST_POSTS_START), index.find(LATEST_POSTS_END)
    if start == -1 or end < start:
        raise SystemExit("web/index.html is missing the LATEST-POSTS markers.")
    cards = render_post_cards(POSTS[:3])
    return index[: start + len(LATEST_POSTS_START)] + "\n" + cards + "\n        " + index[end:]


def absolute_urls(fragment: str) -> str:
    """Root-relative links and images, made absolute for feed readers."""

    return re.sub(r'(href|src)="/(?!/)', rf'\1="{SITE}/', fragment)


def render_feed() -> str:
    """An Atom feed of every post with its full text."""

    def text(value: str) -> str:
        return html.escape(value, quote=False)

    entries = []
    for post in POSTS:
        url = f"{SITE}/blog/{post['slug']}"
        content = absolute_urls(textwrap.dedent(post["body"]).strip())
        entries.append(
            "  <entry>\n"
            f"    <title>{text(post['h1'])}</title>\n"
            f'    <link href="{url}" />\n'
            f"    <id>{url}</id>\n"
            f"    <published>{post['published']}T00:00:00Z</published>\n"
            f"    <updated>{post_updated(post)}T00:00:00Z</updated>\n"
            f"    <summary>{text(post['description'])}</summary>\n"
            f'    <content type="html">{text(content)}</content>\n'
            "  </entry>"
        )
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<feed xmlns="http://www.w3.org/2005/Atom">\n'
        "  <title>LokalBot Blog</title>\n"
        f"  <subtitle>{text(BLOG_INDEX['description'])}</subtitle>\n"
        f'  <link href="{SITE}/blog/feed.xml" rel="self" type="application/atom+xml" />\n'
        f'  <link href="{SITE}/blog" rel="alternate" type="text/html" />\n'
        f"  <id>{SITE}/blog</id>\n"
        f"  <updated>{blog_updated()}T00:00:00Z</updated>\n"
        f"  <author><name>LokalBot project</name><uri>{SITE}/</uri></author>\n"
        f"  <icon>{SITE}/assets/lokalbot-icon-512.png</icon>\n"
        + "\n".join(entries)
        + "\n</feed>\n"
    )


def render_sitemap() -> str:
    pages = [
        ("", STATIC_PAGES[""]),
        ("guides", guides_index_updated()),
        ("blog", blog_updated()),
        *((f"blog/{post['slug']}", post_updated(post)) for post in POSTS),
        *((guide["slug"], guide.get("updated", GUIDES_PUBLISHED)) for guide in GUIDES),
        *((reference["slug"], reference["updated"]) for reference in REFERENCES),
        *((path, updated) for path, updated in STATIC_PAGES.items() if path),
        *((page["slug"], modified(page)) for page in PAGES),
    ]
    entries = [
        "  <url>\n"
        f"    <loc>{SITE}/{path}</loc>\n"
        f"    <lastmod>{updated}</lastmod>\n"
        "  </url>"
        for path, updated in pages
    ]
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        + "\n".join(entries)
        + "\n</urlset>\n"
    )


def render_page(template: str, page: dict, footer: str) -> str:
    replacements = {
        "{{SLUG}}": page["slug"],
        "{{TITLE}}": page["title"],
        "{{META_DESCRIPTION}}": page["description"],
        "{{OG_TITLE}}": page["og_title"],
        "{{OG_DESCRIPTION}}": page["og_description"],
        "{{STRUCTURED_DATA}}": comparison_structured_data(page),
        "{{H1}}": page["h1"],
        "{{LEAD}}": page["lead"],
        "{{VERIFIED_DATE}}": verified(page),
        "{{VERIFIED_LABEL}}": long_date(verified(page)),
        "{{VERIFIED_MONTH}}": month_year(verified(page)),
        "{{COMPETITOR_COLUMN}}": page["competitor_column"],
        "{{TABLE_ROWS}}": render_table_rows(page["table_rows"]),
        "{{COMPETITOR_PICK_TITLE}}": page["competitor_pick_title"],
        "{{COMPETITOR_PICK_SUB}}": page["competitor_pick_sub"],
        "{{COMPETITOR_PICK_ITEMS}}": render_pick_items(page["competitor_pick_items"]),
        "{{LOKAL_PICK_SUB}}": page["lokal_pick_sub"],
        "{{LOKAL_PICK_ITEMS}}": render_pick_items(page["lokal_pick_items"]),
        "{{FAQ_ITEMS}}": render_faq_items(page["faq"]),
        "{{CTA_TITLE}}": page["cta_title"],
        "{{MORE_LINKS}}": render_more_links(page),
        "{{DISCLAIMER}}": page["disclaimer"],
        "{{FOOTER}}": footer,
    }
    return fill_template(template, replacements, "Comparison")


def main() -> int:
    args = parse_args()

    scripts_dir = repo_root() / "Scripts"
    template_paths = {
        "compare": scripts_dir / "compare.template.html",
        "guide": scripts_dir / "guide.template.html",
        "guides": scripts_dir / "guides.template.html",
        "blog": scripts_dir / "blog.template.html",
        "blog_post": scripts_dir / "blog_post.template.html",
        "footer": scripts_dir / "footer.partial.html",
    }
    for template_path in template_paths.values():
        if not template_path.is_file():
            raise SystemExit(f"Template does not exist: {template_path}")
    templates = {
        name: path.read_text(encoding="utf-8")
        for name, path in template_paths.items()
    }
    footer = render_footer(templates["footer"])

    web_dir = repo_root() / "web"
    if not web_dir.is_dir():
        raise SystemExit(f"Output directory does not exist: {web_dir}")

    missing_images = [
        post["slug"] for post in POSTS if not (web_dir / "assets" / "blog" / "og" / f"{post['slug']}.png").is_file()
    ]
    if missing_images:
        raise SystemExit(
            f"Missing share images for: {', '.join(missing_images)}. Run `python3 Scripts/render_social_images.py`."
        )

    generated_pages = [
        (web_dir / f"{page['slug']}.html", render_page(templates["compare"], page, footer))
        for page in PAGES
    ]
    generated_pages.extend(
        (web_dir / f"{guide['slug']}.html", render_guide_page(templates["guide"], guide, footer))
        for guide in GUIDES
    )
    generated_pages.extend(
        [
            (web_dir / "guides.html", render_guides_index(templates["guides"], footer)),
            (web_dir / "blog.html", render_blog_index(templates["blog"], footer)),
            (web_dir / "blog" / "feed.xml", render_feed()),
            (web_dir / "index.html", render_home((web_dir / "index.html").read_text(encoding="utf-8"))),
            (web_dir / "sitemap.xml", render_sitemap()),
        ]
    )
    generated_pages.extend(
        (web_dir / "blog" / f"{post['slug']}.html", render_blog_post(templates["blog_post"], post, footer))
        for post in POSTS
    )

    stale = []
    for output_path, rendered in generated_pages:
        if args.check:
            on_disk = output_path.read_text(encoding="utf-8") if output_path.is_file() else None
            if on_disk != rendered:
                stale.append(output_path)
            continue
        output_path.parent.mkdir(exist_ok=True)
        output_path.write_text(rendered, encoding="utf-8")
        print(f"Rendered {output_path.relative_to(repo_root())}")

    if stale:
        names = ", ".join(str(p.relative_to(repo_root())) for p in stale)
        raise SystemExit(
            f"Out of date: {names}. Run `python3 Scripts/render_web.py` and commit."
        )
    if args.check:
        print(f"All {len(generated_pages)} generated web files are up to date.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
