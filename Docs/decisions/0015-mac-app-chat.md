# 0015. Mac app: Chat

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Services/Chat/`, `LokalBotTests/Services/Chat/`.

## Decisions

### `LokalBot/Services/Chat/ChatAgent.swift`

#### Chat is a prompt-driven ReAct loop with tolerant JSON protocol, degrading to plain answer
In-app meeting assistant (the "Chat" section). A small agent loop on top of
the same `TextEngine` the summariser uses: the model answers questions about
the user's on-device meetings and may call tools (search / list / read) to
ground its answers. Inspired by the `lokalbot-cli` tool surface — same
`list` / `get` / `search` capabilities, exposed to the LLM as callable tools.

The local backends only speak single-shot `generate(system:prompt:context:)`
(no native function-calling), so tool use is a prompt-driven ReAct loop with
a deliberately simple JSON protocol and tolerant parsing — smaller local
GGUFs may emit sloppy output, so the protocol degrades to a plain answer
rather than fail.

#### Arguments are coerced to strings so every tool reads them uniformly
`ChatToolCall`: A parsed tool invocation. Arguments are coerced to strings on parse (numbers
and bools stringified) so every tool reads them the same way regardless of
how the model quoted them.

#### Nil scope differs from empty scope; empty means nothing may be read
`ChatToolCall.scope`: The IDs of a scope the host put on the call (`ScopedChatToolRunner`):
nil when the call carries no such scope, and an empty list when the
scope is there and holds nothing. The two must never read alike: an
empty scope means nothing may be read. `string` reports an empty value
as missing, which read a scope of no meetings as every meeting.

#### Canonical re-serialisation records exactly one well-formed tool call in transcript
`ChatToolCall.json`: Canonical JSON re-serialisation, so the running transcript records exactly
one well-formed tool call back to the model regardless of how it was typed.

#### Ambient overview in system prompt lets simple questions skip tool calls
`ChatToolRunner.libraryOverview`: Compact, always-available context (e.g. recent meeting titles) folded into
the system prompt so simple questions can be answered without a tool call.

#### Empty scope string means the question may see everything
`ChatToolRunner.questionScope`: What this question is limited to, written for the model (see
`ChatPrompt.questionScope`). Empty when it may look at everything.

#### Runner without screen store keeps all attachments as citable
`ChatToolRunner.attachedScreenEvidence`: A runner without a screen store can't check attachments; keep them all.

#### Work memory section is empty unless dreaming is on and memory has content
`ChatPrompt.workMemoryContext`: The dream-maintained work memory as ambient chat context. Empty unless
dreaming is enabled and the memory actually holds something, so the
prompt never grows a vacant section.

#### Time line goes after cached prefix; per-minute system line broke Anthropic caching
`ChatPrompt.currentTimeLine`: Lets the model resolve "yesterday" or "last Tuesday". It opens each
step's instruction, after the cached prefix: Anthropic caches whole
blocks, so a per-minute line in the system prompt made every new
message miss the cached system prompt and replayed history.

#### Scope text stops model calling limited results the whole library
`ChatPrompt.questionScope`: What a limited question can see. Without it the model took the one
meeting a question limited to today could find for the whole library
("the only one in your library"). `limit` completes "limited to", e.g.
"what happened on 4 Nov 2026".

#### Focus is a starting point, not a limit; tools reach the whole library
`ChatPrompt.questionFocus`: Where a question asked from a day or a meeting starts. It must not
read as a limit: the tools still reach the whole library.

#### Tool call only if JSON names a known tool, so quoted JSON stays prose
`ChatPrompt.parse`: Interpret one model turn. Treated as a tool call only when the output
contains a JSON object whose tool name is one of `tools`; otherwise it is
the final answer. The known-tool gate stops prose answers that merely
quote JSON from being mistaken for tool calls.

#### Accept native function-call form some local models emit instead of JSON
`ChatPrompt.parse`

2. Native function-call form some local models emit instead of JSON,
   e.g. \<|tool_call_start|>[get_meeting(id='abc', include='summary')]\<|tool_call_end|>

#### Forced final pass falls back when output is still only a tool call
`ChatPrompt.finalText`: Forced final pass: take whatever the model wrote as the answer. If it is
still only a tool call, we can no longer satisfy it, so fall back.

#### Only explicit final-answer prefix commits stream to prose; incomplete tags stay hidden
`ChatPrompt.streamingAnswer`: Only an explicit final-answer prefix commits the stream to prose. An
incomplete reasoning block, tool JSON, or wrapper stays completely hidden.

#### Hold incomplete tag or tool payload rather than paint and retract
`ChatPrompt.streamingAnswer`: Hold an incomplete tag/tool payload rather than painting it and then
retracting it. The final parser still validates the complete response.

#### Garbled tool attempts get one schema-constrained retry instead of being shown
`ChatPrompt.looksLikeToolAttempt`: True when a turn that did NOT parse into a tool call still looks like
the model was attempting one — wrapper tokens, a `{"tool": …` fragment
that never balanced, or a bare call form with a misspelled name. The
agent answers this with one schema-constrained retry instead of
surfacing the garbled attempt as the answer.

#### Wrapper tokens around prose stay an answer; around nothing count as an attempt
`ChatPrompt.looksLikeToolAttempt`: Wrapper tokens around nothing usable. (Tokens around plain prose stay
an answer — some models wrap their answer in stray tokens.)

#### Balanced JSON with a tool key that parse rejected means an unknown tool name
`ChatPrompt.looksLikeToolAttempt`: Balanced JSON carrying a tool-name key (parse() already rejected it,
so the name must be unknown — e.g. "search_meeting" for "search_meetings").

#### Root stays an object for OpenAI strict outputs; call is anyOf closed shapes
`ChatPrompt.toolCallSchema`: JSON schema forcing exactly one valid tool call, used for the
constrained retry. The root stays an object for OpenAI strict Structured
Outputs; the nested `call` is an anyOf over closed per-tool shapes.

#### Strict Structured Outputs needs optional fields required but nullable
`ChatPrompt.toolCallSchema`: Strict Structured Outputs requires optional fields to be
required-but-nullable rather than omitted.

#### Accept flat shape with arguments alongside the tool name
`ChatPrompt.argumentDictionary`: Flat shape: {"tool": "x", "query": "y"} — arguments alongside the name.

#### Parse small models' function-call form; first known tool wins
`ChatPrompt.pythonicCall`: Parse the function-call form many small models emit instead of JSON, e.g.
`get_meeting(id='abc', include='summary')` (optionally bracketed and
wrapped in tool tokens). Returns the first call whose name is a known
tool. Arguments are read as `key=value` pairs.

#### A lone positional value is stored under arg0
`ChatPrompt.parseKwargs`: `key='value', limit=5` → `["key": "value", "limit": "5"]`. A lone
positional value is stored under `arg0` (tools read named keys).

#### Injectable clock so tests and old-library replays can fix prompt time
`ChatAgent.now`: The clock behind the prompt's current-time line. Tests and replays of
an older library can fix it; interactive callers keep the wall clock.

#### Six tool calls: room to search then read a long meeting in windows
`ChatAgent.maxSteps`: Hard cap on tool calls before we force a final synthesis pass. Six
leaves room to search, then read a long meeting in a few transcript
windows; see `adaptLimits(to:)` for small-window engines.

#### Replay up to 16 recent messages, also bounded by character budget
`ChatAgent.historyWindow`: Most recent prior messages (each user or assistant message counts
once) replayed as context, bounded again by `historyCharacters`.

#### Character budget keeps long answers from crowding out tool observations
`ChatAgent.historyCharacters`: Character budget for replayed messages, so a few long answers cannot
crowd the tools' observations out of the context window.

#### Apple on-device model has about 4K window so keeps smaller loop and history
`ChatAgent.adaptLimits`: Apple's on-device model has a window of about 4K tokens, so it keeps
the earlier, smaller loop and history.

#### Replay never starts with an assistant message whose question was cut
`ChatAgent.replayedHistory`: The newest messages that fit both budgets, oldest first. A replay never
starts with an assistant message whose question was cut off.

#### Constrained retry is best-effort; backends without grammar support fall back to plain generate
`ChatAgent.respond`: Garbled tool attempt → one retry with decode-time constraints.
Backends without grammar support fall back to a plain generate,
so this stays a best-effort second chance, never a hard gate.

### `LokalBot/Services/Chat/ChatCitation.swift`

#### Only app-supplied evidence grants citations, never source text or model output
`ChatEvidence`: App-owned provenance for the exact observations supplied in one turn.
Source text and model output never grant citation authority themselves.

#### Persist markers in messages; UI replaces them with numbered references and source table
`ChatCitation`: Inline citation markers the assistant emits — `[meeting:ID]`,
`[meeting:ID@HH:MM:SS]`, `[screen:ID]`, `[file:ID]`, or `[note:ID]` (see ChatPrompt's
citation instructions).
Messages are persisted with the markers in place; the chat UI replaces each
one in situ with a stable numbered reference and renders a matching source
table that deep-links to the cited evidence.

#### Legacy meeting accessor for existing deep-link route; check kind first
`ChatCitation.meetingID`: Backwards-compatible meeting accessor used by the existing deep-link
route. Callers should check `kind == .meeting` first.

#### Meeting ids match short ids; screen ids positive row ids; stamps M:SS to HH:MM:SS
`ChatCitationParser`: Meeting IDs match SessionLookup's short ids; screen IDs are positive
SQLite row IDs. Meeting stamps accept M:SS, MM:SS, or HH:MM:SS.

#### Accept multi-meeting markers that small models write despite the prompt
`ChatCitationParser.groupedPattern`: Several meetings in one marker — `[meetings:A, B]` or
`[meeting:A; meeting:B@00:01:10]` — which small models write despite
the prompt.

#### Compile regexes once because every streamed partial is reparsed
`ChatCitationParser.markerRegex`: Compiled once: every streamed partial of an answer is parsed again.

#### Repeated sources keep their first reference number
`ChatCitationParser.extract`: Replace markers with ordered `[n]` references and return the matching,
deduped citations. Repeated sources retain their first source number.

#### Invalid markers never render as links, even for real unseen ids
`ChatCitationParser.verified`: Apply before publishing partials or persisting final output. An invalid
marker is never rendered as a source link, even for a real but unseen ID.

#### Nil for out-of-range fields or leading field too large for seconds
`ChatCitationParser.seconds`: "1:23" → 83, "00:14:32" → 872. Nil for out-of-range fields, and for a
leading field too large to count in seconds.

#### Leading field is unbounded and model-supplied, so scaling must not trap
`ChatCitationParser.seconds`: The leading field has no upper bound and can come from a model's
tool call (`get_meeting`'s `from`), so scaling it must not trap.

#### Preserve line-leading indentation because the markdown renderer needs it
`ChatCitationParser.cleaned`: Tidy the gaps removed markers leave behind: the space before trailing
punctuation and doubled interior spaces. Line-leading indentation is
preserved — it's meaningful to the markdown renderer.

### `LokalBot/Services/Chat/ChatViewModel.swift`

#### Activity chips persist; isPending is transient and never written
`ChatMessage`: One line in the chat transcript. `activity` holds the tool steps the
assistant ran for this turn (shown as chips above its answer). Codable so
conversations persist; `isPending` is transient and never written.

#### Legacy messages use conversation date and are marked estimated
`ChatMessage.createdAt`: When this turn entered the conversation. Legacy messages retain the
conversation date for ordering but are marked estimated in the UI.

#### Date filter kept separate so it never silently grants a source
`ChatMessage.dayScopeKey`: Optional civil-day or date-range constraint applied to this turn. Kept separate
from source scopes so a date filter never silently grants a source.

#### OCR stays ephemeral; day keys preserve provenance of attached screens
`ChatMessage.attachedScreenDayKeys`: Civil days represented by screen moments explicitly attached to the
prompt. OCR itself remains ephemeral; these keys preserve provenance.

#### Version-1 turns lack provenance so cannot be retried under narrower scope
`ChatMessage.legacyScopeIsAmbiguous`: Version-1 turns did not persist enough source/day/attachment provenance
to replay or retry them safely under a narrower modern scope.

#### Pending flag is transient and never persisted
`ChatMessage.isPending`: The assistant turn is still being generated. Transient — never persisted.

#### Remember turns save without a model call and stay out of model history
`ChatMessage.rememberReceipt`: Set on the assistant turn that answers a "Remember …" message: the
statement was saved (or refused) without calling a model. These pairs
stay out of model history; the personal-context block carries them.

#### Records personal claims given to the model; nil on older turns
`ChatMessage.usedClaimIDs`: Personal claims supplied to the model for this answer, so the answer
can show what it was given. Nil on older turns and when none were used.

#### Drop old absolute-date scope since its time zone was never saved
`ChatMessage.init(from:)`: Older builds persisted an absolute Date. Its originating time
zone was never saved, so converting it to a civil day after the
user travels can move the retrieval boundary. Drop the unknown
day and prevent a retry from silently widening the old request.

#### Version-1 turns lacked pinned-screen provenance so all are ambiguous for retry
`Conversation migration`: Version 1 also omitted pinned-screen provenance. Even a
Meetings-only label could have hidden OCR in its prompt, so
every old turn is unsafe to retry or reuse in a narrower
source/day request.

#### Version 1 overloaded Today as source and one-day grant; migrate conservatively
`Conversation migration`: Version 1 overloaded Today as a source and, when selected
alone, as a one-day grant to every source. Mixed selections
had asymmetric rules, handled conservatively below.

#### Restore source types without fabricating a civil day for legacy Today scope
`Conversation migration`: Old messages did not record a per-turn date, while mixed
version-1 scopes also date-limited sources asymmetrically.
Even an exact timestamp cannot recover the originating
time zone, so restore source types without fabricating a
civil day or retrying under semantics the turn never had.
Its existing answer remains safe history for full scope.

#### One JSON file per conversation, whole set in memory, atomic single-file saves
`ChatStore`: Persists chat conversations as one JSON file per conversation under
`<root>/chats/`, mirroring the file-per-document layout used for meetings
and journals. Personal scale: the whole set loads into memory and each
save rewrites a single small file atomically.

#### Encrypted copies win when an interrupted migration left both files
`ChatStore.decode`: Encrypted copies win if an earlier migration left both files.

#### Legacy writes stay on store owner; deletion during hydration wins
`ChatStore.finalize`: Legacy writes remain on the store owner so they cannot race save/delete.
Verify the plaintext still exists: deletion during hydration wins.

#### AES-GCM with Keychain key; return success so migration never drops plaintext early
`ChatStore.save`: Encode → AES-GCM seal (per-install Keychain key) → atomic write. Returns
whether the sealed file landed, so the migration above never discards
plaintext before its encrypted replacement exists.

#### Remove legacy copy first so failure keeps encrypted copy for retry
`ChatStore.delete`: Remove the legacy copy first. A failure keeps the encrypted copy
available and the caller retains the conversation for retry.

#### Engine resolved lazily per send, reflecting current Models setting and booting built-in server
`ChatViewModel`: Drives the Chat section: owns the message list and runs `ChatAgent` against
the same `TextEngine` the summariser uses (resolved lazily per send via
`ThinkExecution.makeTextEngine`, so it always reflects the current
Settings → Models choice and boots the built-in server on first use).

#### Fires on explicit navigation even when selecting current or empty question
`ChatViewModel.navigationRevision`: Explicit navigation also fires when selecting the current or empty question.

#### Re-read per send so overnight dream reaches next question without restart
`ChatViewModel.workMemory`: Re-read per send so an overnight dream lands in the next question
without restarting the app. Empty when dreaming is off or has nothing.

#### Nil in contexts without personal context, such as tests and previews
`ChatViewModel.personalModel`: What the person told LokalBot about themselves. Nil in contexts that
don't offer it (tests, previews).

#### Debug accessor exposes ids only, never hidden prompt contents
`ChatViewModel.retainedRetryPayloadIDs`: Exposes identifiers, never hidden prompt contents, for lifecycle tests.

#### displayText keeps model-only OCR context out of visible transcript
`ChatViewModel.send`: Send the current draft (or an explicit `prompt`, e.g. a suggestion chip).
`displayText` keeps model-only context such as attached OCR excerpts out
of the visible transcript while still sending it in the current turn.

#### Remember saves locally without model; attached screen keeps it a question
`ChatViewModel.sendResolved`: "Remember …" is saved locally without a model call. The visible
text is what the person typed (a date scope may prefix the hidden
prompt); with an attached screen it stays a question about it.

#### New question supersedes failed turn; discard its hidden OCR-bearing prompt
`ChatViewModel.sendResolved`: A new question supersedes any failed turn in this conversation.
Discard its transient hidden prompt (which may contain attached OCR)
before retaining the new turn's retry payload.

#### Only complete question/answer pairs go into model history
`ChatViewModel.sendResolved`: Only complete question/answer pairs belong in model history. A
failed or stopped answer must not leave its unanswered question as
implicit context for the next request.

#### Persist immediately since termination or switch may precede provider unwinding
`ChatViewModel.stop`: Persist immediately: app termination or a conversation switch may
happen before a provider or tool cooperatively unwinds.

#### In-session retry keeps hidden context; persisted error falls back to visible question
`ChatViewModel.retry`: Retry an errored assistant turn without duplicating the visible user
message. In-session retries preserve hidden screen/day context; a
persisted error safely falls back to the preceding visible question when
the original turn had no ephemeral screen attachment.

#### Questions with attached screens cannot be asked again; text never stored
`ChatViewModel.canAskAgain`: Whether a finished answer's question can be asked again as it was. A
question that carried an attached screen cannot: that text was never
stored, so asking again would not be the same question.

#### Drop in-flight or empty assistant placeholders so half turns never reach disk
`ChatViewModel.persist`: Fold the live transcript back into its conversation and persist it.
In-flight / empty assistant placeholders are dropped so a half-finished
turn never lands on disk.

#### Derive title locally; avoid inference request for cosmetic label
`ChatViewModel.compactTitle`: A short, stable history label derived locally from the first question.
This deliberately avoids another inference request for a cosmetic title.

#### Cancelled task must not reorder or rewrite newly selected conversation
`ChatViewModel.run`: Conversation switches persist the interrupted terminal turn
before replacing `messages`; do not reorder or rewrite the newly
selected conversation when the cancelled task finally unwinds.

#### Dream memory only for unrestricted questions; it would bypass source/day boundary
`ChatViewModel.run`: Dream memory is distilled from meetings, activity, and screen
context. Including it in a restricted question would bypass the
per-turn source/day boundary even though no tool could do so.

#### Personal statements apply to scoped questions; learned claims follow work-memory boundary
`ChatViewModel.run`: The person's own statements carry no source evidence, so unlike
work memory they apply to scoped questions too. Learned claims,
from meetings or from what the person typed and dictated,
follow the work-memory boundary.

#### Interrupted-turn finalisation is idempotent since stop and cancelled task both reach it
`ChatViewModel.finalizeInterruptedTurn`: Convert an in-flight assistant placeholder into a durable, retryable
terminal turn. This is deliberately idempotent because `stop()` updates
immediately and the cancelled task reaches the same path later.

### `LokalBot/Services/Chat/MeetingChatTools.swift`

#### Tool output kept compact because it feeds a small local model
`MeetingChatFormat`: Renders tool output for the chat model. Pure value-in / string-out so the
formatting is unit-testable without the file system, indexes, or an engine.
Kept compact on purpose — observations are fed back into a small local model.

#### nextStart signals more transcript so long meetings never look complete
`MeetingChatFormat.transcriptObservation`: One window of a structured transcript, starting at `start` seconds.
`nextStart` is where the following window begins when the rest did not
fit, so a long meeting is never presented to the model as complete.

#### Next window starts with whole line; only overlong lines are cut
`MeetingChatFormat.transcriptObservation`: The next window starts with this whole line. Only a line longer
than a window is cut, and reading then moves past it.

#### Heading says notes are an agent's own record, not verified fact
`MeetingChatFormat.agentNoteResults`: One block per note: its citation marker, title, agent and project,
then its text. Notes are an agent's own record, so the heading says so.

#### Expand FTS snippet to whole line so nearby negations are not cut
`MeetingChatFormat.keywordPassage`: The whole transcript utterance or summary line around a keyword match.
An FTS snippet keeps about 14 tokens and can cut a nearby "not" out of
the observation. A line longer than the cap keeps the snippet.

#### search_files is offered only when Files is on with folders
`MeetingChatTools.filesProvider`: The Files search, while Files is on and has folders; nil otherwise, and
then `search_files` is not offered at all.

#### search_agent_notes is offered only when reading agent notes is on
`MeetingChatTools.agentNotesProvider`: The saved coding-agent notes, while Read coding agent notes is on;
nil otherwise, and then `search_agent_notes` is not offered at all.

#### Retry natural-language query with OR content keywords when AND search misses
`MeetingChatTools.search`: A natural-language question ANDs every stop word against the index and
misses; retry on content keywords with OR semantics (ranked by FTS)
before reporting nothing.

#### Transcribe only first two audio/video moments on demand to keep answers quick
`MeetingChatTools.searchFiles`: Recordings and video are transcribed on demand: only the first two
moments, to keep an answer quick.

#### Same OR keyword rescue as meeting search for natural-language questions
`MeetingChatTools.searchScreen`: Same rescue as meeting search: a natural-language question ANDs
stop words and misses; retry on OR'd content keywords.

#### With semantic search, text and picture vectors rank with keyword hits, as in Ask
`MeetingChatTools.searchScreen`: With search by meaning, the screen's text and picture vectors rank
with the keyword hits, as in Ask (`ScreenSearch`).

#### Attached screen is citable only if it exists and fits question dates
`MeetingChatTools.attachedScreenEvidence`: An attached screen stays citable only while it still exists and falls
inside the question's dates.

#### Paired phone history floor: no activity before its start date
`MeetingChatTools.activitySummary`: An asker whose history starts at a date (a paired phone) reads no
activity from before it, whichever day the model asks for.

#### SessionLookup pinned to in-memory list, avoiding hard-coded library path
`MeetingChatTools.resolve`: Resolve by short id / full uuid / 'latest' (via `SessionLookup`, pinned to
the in-memory list we pass it so it never touches the hard-coded library
path), then fall back to a title substring match.

### `LokalBotTests/Services/Chat/ChatAgentTests.swift`

#### Unregistered tool names are never executed, even if shaped like a call
`testParseUnknownToolNameIsTreatedAsAnswer`: Shaped like a tool call, but the name isn't registered — never execute it.

#### Some Qwen-compatible local models emit native function-call tokens instead of JSON
`testParseNativeFunctionCallWithTokens`: Some Qwen-compatible local models emit this form instead of JSON.

#### Models wrap answers in stray tool tokens; tokens around prose stay an answer
`testLooksLikeToolAttemptDetection`: Tokens around prose stay an answer (models wrap answers in stray tokens).

#### Tool schema is sent verbatim as response_format, so it must serialise
`testToolCallSchemaEnumeratesToolsAndRequiredArgs`: Must serialise — it's sent verbatim as the response_format schema.

#### Work memory is background context, not ground truth the model may cite
`testSystemPromptIncludesWorkMemoryOnlyWhenProvided`: Memory is background context, not ground truth the model may cite as fact.

#### After max in-loop tool calls a forced pass that still loops yields the fallback answer
`testAgentForcesAnswerAfterMaxSteps`: 2 in-loop tool calls, then a forced pass that still loops → fallback.

#### No clock in the system prompt, or Anthropic prompt cache rewrites every minute
`testSystemPromptAndHistoryStayIdenticalAcrossMessagesMinutesApart`: Anthropic caches whole blocks up to each breakpoint. A clock in the
system prompt changed it every minute, so each new message rewrote the
cached system prompt and replayed history at the cache-write price.

#### StorageManager is rooted at the temp dir via the environment hook
`testKeywordSearchKeepsANegationOutsideTheSnippetWindow`: rooted at our temp dir via the env hook

#### Semantic search is disabled in tests to stay offline without an embed server
`MeetingChatTools test setup`: keep the test offline (no embed server)

#### Date filtering must happen in SQL before LIMIT or valid hits disappear
`testSearchScreenAndActivitySummaryAgainstPlantedStore`: More than the tool's result limit on another day: date filtering must
happen in SQL before LIMIT or the valid selected-day hit disappears.

#### Natural-language questions are rescued by a relaxed OR fallback
`search_screen`: Natural-language question rescued by the relaxed OR fallback.

#### Default FTS query quotes and ANDs every term, prefix-matching the last
`SearchIndex.ftsQuery`: Default: quote + AND every term, prefix-match the last (search-as-you-type).

#### Relaxed FTS query drops stop words and ORs content terms for recall
`SearchIndex.ftsQuery`: Relaxed: drop stop words, OR the content terms for recall.

#### If every term is a stop word, keep them rather than emit an empty query
`SearchIndex.ftsQuery`: All terms are stop words → keep them rather than emit an empty query.

#### Semantic search is disabled in tests because no embed server runs
`testSearchRescuesNaturalLanguageQuery`: no embed server in tests

#### Strict FTS ANDs every stop word and finds nothing on a raw question
`testSearchRescuesNaturalLanguageQuery`: Strict FTS ANDs every stop word and finds nothing on the raw question…

#### The chat tool's keyword fallback rescues the content terms
`testSearchRescuesNaturalLanguageQuery`: …but the chat tool's keyword fallback rescues the content terms.

### `LokalBotTests/Services/Chat/ChatCitationTests.swift`

#### Oversized leading timestamp field is refused; it once overflowed and crashed the app
`ChatCitationParser.seconds`: A leading field too large to count in seconds is refused. It used
to overflow and stop the app: a model's `get_meeting` call sets it.

#### Citations follow LokalBot's text size, shared with the test host
`testEditorialMarkdownBuildsOneContinuousVisibleString`: Citations follow LokalBot's text size, which the test host shares
with the app (Default is one point above the system size).

### `LokalBotTests/Services/Chat/ChatContinuationEngineTests.swift`

#### Loopback server mimics OpenRouter when a reply reaches max_tokens
`ChatContinuationEngineTests`: Autocomplete through a chat endpoint, against a loopback server that answers
the way OpenRouter does when a reply reaches `max_tokens`.

#### glm-5.3-flash always reasons; 32-token reply ended inside reasoning (2026-10-15)
`testAModelThatAlwaysReasonsIsAskedWithRoomForItFromThenOn`: `z-ai/glm-5.3-flash` always reasons: on 2026-10-15 its 32-token reply
ended inside the reasoning, and autocomplete showed only an error.

### `LokalBotTests/Services/Chat/ScopedToolScopeTests.swift`

#### An empty scope once read as no scope, so tools answered from the whole library
`ScopedToolScopeTests`: What a scope on a question keeps the real library tools from reading. A
scope that holds nothing (a phone that shares no finished meeting yet) once
read as no scope at all, and every tool answered from the whole library.

#### Fixture words appear only in meetings so the query word can't be echoed back
`ScopedToolScopeTests.contents`: Words only the meetings hold; the query word alone can be echoed back.

#### Fixtures start at noon so today holds everything whenever the test runs
`ScopedToolScopeTests.setUpWithError`: Noon, so "today" holds everything whenever the test runs.

#### Timeline is its own source: empty meeting scope hides meetings, not apps
`testAnEmptyMeetingScopeReadsNoMeeting`: The Timeline is its own source: an empty meeting scope hides the
day's meetings, not the day's apps.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
