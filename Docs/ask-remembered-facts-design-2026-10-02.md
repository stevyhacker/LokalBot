# Ask remembers what you tell it

Date: 2026-10-02. Status: folded into
[Personal World Model v1](personal-world-model-rfc-2026-10-14.md), whose Phase
1 implements the stated-facts part as Settings → Day Memory → About you. Code
references are to master at `a635a99` (0.9.4).

## Problem

Each Ask conversation starts from zero. The only carry-over is the Dream work
memory (projects, goals, patterns). It is added to the system prompt only when
overnight review is on and the question has no source, day, meeting, or screen
restriction (`ChatViewModel.run`, `ChatPrompt.workMemoryContext`). Nothing the
person says in Ask survives the conversation. People repeat the same context:

- who people are ("Maya is my manager", "Dana runs the platform team");
- names and aliases ("Atlas is the new name for the billing project");
- preferences ("answer in bullets", "amounts in EUR");
- corrections ("the Q3 launch moved to November").

No path saves any of this today. Ask has no tool that writes state, no
per-user instructions, and no "remember" handling.

## Goals

- Facts the person asks LokalBot to remember persist across Ask conversations
  and Quick Recall (both use `app.chat`).
- **Explicit capture only.** A fact is saved when the person says "Remember …",
  adds it in Settings, or clicks Remember on an answer and confirms the text.
  No background extraction, and no model call per turn.
- **Sources are kept.** A fact saved from an answer records the meetings and
  screen days behind it. Deleting or correcting any of them retracts the fact,
  the same contract as Dream memory (PRIVACY.md, "Dream reports and durable
  work memory record their source dependencies").
- **Visible use.** Each answer shows which remembered facts it used, and every
  fact can be edited or forgotten.
- Encrypted at rest, local only, and works with every Think backend.

## Non-goals (v1)

- Inferring facts the person did not ask to save.
- Merging or rewriting facts with a model (Mem0's ADD/UPDATE/DELETE step).
- Agent Mode, meeting notes, transcription vocabulary, or MCP/CLI access (see
  Phase 3).
- Embedding-based retrieval. Fact counts are small enough for deterministic
  selection.

## Why not Mem0

| | Mem0 | This design |
| --- | --- | --- |
| Capture | Model extraction on every `add` | Explicit only; no added background calls |
| Updates | Model decides ADD/UPDATE/DELETE | Exact-duplicate merge, the person edits, newest wins in the prompt |
| Storage | Vector store (Qdrant, Chroma, …) plus a Python or TS runtime | One encrypted JSON file, at most 100 facts |
| Provenance | Which user or agent said it | Meetings and screen days behind it, retracted with them |
| Transparency | — | Each answer lists the facts it used |

## Fact model

```swift
struct RememberedFact: Codable, Identifiable, Equatable, Sendable {
    enum Origin: Codable, Equatable, Sendable {
        case said(conversationID: UUID, messageID: UUID)   // "Remember …" in Ask
        case added                                          // Settings → Add
        case answer(conversationID: UUID, messageID: UUID)  // Remember on an answer
    }

    let id: UUID
    var text: String          // at most 280 characters, sanitized
    var alwaysUse: Bool       // included first in every eligible prompt
    let createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    let origin: Origin
    /// Only for `.answer` facts that had sources. Nil means "no evidence
    /// dependency", never "legacy". Do not reuse DreamStore's nil-is-invalid rule.
    var evidence: DreamEvidenceProvenance?
}
```

Limits are `maxFacts = 100`, `maxCharacters = 280`, and a prompt budget of
2,000 characters. When the store is full, saving fails with a message. Facts
the person saved are never evicted silently.

Text passes through `PromptContextSanitizer.sanitize` and
`ScreenContextPrivacy.redact`. If redaction would change the text, the save is
refused: "This looks like a password or key. LokalBot doesn't remember those."

Duplicates: text equal after case folding, whitespace collapsing, and trimming
a trailing period updates the existing fact's `updatedAt` instead of adding a
new one.

## 1. Capturing facts

### Say it in Ask (Phase 1)

`RememberIntent.parse(_ message: String) -> String?` is a pure function that
returns the fact text or nil.

- Matches a message that starts with `remember`, `remember that`, `remember:`,
  or `please remember (that)`, case-insensitive, and does not end with `?`.
- Never matches questions:
  - `do you remember …` and `can you remember …`;
  - `remember when|what|who|where|how|why|if|whether …`;
  - anything ending in `?`.
- The fact is the text after the trigger, trimmed, with its first letter
  capitalized.

On a match, Ask doesn't send the message to the model. The transcript shows the
person's turn followed by a confirmation card ("Remembered: Maya is my manager",
with Edit, Undo, and Manage). No backend is needed, so this works offline and
before any model is ready. The trigger is English only in v1. The other two
capture paths work in any language.

The message stays in the transcript, but is left out of the model history
because the facts block already carries it. When Ask memory is off, the
message is sent as an ordinary question.

### Remember an answer (Phase 2)

Add a **Remember** button to `answerActions` in `ChatView.swift`, beside Copy and
Read aloud. It appears only on finished, non-error answers that recorded their
evidence (see below), so older answers don't offer it.

1. Clicking it opens a small sheet with a proposed fact. The proposal comes from
   one call at `.interactive` priority through the existing
   `ThinkExecution.makeTextEngine`.
   - New `ModelRequestPurpose.rememberFact`, with its own system marker.
   - Input: the question and the answer text, with citations stripped.
   - At most 120 output tokens, `reasoningBudgetTokens: 0`.
   - Instruction: rewrite the key fact as one standalone sentence under 200
     characters, in the answer's language, keeping names exact.
   - It sends only text that Ask already sent to the same backend.
   - If the call fails, the sheet is prefilled with the answer's first sentence.
2. The person edits the text and clicks Save, or cancels.
3. The saved fact gets `origin: .answer(...)` and `evidence` built from the
   answer's recorded sources (section 4).

To make this possible, `ChatMessage` (assistant turns) gains three optional,
persisted fields. Older messages decode without them.

- `observedEvidence`: the `ChatEvidence` merged during the turn. Every meeting
  ID and screen snapshot ID any tool returned, not only the cited ones.
- `contextSources: [DreamEvidenceSource]`: the union of the provenance sources
  of Dream memory and of `.answer` facts injected into that turn.
- `evidenceRevision`: the store's evidence revision when the answer was
  generated.

### Add in Settings (Phase 1)

There's an Add… field in the Ask memory section (section 5). These facts get
`origin: .added`.

## 2. Using facts in Ask

**Eligibility per turn**, in `ChatViewModel.run` next to the existing
work-memory gate:

- `.said` and `.added` facts are the person's own statements and are eligible
  for every question, including scoped ones.
- `.answer` facts are distilled from evidence, so they follow the work-memory
  rule: unscoped questions only. This is the same reason as the existing
  comment, where including them would bypass the per-turn source and day
  boundary.

**Selection**, in a pure `RememberedFactSelection.select(facts:question:recentTurns:budget:)`:

1. `alwaysUse` facts, newest first.
2. Facts sharing a content word with the question or the previous two user
   turns. Words are case-folded, stopwords dropped, at least three letters,
   with names matched case-insensitively. Ordered by match count, then
   `updatedAt`.
3. Everything else by `updatedAt`.
4. Stop at the 2,000-character budget.

**Prompt block**, placed before the work-memory block in `ChatPrompt.systemPrompt`:

```
Facts the user asked you to remember (newest first; a newer fact overrides an older one that conflicts):
- [2026-10-02] Maya Chen is my manager.
- [2026-09-30] Atlas is the new name for the billing project.
Use these when relevant. They are the user's statements, not evidence: never cite them as a
meeting or screen source. If retrieved evidence contradicts one, say so.
```

The assistant message records `usedFactIDs`, and the store stamps `lastUsedAt`.
`turnMetadata` shows a "Used 2 remembered facts" disclosure that lists them and
links to Manage. Headless `--chat` builds the same block.

## 3. Storage and encryption

- **File:** `memory/remembered.json.enc`, sealed with AES-GCM under the existing
  `chat-key`. Facts carry the same sensitivity as conversations.
  - Reusing the key means no new Keychain account, no change to
    `DataMigration.keychainAccounts`, and no change to the upgrade-test
    `SecretStore` stub.
  - Writes are atomic, mode 0600, the same as `ChatStore.save`.
- **Plaintext migration:** a plaintext `memory/remembered.json` is accepted and
  re-encrypted on first load, following `ChatStore`'s legacy migration. The
  demo seed and the upgrade fixtures can then include facts without the key.
- **Locking:** all reads and writes run under `DreamStore`'s cross-process
  lock (`flock` on `.dream-store.lock`). The headless runner and the app share
  a library, and retraction (section 4) must update facts in the same critical
  section as Dream memory.
  - `DreamStore` owns a `RememberedFactStore` and exposes `facts()`,
    `saveFact`, `updateFact`, `forgetFacts(ids:)` and `forgetAll()`.
- **Not exposed** through MCP, the CLI, Agent Mode, daily memory export, or
  diagnostics. `DiagnosticsExporter` never reads `memory/`, so this holds by
  construction.

## 4. Lifetime, deletion, and retraction

**Facts the person stated** (`.said`, `.added`) are the person's own data. Like
saved conversations and edited journals, they have an independent lifetime and
stay until forgotten.

**Deleting a conversation** that facts came from changes the "Delete Question?"
alert (`ChatView.swift`, history context menu):

- It says "N remembered facts came from this question."
- It offers **Delete**, **Delete and Forget Facts**, and **Cancel**, with Cancel
  as the default.
- Facts kept after deletion show "From a deleted question".

**Answer-derived facts** (`.answer`) are retracted with their evidence.

- **Provenance at save time:**
  - `sources` are the meeting IDs from `observedEvidence`, plus the
    `.screenDay` key of each screen snapshot (looked up through the activity
    store), plus `contextSources`.
  - `revision` is the answer's `evidenceRevision`.
- **Empty sources:** if the turn used no tools and no memory, `evidence` is nil
  and the fact has no dependency.
- **Sources already changed:** if the provenance is already invalid when
  saving, because a source changed after the answer was generated, the save is
  refused: "The sources behind this answer changed. Ask again to remember the
  current answer."
- **Retraction pass:** `DreamStore.invalidateEvidence` adds a step that removes
  every `.answer` fact for which `isInvalidated(by:currentRevision:meetingRevisions:activityRevisions:)`
  is true. It runs before the pending-revocation intent is cleared, so a crash
  mid-pass is recovered by the existing intent recovery in `evidenceRevision()`.
- **Fail closed:**
  - Reads re-apply the filter.
  - While `evidenceIsAvailable` is false (a revocation intent is pending),
    `.answer` facts are withheld from prompts and the list.
  - `.said` and `.added` facts are still served, because they have no evidence
    dependency.
- **Editing** an answer-derived fact keeps its provenance. The text is still
  derived, so it still retracts with its sources.

Every existing deletion path already goes through `withPrimaryEvidenceChange`
or `withMeetingEvidenceMutation`, so they need no new call sites:

- meeting delete and merge;
- transcript and summary edits;
- outcome edits;
- screen range deletion;
- retention;
- screen moments;
- coding-agent records.

## 5. Settings and UI

The **Day Memory** tab gets a new "Ask memory" section after "Overnight review",
with `settingTarget("settings.askMemory")`:

- **Toggle:** "Remember what I tell Ask" (`AppSettings.askMemoryEnabled`, default
  on; nothing is saved until the person asks).
  - Off stops capture and prompt use, hides the Remember button, and sends
    "Remember …" messages as questions.
  - Existing facts stay until forgotten, matching "disabling a feature doesn't
    delete existing copies".
- **List:** each row shows the fact text and its origin, for example
  "You said this · Oct 2", "From an answer citing Q3 roadmap planning · Oct 2",
  or "Added in Settings".
  - Rows have an "Always use" toggle, plus Edit and Forget in a context menu
    and a trailing button.
  - Answer-derived rows show a small source indicator.
- **Buttons:** Add… and Forget All…, with confirmation.
- **Search keywords:** remember, memory, facts, preferences.

Ask's confirmation card and the "Used N remembered facts" disclosure link here
through `app.focusedSettingID`.

**Copy updates:**

- The remote-origin approval disclosure in Settings adds "remembered facts" to
  the list of what Ask may send.
- PRIVACY.md (section 6).
- DEVELOPMENT.md's Ask section and on-disk layout.

## 6. Privacy contract changes

Add to PRIVACY.md:

- **What's kept:** Ask keeps facts the person asks it to remember.
  - They're stored encrypted in `memory/remembered.json.enc` under the chat key.
  - They go to the selected Think backend with Ask questions, which may be an
    approved remote server.
  - They're never sent through MCP, the CLI, or Agent Mode, and are excluded
    from exports and diagnostics.
- **Stated facts** have an independent lifetime. Deleting the conversation they
  came from offers to forget them too.
- **Facts saved from an answer** record the meetings and screen days behind
  that answer, and retract when any of them is deleted or corrected. A pending
  revocation withholds them until cleanup succeeds.
- **Fix the existing gap:** state that Dream work memory is added to unscoped
  Ask questions, and so reaches an approved remote Think server.

## 7. Phasing

1. **Phase 1, stated facts:**
   - store, encryption, lock, and plaintext migration;
   - `RememberIntent`;
   - Settings section with Add, Edit, Forget, and Always use;
   - prompt block and selection;
   - used-facts disclosure, headless `--chat`, docs, and tests.
   - No new model calls and no provenance.
2. **Phase 2, facts from answers:**
   - persisted per-answer evidence;
   - the `.rememberFact` call and sheet;
   - provenance and the retraction step;
   - the conversation-deletion alert;
   - retraction tests.
3. **Phase 3 candidates** (each a separate decision):
   - Agent Mode context. It gets no Dream memory today either.
   - A per-fact "Use for transcription and notes" flag, for names and aliases.
     It would need a notes disclosure, and must avoid the vocabulary-copy gap
     below.
   - Suggested facts after an answer, saved only on click.
   - Embedding-based selection, if people approach the 100-fact cap.
   - A read-only MCP tool behind the meeting-library toggle.

## Testing

**Unit:**

- `RememberIntentTests`, a table of inputs.
  - Should match: "Remember that …", "remember: …", "Please remember …".
  - Should not match: "Do you remember …?", "Remember when we …?", "remember
    what Maya said?", and any message ending in "?".
- `RememberedFactStoreTests`:
  - encrypted round trip with a test key;
  - plaintext migration;
  - the 100-fact refusal and duplicate merge;
  - edit, forget, and forget all;
  - secret refusal;
  - two store instances writing under the lock.
- `RememberedFactSelectionTests`: Always-use first, lexical matches, recency,
  budget cutoff, and deterministic order.
- `ChatAgentTests` / `ChatViewModelStateTests`:
  - the block renders sanitized, and is absent when disabled or empty;
  - a scoped question keeps stated facts and omits answer facts (a sibling of
    `testRestrictedQuestionOmitsAmbientWorkMemory`);
  - "Remember …" makes no engine call.
- Phase 2, `RememberedFactRetractionTests`, modeled on
  `DreamMemoryRetractionTests`:
  - deleting a cited meeting removes the fact from disk and from reads;
  - screen retention of a cited day removes it;
  - an uncited but tool-returned meeting also retracts it;
  - a pending intent withholds answer facts but not stated ones;
  - refusal when sources already changed;
  - edits keep provenance;
  - inherited Dream-memory provenance retracts too.

**Model scenarios** (`ModelServerScenarioTests`, Bun stub):

- The Ask request's system prompt contains the facts block with the expected
  facts.
- Phase 2: add `ModelRequestPurpose.rememberFact` and its marker, regenerate
  `purpose-markers.json`, and extend `ModelBudgetGuardTests`.
- Phase 2: a stubbed reply fills the sheet, and a malformed or failed reply
  falls back to the first sentence.

**UI** (hosted CI only, `ChatHistoryUITests`):

- "Remember …" shows the confirmation card, and Undo removes it.
- The fact appears in Settings → Day Memory → Ask memory.

**Upgrade:**

- A missing file loads as empty.
- `Scripts/seed_demo_library.py` writes a plaintext `memory/remembered.json`,
  so the first Upgrade fixtures run after release covers facts.
- `UpgradeMigrationTests` asserts that facts load for fixtures that contain
  them.

## Open questions

1. **Conversation deletion:** keep facts by default, with the alert offering to
   forget them (proposed). The alternative is always forgetting them with the
   conversation.
2. **Default:** on (proposed) or off for "Remember what I tell Ask".
3. **Language:** is an English-only composer trigger acceptable in v1? Other
   languages use the Remember button and Settings → Add.

## Related findings (outside this design)

Found while researching this design:

- **Vocabulary copies outlive retraction.**
  - Pinned Dream project names are copied into each meeting's
    `transcription-vocabulary.json` (`ProcessingPipeline.transcriptionPrompt`).
  - That copy is reused when the meeting is reprocessed.
  - It isn't removed when the Dream entry is retracted, which conflicts with
    PRIVACY.md's "retracts dependent facts, including pinned entries".
- **Headless `--chat` differs from the app.** It runs at `.background` priority
  with purpose "summary", and injects work memory without the Ask UI's scope
  check.
- **PRIVACY.md omission:** it doesn't say that Dream work memory goes into
  unscoped Ask prompts.
- **DEVELOPMENT.md is out of date.**
  - Its Ask section lists 3 chat tools; there are 6.
  - Its on-disk layout omits `memory/`, `dreams/`, and `chats/`.
- **Dead code:** `BriefContextView` isn't referenced anywhere.
