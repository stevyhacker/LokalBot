# Personal World Model v1

Date: 2026-10-14. Status: accepted direction; Phases 1–3 in progress in
draft PR 251. Code references are to master at `04f12f6`.

## Summary

LokalBot keeps a small, user-owned model of the person: facts about them,
how they want AI to help, their goals, and the principles they decide by.
It uses that model to shape Ask answers and, behind its own grant, gives
task-scoped slices of it to external agents over MCP. Every item says where
it came from, whether the person stated it or confirmed an inference, and
when it was last true.

This RFC grows out of an outside product discussion (14 October). It builds
on [Ask remembers what you tell it](ask-remembered-facts-design-2026-10-02.md),
which was never implemented and covers most of Phase 1. It reuses Dream
provenance and retraction. It also keeps the native memory backend chosen in
the 13 October memory-systems evaluation, which found deletion residue in
external engines and no quality gain.

## What already exists

| Need | Existing piece | Use |
| --- | --- | --- |
| Experience evidence | Meetings, outcomes with `decisionRecords`, screen text, day digests | Sources for proposals and citations |
| Short-lived work memory | `DreamMemory`: 12 projects, 10 goals, 12 patterns; 30/45-day retention (`DreamModels.swift:273`) | Stays as is. Not a personal profile. |
| Provenance and retraction | `DreamEvidenceProvenance`, `DreamStore.invalidateEvidence` (`DreamStore.swift:197`), pending-intent recovery, `flock` lock | Reused unchanged for evidence-backed claims |
| People and projects | `PeopleDirectory`, `ProjectLinks`, `WorkMemoryConnections`; MCP `list_people` / `get_person` | Claims reference them by id. No second people store. |
| Nightly synthesis | `DreamService.dream` (one model call per day over compiled evidence) | Carries claim proposals; no new background pass |
| The person's own speech | `MeetingOutcomes.isMicrophoneSpeaker` (`MeetingOutcomes.swift:228`) | Proposals may quote only the person's own lines |
| Ambient Ask context | `ChatPrompt.workMemoryContext` (`ChatAgent.swift:114`) and the unscoped-question gate in `ChatViewModel.run` | Personal context goes in beside it, with the same scope rule |
| Agent access | `AgentAccessGate` marker files under `control/`, separate meeting and screen grants | A third, independent grant |
| Encryption | `chat-key` in the Keychain (`DataMigration.swift:41`) | Encrypts the store. The CLI cannot read it (see MCP). |

Corrections to the discussion:

- The "world and live context" layer (people, projects, obligations) is
  largely shipped. The new work is the layers about the person.
- External memory engines are already evaluated. Tencent left derived recall
  after raw deletion. Hindsight needed a maintenance contract to clean up
  deletions. Neither showed a quality gain. No Python service.
- The MCP server runs as the separately signed `lokalbot-cli` and never reads
  the Keychain. It cannot open an encrypted store, so agents get a projection
  the app writes.

## Goals

- One store of **personal claims** that Ask, Quick Recall and (opt-in) MCP
  clients read.
- **The person stays the authority.** Principles are never inferred. Learned
  facts and goals are saved automatically (decision 6), but each shows the line
  it came from, is labelled as learned wherever it is used, and can be kept,
  edited or forgotten.
- **Visible use.** Each answer lists the claims that shaped it. Each claim can
  be edited, retracted or forgotten.
- **Source deletion wins.** Evidence-backed claims retract with their sources,
  with the same contract as Dream memory.
- **Minimum disclosure.** No consumer, including Ask, gets the whole model.
  External agents get only claims the person marked shareable.

## Non-goals (v1)

- Behavioral inference of values, beliefs or "how you decide". It is the most
  sensitive part and the least validated. Revisit after the decision journal
  produces outcome data.
- Write access over MCP or the CLI. The roadmap requires any write surface to
  be a separately granted capability.
- Autocomplete and Agent Mode context. Each is a separate decision, with its
  own latency and privacy contract.
- Claims about other people beyond their role ("Maya is my manager"). Health,
  relationship or money details about third parties are never proposed.
- A knowledge graph. Claims are flat records with typed references to people
  and projects.

## Claim model

The schema generalizes `RememberedFact`. The full shape is below. Phase 1
ships `kind`, `text`, `origin` (`said`, `added`), `alwaysUse` and the dates.
Each later field arrives with the phase that uses it. It decodes with a default
that keeps today's behavior: confirmed, stated, LokalBot-only, no evidence. No
migration is needed. A file LokalBot can't read, including one written by a
newer version, is left untouched. About you shows why, and nothing is saved
until it can be read.

```swift
struct PersonalClaim: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case fact        // identity, roles, relationships, circumstances
        case preference  // how to help: style, tools, units, language
        case goal        // what they're working toward, with a horizon
        case principle   // values and decision rules; stated only
    }
    enum Status: String, Codable, Sendable { case proposed, confirmed }
    enum Authority: String, Codable, Sendable {
        case stated      // the person wrote or said it as a fact to keep
        case confirmed   // a proposal the person accepted, possibly edited
    }
    enum Origin: Codable, Equatable, Sendable {
        case said(conversationID: UUID, messageID: UUID)
        case added
        case answer(conversationID: UUID, messageID: UUID)
        case proposed(dreamDay: String)
    }
    enum Sharing: String, Codable, Sendable {
        case lokalBotOnly  // Ask and Quick Recall
        case agents        // also the MCP projection, if granted
    }

    let id: UUID
    var kind: Kind
    var text: String                 // ≤ 280 characters, sanitized and redacted
    var domains: Set<String>         // closed vocabulary: career, work-style, family, health, money, learning, tools, …
    var status: Status
    var authority: Authority
    var origin: Origin
    var evidence: DreamEvidenceProvenance?   // nil = no evidence dependency
    var horizon: String?             // goals: "this quarter", "5 years"
    var reviewAfter: Date?           // stale-check date; not deletion
    var supersedes: UUID?
    var sensitive: Bool              // health, money, family, beliefs → true
    var sharing: Sharing             // default .lokalBotOnly; sensitive claims can't be .agents without per-claim confirmation
    var alwaysUse: Bool
    let createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
}
```

Rules:

- `principle` claims have `authority == .stated`. They are never proposed.
- A rejected proposal leaves a tombstone (kind plus normalized-text hash, no
  text) for 180 days, so the same claim is not proposed again.
- Limits: 300 confirmed claims, 20 open proposals. Unreviewed proposals expire
  after 14 days. Confirmed claims are never evicted silently.
- `reviewAfter` defaults to one year for facts and goals and none for
  principles. A stale claim stays in use, labeled with its date, and appears
  in a "Still true?" review.

## Storage, locking, retraction

- `memory/personal-model.json.enc`, AES-GCM under `chat-key`, atomic 0600
  writes. This replaces `memory/remembered.json.enc` in the Ask-memory design;
  the plaintext-migration path for demo seeds and upgrade fixtures stays.
- In Phase 1 only the app writes and headless `--chat` reads, so atomic writes
  are enough. With evidence-backed claims (Phase 3), access moves under
  `DreamStore`'s lock. `DreamStore` then owns the `PersonalModelStore`, so
  retraction updates claims in the same critical section as Dream memory.
- `invalidateEvidence` gains one step: drop every claim whose `evidence` is
  invalidated, before the pending intent clears. Reads re-apply the filter.
  While a revocation intent is pending, evidence-backed claims are withheld;
  claims without evidence are still served.
- Every existing deletion path already goes through `withPrimaryEvidenceChange`
  or `withMeetingEvidenceMutation`, so there are no new call sites.
- Deleting a source with confirmed claims behind it shows the claims and offers
  **Keep as my statement**. That clears `evidence` and sets
  `authority = .stated`. Otherwise they retract, as Dream memory does.
- **Clear work memory** does not clear personal claims. They have their own
  **Forget everything about me…** action.

## Capture

In rising order of risk:

1. **Stated: no model call.** Use "Remember …" in Ask (`RememberIntent`, as
   designed) or add a claim in My World. Kind defaults to `fact`; the
   confirmation card lets the person change it. Principles are added here.
2. **From an answer: one interactive call.** The Remember action on a cited
   answer, as designed, with provenance from the answer's observed evidence.
3. **Nightly proposals: no extra call.** The Dream response gains an optional
   `personalClaims` array, at most three per night. Each proposal must:
   - quote a verbatim span the transcript attributes to the person's
     microphone, or a span from their own Ask turn. Screen text is excluded in
     v1 because we can't tell what they wrote from what they read;
   - be about the person, not about someone else;
   - not duplicate a confirmed claim or match a tombstone;
   - carry the evidence of the meeting it quotes.

   Grounding follows the handle-catalog pattern in the uncommitted
   `DreamSynthesisGrounding`. The model picks a handle for an
   evidence-catalog line, and the stored quote comes from that line, never
   from the model's text.
   Proposals need **Review the day overnight** to be on and add nothing to the
   prompt when it is off. Kind `principle` in a response is dropped.

Proposals never reach any prompt until confirmed.

## Use in Ask: PersonalContextBuilder

`PersonalContextBuilder.select(claims:question:recentTurns:scope:budget:)` is a
pure, deterministic function. It generalizes the Ask-memory design's
`RememberedFactSelection`, which was designed but never built:

1. Eligibility. Claims without evidence go into every question. Evidence-backed
   claims go only into unscoped questions, the same rule and reason as
   `workMemoryContext`.
2. Order: `alwaysUse`; `principle` claims whose domain matches the question;
   lexical matches against the question and the last two user turns; then
   recency.
3. Budget: 2,000 characters. Embedding selection (EmbeddingGemma 2 is already
   loaded for search) only once someone passes about 100 confirmed claims.

The block goes before work memory in `ChatPrompt.systemPrompt`:

```
About the user (their own statements and confirmed facts; newest first):
- [principle · stated 2026-10-14] I don't take work that requires relocating my family.
- [goal · confirmed 2026-09-30 · this year] Ship LokalBot 1.0 and reach 1,000 weekly users.
- [preference · stated 2026-10-02] Amounts in EUR.
Use these only when relevant. They are not evidence: never cite them as a meeting or screen
source. If evidence contradicts one, say so. If two conflict, point out the conflict instead of
choosing silently.
```

The answer records `usedClaimIDs`. "Shaped by 3 things about you" lists them
with Edit and Forget. Headless `--chat` builds the same block. This is the
discussion's "show why it influenced the answer".

## External agents: get_personal_context

- **Grant:** a third Agent Access toggle, **Personal context**, off by default
  and independent of meeting and screen access. It exposes only claims with
  `sharing == .agents`.
- **Projection:** while the grant is on, the app writes
  `control/personal-context.json` (0600, plaintext) holding only those claims.
  It rewrites the file on every store change and retraction, and deletes it
  when the grant turns off. The CLI reads that file and never touches the
  Keychain. A shared claim is then exactly as readable on disk as the meeting
  files the meeting grant already exposes.
- **Tool:**

  ```json
  {"name": "get_personal_context",
   "arguments": {"task": "Evaluate a job offer", "kinds": ["principle", "goal"], "max_items": 8}}
  ```

  `PersonalContextSelection` lives in `CLISupport`, so Ask and agents rank
  claims the same way. `max_items` defaults to 8 and is at most 12. The
  result gives each claim's kind, text, authority, as-of date and a source
  label. In later phases the label becomes the meeting title and date, never
  content. A note says items not listed are unknown, not false.
  `lokalbot-cli personal-context --task …` returns the same report.
- **Refusals** use the existing error vocabulary: `personal_context_disabled`,
  and `personal_context_unavailable` when the grant is on but the app hasn't
  written the projection. Out-of-grant claims are simply absent.
- A per-claim **Share with agents** switch in the row menu and the editor.
  Phase 2 filters by kind, not by the `domains` sketched above. Claims carry
  no domains yet, and task-word ranking covers the examples. The bulk
  "share all non-sensitive" action and the `sensitive` flag wait for Phase 3.
  Until then every claim is one the person typed, and sensitivity matters
  most for proposed claims.

## Start-of-session briefing (2026-10-15)

The user's aim: agents should always get the context they need and know what
LokalBot can give them, so the user spends less time approving and
re-explaining. Three pieces, adapted from OptMem's `wake` and age-decay
layout:

- **`get_briefing` / `lokalbot-cli brief`** returns one short read (at most
  12,000 characters). First comes a capability index: each grant, on or off,
  with how to turn it on. With every grant off, that index is all the
  briefing returns, with no counts. Each other section needs the grant that
  covers its source:
  - shared About you items (About you grant);
  - the user's open action items and the newest meeting (meeting grant);
  - work-memory projects and goals. Each source kind needs its grant, screen
    sources also need the history window, and unattributed entries are
    skipped;
  - Claude Code and Codex sessions by project, last 7 days at most,
    scheduled runs excluded (screen grant);
  - the review timeline (meeting and screen grants, clamped to the screen
    profile).

  While a revocation is pending, work memory and the timeline are withheld.
- **Age-decay timeline.** Today and yesterday get two review sentences, the
  rest of the last week one each, then one line per earlier week and per
  month. `DreamRollupService` writes the week and month lines after each
  overnight review: the newest finished periods first, at most three Think
  calls a night, only while screen access is on. Each line stores a SHA-256
  stamp of its reviews (day plus `generatedAt`). Readers recompute it, so a
  deleted or regenerated review makes the line stale at once.
  `DreamStore.invalidateReport` deletes covering lines, and Clear work memory
  removes the folder.
- **Proactive use.** The bundled skill's description tells agents to run
  `brief` first and to search LokalBot before asking the user about past work.
  `initialize` returns MCP `instructions` saying the same.
  `get_briefing` is listed first.

Not adopted from OptMem: per-agent memory files, or a write path for agents.
LokalBot stays read-only to agents, and its memory comes from what the user
did, not from what an agent decided to save.

## My World UI

- **Phase 1:** an "About you" section in Settings → Day Memory, which is the
  Ask-memory list widened. Rows show kind, text, origin, sharing, Always use,
  Edit and Forget, with Add… and Forget everything…. An empty top-level screen
  would be a poor first impression.
- **Phase 2**, once proposals exist: a **My World** sidebar destination with
  four tabs (Facts, Preferences, Goals, Principles) and a review queue. Each
  proposal shows its quoted span, a link to the moment in the meeting, and
  Confirm, Edit, Reject. Confirming asks for kind and sharing, defaulting to
  `.lokalBotOnly`.

## Phasing

The discussion put extraction (its phase 2) ahead of agent access (phase 4).
This RFC flips that. Extraction is the riskiest, least-validated piece, while
agent access is the differentiator and is safe with stated claims alone.

1. **Stated claims end to end.** Store, encryption, `RememberIntent` (English
   and Serbian), About you, `PersonalContextBuilder`, the Ask receipt and
   disclosure, headless `--chat`, PRIVACY.md and DEVELOPMENT.md. This is the
   Ask-memory Phase 1 with the wider schema. No new model calls. Deferred to
   follow-ups: a demo-seed and upgrade fixture, and a hosted UI test for the
   receipt.
2. **Agent access.** The grant, the projection, `get_personal_context`, CLI
   parity (`lokalbot-cli personal-context --task …`) and the lokalbot-cli skill
   docs. Milestone: a principle typed into LokalBot changes Claude Code's
   answer to a relevant question, and revoking the grant or the claim removes
   it. Met on 2026-10-14 with `claude -p` against the built MCP server and a
   synthetic library. Getting there exposed a stdio bug present since
   2026-07-14: the server waited for 64 KB or EOF before answering, so
   clients that keep stdin open never connected. It is fixed in the same PR.
3. **Evidence-backed claims.** Remember-from-answer, the nightly proposals with
   quote grounding, the review queue, the My World destination, the deletion
   alert, and retraction tests.

   Built on 2026-10-14 as automatic learning, after decision 6. It differs
   from the plan above in these ways:
   - **Separate call:** learning is its own small Think call after the review
     (`PersonalLearning`), not a new field in the review's JSON, so the tuned
     brief is untouched. Only days with the person's own lines call the model.
   - **Input:** the person's own lines only. That means "me" segments, or a
     lone "local" voice. A microphone shared by several diarized local voices
     is skipped, because there is no telling which voice is the person.
     Lines need a first-person word (English or Serbian). The cap is 40 lines
     and 6,000 characters.
   - **Grounding:** each item names its line, must share at least a third of
     its content words with it, and must not near-duplicate a known item.
     There are at most three a night.
   - **Retraction:** it is checked on every read against the Dream evidence
     revisions (`DreamStore.evidenceCheck`). It also runs after each meeting
     deletion or correction. A pending revocation withholds learned items
     rather than serving them. The store stays outside `DreamStore`'s lock.
   - **Deletion alert:** it became a per-item **Keep Even If the Meeting Is
     Deleted** action in About you, so no deletion dialog changes.
   - **Not built yet:** Remember-from-answer, the My World sidebar
     destination, bulk sharing, and the `sensitive` flag. Health, money,
     religion, politics and sexuality are excluded at the prompt instead.
   - **Local-model check:** Qwen3.5 4B ran on ten synthetic lines, six of them
     traps (a task, a health detail, a colleague's private news, a joke, a
     value judgment and a deadline). It picked the right three and skipped
     every trap. With the same items already known, it suggested only the new
     one. Until "shorten, don't rephrase" was added, it copied lines word for
     word. A Serbian example in the prompt made it translate English lines
     into Serbian, once reversing a meaning, so the example was removed. It
     still translates Serbian lines into English when a day mixes the two
     languages. Word overlap can't ground those items, which is why
     embedding grounding was added (below).
   - **Embedding grounding (added the same day):** this applies when an item
     and its line are in different languages, by NaturalLanguage's dominant
     language. Such an item is compared with EmbeddingGemma 2's
     sentence-similarity prompt, through the local embedder, and only if the
     model file is already present. On 17 measured Serbian-to-English pairs:
     - Correct translations scored 0.83–0.95 and unrelated claims 0.73–0.79.
     - A wrong detail scored 0.80–0.90 ("doctor" for engineer, the wrong city,
       "calls" for written).
     - So the rules are: below 0.82 an item is dropped. A fact or goal is
       saved at 0.90 or above, or when an item word and a line word share a
       root (Cyrillic transliterated). Otherwise it waits for review.
     - End to end with Qwen3.5 4B and EmbeddingGemma 2 on mixed lines, "I lead
       the platform team." (0.853) and "I want to run a marathon in 2027."
       (0.875) from Serbian lines were saved. They were dropped before. All
       traps were still skipped. With all-Serbian lines the model kept
       Serbian, and word overlap saved them.
     - Same-language items never reach the embedder. Without semantic search,
       translated items are dropped as before.
   - **More sources (2026-10-15):** the learning call also reads the person's
     typed words from the day:
     - requests to Claude Code and Codex, from saved coding-agent bursts with
       scheduled runs excluded;
     - Ask questions, excluding "Remember …" messages.

     Typed lines share the 40-line budget, capped at 15, so meetings aren't
     crowded out.
     - **Typed items** always wait for review. A coding-agent item depends on
       its day's activity evidence. An Ask item has no Dream evidence and
       retracts when its conversation is deleted.
     - **Dictation (2026-10-16):** off by default ("Learn from my
       dictation"), since it is the first time LokalBot keeps dictated text.
       Only the raw spoken words of a paste into an identified field are
       kept, never a Compose draft. The same exclusions as nearby-text
       context apply. The words are sealed with the chat key until that
       night's pass and never kept more than 2 days. Items always wait for
       review, and a dictated agent request is read once, from the request.
       A local Qwen3.5 4B check on 3 good dictated lines and 7 traps (a
       request, someone's family news, health, a joke, someone else's goal,
       a task, a coding request) picked all 3 and skipped every trap. Without
       "Dictated lines are often messages to someone else", it added a year
       to "moving to Lisbon".
     - **Work-memory promotion:** a Dream goal or project seen for 14+ days,
       and active in the last 7, becomes a review suggestion. A goal keeps its
       text; a project becomes "I work on <name>.". It carries the Dream
       provenance, and needs no model call. First sightings are stored as
       hashes in the personal model.
     - **Prompt check on Qwen3.5 4B:** at first it ignored personal items
       inside typed requests. "Look inside them" plus "consider every line
       on its own" fixed that. On a mixed set it picked the staff-engineer
       goal, "I prefer small pull requests" and the Lisbon move. It skipped
       the coding tasks and both lines about a colleague. The original trap
       set still gave the same three correct items.
4. **Decision journal.** Extend existing `decisionRecords` with an optional
   expected outcome and a review date. Today's weekly review asks "How did this
   turn out?", and the answer becomes evidence for later proposals. This is
   where "learn how you decide" can start, with data.

## Privacy contract changes (PRIVACY.md)

- What's kept: personal claims, encrypted under the chat key, local only.
- They go to the selected Think backend with Ask questions, which may be an
  approved remote origin. The remote-origin approval copy lists them.
- Nightly proposals read only what the overnight review already reads. They
  quote only the person's own speech and stay unused until confirmed.
- Evidence-backed claims retract with their sources unless the person keeps
  them as their own statement.
- The Personal context grant writes a plaintext file of shared claims while it
  is on. MCP clients may send those claims under their own terms.
- Excluded from diagnostics, daily exports and Autocomplete.

## Evaluation

The harness should be a fixture-driven XCTest, in the style of
`DreamMemoryRetractionTests`, plus a small labeled set in
`Benchmarks/MemorySystems/`. It should not be a new Python harness.

| Measure | Target |
| --- | --- |
| Retraction correctness: deleted/edited source → claim gone from disk, Ask prompt, projection | 100% |
| Leakage: grant off, `.lokalBotOnly`, sensitive-unshared, or proposed claims in any MCP result | 0 |
| False assumptions: answers stating an unconfirmed proposal as fact (judge over a fixed question set) | 0 on the fixture set |
| Proposal precision: confirmed ÷ proposed over two weeks of real use | ≥ 50%, or turn proposals off by default |
| Context relevance: labeled task → expected claims, precision@5 | ≥ 0.8 on the fixture set |
| Cost: selection time; prompt growth | < 5 ms; ≤ 2,000 characters |

## Decisions (2026-10-14)

1. **Positioning.** CONTEXT.md, the roadmap and the site keep "private work
   memory" for now. The copy changes once Phase 2 makes agent access visible.
2. **Default sharing.** Every claim starts as `.lokalBotOnly`. Sharing with
   agents is per claim, plus the bulk action for non-sensitive confirmed claims.
3. **Source deletion of confirmed claims.** They retract by default. The
   deletion alert offers **Keep as my statement**.
4. **Language.** "Remember …" triggers ship in English and Serbian (Latin and
   Cyrillic) in Phase 1. A Serbian `zapamti da …` keeps its clause order, for
   example "Je Maja moja menadžerka", and can be edited.
5. **Deleting a conversation** keeps the claims stated in it, as their own
   data. The alert proposed in the Ask-memory design is not needed in Phase 1.
6. **Automatic learning (later the same day).** Facts and goals learned from
   the person's own meeting lines are saved without review. Preferences wait
   for review. Principles are never learned. This replaces "proposals never
   reach any prompt until confirmed" for facts and goals. Learned items are
   labelled as learned in Ask and for agents, never default to shared, and
   go to scoped questions only when stated.
