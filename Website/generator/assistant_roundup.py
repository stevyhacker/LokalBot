"""The "best open-source AI assistants" comparison at /best-open-source-ai-assistants.

Rendered by Website/generator/render_web.py as a guide with "kind": "compare", so it is
listed under Compare on /guides. Every fact about another project must come
from that project's own site, docs, license file, or release notes, checked on
VERIFIED. LokalBot's facts must match the README and PRIVACY.md.

Monthly re-check:
1. For each tool, check the latest release, license, platforms, price, memory
   and document features against the sources in its "sources" list.
2. Update the tool's fields and prose, set VERIFIED to the check date, and add
   an UPDATE_LOG entry that says what changed (or that nothing did).
3. Retake a screenshot when the app's main window has visibly changed. The
   recipe is in Docs/guides/best-ai-assistants-screenshots.md.
4. Run `python3 Website/generator/render_web.py` and commit the regenerated HTML.
"""

from __future__ import annotations

from datetime import date
from html import escape

SLUG = "best-open-source-ai-assistants"
PUBLISHED = "2026-11-09"
# The day every competitor fact below was last checked against its source.
VERIFIED = "2026-11-09"
IMAGES = "assets/compare/ai-assistants"
ISSUES_URL = "https://github.com/stevyhacker/lokalbot/issues"
REPO_URL = "https://github.com/stevyhacker/lokalbot"


def _long_date(iso: str) -> str:
    day = date.fromisoformat(iso)
    return f"{day:%B} {day.day}, {day.year}"


# Newest first. Say what changed on the page each month, even "nothing changed".
UPDATE_LOG = [
    (
        "2026-11-09",
        "First published. Checked Ollama 0.40.15, LM Studio 0.4.28, Jan 0.8.8, AnythingLLM 1.19.0, "
        "Open WebUI 0.13.3, and LokalBot 0.12.2.",
    ),
]

# Order: model runners, then chat apps, then LokalBot.
TOOLS = [
    {
        "id": "ollama",
        "name": "Ollama",
        "tagline": "The model runner other apps build on",
        "site": "https://ollama.com/",
        "image": "ollama.webp",
        "image_size": (1600, 1000),
        "alt": "A terminal running Ollama 0.40.15 on Linux: ollama list shows qwen3.5:4b, then ollama run answers a question about bread.",
        "caption": "Real output from Ollama 0.40.15's command line on Linux, answering with Qwen3.5 4B on the CPU. On macOS and Windows, Ollama also has a chat window.",
        "about": (
            "<p>With about 186,000 GitHub stars, Ollama is the best-known way to run open models on your own computer. One command downloads a model and runs it, "
            "and a local API that speaks the OpenAI and Anthropic formats serves it to other apps. That API is why so many tools in this list, "
            "LokalBot included, can use Ollama as their engine. On macOS and Windows it also has a simple chat app with chat history, "
            "file attachments, and a thinking switch. On Linux it is command line only.</p>"
        ),
        "good_for": [
            "Running models for other apps, scripts, and coding agents.",
            "A dependable local API with one-command model downloads.",
        ],
        "watch_out": [
            "No memory between chats, and attached files are pasted into the prompt rather than indexed, so long files get cut off. Unless your GPU has 24 GB or more, the default context is 4,096 tokens.",
            "Cloud models and web search are on by default, and using them needs an Ollama account. Set <code>OLLAMA_NO_CLOUD=1</code> to turn them off.",
        ],
        "facts": [
            ("Latest release", "0.40.15, November 3, 2026"),
            ("License", '<a href="https://github.com/ollama/ollama/blob/main/LICENSE" target="_blank" rel="noopener">MIT</a>, app included'),
            ("Runs on", "macOS 14+, Windows 10+, Linux (command line only), Docker"),
            ("Price", "Free on your own hardware; optional cloud plans from $20 a month"),
            ("Source", '<a href="https://github.com/ollama/ollama" target="_blank" rel="noopener">github.com/ollama/ollama</a> · about 186k stars'),
        ],
        "links": [
            ("Download Ollama", "https://ollama.com/download"),
            ("Releases on GitHub", "https://github.com/ollama/ollama/releases"),
        ],
        "install": [
            ("# macOS and Linux", "curl -fsSL https://ollama.com/install.sh | sh"),
            ("# then download and chat with a model", "ollama run qwen3.5:4b"),
        ],
        "license_url": "https://github.com/ollama/ollama/blob/main/LICENSE",
        "os": "macOS, Windows, Linux",
        "sources": [
            "https://github.com/ollama/ollama/releases",
            "https://docs.ollama.com/faq",
            "https://docs.ollama.com/context-length",
            "https://ollama.com/pricing",
        ],
    },
    {
        "id": "lm-studio",
        "name": "LM Studio",
        "tagline": "The polished desktop app for trying models",
        "site": "https://lmstudio.ai/",
        "image": "lm-studio.webp",
        "image_size": (1600, 1000),
        "alt": "LM Studio 0.4.28 chat window with Gemma 4 E4B explaining in three paragraphs how a heat pump heats a house, after 13.9 seconds of reasoning.",
        "caption": "LM Studio 0.4.28 on Linux with Gemma 4 E4B, the model it suggests on first run, answering with reasoning on.",
        "about": (
            "<p>LM Studio is a desktop app for finding, downloading, and running models from Hugging Face. It has a clean chat window, "
            "chat with documents, MCP tools, and a local server that speaks the OpenAI and Anthropic formats. It runs llama.cpp everywhere "
            "and Apple's MLX on Apple Silicon. Of the apps here, it's the nicest for trying and comparing models.</p>"
            "<p><strong>It is not open source.</strong> The app is proprietary, though free for home and work since July 2025. "
            "Its <code>lms</code> command-line tool, SDKs, and MLX engine are MIT-licensed. We include it because it's one of the most "
            "common answers to “how do I run AI locally?”</p>"
        ),
        "good_for": [
            "Trying and comparing models from Hugging Face.",
            "Serving a model to other apps from a desktop app instead of the command line.",
        ],
        "watch_out": [
            "Closed source, and it remembers nothing between chats: its docs say the model only knows what's in the chat or the system prompt.",
            "Document chat reads PDF, Word, and text files. Voice input and web search aren't in LM Studio; the company's new agent app, LM Studio Bionic, has them, partly on paid plans.",
            "Intel Macs aren't supported.",
        ],
        "facts": [
            ("Latest release", "0.4.28, October 31, 2026"),
            ("License", 'Proprietary (<a href="https://lmstudio.ai/app-terms" target="_blank" rel="noopener">app terms</a>), free for home and work; CLI and SDKs MIT'),
            ("Runs on", "macOS 14+ on Apple Silicon, Windows (x64 and Arm), Linux (x64 and Arm AppImage)"),
            ("Price", "Free"),
            ("Source", 'App not public; <a href="https://github.com/lmstudio-ai" target="_blank" rel="noopener">CLI and SDKs on GitHub</a>'),
        ],
        "links": [
            ("Download LM Studio", "https://lmstudio.ai/download"),
            ("Documentation", "https://lmstudio.ai/docs/app"),
        ],
        "install": [],
        "license_url": "https://lmstudio.ai/app-terms",
        "os": "macOS, Windows, Linux",
        "sources": [
            "https://lmstudio.ai/changelog/lmstudio",
            "https://lmstudio.ai/app-terms",
            "https://lmstudio.ai/blog/free-for-work",
            "https://lmstudio.ai/docs/app/system-requirements",
            "https://lmstudio.ai/docs/app/basics/chat",
            "https://lmstudio.ai/docs/app/basics/rag",
        ],
    },
    {
        "id": "jan",
        "name": "Jan",
        "tagline": "The open-source ChatGPT-style desktop app",
        "site": "https://www.jan.ai/",
        "image": "jan.webp",
        "image_size": (1600, 1000),
        "alt": "Jan 0.8.8 chat window with Jan-v3.5-4B writing a friendly note asking a neighbour to water tomatoes, generated at 16 tokens per second.",
        "caption": "Jan 0.8.8 on Linux with Jan-v3.5-4B, the model it downloads during setup, writing at 16 tokens a second on the CPU.",
        "about": (
            "<p>Jan is the open-source app that feels closest to ChatGPT: install it, let it download a recommended model, and start typing. "
            "It bundles llama.cpp, can also use cloud models with your own API keys, and has projects, chat with files with citations, "
            "MCP tools, web search, and an OpenAI-compatible local server. Analytics stay off unless you allow them during setup.</p>"
        ),
        "good_for": [
            "A simple, open-source private chat app.",
            "Using local and cloud models side by side in one window.",
        ],
        "watch_out": [
            "No memory yet: Jan's site lists it as “coming soon”. Projects share instructions and files across chats in the meantime.",
            "Web search is on by default and sends your query to Exa when the model decides to search. On Intel Macs, Jan only works with cloud models.",
            "Jan published 11 security advisories on October 29, 2026, two of them critical. Use version 0.8.8 or later.",
        ],
        "facts": [
            ("Latest release", "0.8.8, October 28, 2026"),
            ("License", '<a href="https://github.com/janhq/jan/blob/main/LICENSE" target="_blank" rel="noopener">Apache 2.0</a> since May 2025 (AGPLv3 before)'),
            ("Runs on", "macOS 13.6+ (Apple Silicon for local models), Windows 10+, Linux (x64)"),
            ("Price", "Free"),
            ("Source", '<a href="https://github.com/janhq/jan" target="_blank" rel="noopener">github.com/janhq/jan</a> · about 45.6k stars'),
        ],
        "links": [
            ("Download Jan", "https://www.jan.ai/download"),
            ("Releases on GitHub", "https://github.com/janhq/jan/releases"),
        ],
        "install": [
            ("# Linux, from Flathub", "flatpak install flathub ai.jan.Jan"),
        ],
        "license_url": "https://github.com/janhq/jan/blob/main/LICENSE",
        "os": "macOS, Windows, Linux",
        "sources": [
            "https://github.com/janhq/jan/releases",
            "https://jan.ai/",
            "https://docs.jan.ai/desktop/privacy",
            "https://docs.jan.ai/desktop/web-search",
            "https://github.com/janhq/jan/security/advisories",
        ],
    },
    {
        "id": "anythingllm",
        "name": "AnythingLLM",
        "tagline": "The app for chatting with your documents",
        "site": "https://anythingllm.com/",
        "image": "anythingllm.webp",
        "image_size": (1600, 1000),
        "alt": "AnythingLLM workspace called Community garden answering “What happens if I miss a watering shift?” from an uploaded handbook PDF: a €10 contribution to the seed fund unless you arrange a swap, with the source listed.",
        "caption": "AnythingLLM 1.19 answering from a sample handbook PDF in a workspace, with the source listed under the answer. Qwen3.5 4B on Ollama.",
        "about": (
            "<p>AnythingLLM is built around workspaces of documents. Add PDFs, Word files, spreadsheets, web pages, or a GitHub repository, "
            "then ask questions and see the sources under each answer. It also has agents that browse the web and run scheduled jobs, MCP tools, "
            "voice input, and, in the desktop app for macOS and Windows, a meeting assistant that transcribes calls on your computer. The desktop app is single-user "
            "and has its own llama.cpp engine. The Docker version adds user accounts and an embeddable chat widget.</p>"
        ),
        "good_for": [
            "Asking questions across a pile of documents, with sources.",
            "Small teams sharing document workspaces on one server.",
        ],
        "watch_out": [
            "Anonymous usage telemetry is on by default. Turn it off under Privacy, or with <code>DISABLE_TELEMETRY=true</code> on Docker.",
            "Some desktop features, such as the meeting assistant and the Magic dictation and autocomplete tools, aren't in the public repository, and unlimited use of the Magic tools needs a paid Pro license.",
            "Agent web search goes to You.com by default.",
        ],
        "facts": [
            ("Latest release", "1.19.0, October 26, 2026"),
            ("License", '<a href="https://github.com/Mintplex-Labs/anything-llm/blob/master/LICENSE" target="_blank" rel="noopener">MIT</a>'),
            ("Runs on", "macOS, Windows, Linux (AppImage), Docker; an Android app"),
            ("Price", "Free; hosted cloud from $50 a month"),
            ("Source", '<a href="https://github.com/Mintplex-Labs/anything-llm" target="_blank" rel="noopener">github.com/Mintplex-Labs/anything-llm</a> · about 68k stars'),
        ],
        "links": [
            ("Download AnythingLLM", "https://anythingllm.com/download"),
            ("Docker guide", "https://docs.anythingllm.com/installation-docker/local-docker"),
        ],
        "install": [
            ("# Docker, for several users; then open http://localhost:3001", 'export STORAGE_LOCATION=$HOME/anythingllm && mkdir -p $STORAGE_LOCATION && touch "$STORAGE_LOCATION/.env"'),
            ("", 'docker run -d -p 3001:3001 --cap-add SYS_ADMIN \\\n  -v ${STORAGE_LOCATION}:/app/server/storage \\\n  -v ${STORAGE_LOCATION}/.env:/app/server/.env \\\n  -e STORAGE_DIR="/app/server/storage" mintplexlabs/anythingllm'),
        ],
        "license_url": "https://github.com/Mintplex-Labs/anything-llm/blob/master/LICENSE",
        "os": "macOS, Windows, Linux, Android",
        "sources": [
            "https://github.com/Mintplex-Labs/anything-llm/releases",
            "https://docs.anythingllm.com/installation-docker/overview",
            "https://docs.anythingllm.com/features/memories",
            "https://github.com/Mintplex-Labs/anything-llm#telemetry--privacy",
            "https://anythingllm.com/cloud",
        ],
    },
    {
        "id": "open-webui",
        "name": "Open WebUI",
        "tagline": "The self-hosted ChatGPT for a household or team",
        "site": "https://openwebui.com/",
        "image": "open-webui.webp",
        "image_size": (1600, 1000),
        "alt": "Open WebUI 0.13.3 in a browser answering “What should I cook for dinner tonight?” with vegetarian ideas, using two saved memories: vegetarian, and living in Bar, Montenegro.",
        "caption": "Open WebUI 0.13.3 in a browser, connected to Ollama. The answer uses two memories we added under Settings → Personalization → Memory.",
        "about": (
            "<p>Open WebUI is a self-hosted, ChatGPT-style web app. You run it as a server with Docker or Python, connect it to Ollama or any "
            "OpenAI-compatible API, and open it in a browser on any device, including as an installable app on your phone. It has the longest "
            "feature list here: accounts and groups, knowledge bases with citations, web search, memory, voice calls with local Whisper "
            "transcription, image generation, tools, and MCP.</p>"
        ),
        "good_for": [
            "One private ChatGPT-like web app for several people.",
            "Power users who want every feature and don't mind running a server.",
        ],
        "watch_out": [
            "It doesn't run models itself; you need Ollama or another server beside it. A new desktop app (0.1.4, AGPLv3) can run both on one computer.",
            "Since version 0.6.6 (April 2025) the Open WebUI License adds a branding clause to BSD-3 terms: above 50 users you may not remove the Open WebUI branding without an enterprise license. Its own docs say it is not an OSI-approved open-source license.",
            "It's a server to keep updated: there were four releases between November 3 and 8, 2026, and security fixes ship often. With a small model, its built-in tools can pull answers off topic.",
        ],
        "facts": [
            ("Latest release", "0.13.3, November 8, 2026"),
            ("License", '<a href="https://github.com/open-webui/open-webui/blob/main/LICENSE" target="_blank" rel="noopener">Open WebUI License</a> (BSD-3 plus a branding clause)'),
            ("Runs on", "Any OS with Docker or Python 3.11–3.12; a desktop app for macOS, Windows, and Linux"),
            ("Price", "Free; enterprise license for rebranding and support"),
            ("Source", '<a href="https://github.com/open-webui/open-webui" target="_blank" rel="noopener">github.com/open-webui/open-webui</a> · about 158k stars'),
        ],
        "links": [
            ("Quick start", "https://docs.openwebui.com/getting-started/quick-start"),
            ("Releases on GitHub", "https://github.com/open-webui/open-webui/releases"),
        ],
        "install": [
            ("# Docker, with Ollama on the same computer; then open http://localhost:3000", "docker run -d -p 3000:8080 --add-host=host.docker.internal:host-gateway \\\n  -v open-webui:/app/backend/data --name open-webui --restart always ghcr.io/open-webui/open-webui:main"),
            ("# or with Python 3.11 or 3.12", "pip install open-webui && open-webui serve"),
        ],
        "license_url": "https://github.com/open-webui/open-webui/blob/main/LICENSE",
        "os": "Any (Docker or Python); macOS, Windows, Linux desktop app",
        "sources": [
            "https://github.com/open-webui/open-webui/releases",
            "https://docs.openwebui.com/license",
            "https://docs.openwebui.com/features/chat-conversations/memory",
            "https://docs.openwebui.com/getting-started/quick-start",
            "https://github.com/open-webui/desktop/releases",
        ],
    },
    {
        "id": "lokalbot",
        "name": "LokalBot",
        "tagline": "Our app: an assistant that remembers your work",
        "site": "https://www.lokalbot.com/",
        "image": "lokalbot.webp",
        "image_dark": "lokalbot-dark.webp",
        "image_size": (1600, 1000),
        "alt": "LokalBot's Quick Recall searching for “demo pres”: it finds a Keynote deck and a Mail reply seen on screen, and two meetings where the demo presentation came up.",
        "caption": "LokalBot's Quick Recall on a Mac, with fictional demo data: one search finds a Keynote deck and a Mail reply you saw on screen, and two meetings where it came up.",
        "about": (
            "<p>LokalBot is our app, and it's a different kind of assistant. Instead of starting from an empty chat, it builds a memory of your work. "
            "It records meetings without a bot joining, transcribes and summarizes them on your computer, and, if you turn it on, keeps the text "
            "of what you saw on screen. Ask a question and the answer cites the meeting or screen moment it came from. It also has dictation, "
            "autocomplete in other apps, a search of folders you choose, and a read-only MCP server, off until you turn it on, so Claude Code or Codex can search your library. "
            "Its models are built in; you can also point it at Ollama or another OpenAI-compatible server.</p>"
        ),
        "good_for": [
            "Remembering what was said and decided in meetings, and finding something you saw.",
            "Giving coding agents your context, read-only.",
        ],
        "watch_out": [
            "It isn't a general chat app for trying models; pair it with one of the apps above for that.",
            "Recording needs your colleagues' consent, and screen memory and dictation need system permissions.",
            "It's best on a Mac. The Windows and Linux app is in alpha, and LokalBot is a small project built by one developer.",
        ],
        "facts": [
            ("Latest release", "0.12.2, November 5, 2026"),
            ("License", '<a href="https://github.com/stevyhacker/lokalbot/blob/master/LICENSE" target="_blank" rel="noopener">GPLv3</a>'),
            ("Runs on", 'macOS 15+ on Apple Silicon; Windows 10/11 and Linux in alpha (<a href="system-requirements">requirements</a>)'),
            ("Price", "Free, no account"),
            ("Source", f'<a href="{REPO_URL}" target="_blank" rel="noopener">github.com/stevyhacker/lokalbot</a> · 91 stars'),
        ],
        "links": [
            ("Download LokalBot", "https://github.com/stevyhacker/lokalbot/releases/latest"),
            ("Star on GitHub", REPO_URL),
        ],
        "install": [
            ("# Mac, with Homebrew", "brew install --cask stevyhacker/tap/lokalbot"),
        ],
        "license_url": "https://github.com/stevyhacker/lokalbot/blob/master/LICENSE",
        "os": "macOS 15+, Windows 10/11 (alpha), Linux (alpha)",
        "sources": [],
    },
]

# Columns of the at-a-glance table, in TOOLS order.
GLANCE_COLUMNS = ["Best for", "Runs models itself", "Remembers you across chats", "Chat with your files", "License"]
GLANCE_ROWS = {
    "ollama": [
        "Running models for other apps and agents",
        "Yes",
        "No",
        "Attaches a file's text to the prompt",
        "MIT",
    ],
    "lm-studio": [
        "Trying models in a polished app",
        "Yes",
        "No",
        "PDF, Word, and text files",
        "Proprietary, free",
    ],
    "jan": [
        "A simple private chat app",
        "Yes",
        "Not yet (“coming soon”)",
        "Yes, with citations",
        "Apache 2.0",
    ],
    "anythingllm": [
        "Chatting with documents",
        "Yes, in the desktop app",
        "Optional, off by default",
        "Yes, workspaces with sources",
        "MIT",
    ],
    "open-webui": [
        "A shared web app for a household or team",
        "No, connects to Ollama or an API",
        "Yes, marked experimental",
        "Yes, knowledge bases with citations",
        "Open WebUI License (not OSI)",
    ],
    "lokalbot": [
        "Remembering your meetings and screen",
        "Yes, built in",
        "Yes, learns from your own words",
        "Searches folders you choose",
        "GPLv3",
    ],
}


def _figure(tool: dict) -> str:
    width, height = tool["image_size"]
    src = f"{IMAGES}/{tool['image']}"
    img = (
        f'<img src="{src}" width="{width}" height="{height}" alt="{escape(tool["alt"], quote=True)}" '
        'loading="lazy" decoding="async" />'
    )
    if tool.get("image_dark"):
        img = (
            f'<picture><source srcset="{IMAGES}/{tool["image_dark"]}" media="(prefers-color-scheme: dark)" '
            f'width="{width}" height="{height}" />{img}</picture>'
        )
    return (
        '          <figure class="blog-figure">\n'
        f'            <a href="{src}" target="_blank" rel="noopener">{img}</a>\n'
        f"            <figcaption>{tool['caption']}</figcaption>\n"
        "          </figure>"
    )


def _list(items: list[str]) -> str:
    return "\n".join(f"            <li>{item}</li>" for item in items)


def _install(tool: dict) -> str:
    buttons = "\n".join(
        f'            <a class="btn btn--ghost btn--sm" href="{url}" target="_blank" rel="noopener">{label}'
        ' <i class="ph ph-arrow-right" aria-hidden="true"></i></a>'
        for label, url in tool["links"]
    )
    block = f'          <div class="tool-links">\n{buttons}\n          </div>'
    if tool["install"]:
        lines = "\n".join(
            (f'<span class="c-op">{escape(comment)}</span>\n' if comment else "")
            + f'<span class="c-prompt">$</span> {escape(command)}'
            for comment, command in tool["install"]
        )
        block += f'\n          <pre class="code" aria-label="Install {escape(tool["name"])}">{lines}</pre>'
    return block


def _facts(tool: dict) -> str:
    rows = "\n".join(f"            <dt>{label}</dt><dd>{value}</dd>" for label, value in tool["facts"])
    return f'          <dl class="tool-facts">\n{rows}\n          </dl>'


def _tool_section(tool: dict) -> str:
    return "\n".join(
        [
            f'        <section class="tool" id="{tool["id"]}" aria-labelledby="{tool["id"]}-title">',
            f'          <h3 id="{tool["id"]}-title">{tool["name"]}</h3>',
            f'          <p class="tool-tagline">{tool["tagline"]}</p>',
            _figure(tool),
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
            _install(tool),
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


def _update_log() -> str:
    return "\n".join(
        f'          <li><time datetime="{day}">{_long_date(day)}</time>: {text}</li>' for day, text in UPDATE_LOG
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
        <p class="blog-note"><strong>Disclosure:</strong> LokalBot is our app. To keep this fair, we installed the latest release of every app on {verified}, took every screenshot ourselves, and checked each claim against the project's own site, docs, license, and release notes, listed at the end. Nobody paid to be included. We re-check the page every month; if something is wrong or out of date, <a href="{ISSUES_URL}" target="_blank" rel="noopener">tell us on GitHub</a>.</p>

        <h2 id="short-answer">The short answer</h2>
        <p>These six tools all run AI on your own computer, but they do different jobs. Pick by what you want to do:</p>
        <ul>
          <li><strong>A private ChatGPT-style chat app:</strong> <a href="#jan">Jan</a> is open source and sets itself up in a few clicks. <a href="#lm-studio">LM Studio</a> is more polished, but its app is closed source.</li>
          <li><strong>Models for other apps, scripts, and coding agents:</strong> <a href="#ollama">Ollama</a>.</li>
          <li><strong>Answers from your documents:</strong> <a href="#anythingllm">AnythingLLM</a>.</li>
          <li><strong>One ChatGPT-like web app for your household or team:</strong> <a href="#open-webui">Open WebUI</a>, running on top of Ollama. Read its license first if you plan to rebrand it.</li>
          <li><strong>An assistant that remembers your actual work, from meetings to what you saw on screen:</strong> <a href="#lokalbot">LokalBot</a>, our app.</li>
        </ul>
        <p>They also work together. Most of them can use a model that Ollama or LM Studio is already serving, so you don't have to choose just one.</p>

        <h2 id="at-a-glance">At a glance</h2>
        <p>Checked on {verified}. Every app is free to use on your own computer.</p>
{_glance_table()}

        <h2 id="memory">Which one is a ChatGPT alternative with memory?</h2>
        <p>ChatGPT can remember details you share and use them in later chats. Of these six, three remember something about you, and they do it in very different ways:</p>
        <ul>
          <li><strong>Open WebUI</strong> keeps memories under Settings → Personalization → Memory, marked Experimental. You can add them yourself, and with native tool calling the model can save them on its own. In our test with Qwen3.5 4B on Ollama, “Remember that I am vegetarian” got a friendly “I've noted that,” but nothing was saved. Memories we added by hand were used in the next chat. Its docs warn that memory works best with capable models.</li>
          <li><strong>AnythingLLM</strong> added Memories &amp; Personalization in May 2026. It's off by default. Once you turn it on, a background job reads recent chats every three hours and keeps up to 5 memories about you plus 20 per workspace, which you can edit. It needs a model that supports tool calling.</li>
          <li><strong>LokalBot</strong> remembers your work rather than your chats: meeting transcripts, notes, and decisions, and, if you turn it on, what you saw on screen. Its Personal Context is an encrypted list of facts, preferences, and goals. It learns them overnight from your own words in meetings, never other speakers', or when you say “Remember …” in Ask. Every learned item shows the line it came from, and preferences wait for you to keep or dismiss them. Learning is on by default and one switch stops it.</li>
          <li><strong>Jan</strong> lists memory as coming soon. Its projects share instructions and files across chats today.</li>
          <li><strong>Ollama</strong> and <strong>LM Studio</strong> don't remember anything between chats.</li>
        </ul>
        <p>Before you trust any assistant with memory, check what it saves, whether you can see and delete each item, and which model reads it. All of these keep memories on your own computer, but if you connect a cloud model, that model sees them too.</p>

        <h2 id="the-apps">The six apps, one by one</h2>
        <p>In order from model runners to chat apps, with LokalBot last.</p>

{sections}

        <h2 id="together">Use them together</h2>
        <p>A common setup is one app that runs the model and another that you talk to:</p>
        <ul>
          <li><strong>Open WebUI and AnythingLLM</strong> both connect to Ollama out of the box, and to LM Studio's server as an OpenAI-compatible API.</li>
          <li><strong>Jan</strong> can add Ollama or LM Studio as a custom OpenAI-compatible provider.</li>
          <li><strong>LokalBot</strong> can use Ollama or any OpenAI-compatible server, such as LM Studio's or Jan's, in Settings → Models. A server on another computer has to be approved before it receives any of your context.</li>
        </ul>

        <h2 id="how-we-tested">How we tested</h2>
        <p>On {verified}, we installed the latest release of each app on a Linux test machine with an 8-core AMD Ryzen 7 9700X, 64 GB of memory, and no GPU, so every model ran on the CPU. LM Studio and Jan used the model each one suggests on first run: Gemma 4 E4B and Jan-v3.5-4B. Open WebUI and AnythingLLM used Qwen3.5 4B served by Ollama, as did Ollama itself. We kept each app's default settings, except that we declined Jan's analytics prompt and added two memories in Open WebUI by hand. In Open WebUI, the 4B model kept reaching for the built-in automation tools, and with thinking on it once thought for four minutes without answering, so the screenshot's chat uses Legacy tool calling with thinking off. LokalBot's screenshot comes from its Mac app with fictional demo data. The handbook and the questions are made up too.</p>
        <p>A 4B model on a CPU is a modest setup: answers arrived at about 12 to 20 tokens a second. With a GPU or an Apple Silicon Mac, every one of these apps is faster and can run larger models, which also follow instructions and use memory more reliably.</p>

        <h2 id="updates">Update log</h2>
        <ul>
{_update_log()}
        </ul>

        <h2 id="sources">Sources</h2>
        <p>Each project's own pages, checked on {verified}:</p>
        <ul class="source-list">
{_sources()}
        </ul>
        <p>LokalBot's facts come from its <a href="{REPO_URL}#readme" target="_blank" rel="noopener">README</a> and <a href="privacy">privacy policy</a>. If this comparison helped you, a <a href="{REPO_URL}" target="_blank" rel="noopener">star on GitHub</a> is how other people find LokalBot. Trademarks belong to their owners.</p>
        """


def item_list() -> dict:
    """Schema.org ItemList of the apps compared, matching the visible facts."""

    return {
        "@type": "ItemList",
        "@id": f"https://www.lokalbot.com/{SLUG}#apps",
        "name": "Open-source AI assistants compared",
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
                        "applicationCategory": "UtilitiesApplication",
                    }
                ),
            }
            for position, tool in enumerate(TOOLS, start=1)
        ],
    }


ROUNDUP = {
    "slug": SLUG,
    "kind": "compare",
    "published": PUBLISHED,
    "updated": VERIFIED,
    "updated_label": _long_date(VERIFIED),
    "title": "Best Open-Source AI Assistants You Can Run Locally (2026)",
    "description": "Ollama, LM Studio, Jan, AnythingLLM, Open WebUI, and LokalBot compared: memory, document chat, licenses, platforms, and install links, with our own screenshots.",
    "eyebrow": "Compare",
    "h1": "The best open-source AI assistants you can run locally",
    "lead": "Six private ChatGPT alternatives that run on your own computer, compared honestly: what each one is for, what it remembers about you, how it's licensed, and how to install it.",
    "read_time": "12 min read",
    "body": render_body(),
    "item_list": item_list(),
    "faq": [
        (
            "What is the best local AI assistant?",
            "It depends on the job. For a private ChatGPT-style chat, Jan (open source) or LM Studio (more polished, but closed source). "
            "To run models for other apps and agents, Ollama. To ask questions across your documents, AnythingLLM. For one web app shared "
            "by a household or team, Open WebUI. For an assistant that remembers your meetings and what you saw on screen, LokalBot.",
        ),
        (
            "Which local AI assistant has memory like ChatGPT?",
            "Open WebUI has a Memory feature, marked experimental, where you or the model can save facts about you. AnythingLLM has "
            "Memories, off by default, which it extracts from recent chats every three hours. LokalBot remembers your meetings and, if you "
            "turn it on, your screen, and learns facts and preferences from your own words. Ollama and LM Studio have no memory, and Jan "
            "lists it as coming soon.",
        ),
        (
            "Is LM Studio open source?",
            "No. The LM Studio app is proprietary, though free for home and work since July 2025. Its lms command-line tool, its SDKs, and "
            "its MLX engine are open source under the MIT license.",
        ),
        (
            "Is Open WebUI still open source?",
            "Its code is public, but since version 0.6.6 (April 2025) it uses the Open WebUI License, which adds a branding clause to BSD-3 "
            "terms. Its own documentation says it is not an OSI-approved open-source license. Code up to version 0.6.5 remains BSD-3.",
        ),
        (
            "Do I need a GPU to run a local AI assistant?",
            "No. Our test machine had none, and a 4B model answered at about 12 to 20 tokens a second on an 8-core CPU, which is readable but not "
            "fast. A recent GPU or an Apple Silicon Mac is much faster and can run larger, more capable models.",
        ),
        (
            "Can these assistants work completely offline?",
            "Yes, once the app and a model are downloaded, local chat works offline in all six. Some features use the network by default: "
            "Ollama's cloud models and web search, Jan's web search, AnythingLLM's anonymous telemetry, and update checks in most apps. "
            "Each app's section on this page says what to switch off.",
        ),
    ],
    "related": ["open-source-ai-meeting-notes", "local-ai-meeting-notes-mac", "local-ai-meeting-notes-linux"],
}
