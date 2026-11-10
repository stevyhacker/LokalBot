# LokalBot product roadmap

_Status: 2026-08-20 · code-grounded at `9fe1223` · current release line:
v0.6.x_

> Not refreshed since that date. Two items below have shipped and stay only until
> the next refresh: new installs ask before they record (**Make consent the first
> meeting decision**), and selection actions rewrite, fix, translate and summarize
> selected text (**Make the writing tools easier to discover**). LokalBot also runs
> on Windows and Linux in alpha, which the thesis below predates.

This document records product direction, not dates or launch promises. A roadmap
item stays here only while it changes the user experience; implementation plans
belong in issues or short-lived design documents.

## Product thesis

LokalBot is a private work memory for Mac. It should turn meetings and the work
context a person explicitly chooses into outcomes, evidence, and useful writing
without requiring an account or a hosted LokalBot service.

The product loop is:

1. **Remember** meetings and chosen work context.
2. **Recall** an answer with a source.
3. **Write** through Dictation and Autocomplete.
4. **Act** on outcomes through reviewable local drafts and routines.

## Shipped foundation

The following are current product capabilities, not future roadmap items:

- Bot-free meeting capture, live transcription, full transcripts, structured
  recaps, decisions, action items, open questions, and evidence links.
- Today and Timeline views organized around work sessions, day digests, and
  outstanding outcomes rather than raw activity telemetry.
- Keyword and semantic search, cited Ask answers, screen-memory scopes, and
  system-wide Quick Recall.
- On-device Dictation and Autocomplete, with secure-field and app exclusions.
- Calendar-assisted meeting detection and unambiguous one-to-one speaker naming.
- Local routines, scheduled Markdown exports, Agent Mode, a read-only CLI, and
  a read-only MCP server.
- Explicit model roles and presets, inference leases, a shared model-residency
  budget, and visible model readiness/resource state.
- A signed and notarized DMG, Sparkle update channel, reproducible release
  checks, and hosted UI automation.

## Now: trust and reliability

### Make consent the first meeting decision

The actionable **Ask via notification** path exists, but new installs still
default to automatic recording. Make the first-run choice explicit and default
new users to ask-first, while preserving the setting of existing users.

**Done when:** a new user understands what is captured before the first call,
can record or ignore from the notification, and can always see the active state.

### Make every recovery visible and actionable

Summary and Day Digest generation already retry bounded truncation failures.
Extend the same standard to model preparation, interrupted downloads, stale
indexes, and optional remote backends: one plain-language state, one next action,
and diagnostics that do not expose library content.

**Done when:** common failures recover automatically; failures that need a user
decision say exactly what is blocked and how to continue.

### Close the outcome loop

LokalBot can extract, cite, complete, and dismiss action items. Add a local
correction layer for text, owner, and due date; deduplicate repeated commitments;
and make weekly review a first-class Today flow.

**Done when:** users can trust the open-action list as a working system without
editing generated source files or losing the original evidence.

## Next: quality at daily scale

### Tune capture by usefulness, not frequency

Event-driven capture and Accessibility-first text extraction are shipped. The
next step is productizing the trade-off: clear Low/Standard/High sensitivity,
per-app exclusions, visible capture health, and energy/disk benchmarks on 16 GB
Apple Silicon Macs.

**Done when:** Standard captures the moments users search for without surprising
battery use, disk growth, or private-window retention.

### Improve multi-person meeting identity

One remote speaker plus one calendar attendee can be named automatically. For
larger meetings, offer an explicit local mapping UI and never guess across
ambiguous voices.

**Done when:** a user can label a speaker once for a meeting and every transcript,
outcome, citation, and export uses that label consistently.

### Make the writing tools easier to discover

Keep Autocomplete as the low-latency power feature, then reuse its selection,
context, insertion, and undo machinery for explicit transforms such as rewrite,
fix grammar, translate, and summarize.

**Done when:** a user can get daily value from the Type section without enabling
ambient suggestions.

## Later: scoped automation

- Expand local routines only when each action has a preview, explicit scope,
  durable audit record, timeout, and cancel path.
- Keep MCP and CLI read-only by default. Any future write capability must be a
  separately granted surface, not an expansion of existing permissions.
- Explore organization-managed retention and backend policies without adding a
  LokalBot account requirement or uploading a user's library.

## Non-negotiable guardrails

- **Local-first, not vague “private AI.”** Built-in processing stays on the Mac.
  Model/runtime downloads, optional update checks, approved remote inference,
  and network-capable Agent commands remain disclosed exceptions.
- **Files remain portable source material.** Meetings, transcripts, outcomes,
  and exports must remain inspectable without a LokalBot cloud.
- **Evidence survives synthesis.** Generated answers and outcomes link back to
  the retained source whenever the source exists.
- **No silent authority growth.** Capture, screen context, remote origins, Agent
  commands, and future automations stay explicit and revocable.
- **Release proof is end to end.** A tag is not completion; the public app,
  signature, notarization, Gatekeeper result, appcast, and update path are.

## How this roadmap is maintained

- Refresh it after a release that changes a product pillar.
- Remove shipped items instead of leaving them marked “done” indefinitely.
- Link substantial work to an issue or focused design document before coding.
- Validate UI automation on hosted CI; do not run the macOS UI suite on the
  maintainer's local MacBook.
