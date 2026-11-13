# Agent Access Surface (CLI + Skill + MCP) — Design

**Date:** 2026-07-10
**Status:** Approved in brainstorming
**Branch:** `agent-access`
**Scope decision:** Agent access ships first on its own branch; the inference broker is a separate spec/plan/branch cycle afterward. v1 = meeting tools + `ask_library`. Packaging in scope: `.mcpb` bundle, `install-skill` subcommand, Privacy toggle. Deferred: `Website/public/` docs page (follow-up PR), activity/screen tools (v1.1), app-hosted MCP (post-broker).

---

## 1. Why

One library, three doors. Shell agents (Claude Code, Codex, Cursor's agent) work best through a CLI plus a skill; GUI clients (Claude Desktop, ChatGPT desktop) can only reach us through MCP — and the non-technical wedge user lives exclusively there. The pieces mostly exist: `lokalbot-cli` is embedded and code-signed in `Contents/Helpers/`, a `SKILL.md` already ships for the embedded pi agent (`.agents/skills/lokalbot-cli/SKILL.md`, currently carrying a stale `com.dotenv.BotinaV2` path), llama-server listens on fixed localhost ports (17872 main, 17873 embedder), and `LokalBot --chat` proves the headless RAG loop.

The marquee tool is `ask_library`, a privacy diode: the external agent sends a question; LokalBot's local model reads the library and returns only the synthesized answer. Raw transcripts never enter the remote agent's context — "give Claude memory of your meetings, without giving Claude your meetings."

## 2. Decisions (from brainstorming)

| Question | Decision |
|---|---|
| Sequencing | Agent access first; broker second, own branch/spec |
| v1 tool scope | Meeting tools + `ask_library`; activity/screen tools deferred |
| Packaging | `.mcpb` + `install-skill` + Privacy toggle in-branch; web docs page follow-up |
| MCP hosting | Standalone stdio server in `lokalbot-cli`, behind a provider seam for a future app-hosted move |
| Protocol layer | Hand-rolled minimal MCP (JSON-RPC 2.0: `initialize`, `tools/list`, `tools/call`); no new dependencies in the signed helper |

## 3. Architecture

No new processes, no new listeners. MCP clients spawn `/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli mcp` and speak MCP over stdio. Read tools run in-process against the on-disk library (work with the app closed). `ask_library` calls the running app's llama-server at `127.0.0.1:17872/v1`.

New code lives in the CLI target's existing split — thin commands in `CLI/`, testable logic in `LokalBot/CLISupport/`:

| Component | Location | Responsibility |
|---|---|---|
| `MCPCommand` | `CLI/Commands/` | ArgumentParser subcommand; owns the stdin/stdout read-eval loop; wires provider + gate |
| `MCPProtocol` | `CLISupport/` | Pure codec: parse JSON-RPC 2.0, dispatch `initialize` / `tools/list` / `tools/call`, encode responses and spec-standard errors. No I/O |
| `LibraryToolProvider` | `CLISupport/` | The seam: `var tools: [ToolDefinition]`, `func call(name:arguments:) async -> ToolResult`. v1 implementation `FileLibraryToolProvider` wraps `SessionLookup` + the existing search walk; a future app-hosted server implements the same protocol |
| `AskLibraryEngine` | `CLISupport/` | Retrieve → prompt → complete → cite. HTTP behind a small client protocol so tests mock it |
| `AgentAccessGate` | `CLISupport/` | Checks the master-toggle marker file; refuses every `tools/call` with `access_disabled` when off |

`serverInfo` reports name `lokalbot`; its version is read from the enclosing app bundle's `Info.plist` (the helper lives at `Contents/Helpers/`, so `Contents/Info.plist` is two levels up), falling back to `"dev"` when the binary runs outside the bundle (local builds, tests).

## 4. Tool surface

Four tools. Read tools mirror the existing CLI verbs' semantics exactly (case-insensitive substring search, 50-hit cap, short-ID/`latest` resolution) so CLI and MCP stay one behavior.

| Tool | Arguments | Returns |
|---|---|---|
| `list_meetings` | `limit?`, `since?` (ISO date), `query?` (title substring) | id, title, date, duration per meeting |
| `get_meeting` | `id` (short id / UUID / `"latest"`), `include?` (subset of metadata, summary, transcript; default all) | requested sections as markdown |
| `search_meetings` | `query`, `limit?` | hits with kind (title/summary/transcript), snippet, timestamp |
| `ask_library` | `question` | synthesized answer + meeting-title/date citations — never raw transcripts |

`path` stays CLI-only; it is meaningless to a GUI client.

## 5. ask_library

**Flow:** gate check → probe `GET /health` on 17872 → if down, touch the wake file and poll health (≤ 60 s; first call pays the model load) → retrieve → complete → answer.

**Retrieval:** existing substring search for the top 12 snippets across titles/summaries/transcripts (a named constant, recency-ordered like the CLI); when the question names a meeting resolvable by `list` semantics, that meeting's summary is included whole. Prompt instructs the model to answer only from the provided context, cite meetings by title and date, and say "not found in your meetings" when the context doesn't contain the answer. Response returns answer text + a structured citations array.

**Wake protocol:** the app starts llama-server lazily, so the model may be cold. CLI touches `control/agent-wake` under the storage root; while the Privacy toggle is ON the app runs a `DispatchSource` watcher on `control/` and calls the Main LLM's `ensureRunning` on touch. This watcher becomes a P1 broker lease later. If the app process isn't running at all: `app_not_running` error; read tools unaffected.

**Engine edge:** if the user's Main LLM engine is Apple Intelligence (not llama-server), port 17872 has no answerer — return `engine_unavailable` telling the user to pick a local model in Settings → Models. Solving this properly is the app-hosted future the seam exists for.

## 6. Access gate & Privacy toggle

New row in Settings → Privacy: **"Allow external agents to read your meeting library"** — default **off**, subtitle stating exactly what it enables (read-only meeting access + local-LLM answers, localhost only). Flipping ON writes the marker file `control/agent-access-enabled` under the storage root and starts the wake watcher; OFF removes both. A marker file (not shared UserDefaults) so the CLI process and hermetic tests see the same truth via `LOKALBOT_STORAGE_ROOT`.

The toggle gates *tools*, not the binary: with it off, `lokalbot-cli mcp` still completes the `initialize` handshake and lists tools, but every `tools/call` returns `access_disabled` with enable instructions — a working error beats a dead server in every client UI.

## 7. Skill

Rewrite the bundled `SKILL.md`: fix the stale bundle-id path, document `ask_library` guidance (prefer it for synthesis questions; `search`/`get` for exact quotes), and mention the MCP alternative for non-shell clients. The existing pi integration keeps consuming the same file.

New `lokalbot-cli install-skill` subcommand: symlinks the app-bundled skill directory into `~/.claude/skills/lokalbot-cli` (symlink so Sparkle updates keep it current), `--copy` as fallback, `--uninstall` to remove, and prints pointers for non-Claude agents. Nothing installs without the user invoking it.

## 8. .mcpb bundle

`Scripts/build-mcpb.sh` produces `LokalBot.mcpb` attached to releases. The bundle's server entry execs the installed app's helper (`/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli mcp`) rather than embedding a second copy of the binary — no drift, no separate signing. If `LokalBot.app` is missing, the entry fails with a clear "install LokalBot first" message. Exact manifest fields are verified against the current MCPB spec during implementation.

## 9. Error model

Structured MCP tool errors with stable codes; every message says what to do next in one sentence.

| Code | Meaning |
|---|---|
| `access_disabled` | Privacy toggle off — how to enable |
| `app_not_running` | ask_library needs the app; read tools still work |
| `engine_unavailable` | Main LLM engine isn't llama-server |
| `model_loading_timeout` | Wake exceeded 60 s; try again shortly |
| `meeting_not_found` / `ambiguous_id` | Bad or ambiguous `id` argument |

Malformed JSON-RPC gets spec-standard protocol errors. The server never crashes on bad input.

## 10. Testing

- **Unit (LokalBotTests):** `MCPProtocol` codec + dispatch on string fixtures including malformed input; `AgentAccessGate` marker logic; `AskLibraryEngine` retrieval selection, prompt construction, citation extraction with a mocked HTTP client; tool-schema snapshots.
- **Integration:** golden stdio transcripts — pipe scripted `initialize` → `tools/list` → `tools/call` sessions into a spawned `lokalbot-cli mcp` against a fixture library under `LOKALBOT_STORAGE_ROOT`; assert on JSON out.
- **e2e:** one new step in `Scripts/e2e.sh` after processing — write the marker, run `search_meetings` via `tools/call`, and one `ask_library` round-trip when the llama fixture is up. Skips (not fails) when the model is absent, matching the harness's permission-skip philosophy.

## 11. What deliberately does not change

- Read-only invariant: no tool writes to the library; no destructive verbs exist.
- No new network listeners; stdio + existing localhost ports only.
- Recording/processing pipeline, storage layout, existing CLI verbs, pi integration — untouched.
- Nothing-leaves-the-Mac: LokalBot still initiates zero egress. What a user's chosen MCP client does with tool *results* is that client's data flow, opted into by the user's own configuration — and `ask_library` minimizes even that to answers, never transcripts. Documented plainly in the toggle copy and skill text.

## 12. Risks

| Risk | Mitigation |
|---|---|
| Hand-rolled protocol drifts from MCP spec | Minimal surface (3 methods); golden-transcript tests; verified against Claude Desktop + Claude Code during implementation; seam allows swapping the layer without touching tools |
| First `ask_library` call is slow (cold model) | Explicit `model_loading_timeout` code, 60 s poll, skill/docs set expectations ("first question loads the model") |
| Wake watcher lifecycle bugs (toggle races) | Watcher owned by one small type, unit-tested; marker + wake files are plain files, inspectable |
| Another process squats port 17872 | Existing `LlamaServer` residency-marker/reclaim logic already handles port ownership; CLI only ever connects to 127.0.0.1 |
| Skill-directory conventions change across agents | `install-skill` prints paths instead of guessing for non-Claude agents |

## 13. Open questions

None blocking. MCPB manifest field names and the current MCP protocol revision string are verified during implementation, not guessed in this spec.
