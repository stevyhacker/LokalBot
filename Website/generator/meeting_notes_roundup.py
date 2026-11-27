"""The "best local & open-source AI meeting note takers" comparison at /best-local-ai-meeting-notes.

Rendered by Website/generator/render_web.py as a guide with "kind": "compare", so it is
listed under Compare on /guides and in the shared footer. Every fact about another
project comes from that project's own site, docs, license, or release notes, verified on
VERIFIED. LokalBot's facts match README.md, PRIVACY.md, ModelCatalog.swift, and Benchmarks/.
"""

from __future__ import annotations

from datetime import date
from html import escape

SLUG = "best-local-ai-meeting-notes"
PUBLISHED = "2026-11-26"
VERIFIED = "2026-11-26"
ISSUES_URL = "https://github.com/stevyhacker/lokalbot/issues"
REPO_URL = "https://github.com/stevyhacker/lokalbot"


def _long_date(iso: str) -> str:
    day = date.fromisoformat(iso)
    return f"{day:%B} {day.day}, {day.year}"


TOOLS = [
    {
        "id": "lokalbot",
        "name": "LokalBot",
        "tagline": "Our app: bot-free meetings, fine-tuned local models, and workday memory",
        "site": "https://www.lokalbot.com/",
        "compare_slug": "",
        "about": (
            "<p>LokalBot is our app. It captures your microphone and meeting app audio on two synchronized "
            "tracks without joining the call, then transcribes and summarizes on your computer by default. "
            "Version 0.14.0 ships four Apache-2.0 fine-tuned defaults: Qwen3-ASR 1.7B (LokalBot v3) and 0.6B (v1) "
            "for speech, Qwen3.5 4B (LokalBot v4) for notes and Personal Context memory, and Gemma 4 E2B (LokalBot v4) "
            "for inline autocomplete. Everything sits in one local SQLite library with hybrid search (EmbeddingGemma 2), "
            "Obsidian Markdown export, opt-in screen memory, dictation, and a free read-only local MCP server.</p>"
        ),
        "good_for": [
            "Keeping audio, transcripts, summaries, and MCP access strictly on your machine with no account or paid tier.",
            "Teams or solo engineers using Mac, Windows, or Linux (alpha) alongside Obsidian, Claude Code, Codex, or Cursor.",
            "Bilingual calls and custom dictation vocabulary where stock small speech models drift or hallucinate on silence.",
        ],
        "watch_out": [
            "Windows and Linux apps are native Rust + GPUI alphas; the Windows installer is not code-signed yet and a few features (Nemotron diarization, Gmail briefs, Apple Intelligence) remain Mac only.",
            "No Intel Mac build (requires Apple Silicon M1+ and macOS 15+, or x64 on Windows and Linux).",
            "No hosted team workspace; sharing happens via Markdown export or LAN/Tailscale encrypted sync to your own iOS or Android device.",
        ],
        "facts": [
            ("License", '<a href="https://github.com/stevyhacker/lokalbot/blob/master/LICENSE" target="_blank" rel="noopener">GPLv3</a> (Cotabby autocomplete files AGPLv3)'),
            ("Default local stack", "Qwen3-ASR 1.7B v3 (2.52 GB Mac) or 0.6B v1 (1.02 GB), Qwen3.5 4B v4 (2.74 GB), EmbeddingGemma 2 (0.31 GB), Nemotron 3 (0.20 GB Mac)"),
            ("Measured speed / WER", "17.6% AMI mixed WER (44x RT), 9.79% AMI ihm / 12.81% code-switch WER (v3), 39 ms hybrid search at 50 MB RAM"),
            ("Runs on", 'macOS 15+ (Apple Silicon), Windows 10/11 x64 (alpha), Linux x86_64 (alpha), iOS 18+, Android 10+ (<a href="system-requirements">requirements</a>)'),
            ("Price", "Free, no account, no minute cap"),
        ],
        "links": [
            ("Download LokalBot", "https://github.com/stevyhacker/lokalbot/releases/latest"),
            ("See benchmarks", "/benchmarks"),
            ("Check RAM fit", "/hardware"),
        ],
        "license_url": "https://github.com/stevyhacker/lokalbot/blob/master/LICENSE",
        "os": "macOS 15+, Windows 10/11 (alpha), Linux (alpha), iOS, Android",
        "sources": [],
    },
    {
        "id": "meetily",
        "name": "Meetily",
        "tagline": "Popular MIT community notetaker with a paid Pro edition",
        "site": "https://meetily.ai/",
        "compare_slug": "lokalbot-vs-meetily",
        "about": (
            "<p>Meetily has one of the largest communities in open-source meeting notes. Its free Community Edition "
            "captures microphone and system audio without a bot on macOS and Windows, transcribes locally with Whisper "
            "or Parakeet, and summarizes with built-in Qwen 3.5 models, Ollama, or your own API key. Advanced features "
            "such as speaker separation, automatic meeting detection, and MCP access live in a separate commercial Pro codebase.</p>"
        ),
        "good_for": [
            "Windows and Mac users who want a mature MIT-licensed local meeting recorder with a large community.",
            "Teams that want a self-hosted Enterprise option with commercial support.",
        ],
        "watch_out": [
            "Speaker separation, automatic meeting detection, CLI, webhooks, and MCP require Meetily Pro ($10/user/mo annual) on a separate commercial codebase.",
            "Linux currently requires building from source; no built-in dictation, screen memory, or autocomplete.",
        ],
        "facts": [
            ("License", "MIT (Community Edition); commercial codebase for Pro and Enterprise"),
            ("Local models", "Whisper or Parakeet for speech; built-in Qwen 3.5, Ollama, or bring-your-own cloud API keys"),
            ("Runs on", "macOS (Apple Silicon) and Windows; Linux from source"),
            ("Price", "Community free; Pro $10/user/mo billed annually; Enterprise custom"),
        ],
        "links": [
            ("LokalBot vs Meetily", "/lokalbot-vs-meetily"),
            ("Meetily site", "https://meetily.ai/"),
        ],
        "license_url": "https://github.com/Zackriya-Solutions/meeting-minutes/blob/main/LICENSE",
        "os": "macOS, Windows, Linux (source)",
        "sources": [
            "https://meetily.ai/",
            "https://github.com/Zackriya-Solutions/meeting-minutes",
        ],
    },
    {
        "id": "anarlog",
        "name": "Anarlog (formerly Hyprnote)",
        "tagline": "MIT-licensed meeting notepad with bring-your-own LLM flexibility",
        "site": "https://github.com/fastrepl/hyprnote",
        "compare_slug": "lokalbot-vs-hyprnote",
        "about": (
            "<p>Anarlog (originally launched as Hyprnote, while hyprnote.com now points to the team's newer Char product) "
            "is an open-source, local-first meeting notepad. It focuses tightly on call notes and lets you plug in Ollama, "
            "LM Studio, Apple Intelligence, your own API keys, or optional hosted AI and encrypted cloud sync. It stores "
            "notes locally in SQLite and plain files and includes a local CLI and MCP server.</p>"
        ),
        "good_for": [
            "Users who already run Ollama or LM Studio and want a clean MIT-licensed notepad dedicated to meetings.",
            "People who want optional encrypted cloud sync and hosted sharing alongside local files.",
        ],
        "watch_out": [
            "On-device transcription is limited to supported Macs; Linux and Windows betas rely on a cloud provider or a self-hosted server.",
            "No bundled llama.cpp summary model out of the box, and no built-in dictation, day timeline, or autocomplete.",
        ],
        "facts": [
            ("License", "MIT (community app); enterprise components commercially licensed"),
            ("Local models", "On-device ASR on supported Macs; bring-your-own Ollama, LM Studio, Apple Intelligence, or API keys"),
            ("Runs on", "macOS; Windows, Linux, iOS, and Android in beta"),
            ("Price", "Free community app; paid hosted AI and team tiers"),
        ],
        "links": [
            ("LokalBot vs Anarlog", "/lokalbot-vs-hyprnote"),
            ("GitHub repository", "https://github.com/fastrepl/hyprnote"),
        ],
        "license_url": "https://github.com/fastrepl/hyprnote/blob/main/LICENSE",
        "os": "macOS, Windows (beta), Linux (beta), iOS (beta), Android (beta)",
        "sources": [
            "https://github.com/fastrepl/hyprnote",
        ],
    },
    {
        "id": "openwhispr",
        "name": "OpenWhispr",
        "tagline": "MIT dictation and bot-free meeting notes across Mac, Windows, Linux, and iOS",
        "site": "https://openwhispr.com/",
        "compare_slug": "lokalbot-vs-openwhispr",
        "about": (
            "<p>OpenWhispr pairs system-wide voice dictation with bot-free meeting capture under the MIT license. "
            "It ships prebuilt packages for macOS (including Intel Macs), Windows, Linux (AppImage, .deb, .rpm, archive), "
            "and iOS. During setup it recommends OpenWhispr Cloud, so privacy-focused users need to explicitly select "
            "local speech models (Orukeet or Whisper) and built-in llama.cpp or Ollama summaries.</p>"
        ),
        "good_for": [
            "Heavy dictation users who want per-app tone modes, snippets, translation, and standalone iPhone dictation.",
            "Intel Mac users who still want local transcription and meeting capture.",
        ],
        "watch_out": [
            "Setup steers toward OpenWhispr Cloud by default; check local settings separately for dictation, meetings, and file uploads.",
            "Its MCP server is hosted on paid plans ($8-$16/mo) and requires cloud-synced notes; only the local CLI is free.",
        ],
        "facts": [
            ("License", "MIT (client app); hosted cloud and MCP services are proprietary"),
            ("Local models", "Optional on-device Orukeet (Parakeet fine-tune), Whisper, and built-in llama.cpp or Ollama"),
            ("Runs on", "macOS 12+ (Apple Silicon and Intel), Windows 10+ x64, Linux x86_64, iOS, iPadOS"),
            ("Price", "Free (local + limited cloud); Pro $8/mo; Business $16/user/mo"),
        ],
        "links": [
            ("LokalBot vs OpenWhispr", "/lokalbot-vs-openwhispr"),
            ("OpenWhispr site", "https://openwhispr.com/"),
        ],
        "license_url": "https://github.com/HeroTools/open-whispr/blob/main/LICENSE",
        "os": "macOS, Windows, Linux, iOS, iPadOS",
        "sources": [
            "https://openwhispr.com/",
            "https://github.com/HeroTools/open-whispr",
        ],
    },
    {
        "id": "macwhisper",
        "name": "MacWhisper",
        "tagline": "Polished Mac specialist for transcribing files and calls locally",
        "site": "https://goodsnooze.gumroad.com/l/macwhisper",
        "compare_slug": "lokalbot-vs-macwhisper",
        "about": (
            "<p>MacWhisper is the long-standing macOS utility for turning audio and video files into transcripts and "
            "subtitles on-device. It also records Zoom, Teams, Webex, and Discord calls without a bot and offers "
            "system-wide dictation. Unlike open-source meeting libraries, MacWhisper is proprietary and focuses on "
            "file transcription first, using Ollama or cloud API keys you supply for AI summaries.</p>"
        ),
        "good_for": [
            "Journalists, podcasters, and researchers who transcribe pre-recorded audio/video files and export SRT/VTT subtitles.",
            "Mac users who prefer a one-time license (Pro EUR 64) for a dedicated transcription utility.",
        ],
        "watch_out": [
            "Closed source, macOS only (plus a separate iOS app); no Windows or Linux version.",
            "No built-in local meeting library search, cross-meeting Ask, MCP server, or workday memory.",
        ],
        "facts": [
            ("License", "Proprietary"),
            ("Local models", "Local Whisper-family models on macOS; summaries via Ollama or external AI API keys"),
            ("Runs on", "macOS (separate iOS app)"),
            ("Price", "Free tier; Pro EUR 64 one-time"),
        ],
        "links": [
            ("LokalBot vs MacWhisper", "/lokalbot-vs-macwhisper"),
            ("MacWhisper page", "https://goodsnooze.gumroad.com/l/macwhisper"),
        ],
        "license_url": "https://goodsnooze.gumroad.com/l/macwhisper",
        "os": "macOS, iOS",
        "sources": [
            "https://goodsnooze.gumroad.com/l/macwhisper",
        ],
    },
    {
        "id": "screenpipe",
        "name": "Screenpipe",
        "tagline": "Continuous 24/7 local screen and audio capture built as an agent data layer",
        "site": "https://screenpi.pe/",
        "compare_slug": "lokalbot-vs-screenpipe",
        "about": (
            "<p>Screenpipe runs on macOS, Windows, and Linux and records your screen and audio continuously, exposing "
            "everything through a local REST API, MCP server, and programmable agent pipes. Meeting transcription with "
            "speaker labels and summary pipes sit on top of that continuous capture stream. While its code is public, "
            "current releases use the source-available Screenpipe Commercial License rather than an OSI open-source license.</p>"
        ),
        "good_for": [
            "Developers building custom local automations and agent pipes over a continuous screen and audio log.",
            "Intel Mac, Windows, and Linux users who want always-on capture rather than meeting-first workflows.",
        ],
        "watch_out": [
            "Continuous capture uses roughly 30 GB of disk per month and requires a paid commercial license for business use ($21/mo Basic, $42/seat Business).",
            "Does not ship a built-in fine-tuned summarization model by default; you connect your own AI provider or local runner.",
        ],
        "facts": [
            ("License", "Source-available (Screenpipe Commercial License; paid for business use)"),
            ("Local models", "Local Whisper transcription and OCR; connects to external or local LLMs for summaries"),
            ("Runs on", "macOS 13+, Windows 10+, Linux (AppImage)"),
            ("Price", "Free personal tier (limited history); Basic $21/mo; Business $42/seat/mo"),
        ],
        "links": [
            ("LokalBot vs Screenpipe", "/lokalbot-vs-screenpipe"),
            ("Screenpipe site", "https://screenpi.pe/"),
        ],
        "license_url": "https://github.com/mediar-ai/screenpipe/blob/main/LICENSE.md",
        "os": "macOS, Windows, Linux",
        "sources": [
            "https://screenpi.pe/",
            "https://github.com/mediar-ai/screenpipe",
        ],
    },
]

GLANCE_COLUMNS = [
    "Default processing",
    "Local models & WER",
    "Typical disk / RAM",
    "Platforms",
    "Local MCP",
    "License & price",
]

GLANCE_ROWS = {
    "lokalbot": [
        "100% local by default",
        "Qwen3-ASR 1.7B v3 (9.79% AMI ihm) + Qwen3.5 4B v4",
        "~4 GB (Win/Linux) to ~9.6 GB (Mac full stack); 50 MB search RAM",
        "Mac, Win/Linux (alpha), iOS/Android E2EE sync",
        "Yes, free read-only stdio",
        "GPLv3, free",
    ],
    "meetily": [
        "Local by default",
        "Whisper / Parakeet + Qwen 3.5 or Ollama",
        "~2-5 GB models depending on Whisper + LLM size",
        "Mac, Windows; Linux from source",
        "Pro only ($10/user/mo)",
        "MIT (Community); Pro paid",
    ],
    "anarlog": [
        "Local ASR on Mac; BYO LLM",
        "On-device ASR on Mac; Ollama / LM Studio / API keys",
        "Depends on external LLM runner (Ollama/LM Studio)",
        "Mac; Win/Linux/mobile beta",
        "Yes, local CLI & MCP",
        "MIT (Community); paid hosted",
    ],
    "openwhispr": [
        "Setup recommends cloud; local selectable",
        "Orukeet / Whisper + llama.cpp or cloud",
        "~1-4 GB when using local models",
        "Mac (ARM + Intel), Win, Linux, iOS",
        "Hosted MCP on paid plan; local CLI free",
        "MIT client; $8-$16/mo cloud",
    ],
    "macwhisper": [
        "Local speech; BYO AI summaries",
        "Whisper-family local models; Ollama or API keys",
        "~1-3 GB speech models",
        "macOS, iOS",
        "No",
        "Proprietary; free / EUR 64 Pro",
    ],
    "screenpipe": [
        "Local capture; BYO AI",
        "Local Whisper + OCR; connects to your AI",
        "~30 GB/month continuous capture storage",
        "Mac (ARM + Intel), Win, Linux",
        "Yes, local REST + MCP",
        "Source-available; $21-$42/mo",
    ],
}

BENCHMARK_ROWS = [
    ("Qwen3-ASR 1.7B (LokalBot v3)", "Speech (Mac default)", "2.52 GB Q8_0", "9.79% AMI ihm · 12.81% code-switch · 0 silence ghosts", "31.2x RT on M4 Max"),
    ("Qwen3-ASR 0.6B (LokalBot v1)", "Speech (compact)", "1.02 GB Q8_0", "10.72% AMI ihm · 20.72% code-switch · 0 silence ghosts", "52.7x RT on M4 Max"),
    ("Parakeet TDT 0.6B v3", "Speech (fast 25 lang)", "0.63 GB Core ML", "19.2% AMI mixed · 1.65% DE FLEURS", "129x-190x RT on M4 Max"),
    ("Qwen3.5 4B (LokalBot v4)", "Notes, actions & memory", "2.74 GB Q4_K_M", "118/120 Memory120 · -60.6% Blind21 rejections", "13.64 s median (G4 GPU)"),
    ("EmbeddingGemma 2", "Hybrid meeting search", "0.31 GB Q8_0", "0.595 R@10 on 232 QMSum meetings", "39 ms p50 · 50 MB RAM"),
    ("Gemma 4 E2B (LokalBot v4)", "Inline autocomplete", "3.85 GB i1-Q6_K", "56/56 context grounding · 80.0% email precision", "20.2 ms boundary / 56 ms typing"),
]


def _list(items: list[str]) -> str:
    return "\n".join(f"            <li>{item}</li>" for item in items)


def _facts(tool: dict) -> str:
    rows = "\n".join(f"            <dt>{label}</dt><dd>{value}</dd>" for label, value in tool["facts"])
    return f'          <dl class="tool-facts">\n{rows}\n          </dl>'


def _links(tool: dict) -> str:
    buttons = []
    for label, url in tool["links"]:
        ext = ' target="_blank" rel="noopener"' if url.startswith("http") else ""
        buttons.append(
            f'            <a class="btn btn--ghost btn--sm" href="{url}"{ext}>{label}'
            ' <i class="ph ph-arrow-right" aria-hidden="true"></i></a>'
        )
    return '          <div class="tool-links">\n' + "\n".join(buttons) + "\n          </div>"


def _tool_section(tool: dict) -> str:
    return "\n".join(
        [
            f'        <section class="tool" id="{tool["id"]}" aria-labelledby="{tool["id"]}-title">',
            f'          <h3 id="{tool["id"]}-title">{tool["name"]}</h3>',
            f'          <p class="tool-tagline">{tool["tagline"]}</p>',
            f'          {tool["about"]}',
            '          <p class="tool-label">Good for</p>',
            "          <ul>",
            _list(tool["good_for"]),
            "          </ul>",
            '          <p class="tool-label">Watch out for</p>',
            "          <ul>",
            _list(tool["watch_out"]),
            "          </ul>",
            _facts(tool),
            _links(tool),
            "        </section>",
        ]
    )


def _glance_table() -> str:
    head = "".join(f'<th scope="col">{column}</th>' for column in ["App", *GLANCE_COLUMNS])
    rows = []
    for tool in TOOLS:
        cells = "".join(f"<td>{cell}</td>" for cell in GLANCE_ROWS[tool["id"]])
        rows.append(f'              <tr><th scope="row"><a href="#{tool["id"]}">{tool["name"]}</a></th>{cells}</tr>')
    return (
        '        <div class="guide-table-wrap">\n'
        '          <table class="guide-table guide-table--wide">\n'
        f"            <thead><tr>{head}</tr></thead>\n"
        "            <tbody>\n" + "\n".join(rows) + "\n            </tbody>\n"
        "          </table>\n"
        "        </div>"
    )


def _benchmark_table() -> str:
    rows = "\n".join(
        f'              <tr><th scope="row">{model}</th><td>{role}</td><td>{size}</td><td>{score}</td><td>{speed}</td></tr>'
        for model, role, size, score, speed in BENCHMARK_ROWS
    )
    return (
        '        <div class="guide-table-wrap">\n'
        '          <table class="guide-table guide-table--wide">\n'
        '            <thead><tr><th scope="col">Model</th><th scope="col">Role</th><th scope="col">Disk</th><th scope="col">Measured result</th><th scope="col">Speed / RAM</th></tr></thead>\n'
        f"            <tbody>\n{rows}\n            </tbody>\n"
        "          </table>\n"
        "        </div>"
    )


def _sources() -> str:
    parts = []
    for tool in TOOLS:
        if not tool["sources"]:
            continue
        links = ", ".join(
            f'<a href="{url}" target="_blank" rel="noopener">{escape(url.split("://", 1)[1])}</a>' for url in tool["sources"]
        )
        parts.append(f"          <li><strong>{tool['name']}:</strong> {links}</li>")
    return "\n".join(parts)


def render_body() -> str:
    verified = _long_date(VERIFIED)
    sections = "\n\n".join(_tool_section(tool) for tool in TOOLS)
    return f"""
        <p class="blog-note"><strong>Disclosure:</strong> LokalBot is our app. Every claim about the other five projects comes from their public sites, licenses, documentation, and release notes checked on {verified}. Nobody paid to be listed. If a price, license, or platform detail changes, <a href="{ISSUES_URL}" target="_blank" rel="noopener">open an issue on GitHub</a>.</p>

        <h2 id="short-answer">The short answer</h2>
        <p>All six tools avoid sending a visible bot into your Zoom, Teams, or Google Meet calls, and all six can transcribe audio on your computer. They split cleanly by scope, license, and how much setup you want:</p>
        <ul>
          <li><strong>Best all-in-one local meeting library with free MCP and fine-tuned models:</strong> <a href="#lokalbot">LokalBot</a> (GPLv3, free, Mac plus Windows and Linux in alpha).</li>
          <li><strong>Best MIT-licensed Windows + Mac meeting recorder if you want commercial Pro support:</strong> <a href="#meetily">Meetily</a>.</li>
          <li><strong>Best bring-your-own-Ollama meeting notepad:</strong> <a href="#anarlog">Anarlog (formerly Hyprnote)</a>.</li>
          <li><strong>Best dictation-first cross-platform tool (including Intel Mac and standalone iOS):</strong> <a href="#openwhispr">OpenWhispr</a> (switch off its default cloud option during setup).</li>
          <li><strong>Best Mac file and subtitle transcriber:</strong> <a href="#macwhisper">MacWhisper</a> (proprietary, one-time Pro license).</li>
          <li><strong>Best continuous 24/7 screen and audio capture layer for custom agent pipes:</strong> <a href="#screenpipe">Screenpipe</a> (source-available, commercial license for work).</li>
        </ul>

        <h2 id="at-a-glance">At a glance</h2>
        <p>Verified {verified}. Check your own machine's RAM and disk budget in the <a href="/hardware">Hardware Calculator</a>, or compare subscription savings in the <a href="/calculator">SaaS AI Cost Calculator</a>.</p>
{_glance_table()}

        <h2 id="measured-models">Measured local WER, RAM, and speed</h2>
        <p>Cloud meeting apps rarely publish reproducible word error rates. Here are measured local numbers from LokalBot's open <a href="/benchmarks">Local Desktop AI Leaderboard</a> and v0.14.0 Apache-2.0 fine-tunes (primary desktop measurements on Apple M4 Max 48 GB; GPU extraction replay on NVIDIA RTX PRO 6000 Blackwell):</p>
{_benchmark_table()}
        <p>Migrating existing notes from Granola, Otter.ai, Fireflies, Fathom, or Zoom into plain Markdown? Run our offline browser converter at <a href="/migrate">lokalbot.com/migrate</a> without uploading a file.</p>

        <h2 id="the-apps">The six local meeting note takers, one by one</h2>
        <p>Each card lists what the app runs locally, where it sends data if anywhere, its exact license, and its tradeoffs.</p>

{sections}

        <h2 id="how-to-pick">What to verify before trusting a local meeting app</h2>
        <ol>
          <li><strong>Default network path:</strong> Download the models, turn off Wi-Fi, and run a 60-second test call. Some "local" apps still default to cloud transcription or cloud summaries during onboarding.</li>
          <li><strong>License boundaries:</strong> Distinguish OSI open source (GPLv3, MIT, Apache-2.0) from source-available commercial licenses or split open-core codebases where speaker labels and MCP move behind a paywall.</li>
          <li><strong>Hardware fit:</strong> On an 8 GB or 16 GB laptop, a compact speech model (0.6-1.0 GB) plus a 4B quantized summary model (~2.7 GB) leaves room for your browser and video call. Test exact residency in our <a href="/hardware">Hardware Calculator</a>.</li>
          <li><strong>Consent still applies:</strong> Recording without a bot keeps audio off third-party servers, but legal and workplace recording rules still require telling participants before you record.</li>
        </ol>

        <h2 id="sources">Sources</h2>
        <p>Checked on {verified} against each project's public pages and repositories:</p>
        <ul class="source-list">
{_sources()}
        </ul>
        <p>LokalBot's facts come from its <a href="{REPO_URL}#readme" target="_blank" rel="noopener">README</a>, <a href="/privacy">privacy policy</a>, and <a href="/benchmarks">open benchmarks</a>. Trademarks belong to their owners.</p>
        """


def item_list() -> dict:
    """Schema.org ItemList of the local meeting note takers compared."""

    return {
        "@type": "ItemList",
        "@id": f"https://www.lokalbot.com/{SLUG}#apps",
        "name": "Local and open-source AI meeting note takers compared",
        "numberOfItems": len(TOOLS),
        "itemListElement": [
            {
                "@type": "ListItem",
                "position": position,
                "url": f"https://www.lokalbot.com/{SLUG}#{tool['id']}",
                "item": (
                    {"@id": "https://www.lokalbot.com/#software"}
                    if tool["id"] == "lokalbot"
                    else {
                        "@type": "SoftwareApplication",
                        "name": tool["name"],
                        "url": tool["site"],
                        "operatingSystem": tool["os"],
                        "license": tool["license_url"],
                        "applicationCategory": "ProductivityApplication",
                    }
                ),
            }
            for position, tool in enumerate(TOOLS, start=1)
        ],
    }


MEETING_NOTES_ROUNDUP = {
    "slug": SLUG,
    "kind": "compare",
    "footer_label": "Best local AI meeting notes",
    "published": PUBLISHED,
    "updated": VERIFIED,
    "updated_label": _long_date(VERIFIED),
    "title": "Best Local & Open-Source AI Meeting Note Takers (2026)",
    "description": "Compare 6 local AI meeting note takers in 2026: LokalBot, Meetily, Anarlog, OpenWhispr, MacWhisper, and Screenpipe on local WER, RAM, platforms, and license.",
    "eyebrow": "Compare",
    "h1": "Best local and open-source AI meeting note takers (2026)",
    "lead": "Six bot-free meeting note takers that transcribe on your own computer, compared on default privacy, measured local accuracy, RAM usage, MCP access, and open-source licenses.",
    "read_time": "10 min read",
    "body": render_body(),
    "item_list": item_list(),
    "faq": [
        (
            "What is the best completely free, open-source local AI meeting note taker?",
            "LokalBot (GPLv3) ships every feature in one free app with no paid tier: bot-free two-track capture, fine-tuned Apache-2.0 local models for transcription and summaries, speaker separation, Obsidian export, and a free read-only local MCP server. Meetily Community Edition (MIT) is also free for core local recording and summaries, with speaker separation and MCP in its paid Pro tier.",
        ),
        (
            "Do local AI meeting note takers work completely offline?",
            "Yes, once the speech and language models are downloaded. LokalBot, Meetily Community Edition, and MacWhisper transcribe offline. In OpenWhispr, choose on-device models during setup instead of its recommended cloud option. Anarlog transcribes locally on supported Macs and pairs with Ollama or LM Studio for offline summaries.",
        ),
        (
            "How much RAM do I need for local meeting transcription and summaries?",
            "A 16 GB Apple Silicon Mac or a 16 GB Windows or Linux PC comfortably runs a 0.6B-1.7B speech model (1.0-2.5 GB) and a 4B quantized summary model (~2.7 GB) sequentially. On 8 GB machines, use compact speech models like Qwen3-ASR 0.6B or Parakeet 0.6B and smaller summarizers. Check your exact hardware at lokalbot.com/hardware.",
        ),
        (
            "Which local meeting note takers run on Linux and Windows?",
            "LokalBot (native Rust + GPUI alpha with .deb, .rpm, Arch, and Windows installer), OpenWhispr (AppImage, .deb, .rpm, Windows), Screenpipe (AppImage, Windows), and Anarlog (beta; cloud or BYO transcription server on Linux/Windows). Meetily ships native Windows binaries and builds from source on Linux. MacWhisper is macOS and iOS only.",
        ),
        (
            "Which local meeting note taker has a free local MCP server for Claude Code or Cursor?",
            "LokalBot includes a free, read-only local stdio MCP server (lokalbot-cli mcp, off until enabled in Settings) with no cloud sync required. Anarlog and Screenpipe also expose local MCP servers. Meetily gates MCP to Pro, and OpenWhispr's MCP server is hosted on paid plans.",
        ),
    ],
    "related": [
        "open-source-ai-meeting-notes",
        "granola-otter-alternatives-linux-windows",
        "gdpr-local-ai-meeting-notes",
    ],
}
