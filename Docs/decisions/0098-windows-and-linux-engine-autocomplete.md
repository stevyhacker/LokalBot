# 0098. Windows and Linux: engine — autocomplete

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-engine/src/autocomplete.rs`.

## Decisions

### `LinuxWindows/crates/lokalbot-engine/src/autocomplete.rs`

#### Autocomplete flow: debounce, one request in flight, privacy, never downloads, nothing typed logged
Autocomplete (`CotypingCoordinator`): turns the desktop's reads of the
focused field into suggestions.

The desktop sends a [`FieldContext`] on every change. A text change asks
for a suggestion after the debounce; a caret move only drops the one on
screen. Typing a suggestion's next characters, or accepting part of it,
keeps it (shortened) and may top it up with a few more words. One request
is in flight at a time; a newer field read supersedes it, and a result
that arrives late is shown only if the field still continues it. A newly
focused field has its prompt read ahead, so the first keystroke only adds
what was typed. A field read that arrives while the server is still
starting is answered once it is up, unless it was dismissed or answered
some other way meanwhile.

Nothing runs unless Autocomplete is on, and nothing is ever downloaded:
without the Autocomplete model and the llama.cpp runtime, or a server the
user set up and approved, no suggestion is made. Suggestions pause while a
meeting records, and the excluded apps are checked again here. Typed text
stays in memory and is never logged. What stays on disk is counts (see
`autocomplete_measure`) and, when on, examples sealed under a key in the
credential store (`LearningStore`).

#### Idle suggestions are taken down after 60 s so a late Tab reaches the app
`IDLE_SUGGESTION_LIFETIME`: A suggestion left alone this long is taken down, so a Tab pressed long
afterwards reaches the app (`idleSuggestionLifetimeMilliseconds`).

#### Host trait lets worker rules run in tests without a model server
`Host`: The worker's view of the engine, so its rules run in tests without a
model server.

#### Suggestions pause while a meeting records
`Host.recording`: A meeting is recording: suggestions pause (`CotypingMeetingPause`).

#### Server counts as up only when neither stopped nor still starting
`Host.server_running`: The Autocomplete server is up: not stopped, and not still starting.

#### Request run is blocking and called on the request's own thread
`Host.run`: Runs one request against the Autocomplete server. Blocking; called on
the request's own thread.

#### Memory lookup reads the library on a thread of its own
`Host.memory`: Saved facts for `query` the grants allow. Reads the library; called
on a thread of its own.

#### Prompts are not read ahead when using a chosen server
`Host.prefills`: Whether a focused field's prompt can be read ahead: not on a server.

#### Clipboard is returned unless concealed and blocks only briefly
`Host.clipboard`: The clipboard now, unless concealed. Blocks only briefly.

#### Window read is blocking and called on a thread of its own
`Host.read_window`: Reads the focused window. Blocking; called on a thread of its own.

#### Opening learned examples is blocking and called on a thread of its own
`Host.open_learning`: Opens the learned examples. Blocking; called on a thread of its own.

#### Forgetting deletes the file after queued writes, then reports success
`Host.forget_learning`: Deletes the file after any queued writes, then reports whether it worked.

#### Unopenable learned examples are left alone, unlike the Mac which overwrites them
`LearningOpen`: What opening the learned examples found. If they cannot be opened they are
left alone: nothing is written over them (the Mac reads them as empty and
later overwrites them).

#### Writes go off the worker so typing never waits on disk or credential store
`start_writer`: Writes off the worker, one at a time, so typing never waits on the disk or
the credential store.

#### A failed learning write stays memory-only until Forget learned text
`start_writer`: A write that failed stays memory-only until "Forget learned text".

#### A missing file needs no key so credential store is untouched until needed
`open_learning_file`: Opens `<root>/cotyping-learning.enc`. A missing file needs no key, so the
credential store is not touched until there is something to keep.

#### Files this key cannot open, such as a Mac's, are left alone not overwritten
`open_sealed_learning`: A file this key cannot open, such as one a Mac sealed with its own
Keychain key, or that does not parse, is left alone rather than read as
empty and overwritten.

#### Failures are logged once until a request succeeds again
`EngineHost.failing`: Failures are logged once until a request succeeds again.

#### A chosen server counts as up because nothing waits for it to start
`EngineHost.server_running`: A chosen server is up as far as anyone here can tell: nothing waits
for it to start.

#### Server starts on first use; runtime never downloads and unverified models are refused
`EngineHost.run`: Starts the server on first use; the runtime never downloads for
this role, and an unverified model is refused.

#### Nothing is read ahead for a chosen server because it keeps its own cache
`EngineHost.run_on_server`: Autocomplete on a chosen server. Nothing is read ahead: a server keeps
its own cache.

#### Publish only changes so a working server does not redraw Settings
`EngineHost.report_problem`: Publishes only a change, so a working server does not redraw Settings
on every suggestion.

#### Memory lookup selects facts the grants allow, mirroring the Swift provider
`look_up`: `CotypingMemoryContextProvider.load`: the facts the grants allow,
selected for `query`.

#### Sources are stamped before reading so edits made while reading still show
`look_up_guarded`: `CotypingMemoryContextProvider.load` with the stamps that later tell
whether its facts still hold. Sources are stamped before they are read, so
an edit made while reading still shows.

#### Unattributed memory never reaches lookup; unfinished revocation reads as nothing
`look_up_guarded`: Unattributed memory never reaches here; an unfinished revocation reads
as nothing at all.

#### Files a meeting's facts depend on, stamped for staleness
`MEETING_SOURCE_FILES`: The files a meeting's facts depend on (`meetingItems`).

#### Query uses only grants' words, nothing for terminals, no title without app context grant
`query_for`: The memory search for `field` as autocomplete makes it: only the grants'
words, nothing for integrated terminals, no title without the app context
grant.

#### Saved facts for diagnostics and practice editor, empty without the grant
`saved_facts`: The saved facts a suggestion in `field` would use now, as (source title,
fact): for diagnostics and the practice editor's "what shaped this"
(`memoryContextSources`). Reads the library; empty without the grant.

#### Server error messages are not logged because they can quote typed text
`EngineHost.failed`: Logs a failure once per episode, without the server's own message:
a request error can quote the prompt, and typed text is never logged.

#### Suggestions shaped by saved facts or surrounding text are not learned
`JobKind::Fresh.used_context`: Saved facts or the text above the field shaped it: not learned.

#### Top-up adds words to the on-screen suggestion, mirroring Swift extension
`JobKind::TopUp`: More words for the suggestion on screen (`CotypingSuggestionExtension`).

#### Unopenable examples stay in memory and never write
`LearningState::Blocked`: They could not be opened: stays in memory and never writes.

#### Keystrokes never wait for lookups; new lookup runs when finished words could name something new
`MemoryLookup`: The newest saved-memory lookup for the focused field
(`CotypingMemoryLookup`): a keystroke never waits for one; it takes the
newest finished one, and a new lookup runs when the finished words
before the caret could name something new.

#### A different field forgets the previous field's facts at once
`MemoryLookup.begin`: A different field forgets the previous field's facts at once.

#### A finished lookup is kept only if still the newest asked
`MemoryLookup.finish`: Keeps a finished lookup only if it is still the one asked for last.

#### A prefill cannot be stopped once sent but later requests reuse it
`Running.prefill`: A prefill cannot be stopped once sent, but what follows reuses it.

#### Typing on from where a request was asked keeps it alive
`Running.superseded_by`: Whether a request for `before` makes this one useless. Typing on from
where it was asked keeps it: its suggestion may still be continued.

#### Counter bumped per field change so older debounces are dropped
`Worker.work`: Bumped by every field change; a debounce for an older one is dropped.

#### Queued job starts after running finishes: one request at a time
`Worker.queued`: Starts once `running` has finished: one request at a time.

#### A field read arriving during server start is answered once it is up
`Worker.pending`: The field whose newest read arrived while the server was starting:
that read is answered once the server is up.

#### Remembers the last accept that used up a suggestion and its preceding text
`Worker.accepted_tail`: The last accept that used up a suggestion, and the text before it.

#### Generation bump stops an in-flight open from restoring dropped examples
`Worker.learning_generation`: Bumped when the examples in memory are dropped, so an open still
running cannot bring them back.

#### Privacy setting change cancels work and drops content read under old settings
`PrivacySettings`: `CotypingPrivacySettings`: a change here cancels work and drops what was
read or shaped under the old settings.

#### Field reads are processed before finished requests so results check against the newest read
`Worker run loop`: Field reads first, so a finished request is checked against
the newest one.

#### Screen-read text is forgotten as soon as focus leaves its field
`Worker.on_left_field`: Text read from the screen is forgotten as soon as focus leaves the
field it was read for (`handleFocusChange`).

#### Forget cancels, clears memory at once, deletes after queued writes, learning waits
`Worker.forget_learned`: `forgetLearnedText`: cancels what could bring the text back, clears
memory at once, then deletes after any queued writes. New learning
waits until that is done.

#### After successful forget nothing remains to protect from overwrite
`Worker.on_learning_forgotten`: Nothing is left to protect from being overwritten.

#### Save again if expired examples went or something was learned meanwhile
`Worker.on_learning_opened`: Expired examples went, or something was learned meanwhile.

#### Learned examples open only when an identified document needs them, sparing the credential store
`Worker.open_learning_if_needed`: Opens the learned examples the first time an identified document
needs them, so the credential store is never asked otherwise.

#### Editing or deleting a source or withdrawing a grant cancels what its facts shaped
`Worker.discard_revoked_memory`: Editing or deleting a source, or withdrawing a grant, cancels what its
facts shaped (`discardRevokedMemoryContext`).

#### Statistics never count LokalBot's own editor
`Worker.measured`: Whether statistics count this field: never LokalBot's own editor.

#### A read during server start is answered later with the newest read
`Worker.on_context`: A read that arrives while the server is still starting cannot be
answered yet: the newest one is, once it is up (`serve_pending`).

#### A newly focused field suggests nothing until typing but its prompt is read now
`Worker.read_field`: A newly focused field: nothing is suggested until the user
types, but its prompt is read now.

#### Saved facts are looked up on focus so the first suggestion can use them
`Worker.read_field`: The saved facts for this field are looked up now, so the first
suggestion can use them.

#### Caret moves drop the suggestion and ask for nothing
`Worker.read_field`: Arrow keys or a click: the suggestion goes and nothing is asked.

#### Accepted text may omit a space the field already had
`Worker.on_accepted`: The accepted text left out a space the field already had.

#### Accepted typo corrections count only the fix, not shown or accepted suggestions
`Worker.on_accepted`: Not a shown or accepted suggestion: only the fix is counted.

#### An exhausted suggestion's next field read asks for more
`Worker.on_accepted`: The next field read, with the accepted text, asks for more.

#### Nothing read or shaped under old settings stays after a privacy change
`Worker.apply_settings`: Nothing read or shaped under the old settings stays
(`applySettings`).

#### Learned examples dropped from memory only; disk stays until Forget learned text
`Worker.apply_settings`: In memory only: what is on disk stays until "Forget learned text".

#### Turning off stops the model instead of keeping it loaded for idle time
`Worker.apply_settings`: Turned off: the model does not stay loaded for the idle time.

#### Rechecks on, excluded app, terminal and meeting recording, mirroring Swift availability
`Worker.allowed`: `CotypingAvailability.disabledReason`, checked again here: on, not an
excluded app, not a terminal, and no meeting recording.

#### A text change drops the suggestion and asks for one after the debounce
`Worker.schedule`: A text change: the suggestion goes, and one is asked for after the
debounce (`scheduleGeneration`).

#### A request answers the newest read, including one that waited for the server
`Worker.request_suggestion`: This answers the newest read, including one that waited for the
server to start.

#### Explicit emoji shortcode wins over autocorrect and the model
`Worker.request_suggestion`: An explicit `:shortcode` wins over autocorrect and the model.

#### Explicit macro wins and is computed once so random macros are not rerolled at accept
`Worker.request_suggestion`: An explicit `/expr` wins too. The result is computed once, here: a
random macro is not rolled again at the accept.

#### Splices that misspell the word or junk runs are not shown; spell verdicts stand down when inapplicable
`Worker.seam_allows`: `seamVerdict`: a splice that would misspell the word being typed, or a
junk run, is not shown. Spell verdicts stand down where they don't apply.

#### Clipboard is resolved for every request kind as on macOS, never for practice editor
`Worker.extras`: What a request is built with besides the field. The clipboard is
resolved here for every kind of request, as on macOS; LokalBot's own
practice editor never uses it.

#### Window text never blocks keystrokes and its model is never downloaded
`Worker.window_context`: The focused window's text once a background read of it exists. A
keystroke never waits for one; a missing or old read starts here. The
model is never downloaded for this: without it there is no window text.

#### Window text policy is rechecked on every use
`Worker.window_context`: Checked again for every use: `allows_window_text` ran above.

#### New window text is prefilled when idle so the next keystroke need not read it
`Worker.window_text_changed`: New window text changes the prompt's start: with nothing being
generated, the model reads it now, so the next keystroke need not
(`windowTextDidChange`).

#### New facts change prompt start so it is prefilled when nothing else is pending
`Worker.on_memory`: New facts change the prompt's start: read it ahead while nothing
else is asked for (after a prefill already running, if need be).

#### Examples rank on finished words so a half-typed word does not reorder them
`Worker.learned_examples`: Accepted completions from the same document, ranked on the finished
words so a half-typed word does not reorder them.

#### Prompt is read ahead of the first keystroke unless a request is already coming
`Worker.prefill`: Reads a field's prompt ahead of the first keystroke
(`scheduleFocusPrewarm`), unless a request is already going to.

#### Top up only when the suggestion is short and was cut by the length limit
`Worker.maybe_extend`: Tops up the suggestion on screen when it is running short and was cut
by the length limit (`extendSuggestionIfNeeded`).

#### Top-up uses the same saved facts the suggestion was made with
`Worker.maybe_extend`: The same saved facts the suggestion was made with.

#### Sources count as used only if the request carried them
`Worker.rehearsal_report`: Sources count only if the request carried them.

#### Pending read is answered only if field focused, undismissed, nothing shown or due
`Worker.serve_pending`: With nothing else in flight, answers the field read that arrived
while the server was starting, now that it is up. Not if the field
lost focus or the read was dismissed (both drop it), or a suggestion
is on screen or due after the debounce.

#### A suggestion valid for the current field cancels pending requests for keys typed meanwhile
`Worker.on_suggestion`: A suggestion for the field as it is now: the pending request for
the keys typed meanwhile is not needed.

#### Only a top-up that landed is followed up so a refused one cannot loop
`Worker.on_top_up`: Only a top-up that landed is followed up, so a refused one cannot loop.

#### Accepted parts of a suggestion become one learned example
`Worker.clear_suggestion`: What was accepted of the suggestion becomes one learned example.

#### All accepted chunks of one suggestion are one write
`Worker.clear_suggestion`: All chunks from one suggestion are one write.

#### Cancels requests made useless by the new field text; prefills continue
`Worker.cancel_generation`: Drops the pending and in-flight suggestion requests that a field now
reading `before` makes useless (all of them for `None`); a prefill
goes on.

#### Excluded apps match case-insensitive part of name or id
`is_excluded`: `CotypingAvailability.isExcluded`: a case-insensitive part of the app's
name or id.

#### Learning place omits window title without the app context grant
`place`: Where an accepted suggestion was written, for learning. No window title
without the app context grant.

#### Meeting lines: index matches or title named, newest first, max four, read fresh from files
`meeting_items`: Lines from recent meetings that a lookup may offer
(`CotypingMemoryContextProvider.meetingItems`): meetings the index finds
for the query's words or whose title the query names, newest first, at
most four. Notes, summary and outcomes are read fresh from the files.

#### Meeting files are read up to 32 KB as on macOS
`bounded`: Files are read up to 32 KB, as on macOS.

#### Work memory from macOS overnight reviews excludes those built from since-changed meetings
`work_memory_items`: Projects and goals from the overnight reviews a macOS library carries,
without those built from meetings that changed since.

#### The first read of a field only prefills
`typing_asks_for_a_suggestion_after_the_debounce`: The first read of a field only prefills.

#### A top-up asks for one word fewer than a fresh suggestion
`accepting_tops_the_suggestion_up_once_two_words_are_left`: A top-up asks for one word fewer than a fresh suggestion.

#### Excluded apps, private windows and unknown browser pages abstain from window reads
`window_text_needs_its_grant_and_the_model_and_never_downloads`: Excluded app, private window and an unknown browser page abstain.

#### LokalBot's own editor never reads the screen
`window_text_needs_its_grant_and_the_model_and_never_downloads`: LokalBot's own editor never reads the screen.

#### The first clipboard look is a baseline whatever it holds
`a_fresh_related_copy_joins_the_prompt_only_with_its_grant`: The first look is a baseline, whatever it holds.

#### A word still being typed goes to the model; no correction means nothing
`a_typo_is_offered_before_the_model_and_counts_when_fixed`: A word still being typed goes to the model; no correction means
nothing at all.

#### Forgetting is the user's choice and clears the blocked store
`a_store_that_cannot_open_says_so_and_is_never_written_over`: Forgetting is the user's choice, and clears the way.

#### Sealed file layout is nonce, ciphertext, tag matching the Mac's AES.GCM combined box
`a_sealed_file_opens_only_with_its_key_and_is_otherwise_left_alone`: nonce, ciphertext, tag: the Mac's `AES.GCM.SealedBox.combined`.

#### Another key, no store or damage is blocked, never read as empty
`a_sealed_file_opens_only_with_its_key_and_is_otherwise_left_alone`: Another key (a Mac's), no reachable store, or damage: never empty.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
