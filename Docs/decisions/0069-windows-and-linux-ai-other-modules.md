# 0069. Windows and Linux: ai — other modules

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-ai/src/anthropic.rs`, `LinuxWindows/crates/lokalbot-ai/src/ask_agent.rs`, `LinuxWindows/crates/lokalbot-ai/src/catalog.rs`, `LinuxWindows/crates/lokalbot-ai/src/dictation.rs`, `LinuxWindows/crates/lokalbot-ai/src/dictation_preview.rs`, `LinuxWindows/crates/lokalbot-ai/src/digest.rs`, `LinuxWindows/crates/lokalbot-ai/src/digest/`, `LinuxWindows/crates/lokalbot-ai/src/download.rs`, `LinuxWindows/crates/lokalbot-ai/src/download_source.rs`, `LinuxWindows/crates/lokalbot-ai/src/dream.rs`, `LinuxWindows/crates/lokalbot-ai/src/dream/`, `LinuxWindows/crates/lokalbot-ai/src/dream_rollup.rs`, `LinuxWindows/crates/lokalbot-ai/src/embeddings.rs`, `LinuxWindows/crates/lokalbot-ai/src/error.rs`, `LinuxWindows/crates/lokalbot-ai/src/follow_up.rs`, `LinuxWindows/crates/lokalbot-ai/src/http.rs`, `LinuxWindows/crates/lokalbot-ai/src/hugging_face.rs`, `LinuxWindows/crates/lokalbot-ai/src/json.rs`, `LinuxWindows/crates/lokalbot-ai/src/language.rs`, `LinuxWindows/crates/lokalbot-ai/src/lib.rs`, `LinuxWindows/crates/lokalbot-ai/src/media_embedder.rs`, `LinuxWindows/crates/lokalbot-ai/src/personal_learning.rs`, `LinuxWindows/crates/lokalbot-ai/src/process.rs`, `LinuxWindows/crates/lokalbot-ai/src/project_status.rs`, `LinuxWindows/crates/lokalbot-ai/src/prompts.rs`, `LinuxWindows/crates/lokalbot-ai/src/reasoning_lookup.rs`, `LinuxWindows/crates/lokalbot-ai/src/remote_gate.rs`, `LinuxWindows/crates/lokalbot-ai/src/remote_transcription.rs`, `LinuxWindows/crates/lokalbot-ai/src/sanitize.rs`, `LinuxWindows/crates/lokalbot-ai/src/selection.rs`, `LinuxWindows/crates/lokalbot-ai/src/test_support.rs`, `LinuxWindows/crates/lokalbot-ai/src/upcoming.rs`, `LinuxWindows/crates/lokalbot-ai/src/upcoming_tests.rs`, `LinuxWindows/crates/lokalbot-ai/tests/`.

## Decisions

### `LinuxWindows/crates/lokalbot-ai/src/anthropic.rs`

#### Use Messages API for api.anthropic.com; cache breakpoints put varying instruction last
Claude through Anthropic's Messages API (`Engines/AnthropicEngine.swift`).

Think uses it when the OpenAI-compatible server URL names
`api.anthropic.com`: Anthropic's OpenAI compatibility layer rejects
LokalBot's notes schemas (`maxItems`) and has no prompt caching.

Prompt caching: the system prompt and the shared context (a meeting's
transcript) carry cache breakpoints and the varying instruction comes
last, so the next request over the same material reads the prefix from
Anthropic's 5-minute prompt cache instead of paying the full input price.

#### Beta header gates fallbacks default: safety declines retry server-side
`SERVER_FALLBACK_BETA`: Gates `fallbacks: "default"`: a safety decline is retried server-side on
the model Anthropic recommends for the decline's category.

#### Cap whole replies so they finish within timeout at 25 tokens per second
`MAXIMUM_WHOLE_RESPONSE_TOKENS`: A whole reply must arrive within the request timeout even at about 25
tokens per second.

#### Build requests from origin since base URL with or without /v1 is the same API
`versioned_root`: `https://api.anthropic.com` and `…/v1` name the same API, so every
request is built from the origin.

#### Model traits follow Anthropic docs 2026-10; unparseable ids get no effort, newer treated as 5
`ModelTraits`: What LokalBot relies on for one Claude model id, from Anthropic's model
documentation (2026-10). Ids it cannot parse (aliases, Claude 3) get no
effort control; unknown newer generations are treated like Claude 5.

#### Effort levels ordered least first; empty means send no effort
`ModelTraits.effort_levels`: `output_config.effort` values, least first. Empty: send no effort.

#### Unset thinking runs adaptive thinking whose tokens count toward max_tokens
`ModelTraits.thinks_by_default`: Leaving `thinking` unset runs adaptive thinking, whose tokens count
toward `max_tokens`.

#### Marks models accepting fallbacks default
`ModelTraits.server_fallback`: Accepts `fallbacks: "default"`.

#### Dated snapshot ids carry no minor version
`ModelTraits::new`: A dated snapshot ("claude-sonnet-4-20250514") has no minor version.

#### Claude Opus 5.5 and Haiku 5.5 default to medium effort
`ModelTraits::new`: Claude Opus 5.5 and Claude Haiku 5.5 default to medium effort.

#### Chosen effort capped by task budget; Automatic uses budget-implied level on thinking models
`ModelTraits::effort`: The effort for one request. A chosen level is capped by the task's
budget, as on other servers. On Automatic, a model that thinks by
default gets the level its task budget implies, so notes and digests
(budget 0) run at the lowest effort instead of spending their output
allowance on thinking.

#### Thinking shares max_tokens with answer, so default-thinking models get room for both
`ModelTraits::max_tokens`: Thinking shares `max_tokens` with the answer, so a model that thinks
by default gets room for both.

#### Move unsupported schema constraints into descriptions instead of failing with 400
`adapt_schema`: Anthropic's structured outputs accept a JSON Schema subset. Like the
official SDKs, each unsupported constraint moves into the field's
description, where the model still reads it, instead of failing the
request with a 400. LokalBot's parsers keep enforcing the real limits.

#### A 400 naming an optional field retries once without it
`OptionalField`: Request fields a model may reject. A 400 naming one retries once without
it; generation never started.

#### API key is sent only to Anthropic's API
`Engine::headers`: Request headers. The key goes only to Anthropic's API.

#### Never send temperature; sort keys to keep schema bytes and cache stable
`Engine::body`: Pure request construction, covered offline without credentials.
Temperature is never sent: current Claude models reject non-default
sampling. Keys are sorted so the schema's bytes, and with them the
compiled grammar and the cached prefix, stay stable.

#### Retry once without a rejected optional field; transient failures replay in caller
`Engine::complete`: One whole reply. A 400 naming an optional field gets one retry without it;
transient failures replay through the origin's gate, in the caller.

#### Streams retry once without rejected optional field, otherwise never replayed
`Engine::stream`: Streams answer text. A 400 naming an optional field retries once
without it; streams are otherwise never replayed.

#### Read max_input_tokens from model list else documented window; sends key, no content
`Engine::discover_context`: `max_input_tokens` of the selected model from Anthropic's model list,
else the documented window. Carries the key and no content.

#### Shared material first with cache breakpoint; drop blank blocks the API rejects
`user_content`: Shared material first with a breakpoint after it, the varying instruction
last. Blank blocks are dropped; the API rejects them.

#### Only optional fields that the request actually sent count as rejected
`rejected_fields`: The optional fields a 400 names, limited to those the request sent.

#### Streamed message_delta carries only the counts that changed
`CacheUsage::merge`: A streamed `message_delta` carries only the counts that changed.

#### Report whole prompt, cached or not, as other engines do
`CacheUsage::usage`: The whole prompt, cached or not, as other engines report it.

#### Join text blocks in order; server fallback text continues declined partial
`parse_message`: Text blocks joined in order; thinking and fallback marker blocks are not
part of the answer. A server-side fallback's text continues the declined
partial, so joining keeps the whole reply.

#### Final counts arrive together with the stop reason
`StreamEvent::Stop`: The final counts arrive with the stop reason.

#### Skip event lines, pings and block boundaries; payload type is enough
`parse_stream_line`: One line of a Messages stream. `event:` lines repeat the payload's `type`
and are skipped, as are pings and block boundaries.

#### Automatic runs no-reasoning tasks at lowest effort; chosen level capped by budget
`model_traits_follow_anthropics_documentation`: Automatic: a thinking model runs no-reasoning tasks at the lowest
effort; a chosen level is capped by the task's budget.

#### max_tokens leaves room for adaptive thinking beside the answer
`requests_cache_the_system_prompt_and_context_and_skip_sampling`: Room for adaptive thinking beside the answer.

### `LinuxWindows/crates/lokalbot-ai/src/ask_agent.rs`

#### Prompt-driven JSON tool loop, tolerant parsing, retry, forced answer after six calls; tool loop gated
Ask's tool loop (`Services/Chat/ChatAgent.swift`, `MeetingChatTools.swift`).

The model answers by calling tools — search, list and read meetings,
action items, screen text, app activity — one at a time, through a
prompt-driven JSON protocol (no native function calling), and writes its
answer once it has enough. Output is parsed tolerantly, a garbled tool
call gets one schema-constrained retry, and after six calls a final answer
is forced. Only sources a tool returned may be cited.

`uses_tool_loop` decides when to use it: a CPU-only model or a small
context window keeps the single-turn, retrieve-first answer in `ask`.

#### Six tool calls before final answer is forced, as ChatAgent.maxSteps
`MAX_STEPS`: Tool calls before a final answer is forced (`ChatAgent.maxSteps`).

#### Below this window observations crowd out the answer
`MIN_TOOL_LOOP_CONTEXT`: Below this window a few observations crowd out the answer.

#### CPU models and small windows answer in one retrieve-first turn
`uses_tool_loop`: Whether this Think model should answer with the tool loop. Each step is a
model call, so a model on the CPU, or one with a small window, answers in
one retrieve-first turn instead.

#### Write JSON by hand so key order ignores serde_json preserve_order, which GPUI enables
`ToolCall::json`: One canonical call back into the running transcript, written out by
hand like macOS so key order never depends on serde_json's
`preserve_order` feature (which GPUI turns on).

#### Stringify numbers and bools and drop nulls so all arguments are strings
`coerce`: Every value as a string: numbers and bools stringified, nulls dropped.

#### Accept pythonic calls small models write, bracketed or in tool tokens
`pythonic_call`: `get_meeting(id='abc', include='summary')`, as many small models write
calls, optionally bracketed and wrapped in tool tokens.

#### A lone positional value is kept as arg0
`parse_kwargs`: `key='value', limit=5`; a lone positional value is kept as `arg0`.

#### Count a call only for a known tool so answers quoting JSON stay answers
`parse`: One model turn as a tool call or the final answer. A call counts only for
a known tool, so an answer quoting JSON stays an answer.

#### Detect failed tool-call attempts: bare tokens, unknown name or truncated call
`looks_like_tool_attempt`: A turn that did not parse as a call but still looks like an attempt at
one: bare wrapper tokens, a call to an unknown name, or a call cut off.

#### Stream prose only after FINAL_ANSWER, never reasoning or half-written calls
`streaming_answer`: Prose to show while a turn streams: only after `FINAL_ANSWER:`, and never
a reasoning block, a tool call or a payload still being written.

#### Force one valid call via anyOf of closed shapes for OpenAI strict outputs
`tool_call_schema`: Forces exactly one valid call: `{"call": {"tool", "arguments"}}`, an
`anyOf` of closed per-tool shapes, as OpenAI strict outputs require.

#### Tools limited to question scope, mirroring MeetingChatTools and ScopedChatToolRunner
`Tools`: The tools for one question, limited to its scope
(`MeetingChatTools` + `ScopedChatToolRunner`).

#### Include newest meetings so list questions need no tool call
`Tools::library_overview`: The newest meetings in scope, so list questions need no call.

#### Within a limit, count is only what the limit lets through
`Tools::library_overview`: Within a limit the count is only what the limit lets through.

#### Meeting lists state their limit so short lists are not read as whole library
`Tools::run`: A short list read as the whole library ("the only one in your
library"), so the meeting lists say what they were held to.

#### Agent notes are the agent's own record, so heading says so
`Tools::search_agent_notes`: Saved coding-agent notes that match, with their text. A note is an
agent's own record, so the heading says so.

#### Transcribe only first two moments on demand to keep answers quick
`Tools::search_files`: Files that match, with the passage that matched. Recordings and video are
transcribed on demand: only the first two moments, to keep an answer quick.

#### Scope with only a start still blocks earlier days via day argument
`Tools::activity_summary`: A scope with only a start (a paired device's history window) still
reaches no earlier day through the `day` argument.

#### Whole lines up to a character limit with next start, as transcriptObservation
`transcript_window`: One window of a transcript from `start`: whole lines up to `limit`
characters, and where the next window starts when the rest did not fit
(`MeetingChatFormat.transcriptObservation`).

#### A line longer than a window is cut and reading moves past it
`transcript_window`: A line longer than a window is cut, and reading moves past it.

#### Use the whole utterance around a match so nearby negation is not cut
`keyword_passage`: The whole utterance around a keyword match, not just the FTS snippet,
so a nearby "not" is never cut away (`MeetingChatFormat.keywordPassage`).

#### Strip FTS markers, one line, at most 220 characters
`clean`: Without FTS markers, on one line, at most 220 characters.

#### File line layout matches MeetingChatFormat.fileResults
`file_line`: One line per file: its citation marker, name, kind and date, folder, then the
matched passage or the words that matched (`MeetingChatFormat.fileResults`).

#### Note line layout matches MeetingChatFormat.agentNoteResults
`note_line`: One line per note: its citation marker, title, agent and project, date,
then its text (`MeetingChatFormat.agentNoteResults`).

#### Tool catalogue, calling and citing rules mirror ChatPrompt.systemPrompt
`system_prompt`: `ChatPrompt.systemPrompt`: the tool catalogue, how to call tools and
how to cite.

#### Give current time so model resolves relative dates like yesterday
`current_time_line`: Lets the model resolve "yesterday" (`ChatPrompt.currentTimeLine`).

#### Newest messages within both budgets, never starting with answer whose question was cut
`replayed_history`: The newest messages within both budgets, oldest first, never starting
with an answer whose question was cut off (`ChatAgent.replayedHistory`).

#### Activity start labels mirror ChatViewModel.startLabel
`start_label`: `ChatViewModel.startLabel`.

#### Activity finish labels mirror ChatViewModel.finishLabel
`finish_label`: `ChatViewModel.finishLabel`.

#### Stream answer with citations checked against sources tools returned so far
`answer_with_tools`: Answers `question` with the tool loop (`ChatAgent.respond`). The visible
answer streams through `AskEvent::Answer`, with citations checked against
the sources tools returned so far.

#### Garbled tool call gets one decode-constrained retry, never a hard gate
`answer_with_tools`: One decode-constrained second chance, never a hard gate.

#### Rejected stream retries without streaming so replies depend on prompt, not count
`tests::reply`: `text` as the request asked for it. A rejected stream is retried
without streaming, so replies depend on the prompt, never on a count.

#### Summary hit alone does not make a moment citable; reading transcript does
`calls_a_tool_then_answers_with_verified_citations`: The summary hit alone doesn't make the 0:15 moment citable; reading
the transcript does.

#### Paired device history window has start but no end; model still picks day
`a_scope_start_also_limits_the_day_activity_summary_may_read`: A paired device's history window has a start and no end, and the model
still chooses the day it asks about.

#### Day-limited question once answered library has one meeting
`a_limited_question_names_its_limit`: A question limited to one day once answered "the library has only one
meeting": the overview and the meeting lists now say what they were
held to, and the prompt names the limit.

### `LinuxWindows/crates/lokalbot-ai/src/catalog.rs`

#### Model pins equal macOS pins so libraries share the models folder
The GGUF models LokalBot can download (`Engines/ModelCatalog.swift`,
`Services/Search/EmbeddingIndex.swift`). Files, revisions, sizes and SHA-256
digests are the macOS pins, so a library moved between platforms reuses
its `models/` folder.

#### Projector serves Files and screen pictures; not user-pickable, not listed
`ModelKind::Projector`: The embedder's image and audio projector, for Files and pictures of
saved screens. Not a model anyone picks, so it isn't in the catalog list.

#### Files are pinned to an immutable 40-hex commit
`ModelEntry.revision`: Immutable 40-hex commit the file is pinned to.

#### Offered in Autocomplete picker, mirroring keystrokeScaleEntries
`ModelEntry.autocomplete`: Offered in the Autocomplete picker (`keystrokeScaleEntries`).

#### Vendor-required sampling merged last into built-in chat requests
`ModelEntry.request_overrides`: Sampling the vendor requires, merged last into built-in chat requests
(`MainLLMRuntimePolicy.requestOverrides`).

#### Model has no thinking-budget control on llama-server
`ModelEntry.no_reasoning_control`: The model has no thinking-budget control on llama-server.

#### Custom entries store a download URL; catalog models build it from the pin
`ModelEntry.custom_url`: A custom entry's stored download URL; catalog models build theirs from the pin.

#### Sizes shown in decimal gigabytes
`ModelEntry.size_gb`: Decimal gigabytes, as the pickers show them.

#### Models above 7 GB are too slow for keystroke-latency completion
`KEYSTROKE_SCALE_MAX_GB`: Models above this size are too slow for keystroke-latency completion.

#### Projector is the one extra Files file, pinned to the embedder's revision
`PROJECTOR_ID`: EmbeddingGemma 2's image and audio projector, the one extra file Files needs
(`FileSearchModels`), from the same pinned revision as the embedder.

#### Catalog order: text models roughly smallest first, then embedder
`catalog`: Every downloadable model, text models roughly smallest first, then the embedder.

#### Custom entries built once and reused because they are handed out as 'static
`CUSTOM_MADE`: Every custom entry made so far: entries are handed out as `&'static` like
the catalog's, so one is built once and reused.

#### Matches the Mac ModelCatalog.Entry as stored in customBuiltInModels
`StoredEntry`: The Mac's `ModelCatalog.Entry` as `customBuiltInModels` stores it.

#### Records lacking digest or size parse; download refuses them; unsafe file names rejected
`custom_entry`: An entry usable from the stored record. A record with no digest or size
still parses, and the download refuses it with the Mac's message. A file
name that isn't a plain name can't reach the models folder.

#### Older entries carried the digest in the URL fragment
`custom_entry`: Older entries carried the digest in the URL's fragment.

#### Earlier builds' entries recover bytes from the decimal size
`custom_entry`: Entries from an earlier build recover the bytes from the decimal size.

#### Engine calls it with current customBuiltInModels on every change
`set_custom`: Takes the current `customBuiltInModels`; the engine calls it on every change.

#### A catalog id always means the catalog's own pin
`set_custom`: A catalog id always means the catalog's own pin.

#### A custom model cannot leave while a download or role choice depends on it
`custom_removal_blocker`: Why a custom model can't leave the list yet (`customModelRemoval`), so it
never orphans a downloaded file or a saved role choice.

#### One-time migration moves unused LFM2.5 autocomplete default to Gemma 4 E2B
`adopt_default_autocomplete`: Run at launch. Through 0.12.3 the port saved LFM2.5 1.2B as everyone's
Autocomplete model, though the Mac and this catalog recommend Gemma 4 E2B,
and a saved choice outlives a changed default. Setup's "Also prepare
Autocomplete" and turning autocomplete on both downloaded that default, so
a downloaded LFM2.5 isn't a choice either. Moves settings that hold it
while autocomplete is off, and Think isn't the Lightweight preset's, to
Gemma 4 E2B. With autocomplete on, LFM2.5 stays. A downloaded LFM2.5 file
stays on disk, listed as unused in Model Storage, where it can be deleted.
It runs once per library, so choosing LFM2.5 afterwards sticks. Returns
whether the settings changed and need saving.

#### Picker shows models under 7 GB, non-reasoning, plus custom and stored choice
`autocomplete_entries`: Autocomplete picker entries (`keystrokeScaleEntries`): under 7 GB and not
an always-reasoning or legacy model, plus every custom model. A stored
choice stays visible.

#### Cheap UI check uses size, GGUF magic and sidecar; hash only if no sidecar
`is_downloaded`: Cheap check for the UI: the exact size and GGUF magic, plus a matching
`.sha256` sidecar when one exists. [`verify_downloaded`] hashes a file that
has no sidecar yet.

#### Sidecar-less files are hashed once; failing files are left for the caller
`verify_downloaded`: Full integrity check before a model is loaded. A file without a sidecar
(copied in by hand, or written by an older build) is hashed once and the
sidecar recorded. A file that fails is left in place; the caller decides
whether to delete it.

#### GGUF check mirrors ModelFileValidator.looksLikeGGUF: first four bytes
`looks_like_gguf`: `ModelFileValidator.looksLikeGGUF`: the first four bytes are `GGUF`.

#### One-click local setup mirrors ModelStackPreset
`Preset`: A one-click local setup (`ModelStackPreset`).

#### Test fixture is what the Mac's JSONEncoder writes for ModelCatalog.Entry
`custom_tests`: What `JSONEncoder` writes for `ModelCatalog.Entry` on the Mac.

#### A branch instead of a commit is refused with the Mac's message
`older_records_recover_their_pins`: A branch instead of a commit is refused with the Mac's message.

#### Test guards 0.12.3 Windows offering LFM2.5 from a mismatched default
`autocomplete_defaults_to_gemma_e2b_as_on_macos`: 0.12.3 on Windows offered LFM2.5 1.2B for autocomplete because the
port's settings default disagreed with the Mac and this catalog.

#### 0.12.3 setup and switch downloaded the default, so downloads don't show choice
`an_unused_lfm_default_moves_to_gemma_e2b`: Downloaded or not: 0.12.3's setup and autocomplete switch both
fetched the default, so neither tells a choice apart.

#### Migration runs once per library so a later LFM2.5 choice stays
`an_unused_lfm_default_moves_to_gemma_e2b`: Once per library: LFM2.5 chosen afterwards stays.

#### LFM2.5 stays when autocomplete is on or the Lightweight preset
`an_unused_lfm_default_moves_to_gemma_e2b`: Autocomplete in use, or the Lightweight preset: LFM2.5 stays.

#### Other models stay and fresh settings only record the migration ran
`an_unused_lfm_default_moves_to_gemma_e2b`: Any other model stays, and new settings only record that it ran.

#### A sidecar disagreeing with the pinned digest means a different file
`downloaded_status_checks_size_magic_and_sidecar`: A sidecar that disagrees with the pinned digest means another file.

### `LinuxWindows/crates/lokalbot-ai/src/dictation.rs`

#### Transcribe inserts as-is; Compose routes writing requests, else cleanup-only prompt
Dictation text preparation (`DictationTextPreparation.swift`,
`DictationGrounding.swift`, `DictationComposition.swift`).

Transcribe inserts the recognized speech as it is; no model is called and
no context is read. Compose routes the speech: a writing request ("reply
to…", "draft…", "tell him … from the message above") gets the Compose
prompt with whatever context the caller supplies; anything else is sent
as JSON data to a cleanup-only prompt that never answers or carries it out.

#### Keep window bottom 2,000 characters because newest messages sit by the field
`WINDOW_TEXT_LIMIT`: The bottom of the focused window: the newest messages sit next to the
input field (`DictationWindowTextPolicy.production`).

#### Focused window captured when dictation finished and never saved
`ScreenContext`: The focused window at the moment dictation finished (never saved).

#### Bundle ID on macOS; executable or app ID elsewhere
`ScreenContext.bundle_id`: Bundle ID on macOS; the executable or app ID elsewhere.

#### Context is optional and read only for writing requests
`ComposeContext`: Context a Compose writing request may use. All of it is optional and
read only for writing requests.

#### Model name shown to user; None for Transcribe
`Prepared.composition_model`: The model that wrote it ("Qwen3.5 4B · on this PC"); `None` for Transcribe.

#### Routing judged speech a writing request, so context may be used
`Prepared.was_writing_request`: Routing judged the speech a writing request (context may be used).

#### Records what Compose read; None for Transcribe
`Prepared.context_use`: What Compose read for this request; `None` for Transcribe.

#### Shown under Last result so context settings are judged by contribution
`ContextUse`: Which context a Compose request actually used, shown under Last result so
the context settings can be judged by what they contributed.

#### Context is read only for writing requests
`ContextUse.was_writing_request`: Context is read only for writing requests ("reply…", "draft…").

#### tr translates; fill substitutes its argument for {0}
`ContextUse.summary`: The line under Last result. `tr` translates a string; `fill` also puts
its argument in place of `{0}`.

#### Separate Compose model runs built-in; else follows Think without its reasoning level
`composition_settings`: `dictationCompositionTextEngineSettings`: a valid separate Compose model
runs on the built-in server; otherwise Compose follows Think. The Think
reasoning level belongs to the Think model, not this one.

#### Dictation memory grants are separate from Autocomplete's grants
`memory_policy`: The dictation grants for reading saved facts. Autocomplete's grants do not
enable these (`DictationGrounding.memorySettings`).

#### Revoked grants, changed exclusions or destinations invalidate a frozen composition
`permissions_match`: Whether a composition frozen at the shortcut may still go on: revoked
grants, changed exclusions and changed destinations invalidate it
(`DictationGrounding.permissionsMatch`).

#### Each provider call made only when request and frozen settings allow
`ComposeProviders`: Where one Compose request gets its context and model. Each call is made
only when the request and the frozen settings allow it.

#### Context re-validated around model call; revocation rejects composition, transcript survives
`prepare_checked`: `DictationTextPreparation.prepare`. Context is read only for writing
requests and re-validated around the model call, so a grant revoked or a
source changed meanwhile rejects the composition; the transcript survives.

#### Direct speech goes to cleanup prompt as data, never as instruction
`prepare_with`: Direct speech is text to insert: it goes to the cleanup prompt as
data, never to a prompt that may treat it as an instruction.

#### No thinking turn because someone is waiting to insert
`prepare_with`: Someone is waiting to insert this: no thinking turn.

#### Writing request needs command word or relay after openings; unknown phrasing gets cleanup
`requests_context`: Whether the speech is a writing request that may use context
(`DictationGrounding.requestsContext`, production `referencedRelays`):
after up to five filler or polite openings, a command word, or a relay
verb aimed at someone else that also points at context. Unknown
phrasing conservatively gets ordinary cleanup.

#### Capitalized second word is a name; lowercase email is a sentence
`requests_context`: A capitalized second word is a name ("Email Marko…"); lower-case
"email works" is a sentence about email.

#### Small models echo the envelope or wrap text in quotes
`cleanup_normalized_output`: Small models sometimes echo the envelope or wrap the text in quotes.

#### Sections fenced; delimiter look-alikes neutralized; mirrors DictationComposePrompt
`compose_user_prompt`: The Compose user prompt (`DictationComposePrompt.userPrompt`): screen
context, visible text, saved facts, the writing profile and the spoken
request, each fenced; delimiter look-alikes inside are neutralized.

#### Keep last 2,000 characters from a line boundary, prefixed with ellipsis
`window_text`: The last 2,000 characters of the window text, starting at a line
boundary, prefixed with "…".

### `LinuxWindows/crates/lokalbot-ai/src/dictation_preview.rs`

#### Live transcript, window planner and stitcher mirror Swift; insertion check included
The rolling live transcript while dictating (`DictationLiveTranscript`,
`DictationPreviewWindowPlanner`, `DictationPreviewTextStitcher`), and the
check that pasted text reached its field (`DictationInsertionCheck`).

#### Whole sentences settle; otherwise all but last six of over eight words
`LiveTranscript.preview`: Whole sentences are settled; without one, all but the last six of more
than eight words.

#### Each pass overlaps the last to finish boundary words without decoding everything
`window_range`: Each pass starts slightly before the last one ended, so the model hears
enough to finish a word that crossed the boundary, without decoding the
whole growing recording again.

#### Audio that must arrive since last pass before another runs
`minimum_advance`: Audio that must have arrived since the last pass before another runs.

#### Rest after a pass grows with recording length
`interval_after`: How long to rest after a pass, as a longer recording costs more.

#### Newest window replaces matched suffix; untrusted overlap is appended
`stitch`: Joins overlapping windows. The newest window replaces the matched suffix,
so revised capitalization or punctuation at the boundary wins; a window
with no trustworthy overlap is appended rather than risking visible speech.

#### Character fallback only for unsegmented scripts to avoid suffix false matches
`stitch`: The character fallback is for unsegmented scripts only. On ordinary
text it mistakes a word's suffix for the start of another word
(broadcast / cast iron).

#### Match ignoring punctuation and spacing, keep positions for verbatim output
`semantic_graphemes`: Ignores punctuation and spacing while matching, keeping each grapheme's
place so the output has the newest window verbatim from the overlap on.

#### Narrower than non-Latin: Arabic, Cyrillic, Devanagari use word separators
`is_unsegmented_script`: Scripts that commonly omit spaces between words. Deliberately narrower
than "non-Latin": Arabic, Cyrillic and Devanagari use word separators.

#### Unreadable field claims nothing
`InsertionVerdict::Unknown`: The field could not be read; nothing is claimed.

#### Apps may take a moment to publish the pasted change
`READ_DELAYS_MS`: When to read the field after the paste, in milliseconds. An app can take a
moment to publish the change.

#### Last 24 letters and digits of insertion must appear
`PROBE_LENGTH`: Letters and digits from the end of the insertion that must appear.

#### Compare letters and digits only, ignoring spacing, punctuation, emoji, Markdown
`insertion_verdict`: Compares letters and digits only, so spacing, punctuation, emoji and
Markdown changes do not matter, and scripts without spaces between words
match inside a longer run.

### `LinuxWindows/crates/lokalbot-ai/src/digest.rs`

#### Journal sections rendered from evidence so weak model never loses activity
The Day Digest (`DayDigestEvidence.swift`, `DailyDigestEvidence.swift`).

Evidence for one local day (activity blocks, screen text, finished
meetings) is cut into gap-aware segments. A first model pass per segment
extracts work candidates; a second pass groups them into tasks. The
journal's meetings, time allocation and full activity log are rendered
from the evidence itself, so a weak or failed model never loses activity.

#### Agent work arrives pre-structured and gets its own lossless section
`DayEvidence.coding_agent_bursts`: Settled coding-agent work. Like meetings, it arrives pre-structured and
is rendered in its own lossless journal section.

#### Model-facing excerpts strip recurring accessibility chrome
`summary_excerpt`: Model-facing excerpt without recurring accessibility chrome.

#### recorded_outcome means commit, PR, release, push or tests
`Source::AgentSession`: `recorded_outcome`: the burst committed, opened or merged a pull request,
released, pushed, or ran tests.

#### Screen text in agent host apps duplicates session evidence; first fifteen are the Mac's
`CODING_AGENT_HOST_APPS`: Apps that host coding agents: their chat window, a terminal or an editor.
Screen text captured there while a stored session ran is mostly that session
on screen, which the session evidence already states more exactly. The first
fifteen are the Mac's; the rest are Linux and Windows terminals and editors.

#### Long blocks get evidence proportional to duration
`DayEvidence.summary_contexts`: Long blocks get evidence in proportion to their duration.

#### Outcomes lead because busy segments cut each source from the front
`DayEvidence.events`: Outcomes lead: a busy segment cuts each source from the front.

#### Idle gap over 10 minutes splits; one segment per active hour, max 16
`DayEvidence.summary_segments`: Gap-aware segments: an idle gap over 10 minutes always starts a new
one; a session gets one segment per hour of active time, at most 16.

#### Agent section only on agent days so older journals keep their shape
`render_document`: Only days with agent work gain the section, so journals written
without the feature keep their existing shape.

#### Only recorded facts; the agent's own report is a claim for the model
`agent_sessions_section`: Recorded facts only, one entry per session. The agent's own report is a
claim for the model to corroborate, so it stays out of this section.

#### Signature changes whenever anything the digest reads changes
`content_signature`: `contentSignature`: changes whenever anything the digest reads changes.

#### Agent fields appended only when present so old journals still match
`content_signature`: Appended only when present: journals of days without agent work keep
matching the signature they were generated with.

#### Matches Swift String(Double) of epoch seconds, e.g. 1760781234.0
`epoch`: `String(Double)` of epoch seconds ("1760781234.0").

#### SHA-256 over byte length plus bytes per field, mirroring ContentFingerprint
`fingerprint`: `ContentFingerprint.fields`: SHA-256 over `<byte length>:<bytes>` per field.

#### Show a session once per segment so parallel sessions don't crowd detail
`merging_agent_sessions`: A session often has several bursts in one segment. Show it once, with every
burst's requests, actions and files, so parallel sessions do not crowd each
other out of the detail budget.

#### Meetings and up to six outcome sessions are guaranteed detail slots
`detail_indices`: Meetings are already structured work evidence, so a busy interval must not
sample around them merely because it contains many short activity events.
Agent sessions that recorded an outcome get the same guarantee, up to six,
ahead of those that did not. The rest of the budget covers the interval evenly.

#### Session task carries identifiers used to match model tasks
`SessionCandidate`: A session's task, with what identifies its work when matching it to the
model's tasks.

#### Only outcome sessions from recorded facts; scheduled runs excluded; named by work
`session_candidates`: One candidate per agent session that recorded an outcome, from recorded facts
only. Scheduled runs are left to segment extraction: their reports often
describe other days. Tasks are named by the work, not by the first request or
the folder the session started in.

#### Bare number could belong to another repository's PR; needs repo context
`names_pull_request`: The title names one of the session's pull requests: `owner/repo#12`, or `#12`
or `PR 12` beside the repository's name. A number alone could belong to
another repository's pull request.

#### Label match requires no following digit so #10 is not in #105
`contains_label`: `label` occurs and no digit follows it, so `#10` is not mentioned by `#105`.

#### Normalize to singular words with pull request as pr for matching
`work_words`: Lowercased content words in singular form, with "pull request" as "pr", so
"Review the pull requests" and "open PR review" share their words.

#### Same work needs all name words, same project, and no conflicting PRs
`describes_same_work`: Every word of the session's name is in the task's title, the task is about
the session's project, and the two name no different pull requests: "Review
all open PRs" in LokalBot is "LokalBot open PR review and fixes", while
"Review PR" is not "LokalBot PR #290 review".

#### Merged sessions add only pull requests the task has not named
`unmentioned_outcome`: The part of a session's outcome a task does not state yet. Several sessions
can merge into one task, so each adds only pull requests it has not already
named.

#### Small model drops parallel sessions, so outcome sessions are added after aggregation
`merge_session_candidate`: Segment extraction keeps at most three items per segment, and a small model
rarely fills them all, so parallel sessions could still vanish. Those that
recorded an outcome are stated from their actions and added after aggregation.

#### A recorded merge or release settles status over the model's conclusion
`merge_session_candidate`: A recorded merge or release settles the status; nothing weaker overrides
what the model concluded.

#### Conservative output when the model fails or rejects everything
`best_available_blocks`: Conservative output when the model fails or rejects everything.

#### Agent sessions name work and actions, saying more than a window title
`best_available_blocks`: Agent sessions name their work and record their actions, which says more
than a window title without claiming an outcome.

#### Answers cached in memory only, keyed by exact prompt per day
`SEGMENT_CACHE`: Answers already given today, keyed by the exact prompt; in memory only.
Days in use order, then each day's prompt key → answer.

#### Cached answers dropped for days whose evidence was deleted or corrected
`purge_cache`: Forgets cached answers for days whose evidence was deleted or corrected.

#### Model errors never fail; evidence-only journal written with quality fallback
`generate_day_digest`: The journal Markdown for `day` and its sidecar. Never fails on a model
error: the evidence-only journal is written with `quality: fallback`.

#### Callers use only a current digest; a stale one could contradict corrections
`generated_digest`: The day's unedited generated digest and whether it still matches the day's
evidence (`DailyEvidenceArtifacts.generatedDigest`). Callers use only a current
one: a stale digest could disagree with newer corrections or evidence.

#### Decide whether a stored digest is current without generating
`evidence_signatures`: The current evidence signatures for `day`, to decide whether a stored
digest is still current without generating anything.

### `LinuxWindows/crates/lokalbot-ai/src/digest/tests.rs`

#### Test guards one entry per session showing recorded facts, not claims
`agent_work_has_its_own_section_with_recorded_facts_only`: One entry per session, with what was recorded and not what it claimed.

#### Test: capture after burst stays; only one covered-block capture remains
`screen_text_in_a_host_app_defers_to_the_session_covering_it`: The standalone capture at 09:40 is outside the block but also after the
burst, so it stays; only one capture from the covered block remains.

#### Mac-moved libraries hold agent sessions with key saved true; user choice still needed
`sessions_in_the_library_wait_for_the_users_choice`: A library moved from a Mac has them, with the key saved as true.

### `LinuxWindows/crates/lokalbot-ai/src/download.rs`

#### Downloads stream to .part, verify size and SHA-256, resume via range manifest
Verified downloads (`ModelDownloadManager.swift`, `ParallelRangeDownloader.swift`,
`DownloadIntegrity.swift`) and archive extraction.

A download streams into `<dest>.part`, is checked against its pinned size
and SHA-256 (and GGUF magic for `.gguf`), then renamed into place with a
`<dest>.sha256` sidecar so later launches skip re-hashing. Files of 256 MiB
and more arrive as 64 MiB ranges over up to six connections, each written
at its own offset; a `<dest>.part.json` manifest of finished ranges lets a
failed or cancelled download resume.

#### Plain-HTTP loopback allowed only so tests can use a stub server
`Options.allow_loopback_http`: Tests serve files from a plain-HTTP loopback stub.

#### Hugging Face source defaults to the settings' choice when None
`Options.source`: Where Hugging Face files come from; the settings' choice when `None`.

#### Skips installed verified files; progress callback runs on the calling thread
`download`: Downloads `spec` unless it is already installed and verified.
`progress(bytes_done, bytes_total)` runs on the calling thread.

#### Loopback http only for local dry-run update feeds; size and SHA still checked
`download_allowing_loopback_http`: [`download`] that also accepts plain `http://` from this computer, for
dry-run update feeds served locally. Size and SHA-256 are still checked.

#### Count only allocated blocks, since set_len makes ranged parts sparse
`stashed_bytes`: The disk space an interrupted attempt's `.part` file already takes up. A
ranged download gives the file its full length before any byte arrives
(`set_len`), which most Unix filesystems store as a hole, so there only the
allocated blocks count.

#### st_blocks counts 512-byte units regardless of filesystem block size
`stashed_bytes`: `st_blocks` counts 512-byte units whatever the filesystem's block size.

#### Mirrors ModelDownloadManager.sourceRefusal on macOS
`source_refusal`: Why a source may not be downloaded, or `None` (`ModelDownloadManager.sourceRefusal`).

#### Fresh connection per request so HTTP/1.0 servers closing after HEAD don't break GET
`agent (download)`: A new connection for every request. ureq would send the GET down
the connection that answered the HEAD probe even when an HTTP/1.0
server (`python -m http.server` for a dry-run update feed) closes
it after one response, failing the download with "Peer
disconnected".

#### Reuse stash only for same URL, size, part size and validator
`download_ranged`: A stash is reused only for the same URL, size, part size and server
validator: a changed upstream file is never stitched from two versions.

#### Never write a 200 whole-file reply from a server that ignores Range
`fetch_part`: One range, written at its offset as it arrives. A server that ignores
`Range` answers 200 with the whole file; that must never be written here.

#### SAFETY: valid NUL-terminated path and out-parameter for statvfs
`free_space (unix)`: SAFETY: `c_path` is a valid NUL-terminated path and `stat` is a
properly sized out-parameter that statvfs fully initializes on success.

#### statvfs field types vary across Unix targets, so conversion is allowed
`free_space (unix)`: The field types vary across Unix targets.

#### SAFETY: NUL-terminated wide path, valid u64 out-pointer, optional others null
`free_space (windows)`: SAFETY: `wide` is NUL-terminated; the out-pointer is a valid u64 and
the other out-parameters are optional (null).

#### Extraction stops past byte and entry limits to stop archive bombs
`MAX_EXTRACTED_BYTES`: Extraction stops past this many bytes or entries (archive bombs).

#### Supported archive formats; any entry escaping dest fails the whole extraction
`extract_archive`: Extracts a `.zip`, `.tar.gz`/`.tgz`, `.tar.bz2`/`.tbz2` or `.tar` into
`dest`. Entries that would land outside `dest` (absolute paths, `..`, links
pointing out) fail the whole extraction.

#### Link targets resolved lexically relative to the entry's folder
`link_inside`: Resolves a link target written relative to `entry`'s folder, lexically,
and returns it relative to the archive root when it stays inside.

#### Hard links and Windows symlinks become copies after target exists
`extract_tar`: Hard links and (on Windows) symlinks become copies once their target exists.

#### Regression: retried ranged download skipped free-space check on pre-sized part
`a_part_file_sized_up_front_is_credited_only_for_what_it_holds`: Retrying a ranged download skipped the free-space check: the `.part`
file already had its full length, with almost nothing in it.

#### A streamed partial holds every byte, so it is fully credited
`a_part_file_sized_up_front_is_credited_only_for_what_it_holds`: A streamed partial holds every byte of its length.

#### Test: GET must not reuse HEAD connection against HTTP/1.0 servers
`requests_do_not_reuse_a_connection_an_http_1_0_server_closes`: An HTTP/1.0 server, like the `python -m http.server` that serves the
update checks' dry-run feed, answers one request per connection and
then closes it. A request sent down that connection again gets no
answer, so the GET must not reuse the connection of the HEAD probe.

#### Stub closes only after client sends more, keeping the test timing-independent
`requests_do_not_reuse_a_connection_an_http_1_0_server_closes`: Close only once the client has sent more on this
connection (or after a while), so the outcome does not
depend on timing.

### `LinuxWindows/crates/lokalbot-ai/src/download_source.rs`

#### Mirror sources for blocked Hugging Face; pinned size and SHA-256 still enforced
Routes pinned Hugging Face file downloads through the source chosen in
Settings → Models (`ModelDownloadSource`, `ModelDownloadRouting`).

huggingface.co is blocked in mainland China, so two opt-in sources serve the
same files there. Only `https://huggingface.co/<owner>/<repo>/resolve/<revision>/<path>`
URLs are rerouted; GitHub archives, the Hugging Face API and every other host
are untouched, and catalogs keep their Hugging Face URLs, so the pinning
policy still applies to them. The chosen mirror is tried first and each later
source is a fallback. Every file is checked against its pinned size and
SHA-256, so a source can make a download fail but cannot change a model.

#### Engine pushes every settings change of download source here
`set_source`: The source chosen in settings; the engine passes every change here.

#### Path stays percent-encoded as in the original URL
`ResolvedFile`: A Hugging Face `resolve` URL split into its parts. `path` stays
percent-encoded, as it appears in the URL.

#### ModelScope follows branches, so a listing check ensures the pinned file
`candidates`: ModelScope follows branches, not Hugging Face revisions; the listing
check in `model_scope_serves` keeps it to files that match the pin.

#### ModelScope used only if path, pinned SHA-256 and known size match
`model_scope_serves`: Whether ModelScope serves exactly the pinned file: its listing has the same
path with the pinned SHA-256 (and size, when known).

#### Failed or mismatching source falls through to next; cancel stops
`try_candidates`: Tries each source in turn. `attempt` downloads one URL and checks it against
the pin, so a file that fails moves on to the next source. Cancelling stops.

#### Listing cached once per repository per launch; failures not cached
`model_scope_listing`: A ModelScope repository's files by path, fetched once per repository per
launch. A failed fetch isn't cached, so a later download can try again.

#### No listing means ModelScope is skipped without a request
`(test) model scope fallback`: No listing, so ModelScope is skipped without a request.

### `LinuxWindows/crates/lokalbot-ai/src/dream.rs`

#### Nightly review pipeline with evidence-only fallback and privacy-bounded generation
One night's review, end to end (`DreamCompiler`, `DreamPrompts`, `DreamService`):
compile the previous day's evidence, ask the Think model for the retrospective
and the memory update, merge and save. When no model is reachable a
deterministic evidence-only brief is written instead, and the report says
which kind it is. Evidence comes from the local library; generation follows the
Think model's privacy boundary, and artifacts stay inside the library.

#### Cap journal share because its activity log pushed other evidence out
`DIGEST_CHARACTER_LIMIT`: The journal's share of the pack. Its activity log can run to hundreds of KB;
unbounded it pushed everything else past the limit.

#### Under five tracked minutes a day counts as empty
`EMPTY_DAY_TRACKED_SECONDS_FLOOR`: Under five tracked minutes a day counts as empty.

#### Evidence gathered up front so synthesis is a pure function
`DreamEvidence`: Everything one review reads, gathered up front so the synthesis is a pure
function of this value.

#### Prior meetings carry titles and days only, to show recurring themes
`DreamEvidence.prior_meetings`: Titles and days only, so recurring themes show without re-reading.

#### Candidates rendered with handles that index open_action_thread_ids
`DreamEvidence.open_actions`: Rendered candidates, `- [ ] [A1] …`; each handle indexes the ids below.

#### Complete app-owned dependency set of the rendered input
`DreamEvidence.sources`: The complete, app-owned dependency set of the rendered input.

#### Only the analyzed day counts toward emptiness, never the comparison window
`DreamEvidence.is_substantively_empty`: The analyzed day itself produced nothing worth a model pass. The
comparison window never counts.

#### Mirrors DreamCompiler.compile; read-only over the library
`compile`: `DreamCompiler.compile`: read-only over the library.

#### Sample meeting is made up and never part of the day
`compile`: The sample meeting is made up: it never becomes part of the day.

#### Keep grounded sections, then as much raw activity log as fits
`digest_for_dream`: The journal's grounded sections, then as much of its raw activity log as fits.

#### Sanitize and hard-cap evidence so OCR-heavy days fit the context
`evidence_pack`: Every section as labeled plain text, sanitized and hard-capped so an OCR-heavy
day can't blow the context window.

#### Model-free brief only restates evidence so it cannot invent
`fallback_report`: The model-free brief: it only restates evidence, so it can never invent.

#### Strict outputs need every property, so expired is required and prompted false
`schema`: JSON schema matching the system prompt, for grammar-constrained backends.
Strict structured outputs need every declared property, so `expired` is
required here and the prompt says to return false for an active goal.

#### Unknown handles removed without inventing links; duplicates keep first link
`link_top_actions`: Strips candidate handles ("[A2] …") and maps each to its thread. Unknown or
out-of-range handles are removed without inventing a link; duplicates keep
only their first link.

#### Tolerant JSON extraction, strict decoding; memory lists stay strict; None triggers fallback
`parse`: `DreamPrompts.parse`: tolerant extraction of the JSON object, then strict typed
decoding. Report sections drop blank bullets; memory lists stay strict because
they replace stored entries. `None` sends the service to the fallback.

#### On truncation retry once with thinking off and more output room
`generate_synthesis`: The model ran out of room: retry once with thinking off and more room for the
visible JSON, as the day digest does.

#### Mirrors DreamInferenceProvenance for where a Think client runs
`inference_provenance`: Where a Think client runs, for the report (`DreamInferenceProvenance`).

#### Consecutive transient failures already seen for this day
`DreamRequest.transient_failures`: Consecutive transient failures already seen for this day.

#### Failing to make the engine yields an evidence-only brief
`DreamRequest.make_engine`: `None` when the Think model can't be made; the brief is then evidence-only.

#### True once the run was overtaken and must stop
`DreamRequest.cancelled`: True once the run has been overtaken and must not continue.

#### Automatic runs retry transient errors this many times before evidence-only brief
`TRANSIENT_ATTEMPTS_BEFORE_FALLBACK`: Automatic runs that hit a rate limit or dropped connection are retried after
the backoff; the evidence-only brief is written only after this many.

#### Transient failure retried quietly by the scheduler after backoff
`DreamError::Deferred`: A transient failure the scheduler retries after its backoff, quietly.

#### Cancelled when sources change, work memory cleared or run stopped
`DreamError::Cancelled`: The sources changed, Clear work memory ran, or the run was stopped.

#### Read evidence revision before compiling to notice source changes
`dream`: Read before compiling: a source change while the library is being read
can't be noticed any other way.

#### Rebuild missing historical report from own evidence, never replay over newer memory
`dream`: A missing historical report may need rebuilding after later days advanced
memory: rebuild it from its own evidence, but never replay an older
synthesis over newer state.

#### Empty days get a stub without a model call; stub marks day reviewed
`dream`: Nothing happened that day: don't wake a model to say so. The stub
marks the day reviewed so catch-up moves on, and memory carries forward.

#### Rate limit or dropped connection is not a broken backend
`dream`: A rate limit or dropped connection isn't a broken backend.

#### Engine failure writes evidence-only brief, leaves memory, marks day done
`dream`: No model prepared, server down, remote origin unapproved, or
still failing: deliver the morning surface, memory untouched,
and mark the day done. "Review now" can redo it.

#### Show yesterday's brief or newest substantive within five days; skip empty stubs
`today_report`: `TodayDreamSelection.report`: yesterday's brief when there is one, otherwise the
newest substantive brief within the last five days. Empty-day stubs exist only
to mark their day reviewed and are never shown.

#### Only yesterday's model-caused fallback brief is retryable; empty day is not
`is_retryable_failure`: A current evidence-only brief caused by model generation can be retried
(`TodayDreamSelection.isRetryableFailure`). An empty day has nothing to redo.

### `LinuxWindows/crates/lokalbot-ai/src/dream/tests.rs`

#### Blank memory string would replace a stored entry, so reply is rejected
`parse_is_tolerant_of_wrapping_and_strict_about_memory`: A blank memory string would replace a stored entry: the whole reply is bad.

#### Empty-day stubs mark the day but are never shown
`an_empty_day_writes_a_stub_without_waking_a_model`: Empty-day stubs mark the day but are never shown.

#### Work memory must stay readable by readers written against the Mac file
`a_model_reply_becomes_a_report_and_merged_memory`: Readers that were written against the Mac's file still read it.

#### Manual Review now does not wait for a retry
`a_rate_limit_defers_an_automatic_run_and_then_gives_up`: "Review now" doesn't wait for a retry either.

### `LinuxWindows/crates/lokalbot-ai/src/dream_rollup.rs`

#### Weekly and monthly rollup lines carry a stamp; stale lines removed, few model calls nightly
After the overnight review: one line for each recent finished week and month,
condensed from that period's daily reviews, so the agent briefing can show
older time at lower detail (`DreamRollupService`). A line records a stamp of
the reviews it came from; a deleted or regenerated review makes it stale, and
stale lines are removed here and never shown. At most a few model calls a
night, newest periods first.

#### Prune stale lines, write due lines within interval; engine made only when due
`run`: Removes stale lines and lines for periods the briefing no longer shows, then
writes up to `limit` due lines, unless lines were written within the minimum
interval. The engine is made only when something is due.

### `LinuxWindows/crates/lokalbot-ai/src/embeddings.rs`

#### Chunking and scoring live in core; this layer computes vectors on local embedder
"Search by meaning" for meetings (`Services/Search/EmbeddingIndex.swift`).

Chunking, storage and brute-force scoring live in `lokalbot_core::embeddings`;
this layer computes the vectors on the local embedder server.

#### Purge vectors from other models, then index missing or stale meetings
`index_pending`: Indexes every meeting whose embeddings are missing or stale, oldest
vectors from another model first purged. Returns how many were indexed.

#### Start is 0 for summary and notes chunks
`SemanticHit.start`: Seconds into the recording (0 for summary and notes chunks).

#### Hits must exceed the meeting similarity floor
`semantic_meeting_hits`: The best meeting passages for `query` above the meeting similarity floor.

### `LinuxWindows/crates/lokalbot-ai/src/error.rs`

#### Wording follows macOS TextEngineError, LlamaServer and download messages
`AiError`: Failures callers branch on. Wording follows the macOS `TextEngineError`,
`LlamaServer.ServerError` and `ModelDownloadManager` messages.

#### Remote origin not approved or not HTTPS requires consent
`AiError::ConsentRequired`: The server is remote and its origin is not approved (or not HTTPS).

#### Reply hit max_tokens; partial holds visible text so far
`AiError::Truncated`: The reply hit `max_tokens`; `partial` holds the visible text so far.

#### Open Agent Mode task keeps model loaded, blocking model or backend change
`AiError::ModelHeld`: An open task keeps `held` loaded, so the server can't change models
(or backends) until that task is closed.

#### Cancellation messages contain the word cancelled so callers detect them in text
`AiError::Cancelled`: Messages contain "cancelled" so callers can recognize them in text.

#### Retryable: 408/409/425/429/5xx and transport failures, per macOS
`AiError::is_retryable`: 408/409/425/429/5xx and transport failures (`TextEngineError.isRetryable`).

#### 429 may come from the server or a router's provider behind it
`AiError::is_rate_limit`: The server, or a provider behind a router, is rate limiting this key.

### `LinuxWindows/crates/lokalbot-ai/src/follow_up.rs`

#### Follow-up draft is explicit, grounded in outcomes, and never sent
A follow-up email draft from one meeting's own outcomes
(`FollowUpDraftGenerator.swift`). Explicit (the user asks for it),
grounded (only the recap, decisions, corrected actions and open
questions) and never sent: the draft is returned for the user to review.

#### Draft is only shown to the user; nothing is sent
`FollowUpDraft`: The draft to show; nothing is sent.

#### Owner is Me for the user's own work
`EvidenceAction.owner`: "Me" for the user's own work.

#### Due is resolved day text or the spoken phrase
`EvidenceAction.due`: The resolved day ("Thu, Oct 22") or the spoken phrase.

#### Calendar display names only, used for the greeting
`Evidence.participant_names`: Calendar display names only, for the greeting.

#### Mirrors FollowUpDraftGenerator.evidence(for:summary:)
`evidence`: `FollowUpDraftGenerator.evidence(for:summary:)`.

#### Evidence prompt text is sanitized and capped at 8,000 characters
`prompt_context`: The evidence as prompt text, sanitized and capped at 8,000 characters.

#### Mirrors FollowUpDraftGenerator.generate(evidence:engine:)
`generate_from`: `FollowUpDraftGenerator.generate(evidence:engine:)`.

#### Line that older merge drafts open with, from SummaryPresentation
`MERGE_BOILERPLATE`: The line older merge drafts open with (`SummaryPresentation.meetingBody`).

#### Merged meetings show display title and drop implementation boilerplate; mirrors macOS
`meeting_body`: `SummaryPresentation.meetingBody`: merged meetings show their display
title and drop implementation boilerplate.

#### Strip provenance line; mirrors SummaryPresentation.split
`summary_body`: The summary without its provenance line (`SummaryPresentation.split`).

#### Counts Label:value pairs joined by dot; zero if any piece is not one
`metadata_pairs`: How many `**Label:** value` pairs joined by " · " make up `line` (0 when
any piece is not one).

#### Reading preview: TL;DR section else first paragraph, no speaker labels or stamps
`recap`: The reading preview of a summary (`SummaryPresentation.recap`): its
TL;DR section, else its first prose paragraph, without speaker labels or
playback stamps.

#### Dedupe by email else folded name; legacy hints when no structured attendees
`participant_names`: Calendar attendee names (`resolvedCalendarParticipantIdentities`),
deduplicated by email, else by folded name; legacy name hints when the
meeting has no structured attendees.

#### Mirrors CalendarParticipantIdentity.normalizedDisplayName
`display_name`: `CalendarParticipantIdentity.normalizedDisplayName`.

#### Mirrors CalendarParticipantIdentity.normalizedEmailAddress
`email_address`: `CalendarParticipantIdentity.normalizedEmailAddress`.

### `LinuxWindows/crates/lokalbot-ai/src/http.rs`

#### Blocking HTTP shared by clients and runtime health checks
Blocking HTTP shared by the clients and the runtime's health checks.

#### Loopback bypasses environment proxy, remote honours it; statuses returned not raised
`agent`: An agent for one server. Loopback servers bypass any proxy from the
environment; remote ones honour it. Status codes are returned, not raised.

#### Mirrors TextEngineError.fromHTTPResponse: server's own message, clipped
`Reply::status_error`: `TextEngineError.fromHTTPResponse`: the server's own message, clipped.

#### Log only the host, never path or query
`host_label`: The host of a URL for logs; never the path or query.

#### Ignore inf or overlarge Retry-After so caller backoff applies instead of panic
`retry_after`: `Retry-After` in seconds. `inf` or a value too large for a `Duration` is
ignored, so the caller's own backoff applies instead of a panic.

#### Header values are never logged
`post_json_with`: A JSON POST with explicit headers (Anthropic's `x-api-key`, a plan's
bearer token). Header values are never logged.

#### Form fields sent in key order with every value percent-encoded
`post_form`: An `application/x-www-form-urlencoded` POST (OAuth token endpoints).
Fields are sent in key order, every value percent-encoded.

#### Percent-encode everything outside RFC 3986 unreserved characters
`form_escaped`: Percent-encodes everything outside RFC 3986's unreserved characters.

#### Each item is written as a data: line with blank terminator
`testing::Reply::Sse`: Server-sent events: each item is written as `data: <item>\n\n`.

#### File reply honours HEAD and Range byte requests
`testing::Reply::File`: A file honouring HEAD and `Range: bytes=a-b` / `bytes=a-`.

### `LinuxWindows/crates/lokalbot-ai/src/hugging_face.rs`

#### Search results are ordered most downloaded first
`ModelSummary`: One repository from the search, most downloaded first.

#### Percent-encoded resolve URL with digest in fragment, as the Mac stores it
`HfFile::download_url`: The `resolve` URL, percent-encoded, with the digest in its fragment the
way the Mac stores it.

#### Nested repo files download flat under models/
`HfFile::file_name`: Repos sometimes nest files, and downloads land flat under `models/`.

#### customBuiltInModels record read by both apps, matching ModelCatalog.Entry
`HfFile::catalog_record`: The `customBuiltInModels` record both apps read (`ModelCatalog.Entry`).

#### direction=-1 required because sort=downloads alone returns least popular first
`search_url`: `direction=-1` is required: `sort=downloads` alone returns least popular first.

#### Files listed in natural filename order so quantization variants group
`files`: A repository's `.gguf` files in natural filename order, so quantization
variants group sensibly.

#### Matches localizedStandardCompare: ignore case, digit runs compare numerically
`natural_order`: `localizedStandardCompare`: ignores case, and digit runs compare as numbers.

#### Ignored test needs network; run with --ignored
`the_live_api_lists_pinned_files`: Needs the network: `cargo test -p lokalbot-ai hugging_face -- --ignored`.

### `LinuxWindows/crates/lokalbot-ai/src/json.rs`

#### Tolerant model-output reading mirrors Swift ChatPrompt and CompleteJSONRecords
Tolerant reading of model output (`ChatPrompt.extractJSONObject`,
`CompleteJSONRecords`, `strippingReasoning`).

#### Removes think blocks that Qwen 3 and similar models emit before answer
`strip_reasoning`: Removes `<think>…</think>` blocks that Qwen 3 and similar models emit
before the answer, then trims.

#### Unclosed thinking block in truncated reply counts as reasoning
`visible_text_of_truncated`: A truncated reply's visible part: an unclosed thinking block is reasoning.

#### Keeps complete top-level array records even from truncated envelope
`CompleteRecords`: Complete top-level array records, even from a truncated envelope.

#### Complete means envelope parsed whole and every requested key was an array
`CompleteRecords.complete`: The envelope parsed whole and every requested key held an array.

#### Never close partial objects or invent fields; keep only fully written records
`complete_records`: `CompleteJSONRecords.parse`: never closes a partial object or invents
fields; it keeps only records that were fully written.

#### Strict envelope must start with an object, not prose
`complete_records`: The strict envelope starts with an object, not arbitrary prose.

#### Sort keys because grammar-constrained servers emit properties in wire order; keep bodies stable
`sort_keys`: Rebuilds every object with sorted keys. Grammar-constrained servers emit
schema properties in wire order, so request bodies must be stable.

### `LinuxWindows/crates/lokalbot-ai/src/language.rs`

#### Summary language by voting over sampled windows, using whatlang instead of Apple's recognizer
Summary language (`Models/Meetings/SummaryLanguage.swift`, `LanguageCode.swift`).

`match` resolves the transcript to a concrete language by voting over
windows sampled across the meeting, so a foreign-language opening never
decides the whole meeting. Detection uses `whatlang` instead of Apple's
`NLLanguageRecognizer`; a language outside the summary presets keeps the
prompt's own "the transcript's language" rule.

#### Setting is match, a code or custom:name; None means transcript's language
`prompt_language`: The language name the prompts carry for the `summaryLanguage` setting
(`match`, a code, or `custom:<name>`); `None` means "the transcript's
language".

#### Returns preset name for dominant language; None if winner is not a preset
`detect`: A preset language name for the dominant language, `None` when the
winner is not a preset (or nothing could be detected).

#### Mostly-English meetings get English-only wording checks
`is_mostly_english`: Mostly-English meetings get the English-only wording checks.

#### Simplified versus Traditional Chinese decided by script
`chinese_script`: Simplified vs Traditional Chinese is a matter of script.

#### Kana alongside Han means Japanese, not Chinese
`chinese_script`: Kana alongside Han is Japanese, not Chinese.

### `LinuxWindows/crates/lokalbot-ai/src/lib.rs`

#### Crate overview: pinned models match macOS; errors are anyhow wrapping AiError
Think, Autocomplete and embeddings for LokalBot on Linux and Windows.

- [`catalog`]: the pinned GGUF models (same files and digests as macOS).
- [`download`]: verified, resumable HTTPS downloads and archive extraction.
- [`runtime`]: prebuilt llama.cpp `llama-server` subprocesses, one per role.
- [`think`]: chat, embedding and raw-completion clients with the consent gate.
- [`anthropic`]: Claude through Anthropic's Messages API.
- [`plans`]: Think on the user's ChatGPT or Claude plan.
- [`ocr`]: on-device screen text recognition (ocrs, Tesseract, Windows).

Errors are `anyhow::Error`; the ones callers act on are [`AiError`] values
inside it (`err.downcast_ref::<AiError>()`).

### `LinuxWindows/crates/lokalbot-ai/src/media_embedder.rs`

#### Single-caller media embedder; inputs sent as the Mac parity run qualified
EmbeddingGemma 2 with its image and audio projector, on the media
llama-server (`FileMediaEmbedder`). One caller at a time, one thread, and it
waits: Files' indexer and the picture vectors of saved screens both use it.

Inputs travel the way the Mac's parity run qualified them: texts as given
(cut to one batch when longer), images as PNG sized for their budget, audio
as WAV, each medium as a typed content part. Searches never use this server;
they embed their words on the small text-only embedder.

#### Bump when pipeline changes vectors; every file index re-embeds
`VECTOR_VERSION`: Which vectors this pipeline makes: the model files, the llama.cpp build, the
image sizing and the request shapes. Bump it when any of them changes the
vectors; every file index then embeds again.

#### Name the index stores for vectors, mirroring WorkerInfo.vectorSource
`vector_source`: What the index calls its vectors (`WorkerInfo.vectorSource`).

#### Any change to picture model identity re-embeds every retained capture
`picture_model_id`: What pictures of saved screens are called: model, projector, sizing and request
shapes. Any change embeds every retained capture again.

#### One request is one batch; cap keeps long documents from multi-minute requests
`TEXTS_PER_REQUEST`: Texts per request. One request is one llama-server batch; this keeps a long
document from becoming a single multi-minute request.

#### Maximum tokens per input including bos and eos
`MAX_INPUT_TOKENS`: The most tokens one input may have, `<bos>` and `<eos>` included.

#### Server answered but not with vectors; only that file fails
`MediaError::Rejected`: The server answered, but not with vectors for this input (a broken
picture, one too large for its batch): the file fails alone.

#### Server cannot answer; files stay pending for the next pass
`MediaError::Unavailable`: The server can't answer: files stay pending for the next pass.

#### Dropping the embedder lets the model unload after idle time
`MediaEmbedder`: The server for one pass. Dropping it lets the model go after its idle time.

#### Cut long text like transformers; llama-server returns 500 for overlong input
`MediaEmbedder::fitted`: A text as it is sent: itself when it fits one batch, otherwise its tokens
cut the way transformers cuts, the first 2,047 and `<eos>`. llama-server
refuses a longer input with HTTP 500 instead of cutting it. No token is
shorter than a byte, so shorter texts skip the tokenizer.

#### Overlong-input HTTP 500 rejects the file alone instead of stalling every pass
`classify_status`: llama-server answers an input longer than its batch with HTTP 500, though the
server is fine; a picture or recording that still doesn't fit fails alone
instead of stopping every pass at the same file.

#### Typed content part must be nested; flat image_url input is rejected by llama.cpp
`image_part`: A typed content part nested one level inside the input item; a flat
`input: [{type: image_url}]` is rejected (ggml-org/llama.cpp#30082).

### `LinuxWindows/crates/lokalbot-ai/src/personal_learning.rs`

#### Overnight learning reads only the person's words, max three grounded items
The overnight learning pass's model call (`PersonalLearning`). After the day's
review it reads only the person's own words from that day and asks the Think
model for at most three durable things about them. Every result must point at
one of those lines and be grounded in it; anything else is dropped. Which lines
may be read is decided in `lokalbot_core::personal::learning`.

#### Cross-language similarity floor from measured Serbian vs English; recalibrate on model change
`CROSS_LANGUAGE_FLOOR`: EmbeddingGemma 2 with the sentence-similarity prompt, measured on Serbian lines
against English items (2026-10-14): correct translations 0.83–0.95, unrelated
claims 0.73–0.79, and a wrong detail 0.80–0.90. Below the floor an item is
dropped. Above it, a fact or goal is saved only with a shared word root or a
very high score; otherwise it waits for review. Recalibrate whenever the
embedding model changes.

#### Only items citing a real line with a learnable kind, in reply order
`proposals`: Every item that cites a real line with a learnable kind, in reply order.

#### Principles are never learned
`proposals`: Principles are never learned.

#### Grounded means a third of content words appear in the line
`is_grounded`: Word overlap: at least a third of the item's content words are in the line.

#### Differing languages skip word overlap; unknown counts as same, stricter path
`is_cross_language`: The two texts' dominant languages differ, so word overlap can't apply. Unknown
counts as the same language: the stricter path.

#### Serbian Cyrillic transliteration is just enough for the root check
`latin`: Serbian Cyrillic to Latin, enough for the word-root check.

#### Word-root check: content words starting the same way, across transliteration
`shares_word_root`: A content word of the item and of the line (Cyrillic transliterated) start the
same way: "platform" in "platformu", "marathon" in "maraton".

#### Learned items depend on meeting or day evidence; Ask and dictation have none
`provenance`: What a learned item depends on: its meeting, or the day's activity evidence for
a coding-agent request. An Ask question or dictation has none.

#### Embeddings are L2-normalized; None when no embedder is available
`Embed`: Vectors for texts, L2-normalized, or `None` when no embedder is available.

#### Translated items compared by meaning; dropped without embedder; at most three
`grounded_candidates`: Word overlap for items in the line's language. An item the model translated
can't share words, so it is compared by meaning instead, when the embedder is
available. Without it those items are dropped. At most three.

#### Takes gathered lines so caller can check prior reads; no lines no call
`run`: The pass over lines already gathered, so the caller can first check whether the
day's lines were read before. No lines, no model call.

### `LinuxWindows/crates/lokalbot-ai/src/process.rs`

#### Linux PDEATHSIG needs one long-lived spawner thread; Windows uses job object
Child processes that cannot outlive LokalBot, plus liveness checks for
PID markers left by an earlier run.

Linux: `PR_SET_PDEATHSIG` fires when the *thread* that forked the child
exits, so every helper is spawned from one thread that lives as long as
the process. Windows: helpers join a job object that kills them when the
last handle to it (ours) closes.

#### pre_exec hook must be async-signal-safe and allocation-free
`linux::spawn`: SAFETY: the hook runs between fork and exec and only calls the
async-signal-safe prctl/getppid; it allocates nothing.

#### Parent may die before prctl takes effect; check getppid
`linux::spawn`: The parent may have died before prctl took effect.

#### Job handle is process-wide, thread-safe, never closed while running
`windows::Job`: SAFETY: a job handle is a process-wide kernel handle; it is only passed
to thread-safe Win32 calls and never closed while the process runs.

#### Win32 calls valid; zeroed info struct sized exactly
`windows::job`: SAFETY: plain Win32 calls with valid arguments; the info struct
is zero-initialized as the API allows and sized exactly.

#### Both handles valid for the duration of the call
`assign_to_job`: SAFETY: both handles are valid for the duration of the call.

#### Process may exist but belong to another user
`pid_alive`: Whether a process with this PID exists (it may belong to another user).

#### Signal 0 only checks existence and permission
`pid_alive`: SAFETY: signal 0 only checks for existence and permission.

#### Handle checked and closed; code is valid out-pointer
`pid_alive`: SAFETY: the handle is checked and closed; `code` is a valid out-pointer.

#### Handle checked and closed; buffer length passed in and out
`exe_path`: SAFETY: the handle is checked and closed; the buffer length is passed in and out.

#### SIGTERM then SIGKILL after grace; Windows terminates at once
`terminate`: SIGTERM, then SIGKILL after `grace` (Windows terminates at once).
Returns whether the process is gone.

#### Signal goes to a PID verified as a helper
`terminate`: SAFETY: plain signal delivery to a PID we verified belongs to a helper.

#### SIGKILL safety same as SIGTERM above
`terminate`: SAFETY: as above.

#### Process handle is checked and closed
`terminate`: SAFETY: the handle is checked and closed.

#### Signal goes to our own unreaped child
`stop_child`: SAFETY: signal delivery to our own, not yet reaped, child.

#### Drain both pipes concurrently so a full pipe can't block child
`run_capture`: Runs a short command with both pipes drained concurrently (a full pipe
would block the child), killing it after `timeout`.

### `LinuxWindows/crates/lokalbot-ai/src/project_status.rs`

#### Status note is cited per meeting and stamped with evidence fingerprint
A project's "Where it stands" note (`ProjectStatusGenerator.swift`):
grounded in the lines of its recent meetings that name it and the
decisions and actions that name it, cited per meeting, and stamped with
an evidence fingerprint so the page can tell when newer evidence exists.

#### Label M1 is the newest meeting
`MeetingEvidence.label`: "M1" is the newest meeting.

#### Mirrors ProjectStatusGenerator.evidence(for:)
`evidence`: `ProjectStatusGenerator.evidence(for:)`.

#### Mirrors SpeakerDisplayName.label; raw speaker keys read as people
`speaker_label`: `SpeakerDisplayName.label`: raw speaker keys read as people.

#### Context carries no date so its hash changes only with evidence
`prompt_context`: The evidence as prompt text. It carries no date of its own, so its hash
changes only when the evidence does.

#### Points cite meeting label or review; enum dropped past server limit
`schema`: Points cite a meeting label or "review"; the enum is dropped when the
server cannot hold that many values.

#### Library supplies evidence; note is returned, saved separately by caller
`generate`: Writes the status note for `project`. The library is the source of the
project's evidence (`Library::projects`); the note is returned, not saved
(`Library::save_project_summary` saves it).

#### Mirrors ProjectStatusGenerator.generate
`generate_from`: `ProjectStatusGenerator.generate(evidence:projectID:engine:location:now:)`.

### `LinuxWindows/crates/lokalbot-ai/src/prompts.rs`

#### Prompts copied verbatim from macOS app; Mac becomes PC
Every prompt the generators send, copied verbatim from the macOS app
(`Services/Notes/PromptTemplates.swift` unless noted). Only "Mac" becomes "PC".

#### None language means the transcript's language
`meeting_notes_system`: `meetingNotesSystem(template:language:)`. `language` is the prompt
language name ("English"), or `None` for the transcript's language.

#### Mirrors meetingNotesRepairSystem
`meeting_notes_repair_system`: `meetingNotesRepairSystem(language:)`.

#### Mirrors MeetingNotesRecovery.repairPrompt
`notes_repair_prompt`: The targeted repair's user prompt head (`MeetingNotesRecovery.repairPrompt`).

#### Mirrors MeetingNotes.promptContext
`user_notes_context`: `MeetingNotes.promptContext`.

#### User digest instructions capped at 500 characters
`DAY_DIGEST_CUSTOM_PROMPT_MAX_CHARACTERS`: The user's optional digest instructions are capped at this length.

#### Mirrors DayDigestOverviewGenerator.focusRetryPrompt
`DIGEST_FOCUS_RETRY`: `DayDigestOverviewGenerator.focusRetryPrompt`.

#### Mirrors DayDigestOverviewGenerator.digestRetryPrompt
`DIGEST_AGGREGATION_RETRY`: `DayDigestOverviewGenerator.digestRetryPrompt`.

#### Mirrors FollowUpDraftGenerator.system
`FOLLOW_UP_SYSTEM`: `FollowUpDraftGenerator.system`.

#### Mirrors ProjectStatusGenerator.system
`PROJECT_STATUS_SYSTEM`: `ProjectStatusGenerator.system`.

#### today format is EEEE, yyyy-MM-dd; zone is time zone identifier
`ask_library_system`: `AskLibraryEngine` (CLI/MCP `ask_library`). `today` is
`EEEE, yyyy-MM-dd`, `zone` the time zone identifier.

#### Mirrors DictationCleanupPrompt.transcriptAsData
`DICTATION_CLEANUP_SYSTEM`: Dictation cleanup (`DictationCleanupPrompt.transcriptAsData`).

#### Mirrors SelectionActionPrompt.system
`SELECTION_ACTION_SYSTEM`: `SelectionActionPrompt.system`.

#### Mirrors SelectionActionPrompt.memoryRules
`SELECTION_ACTION_MEMORY_RULES`: `SelectionActionPrompt.memoryRules`.

#### Action instructions mirror SelectionAction, keyed by action id
`SELECTION_ACTION_*`: `SelectionAction`'s instructions, by action id.

#### Mirrors DictationComposition
`DICTATION_COMPOSE_SYSTEM`: Dictation compose (`DictationComposition`).

#### Mirrors DreamPrompts.system
`DREAM_SYSTEM`: `DreamPrompts.system`.

#### Mirrors DreamRollupService.system
`DREAM_ROLLUP_SYSTEM`: `DreamRollupService.system`.

#### Mirrors PersonalLearning.system
`PERSONAL_LEARNING_SYSTEM`: `PersonalLearning.system`.

#### Mirrors PersonalLearning.prompt instructions; caller appends lines
`personal_learning_rules`: `PersonalLearning.prompt`'s instructions; the caller appends the lines.

#### Heading above work memory in Ask's system prompt, mirrors ChatPrompt
`ASK_WORK_MEMORY_HEADER`: The heading above work memory in Ask's system prompt (`ChatPrompt`).

### `LinuxWindows/crates/lokalbot-ai/src/reasoning_lookup.rs`

#### Reasoning support read only from allowed origins; no key or content
What a server publishes about a model's reasoning levels
(`ReasoningSupport.resolve`, `OpenRouterModelCatalog.reasoningSupport`,
`OllamaEngine.reasoningSupport`): OpenRouter's model list and Ollama's
capabilities. Both are read only from origins already allowed for inference, and
carry no key and no content. Callers check that the origin is allowed.

#### Running app re-reads OpenRouter's list once a day
`REFRESH_INTERVAL`: `OpenRouterModelCatalog.refreshInterval`: a running app looks again once a day.

#### Failed list read waits ten minutes so offline doesn't slow Think
`RETRY_INTERVAL`: A failed list read waits this long, so an offline computer doesn't add a timeout
to every Think request.

#### reasoning_effort and OpenRouter effort spell Off as none
`level_for_effort`: `reasoning_effort` and OpenRouter `effort` spell Off as "none".

#### No reasoning object means no reasoning; without efforts only off
`support_of`: A model's `reasoning` object: `supported_efforts`, whether reasoning is
`mandatory` (no Off), and its defaults. No object: the model doesn't reason.
Without listed efforts, reasoning can only be switched off.

#### Read when a day old or missing and not just tried
`ModelList::due`: Whether to read the list now: it's a day old, or missing and not just
tried. Saying yes counts as the try.

#### Separate read lock so interface drawing never waits on network
`OPENROUTER_READ`: Held for a read of OpenRouter's list, so callers that arrive during one wait
for it. The list has its own lock, held only to look at it: the interface
asks [`openrouter_cached`] while drawing and must never wait for the network.

#### Silent server loses its entry so built-in knowledge applies again
`OLLAMA`: Ollama's last answers, by server and model. A server that stops answering loses
its entry, and what LokalBot knows without asking applies again.

#### List read at most daily via GET base/models; None if unlisted
`openrouter`: The selected model's levels from OpenRouter's list, read at most daily (`GET
\<base>/models`). `None` when the model isn't listed.

#### No thinking capability means nothing to set
`support_of_capabilities`: Whether Ollama says the model thinks: no capability means nothing to set.

#### Uses POST /api/show; request carries only model name
`ollama`: The model's levels from `POST /api/show` capabilities. `None` if the server
doesn't answer. The request carries only the model name.

#### Good read lasts a day; later failure keeps known data
`the_list_is_read_daily_and_a_failed_read_waits`: A good read lasts a day, and a later failure keeps what it knew.

#### Interface reads cache while drawing; list read can take ten seconds
`a_read_of_the_list_leaves_the_cached_answers_free`: The interface reads the cached list while drawing, and a read of the
list can take ten seconds on a bad network.

### `LinuxWindows/crates/lokalbot-ai/src/remote_gate.rs`

#### One per-origin admission gate for remote servers, process-local like Mac actor
One admission gate for every external Think and autocomplete server, keyed by
origin (`RemoteInferenceGate.swift`). Every request waits for a slot, so
background digests and overnight reviews can't starve meeting notes, and a
rate limit pauses every caller of that origin instead of each one trying again
a second later. The built-in runtime has its own leases and never comes here.

The gate lives in one process, like the Mac's actor.

#### Cooldown cap mirrors RemoteRequestQueue.maximumCooldown, in seconds
`MAXIMUM_COOLDOWN_SECONDS`: `RemoteRequestQueue.maximumCooldown`, in seconds.

#### Waiters poll cancel flag, deadline and cooldown every 50 ms
`WAIT_TICK`: How often a waiter looks at its cancel flag, its deadline and the cooldown.

#### Priority order mirrors InferencePriority, most urgent first
`Priority`: `InferencePriority`, most urgent first.

#### Interactive means the person is watching: chat, autocomplete, model check
`Priority::Interactive`: The person is watching this happen (chat, autocomplete, model check).

#### Agent priority means an agent is waiting
`Priority::Agent`: An agent is waiting.

#### Pipeline is processing the person opens next, such as just-ended meeting notes
`Priority::Pipeline`: Processing the person will open next: notes for a meeting that just ended.

#### Background is scheduled work nobody waits for: digests, overnight review, briefs
`Priority::Background`: Scheduled work nobody is waiting for (digests, overnight review, briefs).

#### Limits mirror RemoteRequestQueue.Limits
`Limits`: `RemoteRequestQueue.Limits`.

#### Slot rules: concurrency caps, priority order, background never blocks, cooldown
`RequestQueue`: `RemoteRequestQueue`: pure bookkeeping for one origin's slots, with no clock
and no threads. Processing work runs at most `maximum_concurrent` requests at
once; background work holds at most `maximum_background` of them; someone
waiting on the answer is never queued behind processing work. Waiters start in
priority order, first come first served within a priority, and a blocked
background waiter never holds back one that could start. After a rate limit
nothing starts until the cooldown has passed.

#### Rate-limit count resets on first non-rate-limited answer
`RequestQueue.consecutive_rate_limits`: Consecutive rate-limited answers; resets on the first other answer.

#### Cooldown is Retry-After if given, else grows with consecutive rate limits
`cooldown`: `RemoteRequestQueue.cooldown`: the server's `Retry-After` when given, else a
pause that grows with consecutive rate limits.

#### Attempts bounded per priority; cooldown paces rate limits; notes wait, chat fails fast
`maximum_attempts`: `RemoteRetryPolicy.maximumAttempts`: the gate's cooldown already paces rate
limits, so this bounds attempts rather than the wait. Meeting notes are worth
waiting for; a person watching chat would rather see the error quickly.

#### Backoff applies only to non-rate-limit replays; rate limits wait on cooldown
`backoff`: `RemoteRetryPolicy.backoff`: the pause before a replay that didn't fail with a
rate limit. Rate limits wait on the cooldown instead.

#### Origin key is scheme, host and port in lower case, as on Mac
`origin`: `RemoteInferenceGate.origin(for:)`: scheme, host and port, in lower case.

#### Dropping a ticket unfinished frees its slot so a panic cannot leak it
`Ticket`: The slot one request holds. Dropped without `finish` it frees
the slot as an ordinary answer, so a panic can't leak it.

#### acquire blocks the calling thread until a slot is free
`Gate::acquire`: Waits for a slot on `origin`. Blocking.

#### Streaming requests are never replayed because replay could repeat shown text
`Gate::once`: One request that is never replayed: a stream could repeat text already shown.

#### Replaying requests own the retry; callers must not add their own replay
`Gate::replaying`: A replayable request (`GatedTextEngine.replaying`). Callers must not add
their own replay on top.

#### Rate limits wait on the origin cooldown in acquire, not a backoff pause
`Gate::replaying`: A rate limit waits on the origin's cooldown in `acquire`.

### `LinuxWindows/crates/lokalbot-ai/src/remote_transcription.rs`

#### Remote transcription never follows redirects so clips stay on the approved origin
Sends speech clips to the transcription server the user approved
(`RemoteTranscriptionEngine`), in OpenAI's `/audio/transcriptions` shape.
Redirects are not followed, so a clip can't leave the approved origin.

#### Ten-minute timeout because a slow CPU server can take over a minute per span
`REQUEST_TIMEOUT`: A slow CPU server can spend well over a minute on one span.

#### Word-timing refusals kept in memory only, so support is retried after relaunch
`WORD_TIMING_REJECTIONS`: Servers and models that refused the word-timing fields during this run
(`WordTimingRejections`). Kept in memory only: a server that adds support is
asked again after the next launch.

#### Client holds the API key only for one transcription
`Client`: One approved server, its key held for the life of one transcription.

#### Refuses unconfigured, invalid, unencrypted or unapproved servers
`Client::new`: Refuses an unconfigured, invalid, unencrypted or unapproved server.

#### Identity changes with server, model or key and holds no secret
`Client::identity`: Changes when the server, the model or the key does; holds no secret.

#### HTTP 400 on word timings retries with plain json and disables timings until quit
`Client::upload`: One clip, retried on rate limits, server errors and dropped connections. A
server that answers the word-timing fields with HTTP 400 is asked again with
plain `json`; when that succeeds, it stops being asked for word times until
LokalBot quits.

#### Disable word timings only once plain json works, not for other refusals
`Client::upload`: Only once plain json works: a clip the server refuses
for another reason changes nothing.

#### Backoff mirrors RemoteRetryPolicy: server hint, else doubling with jitter, max a minute
`backoff`: `RemoteRetryPolicy.backoff`: what the server asked for, else doubling with a
little jitter, never longer than a minute.

#### json is the portable response format; model omitted when empty for single-model servers
`multipart_body`: A multipart form in OpenAI's shape. `response_format=json` is the one every
provider and whisper.cpp accept; `word_timings` asks for `verbose_json` with word
timestamps instead. `model` is left out when empty because single-model servers
need none.

#### Drop wordless tokens; one invalid time drops all words so clip keeps one speaker
`timed_words`: `verbose_json`'s `words: [{word, start, end}]`. Tokens without letters or digits
are dropped; one word without valid times drops them all, and the clip then keeps
one speaker.

#### Accept OpenAI-style JSON text plus word times; some self-hosted servers answer plain text
`transcription`: `{"text": …}` from OpenAI-style servers, plus any word times; a few self-hosted
ones answer plain text instead.

#### Show the server's own error message in its common shapes, bounded
`error_detail`: The server's own message (`{"error": {"message": …}}`, `{"error": "…"}`, or a
short plain body), bounded for display.

### `LinuxWindows/crates/lokalbot-ai/src/sanitize.rs`

#### Sanitizer mirrors PromptContextSanitizer: strips control bytes, ragged spacing, stacked blanks
`PromptContextSanitizer`: prompt-ready text without control bytes,
ragged spacing or stacked blank lines. Punctuation is kept.

#### prefix counts characters, not bytes
`prefix`: The first `n` characters (not bytes).

### `LinuxWindows/crates/lokalbot-ai/src/selection.rs`

#### Selection actions mirror SelectionAction.swift; nothing here is stored
Selection actions (`SelectionAction.swift`): the built-in actions on text
selected in another app, typed instructions, their prompts, and the work
memory an action marked "with my memory" adds. Nothing here is stored.

#### Longer selections are cut at 12,000 characters and the panel says so
`SELECTION_CHARACTER_LIMIT`: The selection sent to the model. Longer selections are cut, and the panel
says so.

#### Memory search uses selection start, where messages usually state their topic
`MEMORY_QUERY_CHARACTER_LIMIT`: What the memory search looks for: the start of the selection is where a
message usually says what it is about.

#### Title is interface text, except for a typed instruction
`Action.title`: Interface text, except for a typed instruction.

#### Typed instruction replaces a selection, or writes new text at cursor without one
`Action::custom`: A typed instruction. With a selection it can replace it; without one
it writes new text at the cursor.

#### Match titles containing every typed word in English or interface language
`Action::matching`: Built-in actions whose title contains every typed word, in English or
in the interface language.

#### No thinking turn because someone waits to paste; 4,096 output ceiling fits long rewrites
`request`: No thinking turn: someone is waiting to paste. The output ceiling fits a
long rewritten passage.

#### Memory is matching meetings plus overnight work memory, same search as Ask's tool
`memory_context`: Meetings that match the selection, plus the overnight work memory
(`AppState.selectionMemoryContext`). Uses the same search as Ask's tool.

#### Empty when overnight review is off, file unreadable or memory empty; mirrors ChatPrompt
`work_memory_context`: `ChatPrompt.workMemoryContext`: empty when the overnight review is off,
the file is unreadable, or the memory holds nothing.

#### Fixture matches memory.json as Mac DreamStore writes it, with iso8601 dates
`tests::MAC_MEMORY`: `memory/memory.json` as `DreamStore` writes it (`.iso8601` dates).

### `LinuxWindows/crates/lokalbot-ai/src/test_support.rs`

#### Copy the macOS upgrade fixture; None when not checked out beside workspace
`fixture_library`: The macOS upgrade fixture, copied so tests never write into it. `None`
when the fixture is not checked out next to the workspace.

### `LinuxWindows/crates/lokalbot-ai/src/upcoming.rs`

#### Code picks meeting evidence; Think only rewrites it into an unsaved brief
Preparation for an upcoming meeting (`UpcomingMeetingPreparation.swift`).

Code picks the evidence: prior meetings by attendees and recurring title,
their decisions, open commitments and related projects. The local Think
model only rewrites that packet into a short brief, which is kept in
memory and never saved.

#### References carry source meeting so Today can open it instead of uncited claims
`UpcomingReference`: A decision or commitment with the meeting it came from, so Today can open
the source instead of an uncited assertion.

#### Agenda is included sanitized, only when agenda use is on
`UpcomingEvidence.agenda`: The sanitized agenda, only when agenda use is on.

#### Signature changes with evidence so new summaries invalidate old briefs
`UpcomingEvidence::signature`: Changes whenever the evidence does, so a new summary or outcome
invalidates a brief written for the old one.

#### Model-free brief shown at once and when no model writes one; restates evidence only
`UpcomingEvidence::fallback_brief`: A model-free brief shown at once and whenever no model writes one. It
only restates selected evidence.

#### Decisions, commitments, projects first; summaries share leftover room under the cap
`UpcomingEvidence::prompt_context`: Decisions, commitments and projects first; prior summaries share the
room they leave, so long summaries cannot push them past the cap.

#### Evidence uses meetings from last 180 days scored by attendees, title, recency
`compile`: Everything LokalBot knows for `event` (`UpcomingMeetingPreparationCompiler`):
prior meetings of the last 180 days, scored by shared attendees, then a
recurring title, then recency.

#### Projects whose sources were deleted or corrected do not count
`read_projects`: `DreamMemory.activeProjects`, through the evidence check: a project whose
sources were deleted or corrected since it was written doesn't count.

#### Briefs are generated only by an on-device Think model
`generate_brief`: Rewrites the evidence into two or three sentences
(`UpcomingMeetingBriefGenerator`). Only for a Think model on this computer.

### `LinuxWindows/crates/lokalbot-ai/src/upcoming_tests.rs`

#### Tests ported from the Swift UpcomingMeetingPreparationTests
Ported from `UpcomingMeetingPreparationTests.swift`.

#### Meeting delete or correction invalidates derived projects before any rewrite
`a_project_from_a_meeting_goes_when_that_meeting_changes`: Deleting or correcting the meeting advances the evidence, and work memory
built from it stops counting even before anything rewrites the file.

### `LinuxWindows/crates/lokalbot-ai/tests/e2e_runtime.rs`

#### E2E runtime test needs network and about 1 GB; run with LOKALBOT_E2E_ROOT
Real downloads and a real `llama-server`. Needs the network and ~1 GB of
disk; run on a development machine:

```sh
LOKALBOT_E2E_ROOT=~/scratch-root cargo test -p lokalbot-ai --test e2e_runtime -- --ignored --nocapture
```

#### Test starts from a library made by a version pinned to another llama.cpp build
`an_update_replaces_the_runtime_an_older_version_installed`: A library set up by a version pinned to another llama.cpp build, on this
platform's real archives.

#### Copy the macOS upgrade fixture so nothing writes into it
`fixture_library`: The macOS upgrade fixture, copied so nothing writes into it.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
