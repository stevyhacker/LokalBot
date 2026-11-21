# 0015. People, personal model, projects and actions

- Status: Accepted
- Date: 2026-11-20

## Context

This feature covers people profiles, the personal model (Personal Context) and its overnight learning, tracked projects, actions extracted from meetings with Follow-through, and memory routines, in the Mac app (Swift) and the Windows and Linux app (Rust). Much of it decides what LokalBot may read, keep, learn or show about the person and the people they meet. These decisions were moved here from code comments when the code stopped carrying comments ([ADR 0001](0001-code-carries-no-comments.md)).

## Overnight learning

### Learning reads only the person's own first-person words, and every result must be grounded in a cited line

After the day's review, the overnight pass reads only the person's own words from that day (their meeting lines, what they typed to coding agents or in Ask, and their dictation when Learn from my dictation is on); lines without a first-person word and other speakers' lines are never sent. The Think model is asked for at most three durable things about the person, and any result that does not point at one of those lines and is not grounded in it is dropped. Facts and goals from meetings are saved; preferences, and anything learned from typing, wait for review. In Rust, which lines may be read is decided in `lokalbot_core::personal::learning`, and the model call and grounding checks live in `lokalbot-ai`.

Where: `LokalBot/Services/PersonalModel/PersonalLearning.swift` (`PersonalLearning`), `LinuxWindows/crates/lokalbot-ai/src/personal_learning.rs`, `LinuxWindows/crates/lokalbot-core/src/personal/learning.rs`.

### Principles are never learned

Principles are the person's call and are never guessed: the overnight pass never proposes or saves one.

Where: `LokalBot/Services/PersonalModel/PersonalLearning.swift` (`PersonalLearning`), `LinuxWindows/crates/lokalbot-ai/src/personal_learning.rs` (`proposals`), `LinuxWindows/crates/lokalbot-core/src/personal/mod.rs`, `LokalBotTests/Services/PersonalModel/PersonalModelTests.swift` (`PersonalClaim.Kind.suggested`).

### A meeting counts as the person's speech only when one microphone voice clearly dominates

Own speech is microphone speech ("me", "local", "local N", also behind a merged recording's "source:" prefix) attributed to the user; echo, overlapping voices and voices corrected to someone else are left out, and plain "local" segments count as the same voice as "local 1" because diarization leaves some of the person's segments unnumbered. A voice the person confirmed as theirs wins. Otherwise, when diarization found several voices on the microphone, the meeting counts only if one dominates (four times the next) and only that voice is used; with no clear winner the microphone was shared and the meeting is skipped, since there is no telling which voice is the person.

Where: `LokalBot/Services/PersonalModel/PersonalLearning.swift` (`PersonalLearning.ownTurns`), `LinuxWindows/crates/lokalbot-core/src/personal/learning.rs` (`own_turns`).

### Cross-language grounding uses a measured similarity floor, and near-floor facts wait for review

EmbeddingGemma 2 with the sentence-similarity prompt, measured on Serbian lines against English items (2026-10-14), scored correct translations 0.83–0.95, unrelated claims 0.73–0.79 and a wrong detail ("doctor" for engineer, the wrong city) 0.80–0.90. Items below the floor are dropped; above it, a fact or goal is saved only with a shared word root or a very high score and otherwise waits for review, because embeddings alone can't tell a wrong detail from a right one. Recalibrate the floor whenever the embedding model changes.

Where: `LokalBot/Services/PersonalModel/PersonalLearning.swift` (`PersonalLearning.crossLanguageFloor`), `LinuxWindows/crates/lokalbot-ai/src/personal_learning.rs` (`CROSS_LANGUAGE_FLOOR`).

### The day fingerprint leaves out dictated lines

The fingerprint of what the pass read for a day is independent of order and handles, and leaves out dictated lines: they are deleted once read, so a later review of the same day would otherwise always look changed.

Where: `LinuxWindows/crates/lokalbot-core/src/personal/learning.rs` (`fingerprint`).

## Learning from dictation

### Dictation learning is off by default and keeps raw words encrypted for at most two days

Learn from my dictation is off by default. While it is on, LokalBot keeps the raw dictated words, encrypted, in `DictationLearningLog` until the next learning pass reads them and for at most two days; the pass reads them once and they are not kept past it. Items found in dictation always wait for review.

Where: `LokalBot/Models/Settings/AppSettings.swift` (`AppSettings.personalLearningFromDictation`), `LokalBot/AppState.swift` (`AppState.learnAboutPerson`).

### Dictation is kept only where nearby-text context would be allowed, and never from LokalBot or an unreadable browser

A dictation is kept for learning only under the same app, website and private-window exclusions as nearby-text context, and never from LokalBot itself, since Ask questions are read from the conversation. A browser whose page address can't be read can't be checked against the website exclusions, so its dictation is not kept.

Where: `LokalBot/Services/PersonalModel/DictationLearningLog.swift` (`DictationLearningPolicy`, `DictationLearningPolicy.permits`).

## Personal model storage and claims

### One controller owns the personal model and refuses every edit when the saved file can't be read

The controller (`PersonalModelController` and `PersonalModelStore` on the Mac) is the only owner: Ask reads and adds claims through it, Settings → Personal Context edits them, and the overnight review adds learned ones. Nothing touches the credential store until first use. If the saved file can't be read, every edit is refused instead of overwriting it.

Where: `LinuxWindows/crates/lokalbot-core/src/personal/controller.rs`.

### The model is sealed under the `chat-key`, and a plaintext copy is accepted and re-sealed

`memory/personal-model.json.enc` is sealed under the `chat-key`. A plaintext `memory/personal-model.json` (demo seeds, upgrade fixtures) is accepted and re-sealed on the next save, and a sealed copy wins over a plaintext one.

Where: `LinuxWindows/crates/lokalbot-core/src/personal/controller.rs`.

### Over-long claim text is refused, not truncated

A claim whose text is too long is refused rather than cut, because a cut sentence can drop a negation.

Where: `LokalBot/Services/PersonalModel/PersonalClaim.swift` (`PersonalModel.validatedText`), `LinuxWindows/crates/lokalbot-core/src/personal/mod.rs` (`EditError`).

### Forgetting a learned claim leaves a tombstone; a source retraction does not

When the person forgets a learned claim, a tombstone stays so tomorrow's review doesn't learn it again; forgetting a stated claim leaves nothing behind. When a claim goes because its source was deleted or corrected, it leaves no tombstone, so it can be learned again from evidence that still exists.

Where: `LokalBot/Services/PersonalModel/PersonalClaim.swift` (`PersonalModel.remove`, `PersonalModel.retract(ids:)`), `LinuxWindows/crates/lokalbot-core/src/personal/mod.rs` (`PersonalModel::remove`, `PersonalModel::retract`).

### Learned claims retract with their source, and are withheld while that can't be checked

Learned claims carry the source they came from and are checked against the evidence revisions on every use. A claim whose source changed keeps its place while the source still has the line it quotes (a rebuilt review, a re-read agent session, an unrelated edit to the meeting) and is retracted once it doesn't (the meeting or session deleted, the line corrected or no longer the person's). While a revocation is pending the evidence can't be checked, so evidence-backed claims are withheld meanwhile.

Where: `LokalBot/Services/PersonalModel/PersonalModelController.swift` (`PersonalModelController.retractInvalidated`), `LinuxWindows/crates/lokalbot-core/src/personal/controller.rs`, `LinuxWindows/crates/lokalbot-core/src/personal/mod.rs`.

## Who reads personal context

### Only Ask and Quick Recall read the personal model; agents get shared items only under the grant

The personal model is private by default. Ask and Quick Recall read it; external agents get only items marked for them, through the plaintext copy in `control/personal-context.json`, and only while the Personal context grant is on. Agent Mode, Autocomplete, notes, exports and diagnostics never read it.

Where: `LinuxWindows/crates/lokalbot-core/src/personal/mod.rs`.

### The CLI and MCP read a plaintext copy of shared claims, removed on any failure

The Personal context grant (`PersonalContextAccessGate`, `PersonalContextAccessManager` on the Mac) is a marker under `control/` plus a plaintext copy of only the claims the person shared, so the CLI and MCP can answer without the app running and without reading the encrypted model, which the CLI never reads. The copy exists only while the grant is on, and every failure removes it rather than leaving a stale one.

Where: `LokalBot/CLISupport/PersonalContextAccess.swift` (`PersonalContextProjection`), `LinuxWindows/crates/lokalbot-core/src/personal/access.rs`.

### Scoped Ask questions get only stated claims

A question limited to some sources or days passes `includeEvidenceBacked: false` and gets only what the person stated: like work memory, learned claims would carry meeting content past the question's source boundary. That includes claims learned from an Ask question or a dictation, which have no evidence to depend on but are learned all the same; the test guards against such an item, kept in review, going out with scoped questions as if it were a statement.

Where: `LokalBot/Services/PersonalModel/PersonalModelController.swift` (`PersonalModelController.usableClaims`), `LokalBotTests/Services/PersonalModel/PersonalModelTests.swift` (`PersonalModelStoreTests.testScopedQuestionsGetStatedItemsNotOnesLearnedFromAskOrDictation`).

### Agent skills name every authority Personal Context returns

The plugin's skills tell the agent which kind of item each one is, because an agent told every item is the user's own statement quotes a learned, possibly outdated one as the user's words.

Where: `Scripts/tests/test_claude_plugin.py` (`test_skills_name_every_authority_personal_context_returns`).

## People and action ownership

### Attendee email addresses are private join keys only

People profiles are assembled from local meeting metadata: calendar attendee names, speaker names the user applied and action owners. Attendee email addresses are used only as private join keys and never appear in a profile, its ID or anything derived from it.

Where: `LokalBot/Models/People/PeopleDirectory.swift` (`PersonProfile`), `LinuxWindows/crates/lokalbot-core/src/people.rs`.

### Action ownership comes from the transcript speaker, not the model

Whose task an extracted action is comes from the speech it cites: identity is the cited row's speaker as the transcript attributes it, and the model's owner, basis and quote are claims to check, never proof. A task belongs to a speaker when that speaker's own words around the cited rows undertake it, and to nobody when those words are a question, a negation or someone else's job.

Where: `LokalBot/Services/Actions/ActionOwnership.swift` (`ActionOwnership`).

### Spoken undertakings are found in a speaker's stream of words, refusing only contradictions

Transcripts are not sentences: a commitment can sit anywhere in a run-on clause, repeat or stumble ("the extraction PR is something I I have to update"), and be cut across rows by the diarizer. Recognition reads one speaker's consecutive rows as a stream of words and looks for a first-person subject bound to an undertaking verb wherever it appears. It refuses only negation, a question, reported or habitual speech, and work handed to someone else; a condition ("if approved, I'll ship it") changes when the task happens, never whose it is.

Where: `LokalBot/Support/SpokenUndertaking.swift` (`SpokenUndertaking`).

### Owners are matched by name, not by voice, until someone says so

"Them" on an action is not the person that voice was named as afterwards, until someone says so.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/meetings/presentation.rs` (`owner_options`).

### The translated "Me" owner saved by v0.11 is read as the user only in its own language

In v0.11.0–v0.11.5 the Windows/Linux correction sheet saved the interface word for "Me" as the owner for "You", which nothing read as the user. Each such word counts as the user only in the language that wrote it; elsewhere "Mimi", "Saya" or "Moi" is more likely somebody's name.

Where: `LinuxWindows/crates/lokalbot-core/src/actions.rs` (`TRANSLATED_ME_OWNERS`).

### Actions form threads only on equal canonical source text

Only equal canonical source commitments form threads; similar wording is not enough authority to share status, ownership or corrections.

Where: `LokalBot/Models/Actions/ActionThreads.swift` (`ActionThreadClusterer`).

## Actions and Follow-through

### Status changes and corrections never alter what was extracted

Each of the user's actions is shown once however many meetings it came up in. Status changes and corrections go through `OutcomeIndex` and never alter or replace what was extracted.

Where: `LokalBot/Views/Actions/ActionsWorkspaceView.swift` (`ActionsWorkspaceView`), `LinuxWindows/crates/lokalbot-app/src/pages/actions/details.rs` (`ActionsPage.render_passages`).

### "Looks done?" hints are suggestions from consented text, read only when asked

Completion hints are suggestions only. They read only text kept with consent, and only when asked to (`refreshActionCompletionHints`).

Where: `LinuxWindows/crates/lokalbot-app/src/pages/actions/mod.rs` (`ActionsPage::reload`), `LinuxWindows/crates/lokalbot-app/src/ui/action_row/thread.rs` (`suggests_completion`).

### Every Follow-through step needs the person's approval and opens as a draft

In a Follow-through run the Think model plans the work for one action, reads what it needs from the library and proposes steps. Each step waits for the person to approve, edit or decline it; nothing leaves the Mac as an email, invitation or task without that click, and even then it opens as a draft.

Where: `LokalBot/Services/FollowThrough/FollowThroughSession.swift` (`FollowThroughSession`).

### Follow-through tells the model names only

The briefing about the action gives the model people's names only; calendar addresses stay local.

Where: `LokalBot/Services/FollowThrough/AppFollowThrough.swift` (`FollowThroughBriefing.make`).

### Mailto drafts percent-encode a literal `+`

A `+` in the mailto query is written as `%2B`, because some mail clients' query parsing reads `+` as a space.

Where: `LokalBot/Services/FollowThrough/FollowThroughTools.swift` (`FollowThroughTools.mailtoURL`).

## Projects

### The "Where it stands" note stays, marked, when its evidence changes

The tracked project's "Where it stands" note is the only model-written text on the page (overview, points with the meeting each comes from, and open questions), and its heading says when it was written, by which model and where that ran. A note whose evidence has changed stays, marked, until the person updates it or an approved automatic update replaces it.

Where: `LokalBot/Views/Projects/ProjectPageView.swift` (`WhereItStandsCard`), `LinuxWindows/crates/lokalbot-app/src/pages/projects/detail.rs` (`ProjectsPage.where_it_stands`).

### Deleting a meeting withdraws every project note that cited it

A deleted meeting takes every note that used it along with it, as `PRIVACY.md` states.

Where: `LokalBot/Services/Projects/ProjectStore.swift` (`ProjectStore.withdrawSummaries(citing:)`).

### Projects whose sources were deleted or corrected stop counting as evidence

Projects are read for `DreamMemory.activeProjects` through the evidence check: a project whose sources were deleted or corrected since it was written doesn't count.

Where: `LinuxWindows/crates/lokalbot-ai/src/upcoming.rs` (`read_projects`).

### Nothing is written from a just-tracked project's settling copy

A suggestion that was just tracked stays on screen, already as tracked, until the next load delivers its tracked profile (`ProjectsWorkspaceView.settlingProfile` on the Mac). Nothing is written from this copy, because its evidence is about to be replaced.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/projects/model.rs` (`settling_profile`).

### Windows and Linux write `projects/summaries.json` the way macOS decodes it

The file uses a bare project UUID and ISO-8601 meeting dates, as `ProjectStore` reads it. macOS decodes the file as a whole, so a note that is not for a tracked project is left out.

Where: `LinuxWindows/crates/lokalbot-core/src/projects.rs` (`write_project_summaries`).

### Transcript lines for project links are parsed by hand, without speaker labels

Lines like "**[00:13:21] Them 3:** text" from `transcript.md` are parsed by hand, because a Swift regex took 1.9 s over a 31,000-line library. Speaker labels are dropped because they are only meaningful inside one meeting.

Where: `LokalBot/Models/Projects/ProjectLinks.swift` (`ProjectLinks.transcriptLines(fromMarkdown:)`).

## Memory routines

### Routines are fixed-scope and write one private file inside the chosen folder

Local routines (`MemoryRoutines.swift` on the Mac) do not invoke a shell, contact a network, mutate meeting data or accept arbitrary prompts. Their sole write is one private Markdown file under the folder the person chose, and the folder it lands in must resolve inside the chosen one, so a link can't carry the file elsewhere.

Where: `LinuxWindows/crates/lokalbot-engine/src/routines.rs` (`routines::write`).

## Consequences

- Anything that reads the personal model, learns from the person's words or shares claims with agents must keep the boundaries above: own first-person lines only, grounded results, principles never learned, scoped questions and agents limited to stated or shared items, and the shared copy removed on failure.
- Generated or derived content (learned claims, project notes, action status) follows its evidence: an explicit deletion withdraws or retracts it, a revision marks it stale or keeps it while the quoted line remains, and nothing overwrites what was extracted.
- The Mac and Windows/Linux apps share files and rules (`projects/summaries.json`, the personal model, the v0.11 owner words, the similarity floor); change both sides together, and recalibrate the floor when the embedding model changes.
