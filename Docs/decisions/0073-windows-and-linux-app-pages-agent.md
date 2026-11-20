# 0073. Windows and Linux: app — pages / agent

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-app/src/pages/agent/`.

## Decisions

### `LinuxWindows/crates/lokalbot-app/src/pages/agent/approval.rs`

#### Approval card: commands and LokalBot-data files get Deny and Allow once only
The approval card above the composer (`AgentApprovalDock.swift`): a
question that names its file or command, what will happen and where, the
first lines to review, then Deny apart from the answers that allow. A
command gets Deny and Allow once only, and so does a file inside
LokalBot's own data.

#### A command runs in the folder its request came from
`AgentPage::approval_card`: A command runs in the folder its request came from.

#### Preview height leaves room for conversation in small windows
`AgentPage::render_approval_dock`: Room for the whole preview once it is opened, without taking the
conversation above it in a small window.

#### Escape denies first waiting approval of selected task
`AgentPage::deny_visible_approval`: Escape denies the first waiting approval of the selected task.

### `LinuxWindows/crates/lokalbot-app/src/pages/agent/composer.rs`

#### Message sent while agent works is queued above field until turn ends
The composer (`AgentComposer.swift`): what the agent is told to do, what
to attach, the working folder and how much it may do on its own. A message
sent while the agent works waits above the field until the turn ends.

#### Reasoning levels asked once per model; later tasks offer them
`AgentPage::look_up_reasoning`: Asks the Think server what the selected model accepts, once per model
(`AgentComposer`). A task started afterwards offers those levels.

#### Queue shows up to three rows whole, longer scrolls
`AgentPage::render_queue`: Up to three rows show whole; a longer queue scrolls in the same space.

#### While working, Send queues the message; Ctrl+Enter steers
`AgentPage::render_surface`: While the agent works, Send queues the message (Ctrl+Enter steers).

#### Destination line only when model is off this computer so prompt destination stays visible
`AgentPage::render_destination_line`: Shown only when the model is not on this computer, so where a task's
prompts go stays in view without opening the access list.

#### New folder applies to empty unsaved task, otherwise starts a new task
`AgentPage::choose_workspace`: A new working folder applies to this task while it is empty and
unsaved; otherwise it starts a new task (`pickingFolder`).

#### Access level is one remembered choice for every task
`render_access`: The access list: the levels by what still asks, then the model and
reasoning. The level is one remembered choice for every task.

#### Raising access level is confirmed; lowering applies at once
`render_access`: Raising the level is confirmed; lowering it applies at once.

#### Offer only reasoning levels the model accepts, or Same as Think
`reasoning_menu`: Agent Mode's own level, or "Same as Think", offering only the levels the
model accepts.

#### Strip the \\?\ prefix on Windows so folder paths compare and display cleanly
`dunce_like`: Canonical folder paths (no `\\?\` on Windows) compare and display cleanly.

#### Escalating access level asks first
`confirm_mode`: Escalations ask first (`pendingMode` alert).

### `LinuxWindows/crates/lokalbot-app/src/pages/agent/conversation.rs`

#### Working agent steps fold to one line; finished turn folds into steps line above answer
One task (`AgentSessionView.swift`): a new task's heading and composer
mid-page, or the conversation with the composer docked under it. While
the agent works its words show in full and its steps fold to one line a
run; a finished turn folds its work into one steps line above its answer
and the files it changed. An approval request docks above the composer.

#### Snapshot is copied out of the model so rendering can borrow page mutably
`Snapshot`: What the conversation shows for the selected task, copied out of the
model so rendering can borrow the page mutably.

#### Starters mirror Swift AgentSessionView starters
`STARTERS`: `starters` in `AgentSessionView`.

#### A find match inside a folded run of steps opens that run
`AgentPage::scroll_to_match`: A match inside a folded run of steps opens that run.

#### User message actions Copy, Edit as follow-up, Branch live in its menu
`AgentPage::render_user`: The user's message on the trailing side; Copy, Edit as follow-up and
Branch from here are in its menu.

#### Agent text renders plain while streaming and formatted afterward
`AgentPage::render_text`: The agent's words, in full: plain while they stream, formatted after.

#### Finished turn's steps line counts steps and holds interim agent words
`AgentPage::render_steps`: A run of steps as one quiet line that opens to a row per step. A
finished turn's line counts its steps and holds what the agent said
between them.

#### Steps chevron follows reading direction when folded, down when open
`AgentPage::render_steps`: Points along the reading direction while folded, down once open.

#### Numbered reference opens attached source beside task; others do nothing
`AgentPage::open_cited_source`: A numbered reference opens its attached source beside the task, as
source links in macOS answers do; references to anything else do
nothing.

#### Answer link opens named source or tool result; other links do nothing
`AgentPage::open_answer_link`: A link in an answer opens the source or tool result it names beside the
task (`AgentSessionView`'s `openURL`); any other link does nothing.

#### Task error shows once as a toast instead of macOS alert
`AgentPage::show_task_error`: Task errors (`sessions.error`, an alert on macOS) appear as a toast once.

#### Reading column is centred with 20 px pane margins
`reading_column`: A row centred at the reading width, 20 px from the pane's edges.

#### Source links and bare moment ids become numbered reference markers
`cite_sources`: Agent answers cite attached sources by their identifiers, often as
Markdown links such as `[meeting:<id>](meeting:<id>)` or
`[Title](moment:<n>)`. The shared answer renderer shows `[meeting:<id>]`
and `[screen:<n>]` markers as numbered references, so links to a source
and bare moment ids become those markers.

#### Target forms map to meeting and screen reference markers
`source_marker`: `meeting:<id>[@m:ss]` → `[meeting:<id>[@m:ss]]`; `moment:<n>` or
`screen:<n>` → `[screen:<n>]`.

### `LinuxWindows/crates/lokalbot-app/src/pages/agent/dialogs.rs`

#### Context picker, saved sessions and rename dialogs mirror Swift views
Agent dialogs: attaching meetings and saved moments (`AgentContextPicker`),
browsing saved sessions (`AgentSessionHistoryView`) and renaming a task.

#### Dialogs are built during page update, so constructors take values instead of reading page
`AgentPage dialogs`: The dialogs are built while this page is being updated, so their
constructors take what they need from the page instead of reading it.

#### Saved sessions are searchable local pi history; Open reopens in original folder
`SavedSessions`: Searchable local history of pi sessions; Open reopens one in its
original working folder.

### `LinuxWindows/crates/lokalbot-app/src/pages/agent/mod.rs`

#### AgentModel does the work; the page view owns only presentation state
Agent (`AgentView.swift`): a local coding and file agent powered by the
selected Think model. Before setup the page explains Agent Mode and offers
"Set Up Agent Mode"; afterwards it shows the task list grouped by day, the
task (a new task's composer mid-page, or the conversation with its folded
steps, approval card and composer), and an optional results panel. The
task's title and status sit in the toolbar.

The work happens in [`model::AgentModel`] (the installer and the
`lokalbot-agent` task list); this view owns only presentation state.

#### Agent key bindings mirror AgentCommands.swift with Ctrl for Command
`bind_keys`: `AgentCommands.swift`, with Ctrl for ⌘.

#### Context picker opens only for @ at word start, not in addresses
`context_trigger`: The draft without its @, when an @ was just typed where a word starts
(`AgentComposer`: at the start, after a space or a new line). An address
such as me@example.com stays text.

#### Parsed answers are cached with a hash of their source text
`AgentPage.answers`: Parsed responses by item id, with the hash of the text they came from.

#### Typing @ opens the context picker instead of inserting the character
`AgentPage::new`: Typing @ asks for context instead of typing it.

#### Create the controller on first visit so unused Agent Mode never touches files
`AgentPage::ensure_model`: The controller is created on the first visit, so a library that
never uses Agent Mode never touches its files.

#### Prompt requests go into selected draft, wait for setup, and are never sent
`AgentPage::take_request`: Acts on what another page or the palette asked for. A prompt goes into
the selected task's draft (`AppState.openAgent`), waits for setup, and is
never sent.

#### Typing writes draft; task-side draft changes are written back to composer
`AgentPage::sync_composer`: Keeps the composer showing the selected task's draft. Typing writes
the draft; a change made by the task (sent, restored, edited from the
queue) is written back into the composer.

#### Send queues while working; Ctrl+Enter steers the running turn
`AgentPage::submit`: Send, or while the agent works queue the message; with `steer`
(Ctrl+Enter) a message steers the running turn instead.

#### New task shows no status word because list row says Not started
`AgentPage::title_control`: A new task needs no word beside its title; the list row says "Not started".

#### Only finished tasks count changed files because counting reads disk
`task_status`: Where a task stands. Only a finished task counts its changed files;
counting reads the disk.

### `LinuxWindows/crates/lokalbot-app/src/pages/agent/model.rs`

#### Controller created on first Agent page open; stops every agent on quit
The Agent page's controller (`AgentRuntimeInstaller` + `AgentSessionTabs`
as `AppState` owns them on macOS): Agent Mode setup and the task list,
driven on the UI thread by each task's inbox. Created the first time the
Agent page opens; stops every agent when LokalBot quits.

#### On quit agents are asked to stop together, then killed; process tree never outlives app
`AgentModel::new`: Every agent is asked to stop at once, then whatever is left
is killed; the process tree never outlives LokalBot.

#### Cheap receipt check here; deep audit runs before each launch
`AgentModel::check_receipt`: The cheap receipt check (the deep audit runs before each launch).

#### A pi left by a crashed LokalBot is stopped first
`AgentModel::check_receipt`: A pi left by a crashed LokalBot is stopped first.

#### Repair stops every agent first because running Bun keeps files open on Windows
`AgentModel::install`: "Set Up Agent Mode" / "Repair Agent Mode". Repair stops every agent
first: a running Bun keeps its files open on Windows.

#### Failed runtime audit parks every task until repaired
`AgentModel::verify`: "Verify Agent runtime…": hashes every runtime file. A failed audit
parks every task until the runtime is repaired.

#### Settings reach new launches; reasoning change reaches running agents next model call
`AgentModel::sync_settings`: Settings changes reach new launches; a reasoning change also reaches
running agents from their next model call.

### `LinuxWindows/crates/lokalbot-app/src/pages/agent/results.rs`

#### Results panel shows files, steps, sources and preview; opening preview never runs a tool
Results (`AgentResultsPanel.swift`): beside the conversation, the files
the task changed, its steps, the sources it was given, and a preview of
whichever one is chosen. Opening a preview never runs a tool.

### `LinuxWindows/crates/lokalbot-app/src/pages/agent/setup.rs`

#### Setup card downloads nothing until user explicitly asks
The setup card (`AgentView.installCard`): what Agent Mode is, what setup
downloads, and the explicit "Set Up Agent Mode" action. Nothing is
downloaded until the user asks.

#### Description wraps in logical order so Arabic and Urdu stay in column
`AgentPage setup card`: Wrapped in logical order, so Arabic and Urdu stay
inside the column.

### `LinuxWindows/crates/lokalbot-app/src/pages/agent/sidebar.rs`

#### Sidebar groups tasks by day; refresh, saved sessions, runtime check live in the menu
The task list (`AgentTaskSidebar.swift`): search and New on top, tasks
grouped by day with their status and time, and Archived at the bottom.
Refresh, saved sessions, the runtime check and clearing history are in
the … menu beside Archived.

#### Status icons mirror Swift AgentTaskStatus.symbol
`status_icon`: `AgentTaskStatus.symbol`.

### `LinuxWindows/crates/lokalbot-app/src/pages/agent/words.rs`

#### Words mirror AgentPresentation.swift; rules live in lokalbot_agent::presentation
The words the Agent page shows (`AgentPresentation.swift`): each step in
plain words, the steps line, where a task stands, a changed file's line,
the access levels and the approval card. The rules behind them (layout,
status, changed files) are in `lokalbot_agent::presentation`.

#### Flag keeps capitals when words begin with a file or tool name
`StepLabel.begins_with_name`: The words begin with a file or tool name, whose capitals must stay.

#### A step still running when its task stopped never finished
`StepLabel::text`: The words for a step in the given state. A step still running when
its task stopped never finished.

#### Right-to-left translation can begin with the name
`named`: A right-to-left translation can begin with the name.

#### Only plain lokalbot-cli lookups get names; anything chainable shows command text
`command_label`: `lokalbot-cli` calls made of plain words get a name for what they look
up. Anything a shell could chain or redirect is a command, shown with its
text, so a label never hides what ran.

#### Summary lists each different step once, lowercasing later items except names
`steps_summary`: "Searched meeting library, read meeting notes": each different step
once, in order. `lowercase_following` suits languages that write a list's
later items without a capital; names keep theirs.

#### English writes later list items without a capital
`lowercases_list_items`: English writes a list's later items without a capital.

#### Toolbar word is omitted for a saved task doing nothing
`status_title`: The word for the toolbar. A saved task that is doing nothing shows none.

#### No label when history does not say what the write did
`change_label`: "New file", or nothing when history does not say what the write did.

#### Day groups show time; pinned task from another day shows date
`row_time`: A day group already names the day, so its rows show the time. A pinned
task from another day shows the date.

#### Full access runs commands unasked, so it uses the caution colour
`needs_caution`: Full access runs commands unasked, so it is drawn in the caution colour.

#### Lookups skip approval only with a model on this computer
`level_detail`: Lookups skip approval only with a model on this computer (policy.rs).

#### Full path shown with caution when file is outside working folder
`ApprovalCard.caution`: The full path, shown with a caution when the file is not in the
working folder.

#### Destination shown only when the model is not on this computer
`ApprovalCard.destination`: Where the result goes when the model is not on this computer.

#### Allow for this task offered only when policy permits it
`ApprovalCard.task_answer`: "Allow writes for this task", when the policy lets this request be
allowed that way.

#### File tool always names its file; otherwise shown as the tool
`ApprovalCard::new`: A file tool always names its file; one that does not is shown as the tool it is.

#### Question says what happens to file; separate line says where it is
`ApprovalCard::new`: The question says what happens to the file; this line where it is.

#### Right-to-left translation can begin with file or folder name
`ApprovalCard::new`: A right-to-left translation can begin with the file's or folder's name.

#### Test paths must be absolute per OS; on Windows /etc/hosts is on current drive
`file_steps_name_the_file_and_its_folder`: A file outside the workspace shows its full folder. The path must be
absolute on each system: on Windows "/etc/hosts" is on the current drive.

#### Test: label never hides what ran; chainable or redirecting commands show text
`other_commands_show_their_text`: A label never hides what ran: anything a shell could chain or redirect
is a command, shown with its text.

#### Test: translations putting file name first keep its capitals
`the_summary_names_each_different_step_once`: Where a translation puts the file name first, its capitals stay.

#### History does not say whether a written file existed before
`a_changed_file_says_what_happened_how_long_and_where`: History does not say whether a written file was there before.

#### A write's text stays in the approval until the agent reads something back
`a_command_and_other_tools_show_exactly_what_will_run`: A write's text stays here until the agent reads something back.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
