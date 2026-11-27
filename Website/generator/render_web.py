#!/usr/bin/env python3
"""Render LokalBot's comparison pages, guides, blog, and sitemap, and the home page's latest posts.

Generated HTML stays checked in under Website/public/. Hosting remains fully static and
nothing runs at deploy time.

To change a page:
1. edit the relevant *_pages.py or blog_posts.py content or *.template.html markup
   (footer.partial.html is shared by every generated page)
2. run `python3 Website/generator/render_web.py`
3. commit the regenerated files under Website/public/

Usage:
    python3 Website/generator/render_web.py            # render into Website/public/
    python3 Website/generator/render_web.py --check    # verify Website/public/ is up to date (CI)
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
from comparison_pages import LOKALBOT_UPDATED, PAGES, RELATED_GUIDES_BY_SLUG, VERIFIED  # noqa: E402
from guide_pages import GUIDES, GUIDES_INDEX, REFERENCES  # noqa: E402
from blog_posts import BLOG_INDEX, POSTS  # noqa: E402
from locale_pages import LOCALE_PAGES  # noqa: E402

TOKEN_OPEN = "{{"

CHECK_ICON = '<i class="ph ph-check" aria-hidden="true"></i>'

SITE = "https://www.lokalbot.com"
OG_IMAGE = f"{SITE}/assets/og-image.png"
BLOG_ID = f"{SITE}/blog#blog"
GUIDES_PUBLISHED = "2026-07-13"

ORGANIZATION = {
    "@type": "Organization",
    "@id": f"{SITE}/#organization",
    "name": "LokalBot",
    "url": f"{SITE}/",
    "logo": {"@type": "ImageObject", "url": f"{SITE}/assets/lokalbot-icon-512.png"},
    "sameAs": [
        "https://github.com/stevyhacker/LokalBot",
        "https://huggingface.co/stevyhacker",
    ],
}

FOUNDER_AUTHOR = {
    "@type": "Person",
    "@id": f"{SITE}/#author",
    "name": "Stevan Bogosavljević",
    "url": "https://bogosavljevic.me/",
    "sameAs": [
        "https://github.com/stevyhacker",
        "https://huggingface.co/stevyhacker",
    ],
}

WEBSITE_NODE = {
    "@type": "WebSite",
    "@id": f"{SITE}/#website",
    "url": f"{SITE}/",
    "name": "LokalBot",
    "publisher": {"@id": f"{SITE}/#organization"},
}

SOFTWARE_NODE = {
    "@type": "SoftwareApplication",
    "@id": f"{SITE}/#software",
    "name": "LokalBot",
    "url": f"{SITE}/",
    "operatingSystem": "macOS 15+, Windows 10/11 (alpha), Linux x86_64 (alpha), iOS 18+, Android 10+",
    "applicationCategory": "ProductivityApplication",
    "softwareVersion": "0.14.0",
    "license": "https://github.com/stevyhacker/LokalBot/blob/master/LICENSE",
    "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
    "author": {"@id": f"{SITE}/#author"},
}

BASE_ENTITIES = [WEBSITE_NODE, ORGANIZATION, FOUNDER_AUTHOR, SOFTWARE_NODE]

BLOG_STUB = {
    "@type": "Blog",
    "@id": BLOG_ID,
    "url": f"{SITE}/blog",
    "name": "LokalBot Blog",
    "publisher": {"@id": f"{SITE}/#organization"},
    "isPartOf": {"@id": f"{SITE}/#website"},
}

INTERACTIVE_TOOLS = [
    (
        "wrapped",
        "CLI + Browser",
        "Agent Wrapped 2026",
        "Local, zero-upload year in review for Claude Code, Codex, Cursor, Pi, OMP, OpenCode, Antigravity, and Gemini CLI (npx lokalbot).",
    ),
    (
        "migrate",
        "Offline converter",
        "Meeting Migrator",
        "Convert Granola, Otter.ai, Fireflies, Fathom, Zoom, Teams, Screenpipe, Krisp, Tactiq, and Wispr Flow exports to Obsidian Markdown locally.",
    ),
    (
        "hardware",
        "RAM calculator",
        "Local AI Hardware & RAM Calculator",
        "Estimate exact disk downloads, resident RAM, KV-cache, GPU offload, and memory caps for Mac, Windows, and Linux.",
    ),
    (
        "calculator",
        "Cost calculator",
        "SaaS AI Cost & Cloud Audio Calculator",
        "Compare 1-year and 3-year SaaS meeting and dictation costs plus uploaded audio hours against $0 and 0 bytes on-device.",
    ),
]

NAV_ITEMS = [
    ("demo", "/#demo"),
    ("compare", "/#compare"),
    ("benchmarks", "/benchmarks"),
    ("guides", "/guides"),
    ("blog", "/blog"),
    ("migrate", "/migrate"),
    ("hardware", "/hardware"),
    ("calculator", "/calculator"),
    ("wrapped", "/wrapped"),
]

NAV_LABELS = {
    "aria": "Primary",
    "demo": "Demo",
    "compare": "Compare",
    "benchmarks": "Benchmarks",
    "guides": "Guides",
    "blog": "Blog",
    "migrate": "Migrate",
    "hardware": "Hardware",
    "calculator": "Calculator",
    "wrapped": "Wrapped",
}

HAND_WRITTEN_PAGES = {
    "404": None,
    "about": None,
    "benchmarks": "benchmarks",
    "calculator": "calculator",
    "enshittification-proof": None,
    "hardware": "hardware",
    "migrate": "migrate",
    "privacy": None,
    "support": None,
    "terms": None,
    "wrapped": "wrapped",
}

PRIMARY_NAV = re.compile(r'<nav class="nav__links"[^>]*>.*?</nav>', re.S)

STATIC_PAGES = {
    "": "2026-11-26",
    "wrapped": "2026-11-26",
    "migrate": "2026-11-26",
    "calculator": "2026-11-26",
    "privacy": "2026-11-26",
    "terms": "2026-11-26",
    "support": "2026-11-26",
    "enshittification-proof": "2026-11-26",
}


def repo_root() -> Path:
    """Repo root, derived from this script's location under Website/generator/."""

    return Path(__file__).resolve().parents[2]


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


def primary_nav(active: str | None = None, labels: dict[str, str] | None = None) -> str:
    """The one top navigation every page shows, in the page's language."""

    labels = labels or NAV_LABELS
    links = []
    for key, href in NAV_ITEMS:
        current = ' aria-current="page"' if key == active else ""
        links.append(f'<a href="{href}"{current}>{html.escape(labels[key])}</a>')
    return f'<nav class="nav__links" aria-label="{html.escape(labels["aria"])}">{"".join(links)}</nav>'


def with_primary_nav(page: str, label: str, active: str | None = None) -> str:
    """A hand-written page with its top navigation replaced by the shared one."""

    found = len(PRIMARY_NAV.findall(page))
    if found != 1:
        raise SystemExit(f"{label} needs exactly one <nav class=\"nav__links\">, found {found}.")
    return PRIMARY_NAV.sub(lambda _: primary_nav(active), page, count=1)


def locale_nav_labels(loc: dict) -> dict[str, str]:
    return {"aria": loc["nav_aria"], **{key: loc[f"nav_{key}"] for key, _ in NAV_ITEMS}}


def render_footer(partial: str) -> str:
    """The shared footer, with Compare links and all locale links."""

    roundups = [
        f'      <a href="/{guide["slug"]}">{guide.get("footer_label", guide["h1"])}</a>'
        for guide in GUIDES
        if guide.get("kind") == "compare"
    ]
    links = "\n".join(
        roundups
        + [f'      <a href="/{page["slug"]}">{page["h1"].removeprefix("LokalBot ")}</a>' for page in PAGES]
    )
    languages = " &middot; ".join(
        ['<a href="/" hreflang="en">English</a>']
        + [
            f'<a href="/{loc["slug"]}" hreflang="{loc["hreflang"]}">{html.escape(loc["label"])}</a>'
            for loc in LOCALE_PAGES
        ]
    )
    return fill_template(
        partial,
        {"{{COMPARE_LINKS}}": links, "{{LANGUAGE_LINKS}}": languages},
        "Footer",
    ).rstrip("\n")


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


def render_compare_related_guides(page: dict) -> str:
    slugs = RELATED_GUIDES_BY_SLUG.get(
        page["slug"],
        ["best-local-ai-meeting-notes", "open-source-ai-meeting-notes", "gdpr-local-ai-meeting-notes"],
    )
    return render_related_links({"related": slugs})


def guide_structured_data(page: dict) -> str:
    url = f"{SITE}/{page['slug']}"
    extra = [page["item_list"]] if page.get("item_list") else []
    return json_ld(
        [
            *BASE_ENTITIES,
            {
                "@type": "Article",
                "headline": page["h1"],
                "description": page["description"],
                "datePublished": page.get("published", GUIDES_PUBLISHED),
                "dateModified": page.get("updated", GUIDES_PUBLISHED),
                "mainEntityOfPage": url,
                "image": OG_IMAGE,
                "author": {"@id": f"{SITE}/#author"},
                "publisher": {"@id": f"{SITE}/#organization"},
                "isPartOf": {"@id": f"{SITE}/#website"},
            },
            breadcrumb_list([("Home", f"{SITE}/"), ("Guides", f"{SITE}/guides"), (page["h1"], url)]),
            faq_page(page["faq"], url),
            *extra,
        ]
    )


def comparison_structured_data(page: dict) -> str:
    url = f"{SITE}/{page['slug']}"
    return json_ld(
        [
            *BASE_ENTITIES,
            {
                "@type": "Article",
                "headline": page["h1"],
                "description": page["description"],
                "datePublished": page["published"],
                "dateModified": modified(page),
                "mainEntityOfPage": url,
                "image": f"{SITE}/assets/compare/og/{page['slug']}.png",
                "author": {"@id": f"{SITE}/#author"},
                "publisher": {"@id": f"{SITE}/#organization"},
                "isPartOf": {"@id": f"{SITE}/#website"},
                "about": [
                    {"@id": f"{SITE}/#software"},
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
        + [loc["updated"] for loc in LOCALE_PAGES]
    )


def guides_index_structured_data() -> str:
    url = f"{SITE}/guides"
    listed = (
        [(guide["slug"], guide["h1"]) for guide in GUIDES if guide.get("kind") == "question"]
        + [(guide["slug"], guide["h1"]) for guide in GUIDES if guide.get("kind", "guide") == "guide"]
        + [(guide["slug"], guide["h1"]) for guide in GUIDES if guide.get("kind") == "compare"]
        + [(page["slug"], page["h1"]) for page in PAGES]
        + [(slug, heading) for slug, _, heading, _ in INTERACTIVE_TOOLS]
        + [(reference["slug"], reference["h1"]) for reference in REFERENCES]
        + [(loc["slug"], f"LokalBot ({loc['label']})") for loc in LOCALE_PAGES]
    )
    return json_ld(
        [
            *BASE_ENTITIES,
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
        "{{PRIMARY_NAV}}": primary_nav("guides"),
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
            [
                (guide["slug"], "Compare", guide["h1"], guide["description"], search_terms(guide))
                for guide in GUIDES
                if guide.get("kind") == "compare"
            ]
            + [(page["slug"], "Compare", page["h1"], page["description"], search_terms(page)) for page in PAGES]
        ),
        "{{TOOL_CARDS}}": render_compact_cards(
            [(slug, eyebrow, heading, description, "") for slug, eyebrow, heading, description in INTERACTIVE_TOOLS]
        ),
        "{{REFERENCE_CARDS}}": render_compact_cards(
            [(ref["slug"], ref["eyebrow"], ref["h1"], ref["description"], "") for ref in REFERENCES]
        ),
        "{{LANGUAGE_CARDS}}": render_compact_cards(
            [
                (
                    loc["slug"],
                    loc["lang"],
                    f"LokalBot ({loc['label']})",
                    loc["description"],
                    f' data-terms="{html.escape(loc["label"] + " " + loc["title"], quote=True)}"',
                )
                for loc in LOCALE_PAGES
            ]
        ),
        "{{PRIMARY_NAV}}": primary_nav("guides"),
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


def render_post_cards(posts: list[dict], summaries: bool = True) -> str:
    """Cards linking to posts. The home page leaves the summaries out to stay short."""
    return "\n".join(
        f'        <a class="guide-card blog-card" href="/blog/{post["slug"]}">\n'
        f'          <span class="guide-card__eyebrow"><time datetime="{post["published"]}">{long_date(post["published"])}</time> · {post["eyebrow"]}</span>\n'
        f'          <strong>{post["h1"]}</strong>\n'
        + (f'          <span>{post["description"]}</span>\n' if summaries else "")
        + f'          <span class="guide-card__meta">{post["read_time"]}</span>\n'
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
        "author": {"@id": f"{SITE}/#author"},
        "publisher": {"@id": f"{SITE}/#organization"},
        "isPartOf": {"@id": BLOG_ID},
    }


def post_structured_data(post: dict) -> str:
    url = f"{SITE}/blog/{post['slug']}"
    return json_ld(
        [
            *BASE_ENTITIES,
            BLOG_STUB,
            blog_posting(post),
            breadcrumb_list([("Home", f"{SITE}/"), ("Blog", f"{SITE}/blog"), (post["h1"], url)]),
        ]
    )


def blog_index_structured_data() -> str:
    url = f"{SITE}/blog"
    return json_ld(
        [
            *BASE_ENTITIES,
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
                        "author": {"@id": f"{SITE}/#author"},
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
        "{{PRIMARY_NAV}}": primary_nav("blog"),
        "{{FOOTER}}": footer,
    }
    return fill_template(template, replacements, "Blog")


def render_blog_post(template: str, post: dict, footer: str) -> str:
    others = [other for other in POSTS if other["slug"] != post["slug"]][:3]
    replacements = {
        "{{SLUG}}": post["slug"],
        "{{TITLE}}": f"{post['title']} | LokalBot",
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
        "{{PRIMARY_NAV}}": primary_nav("blog"),
        "{{FOOTER}}": footer,
    }
    return fill_template(template, replacements, "Blog post")


LATEST_POSTS_START = "<!-- LATEST-POSTS:START (generated by Website/generator/render_web.py) -->"
LATEST_POSTS_END = "<!-- LATEST-POSTS:END -->"


def render_home(index: str) -> str:
    """The hand-written home page, with its "Latest from the blog" cards refreshed."""

    start, end = index.find(LATEST_POSTS_START), index.find(LATEST_POSTS_END)
    if start == -1 or end < start:
        raise SystemExit("Website/public/index.html is missing the LATEST-POSTS markers.")
    cards = render_post_cards(POSTS[:3], summaries=False)
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
        f"  <author><name>Stevan Bogosavljević</name><uri>https://github.com/stevyhacker</uri></author>\n"
        f"  <icon>{SITE}/assets/lokalbot-icon-512.png</icon>\n"
        + "\n".join(entries)
        + "\n</feed>\n"
    )


def render_llms_full(web_dir: Path) -> str:
    """Full machine-readable context corpus for AI search and answer engines (/llms-full.txt)."""

    llms_index = (web_dir / "llms.txt").read_text(encoding="utf-8").strip()
    parts: list[str] = [llms_index]

    benchmarks_path = web_dir / "benchmarks.json"
    if benchmarks_path.is_file():
        bdata = json.loads(benchmarks_path.read_text(encoding="utf-8"))
        parts.append("")
        parts.append("---")
        parts.append("")
        parts.append(f"## Full Benchmark Dataset ({SITE}/benchmarks · updated {bdata.get('updated', '')})")
        parts.append("")
        parts.append(bdata.get("hardwareSummary", ""))
        parts.append("")
        parts.append("### Current local reference stack")
        parts.append("")
        parts.append("| Role | Default model | Format | Size (GB) | Headline |")
        parts.append("| --- | --- | --- | ---: | --- |")
        for item in bdata.get("referenceStack", []):
            size = f"{item['sizeGb']}" if item.get("sizeGb") is not None else "Built-in"
            parts.append(
                f"| {item['role']} | {item['model']} | {item['format']} | {size} | {item['headline']} |"
            )

        for cat in bdata.get("categories", []):
            parts.append("")
            parts.append(f"### {cat['label']}")
            parts.append("")
            parts.append(cat["summary"])
            for suite in cat.get("suites", []):
                parts.append("")
                parts.append(f"#### {suite['label']} (`{SITE}/benchmarks#{suite['id']}`)")
                parts.append(f"- Run date: {suite['runDate']} · Hardware: {suite['hardware']}")
                parts.append(f"- Dataset: {suite['dataset']}")
                parts.append(f"- Report: {suite['reportUrl']}")
                parts.append("")
                cols = suite.get("columns", [])
                headers = ["Model", "Status", "Runtime / Quant"] + [c["label"] for c in cols]
                sep = ["---", "---", "---"] + ["---:" if c.get("align") == "right" else "---" for c in cols]
                parts.append("| " + " | ".join(headers) + " |")
                parts.append("| " + " | ".join(sep) + " |")
                for row in suite.get("rows", []):
                    rt = " · ".join(x for x in [row.get("runtime"), row.get("quant")] if x)
                    cells = [row["model"], row.get("status", ""), rt]
                    for col in cols:
                        cell = (row.get("values") or {}).get(col["key"])
                        cells.append(cell["display"] if cell else "-")
                    parts.append("| " + " | ".join(cells) + " |")
                parts.append("")
                parts.append(f"Note: {suite['note']}")
                parts.append(f"Caveat: {suite['caveat']}")

    parts.append("")
    parts.append("---")
    parts.append("")
    parts.append("## Detailed Competitor Comparisons")
    for page in PAGES:
        parts.append("")
        parts.append(f"### {page['h1']} ({SITE}/{page['slug']} · verified {verified(page)})")
        parts.append("")
        parts.append(plain_text(page["lead"]))
        parts.append("")
        parts.append(f"| Feature | LokalBot | {page['competitor_column']} |")
        parts.append("| --- | --- | --- |")
        for feat, lokal_val, comp_val in page["table_rows"]:
            parts.append(f"| {plain_text(feat)} | {plain_text(lokal_val)} | {plain_text(comp_val)} |")
        if page.get("faq"):
            parts.append("")
            for q, a in page["faq"]:
                parts.append(f"- **Q: {plain_text(q)}** {plain_text(a)}")

    parts.append("")
    parts.append("---")
    parts.append("")
    parts.append("## Guides & Frequently Asked Questions")
    for guide in GUIDES:
        parts.append("")
        parts.append(f"### {guide['h1']} ({SITE}/{guide['slug']})")
        parts.append(plain_text(guide["description"]))
        if guide.get("faq"):
            for q, a in guide["faq"]:
                parts.append(f"- **Q: {plain_text(q)}** {plain_text(a)}")

    return "\n".join(parts).rstrip() + "\n"


def render_hreflang_links() -> str:
    links = [f'  <link rel="alternate" hreflang="en" href="{SITE}/" />']
    for loc in LOCALE_PAGES:
        links.append(f'  <link rel="alternate" hreflang="{loc["hreflang"]}" href="{SITE}/{loc["slug"]}" />')
    links.append(f'  <link rel="alternate" hreflang="x-default" href="{SITE}/" />')
    return "\n".join(links)


def render_lang_switcher(current_slug: str) -> str:
    items = ['      <a class="loc-lang" href="/" hreflang="en">English</a>']
    for loc in LOCALE_PAGES:
        current = ' aria-current="page"' if loc["slug"] == current_slug else ""
        items.append(
            f'      <a class="loc-lang" href="/{loc["slug"]}" hreflang="{loc["hreflang"]}"{current}>{loc["label"]}</a>'
        )
    return "\n".join(items)


def locale_structured_data(loc: dict) -> str:
    url = f"{SITE}/{loc['slug']}"
    graph = [
        *BASE_ENTITIES,
        {
            "@type": "WebPage",
            "@id": f"{url}#page",
            "url": url,
            "name": loc["title"],
            "description": loc["description"],
            "inLanguage": loc["lang"],
            "datePublished": "2026-11-20" if loc["slug"] in ("de", "zh", "ja", "ru") else "2026-11-26",
            "dateModified": loc["updated"],
            "isPartOf": {"@id": f"{SITE}/#website"},
            "about": {"@id": f"{SITE}/#software"},
            "publisher": {"@id": f"{SITE}/#organization"},
        },
        breadcrumb_list([(loc["home_label"], f"{SITE}/"), (loc["label"], url)]),
        faq_page(loc["faq"], url),
    ]
    return json_ld(graph)


def render_locale_page(template: str, loc: dict, footer: str) -> str:
    feature_cards = "\n".join(
        '      <article class="loc-tile">\n'
        f'        <p class="loc-tile__kicker">{html.escape(kicker)}</p>\n'
        f"        <h2>{html.escape(title)}</h2>\n"
        f"        <p>{html.escape(body)}</p>\n"
        "      </article>"
        for kicker, title, body in loc["features"]
    )
    stack_rows = "\n".join(
        f"            <tr><td><strong>{html.escape(role)}</strong></td><td>{html.escape(model)}</td><td>{html.escape(detail)}</td></tr>"
        for role, model, detail in loc["stack_rows"]
    )
    replacements = {
        "{{SLUG}}": loc["slug"],
        "{{LANG}}": loc["lang"],
        "{{OG_LOCALE}}": loc["og_locale"],
        "{{TITLE}}": html.escape(loc["title"]),
        "{{META_DESCRIPTION}}": html.escape(loc["description"]),
        "{{OG_TITLE}}": html.escape(loc["og_title"]),
        "{{OG_DESCRIPTION}}": html.escape(loc["og_description"]),
        "{{OG_IMAGE_ALT}}": html.escape(loc["og_image_alt"]),
        "{{SKIP_LINK}}": html.escape(loc["skip_link"]),
        "{{HOME_ARIA}}": html.escape(loc["home_aria"]),
        "{{PRIMARY_NAV}}": primary_nav(labels=locale_nav_labels(loc)),
        "{{LANGS_ARIA}}": html.escape(loc["langs_aria"]),
        "{{FAQ_EYEBROW}}": html.escape(loc["faq_eyebrow"]),
        "{{HREFLANG_LINKS}}": render_hreflang_links(),
        "{{STRUCTURED_DATA}}": locale_structured_data(loc),
        "{{DOWNLOAD_BTN}}": html.escape(loc["download_btn"]),
        "{{LANG_SWITCHER}}": render_lang_switcher(loc["slug"]),
        "{{EYEBROW}}": html.escape(loc["eyebrow"]),
        "{{H1}}": html.escape(loc["h1"]),
        "{{LEAD}}": html.escape(loc["lead"]),
        "{{HERO_CTA}}": html.escape(loc["hero_cta"]),
        "{{BENCH_CTA}}": html.escape(loc["bench_cta"]),
        "{{MIGRATE_CTA}}": html.escape(loc["migrate_cta"]),
        "{{META_LINE}}": html.escape(loc["meta_line"]),
        "{{FEATURES_ARIA}}": html.escape(loc["features_aria"]),
        "{{FEATURE_CARDS}}": feature_cards,
        "{{STACK_EYEBROW}}": html.escape(loc["stack_eyebrow"]),
        "{{STACK_TITLE}}": html.escape(loc["stack_title"]),
        "{{STACK_LEAD}}": html.escape(loc["stack_lead"]),
        "{{COL_ROLE}}": html.escape(loc["col_role"]),
        "{{COL_MODEL}}": html.escape(loc["col_model"]),
        "{{COL_DETAIL}}": html.escape(loc["col_detail"]),
        "{{STACK_ROWS}}": stack_rows,
        "{{STACK_NOTE}}": loc["stack_note"],
        "{{FAQ_TITLE}}": html.escape(loc["faq_title"]),
        "{{FAQ_ITEMS}}": render_faq_items(loc["faq"]),
        "{{DL_EYEBROW}}": html.escape(loc["dl_eyebrow"]),
        "{{DL_TITLE}}": html.escape(loc["dl_title"]),
        "{{DL_LEAD}}": html.escape(loc["dl_lead"]),
        "{{FOOTER}}": footer,
    }
    return fill_template(template, replacements, f"Locale ({loc['slug']})")


def render_sitemap() -> str:
    locale_slugs = {loc["slug"] for loc in LOCALE_PAGES}
    locale_alternates = (
        f'    <xhtml:link rel="alternate" hreflang="en" href="{SITE}/" />\n'
        + "".join(
            f'    <xhtml:link rel="alternate" hreflang="{loc["hreflang"]}" href="{SITE}/{loc["slug"]}" />\n'
            for loc in LOCALE_PAGES
        )
        + f'    <xhtml:link rel="alternate" hreflang="x-default" href="{SITE}/" />\n'
    )
    pages = [
        ("", STATIC_PAGES[""]),
        *((loc["slug"], loc["updated"]) for loc in LOCALE_PAGES),
        ("guides", guides_index_updated()),
        ("blog", blog_updated()),
        *((f"blog/{post['slug']}", post_updated(post)) for post in POSTS),
        *((guide["slug"], guide.get("updated", GUIDES_PUBLISHED)) for guide in GUIDES),
        *((reference["slug"], reference["updated"]) for reference in REFERENCES),
        *((path, updated) for path, updated in STATIC_PAGES.items() if path),
        *((page["slug"], modified(page)) for page in PAGES),
    ]
    entries = []
    for path, updated in pages:
        extra = locale_alternates if (path == "" or path in locale_slugs) else ""
        entries.append(
            "  <url>\n"
            f"    <loc>{SITE}/{path}</loc>\n"
            f"    <lastmod>{updated}</lastmod>\n"
            f"{extra}"
            "  </url>"
        )
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"\n'
        '        xmlns:xhtml="http://www.w3.org/1999/xhtml">\n'
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
        "{{RELATED_GUIDES}}": render_compare_related_guides(page),
        "{{MORE_LINKS}}": render_more_links(page),
        "{{DISCLAIMER}}": page["disclaimer"],
        "{{PRIMARY_NAV}}": primary_nav(),
        "{{FOOTER}}": footer,
    }
    return fill_template(template, replacements, "Comparison")


def main() -> int:
    args = parse_args()

    templates_dir = Path(__file__).resolve().parent / "templates"
    template_paths = {
        "compare": templates_dir / "compare.template.html",
        "guide": templates_dir / "guide.template.html",
        "guides": templates_dir / "guides.template.html",
        "blog": templates_dir / "blog.template.html",
        "blog_post": templates_dir / "blog_post.template.html",
        "locale": templates_dir / "locale.template.html",
        "footer": templates_dir / "footer.partial.html",
    }
    for template_path in template_paths.values():
        if not template_path.is_file():
            raise SystemExit(f"Template does not exist: {template_path}")
    templates = {
        name: path.read_text(encoding="utf-8")
        for name, path in template_paths.items()
    }
    footer = render_footer(templates["footer"])

    web_dir = repo_root() / "Website" / "public"
    if not web_dir.is_dir():
        raise SystemExit(f"Output directory does not exist: {web_dir}")

    missing_images = [
        f"blog/{post['slug']}"
        for post in POSTS
        if not (web_dir / "assets" / "blog" / "og" / f"{post['slug']}.png").is_file()
    ] + [
        f"compare/{page['slug']}"
        for page in PAGES
        if not (web_dir / "assets" / "compare" / "og" / f"{page['slug']}.png").is_file()
    ]
    if missing_images:
        raise SystemExit(
            f"Missing share images for: {', '.join(missing_images)}. Run `python3 Website/generator/render_social_images.py`."
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
            (
                web_dir / "index.html",
                with_primary_nav(render_home((web_dir / "index.html").read_text(encoding="utf-8")), "index.html"),
            ),
            (web_dir / "llms-full.txt", render_llms_full(web_dir)),
            (web_dir / "sitemap.xml", render_sitemap()),
        ]
    )
    generated_pages.extend(
        (
            web_dir / f"{slug}.html",
            with_primary_nav((web_dir / f"{slug}.html").read_text(encoding="utf-8"), f"{slug}.html", active),
        )
        for slug, active in HAND_WRITTEN_PAGES.items()
    )
    generated_pages.extend(
        (web_dir / f"{loc['slug']}.html", render_locale_page(templates["locale"], loc, footer))
        for loc in LOCALE_PAGES
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
            f"Out of date: {names}. Run `python3 Website/generator/render_web.py` and commit."
        )
    if args.check:
        print(f"All {len(generated_pages)} generated web files are up to date.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
