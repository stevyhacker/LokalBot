# 0083. Windows and Linux: app — windows

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-app/src/windows/`, `LinuxWindows/crates/lokalbot-app/src/windows/onboarding/`, `LinuxWindows/crates/lokalbot-app/src/windows/quick_recall/`.

## Decisions

### `LinuxWindows/crates/lokalbot-app/src/windows/agent_setup.rs`

#### Agent setup window: Allow enables settings access and ticked reads; Don't Allow leaves all off
The agent setup window (`AgentSetupView.swift`): an agent ran `lokalbot-cli
setup start` and asks to set LokalBot up for the person. Allow turns on
settings access and any read access the person ticks; Don't Allow leaves
everything off.

#### A new setup request starts with nothing ticked
`AgentSetup nonce change`: A new request starts with nothing ticked.

### `LinuxWindows/crates/lokalbot-app/src/windows/mod.rs`

#### Keep secondary window handles so windows are reused, not stacked
`SecondaryWindows`: Handles of the secondary windows, so they are reused instead of stacked.

#### Use Wayland layer surface for floating popups; GNOME lacks layer shell so fall back
`layer_surface`: A Wayland layer surface for a window that floats above the others.
Wayland compositors place ordinary windows themselves, and tiling ones
(Hyprland, Sway, Omarchy) would put a popup in the layout. `None` outside
Wayland. GNOME has no layer shell, so opening one fails there and the
caller falls back to an ordinary window.

#### Open floating window after a LokalBot window has focus so GPUI parents it
`when_focused`: Runs `open` once one of LokalBot's windows has the keyboard, so a window
opened as `WindowKind::Floating` gets it as its parent: GPUI parents such
a window to the focused one. A main window that has only just opened gets
the keyboard a moment later. Runs at once when no window is open, and
after [`FOCUS_WAIT`] without a parent.

#### Reopen main window when closed to tray
`activate_main`: Brings the main window forward, reopening it when it was closed to the tray.

### `LinuxWindows/crates/lokalbot-app/src/windows/onboarding/access.rs`

#### Linux/Windows lack permission prompts; rows show observable state, unknowable ones claim none
Setup, step 2 (`OnboardingAccessStep.swift`): only what the choices need,
each row naming the feature it serves, why, and where it stands. Linux and
Windows have no permission prompts like macOS: each row shows what this
computer can be seen to allow (`lokalbot_platform::access`), and a row
whose state can't be known before the feature runs claims none.

#### Which permissions each setup choice needs, mirroring OnboardingAccess.permissions
`permissions`: The microphone always (Record uses it even with detection off), window
titles for the workday, accessibility once it keeps text, and screenshots
with their key only for screenshots (`OnboardingAccess.permissions`).

#### Allowed count excludes rows of unknown state; none if all unknown
`allowed_count`: "2 of 3 allowed", counting only rows whose state is known; `None` when
no row's is.

#### Test: unknown screenshot row counts neither as allowed nor denied
`rows_carry_what_the_desktop_reports`: The unknown screenshot row counts neither way.

### `LinuxWindows/crates/lokalbot-app/src/windows/onboarding/choose.rs`

#### Setup step 1 mirrors OnboardingChooseStep: local-only promise and choices with one real option
Setup, step 1 (`OnboardingChooseStep.swift`): what LokalBot does, that it
stays on this computer, and the choices, each with its one real option.

#### Port wording differs from Mac: private windows' text and images never captured
`retention_note`: The retention sentence under the choices, for every workday choice. The
port's wording, because it differs from the Mac: private windows' text
and images are never captured here.

#### A server configured before setup was reopened is named for what it is
`welcome lock note`: A server set up before setup was reopened is named for what it is.

#### Retention note shown for every workday choice as what the person agrees to
`retention_note placement`: Shown for every workday choice: it is what the person agrees to
before picking more.

### `LinuxWindows/crates/lokalbot-app/src/windows/onboarding/download.rs`

#### Download step shows sizes and free space; nothing downloads until Download pressed
Setup, step 3 (`OnboardingDownloadStep.swift`): each model's job and size
and the free space before anything downloads, then progress per model
and overall, with the time left once the speed is known. Nothing
downloads until Download is pressed.

#### Disk headroom must match DiskSpacePrecheck.headroomBytes on the Mac
`HEADROOM_BYTES`: Slack a download needs beyond its own size (`DiskSpacePrecheck.headroomBytes`).

#### Session mirrors Mac OnboardingDownloadSession shared by step and footer
`Session`: What the download step and its footer share while the window is open
(`OnboardingDownloadSession`).

#### Progress counts only models this download fetches, not preinstalled ones
`Session.ready_before`: What was on this computer when the download began, so progress counts
only what this download fetches.

#### Each model id is requested once until Retry clears the set
`Session.requested`: Ids this window asked for, so each is asked for once until Retry.

#### Search embedding model is port-only; the Mac's is built in
`Role::Search`: Port-only: search by meaning's embedding model (the Mac's is built in).

#### Screen text recognition role is port-only, when workday keeps text
`Role::ScreenText`: Port-only: screen text recognition, when the workday keeps text.

#### Downloading progress is a fraction from 0 to 1
`ModelState::Downloading`: How far, 0…1.

#### Elsewhere means a model server does the work, nothing downloads
`ModelState::Elsewhere`: Nothing downloads for it here: a model server does the work.

#### llama.cpp runtime id attaches to the first role that needs it
`Model.ids`: What downloads for it, with the llama.cpp runtime on the first role
that needs it.

#### Stopped means a download failed while others may still run
`Phase::Stopped`: At least one download failed; others may still be running.

#### Screen text download reflects the draft's choice, not saved settings
`Inputs.screen_text`: What screen text recognition would download for the draft's choice.

#### Plan mirrors Mac OnboardingDownloadPlan
`Plan`: `OnboardingDownloadPlan`.

#### Autocomplete row listed while choosable and once part of the download
`Plan.models`: The rows, in order. Autocomplete is listed while it can still be
chosen and once it is part of the download.

#### Downloading is true also beside a stopped download
`Plan.is_downloading`: A download is running now, also beside one that stopped.

#### Free space is measured on the drive holding the library
`Plan.available_bytes`: Free space on the drive that holds the library.

#### Total counts only selected model bytes not present when download began
`Plan.total_bytes`: Bytes of the selected models that were not here when the download
began.

#### Runtime downloads with the first selected role that runs on it
`Plan::new`: The runtime downloads with the first selected role that runs on it.

#### After pressing Download, treat as Running before any progress state exists
`Plan::new`: Between the button and the first progress there is no state yet.

#### Overall fraction ranges 0 to 1 across the whole download
`Plan::fraction`: 0…1 across the whole download.

#### Fit check includes headroom and is true when free space unknown
`Plan::fits_on_disk`: Whether the download and the headroom it needs fit in the free space.
True when the free space is unknown.

#### Row weight is missing ids' bytes, or all of them once installed
`Plan::row_bytes`: What the row weighs: its ids still to come, or all of them once here.

#### Time left uses 30 s window, silent until a few seconds observed
`Estimator`: Time left for a download, from how fast the bytes arrived over the last
half minute. It says nothing until it has watched for a few seconds, and
nothing while no bytes arrive (`DownloadTimeEstimator`).

#### A retried download resets speed samples
`Estimator::record`: A retried download starts over, so earlier speeds no longer apply.

#### Time left shows whole minutes, never less than one
`Estimator::minutes_left`: Whole minutes, never less than one.

#### Downloads begun elsewhere count what is missing from first sight
`Onboarding::plan`: A download that began outside this window (before a relaunch, or
from Settings) counts what is missing from when it is first seen.

#### Meeting models go through PrepareModels, fetched one at a time
`Onboarding::start_download`: Asks for every selected model this computer lacks that this window
hasn't asked for yet. The meeting models go through `PrepareModels`,
which fetches them one at a time.

#### Sizes carry their unit so the amount pair reads the same in every language
`Onboarding::hero`: Sizes carry their unit, so the pair reads the same in every language.

#### Picking a download source only sets it; Download still starts the transfer
`Onboarding::before_notes`: Only where to download from: Download still starts it.

#### Footer mirrors Mac OnboardingDownloadFooterContent
`Onboarding::download_footer`: Skip and "Download 5.9 GB" before anything downloads, then the way
into the app while it runs (`OnboardingDownloadFooterContent`).

#### Sample opens now or when models land; setup already requested them
`open_sample_when_ready`: Opens the sample meeting now when its models are here, or once they land
(`openSampleMeetingWhenReady`). Nothing more downloads for it: setup's
download already asked for its models.

#### Offer HF-Mirror and ModelScope where huggingface.co is blocked in mainland China
`shows_download_source`: huggingface.co is blocked in mainland China, so the first download offers
HF-Mirror and ModelScope there: on a computer set to that region or to
Simplified Chinese, or once a mirror is already chosen. Settings → Models
always has the same picker.

#### Meeting models are what engine PrepareModels fetches one at a time
`SetupDownloads.meeting`: What the engine's `PrepareModels` fetches, one at a time: Transcribe
with voice detection and speaker separation, Think, search by meaning
and the llama.cpp runtime.

#### Screen text and Autocomplete models are each requested on their own
`SetupDownloads.extra`: The rest, each asked for on its own: what the chosen screen text
needs, and Autocomplete's model when asked for.

#### PrepareModels leaves Autocomplete to its switch and screen text to settings
`setup_downloads`: `PrepareModels` leaves Autocomplete to its own switch, and screen text
to what the settings, not the draft, chose.

#### Disclosure text mirrors Mac OnboardingView for what Autocomplete reads
`autocomplete_disclosure`: What preparing Autocomplete means for what it reads (`OnboardingView`).

#### Settings-enabled Autocomplete or screen text is not downloaded by PrepareModels
`setup_downloads_split_what_prepare_models_fetches`: Autocomplete already on, or screen text already chosen in settings,
still isn't something `PrepareModels` downloads.

### `LinuxWindows/crates/lokalbot-app/src/windows/onboarding/mod.rs`

#### Setup keeps choices as draft until finish; unfinished setup resumes next launch
First-run setup (`OnboardingView.swift`): three steps under a labelled
stepper. Choices stay a draft until setup finishes. The access step only
reads what this computer allows, and nothing downloads until Download is
pressed. An unfinished setup reopens where it was on the next launch.

#### Setup window size matches Mac OnboardingView.size
`WIDTH`: The Mac's setup window (`OnboardingView.size`).

#### Linux client decorations add 20 px shadow per side to window bounds
`FRAME`: With client decorations on Linux the window's bounds include the shadow
GPUI Kit draws around it (20 px a side), so the content gets the Mac's size.

#### Floating window parent is the focused window, which is new on first launch
`open`: A floating window's parent is the focused window, and on first launch
the main window has only just opened.

#### Open welcome window Floating on tiling desktops so it floats centered
`window_kind`: Hyprland and Sway would tile the welcome window beside the main window.
Opened as `Floating`, it gets the main window as its parent, so they
float it, centered, at its own size. Other desktops place a normal window
themselves.

#### Recheck for existing window since it may open while waiting for main
`open_window`: It may have opened while `open` waited for the main window.

#### Steps mirror Mac OnboardingStep order
`Step`: Setup's three steps, in order (`OnboardingStep`).

#### Draft mirrors Mac CaptureSetupDraft, applied only when setup finishes
`Draft`: `CaptureSetupDraft`: the choices, applied only when setup finishes.

#### Master switch only; per-agent switches and exclusions stay in Settings
`Draft.coding_agent_sessions`: The master switch for reading Claude Code and Codex sessions. The
per-agent switches and folder exclusions stay with Settings.

#### Remember detected-call mode so toggling Meeting notes keeps the choice
`Draft.detected_call_mode`: What a detected call does while Meeting notes is on. The switch
returns to it, so turning it off and on keeps the choice.

#### Setup never picks a detected-call mode other than the install default
`Draft::default_detected_call_mode`: A new install's own choice; setup never picks a different one.

#### Finishing setup counts as the person's answer on coding agents
`Draft::apply`: Setup shows this choice, so finishing it is the person's answer.

#### Stop saving resume state once setup has finished
`Onboarding.saves`: False once setup has finished, so nothing more is saved for it.

#### Finished setup has nothing to resume; port never reopens after requested restart
`Onboarding::new`: A finished setup has nothing to resume: the port never reopens one
after a restart it asked for.

#### Access checks run off UI thread, repolled every few seconds, shared with Settings
`Onboarding::start_checks`: Reads what this computer allows, away from the UI thread, and again
every few seconds while the access step shows (`startPolling`). The
reading is `AppData`'s, the one Settings shows.

#### Sample meeting opens only if person saw that option after a download exists
`Onboarding::finish`: Applies the choices and ends setup. The sample meeting opens only
when the person saw that option, which is once a download exists.

#### Heading mirrors Mac OnboardingHeading
`heading`: A step's title with one lead sentence, centred (`OnboardingHeading`).

#### Row mirrors Mac OnboardingRow
`row`: One card row: a symbol tile, its text, and a control or state at the end
(`OnboardingRow`).

#### Note mirrors Mac OnboardingNote
`note`: A quiet line under a card: a small symbol and one sentence (`OnboardingNote`).

#### Done label mirrors Mac OnboardingDoneLabel
`done_label`: A green check with one word: Allowed, Ready (`OnboardingDoneLabel`).

### `LinuxWindows/crates/lokalbot-app/src/windows/onboarding/resume.rs`

#### Resume state stored beside library settings; reopens same step with unapplied choices
Where an unfinished setup was (`OnboardingResumeState`), kept next to the
library's settings so the next launch reopens setup at the same step with
the choices not applied yet.

#### Saved draft is stale when settings changed since it started
`ResumeState.baseline`: The choices the settings held when the draft was started. When the
settings have changed since, the saved draft no longer describes them.

#### Saved state is valid only when baseline equals current settings choices
`load`: The saved state, when it still belongs to settings whose choices are
`current`.

### `LinuxWindows/crates/lokalbot-app/src/windows/quick_recall.rs`

#### Quick Recall behaviour: grouped results, Ctrl+Return asks, Escape closes
Quick Recall (`QuickRecallView.swift`): the window Ctrl+K and the
system-wide shortcut open. Type to search meetings, screen history, files
and agent notes, run a command, or ask. Results are grouped by kind, three
of each with Show all. Return opens the selected row; Ctrl+Return asks, and
the answer shows here with numbered sources and Continue in main window.
Before anything is typed it lists recent items and every command. Escape
or leaving the window closes it.

#### Quick Recall window size matches Mac QuickRecallView.size
`WIDTH`: The window (`QuickRecallView.size`).

#### Reopening brings existing window forward with its text selected
`open`: Opens Quick Recall from the system-wide shortcut, the tray or the command
line, or brings the open window forward with its text selected.

#### From main window, Ctrl+K also offers page commands; repeat keeps origin
`open_from_shortcut`: Ctrl+K. Opened from the main window, the window also offers the commands
of the page it shows (`quickRecallOpenedFromMainWindow`). Pressing it again
inside the window keeps what it was opened from.

#### Windows uses PopUp tool window; X11 focus needs managed Normal window
`open_from`: Windows takes a borderless, topmost tool window; X11 only gives
keyboard focus to managed windows, so Linux uses a normal one.

#### Wayland uses centered exclusive layer surface so tiling compositors do not split
`open_from`: On Wayland, a centered layer surface that takes the keyboard: a tiling
compositor would otherwise split the screen with it.

#### Opened from main window also offers its page's commands
`QuickRecall.in_workspace`: Opened with Ctrl+K from the main window: the commands of its page are
offered too.

#### Groups expanded in place when heading asked to list everything (commands)
`QuickRecall.expanded`: Groups whose heading was asked to list everything here (commands).

#### Ctrl+Return during matching waits for matches to finish
`QuickRecall.pending_question`: Ctrl+Return arrived while a word's matches were still being found.

#### Leaving Quick Recall dismisses it, like the macOS panel
`QuickRecall::new`: Like the macOS panel, leaving Quick Recall dismisses it.

#### Commands include main window page's when opened from there
`QuickRecall::commands`: Every command, those of the main window's page included when it was
opened from there.

#### Groups mirror Mac QuickRecallContent.groups
`QuickRecall::groups`: The groups on show (`QuickRecallContent.groups`).

#### Recent list omits meetings merged into another; the target is listed
`QuickRecall::groups`: The newest meetings; one merged into another is listed by it.

#### Selectable count mirrors Mac model::selectable_rows
`QuickRecall::selectable_count`: Rows Return may land on as a list appears (`model::selectable_rows`).

#### Word matches first, meaning refinement second so results show at once
`QuickRecall::search`: Meaning second, so words show at once.

#### Arrows cycle rows and Ask row; inside an answer the field keeps them
`QuickRecall::move_selection`: Up and Down go round the rows and the Ask row. Inside an answer the
field keeps them.

#### Recording and dictation act on previous app, which regains keyboard on close
`QuickRecall::run`: Recording and dictation act on the app the person came from,
which gets the keyboard back as this window closes.

#### Show all lists commands in place; other kinds open Ask narrowed to source
`QuickRecall::show_all`: "Show all N": commands list here; a kind of result opens Ask on this
search, narrowed to that kind's source.

#### From results ask starts a conversation; in an answer a scoped follow-up
`QuickRecall::ask`: Asks here. From the results this starts a new conversation; inside an
answer it is a follow-up within the scope of the question before it.

#### Show an in-flight answer instead of dropping the key
`QuickRecall::ask`: An answer is already being written (asked here or in the main
window): show it instead of dropping the key.

#### Send no follow-up until the prior question's scope is known
`QuickRecall::ask`: Until the question before it is known, nothing is sent.

#### Short phrases wait for listed matches; full questions do not
`QuickRecall::ask`: A word or short phrase is answered from its matches, so it waits for
them. A full question does not depend on what is listed.

#### Both windows share the conversation; opening it never re-asks
`QuickRecall::continue_in_main_window`: Both windows share the conversation; opening it never asks again.

#### Draw group heading inside first row element because scroll reveals by child index
`QuickRecall::render_results`: The scroll handle reveals rows by child index, so a group's heading
is drawn inside its first row's element.

#### No-match line is quiet beside commands, fuller when alone
`QuickRecall::render_no_matches`: Nothing in memory matched. Under matching commands it is one quiet
line; alone it also says what was searched.

#### Ask row pinned under results; Ctrl+Return asks from anywhere
`QuickRecall::render_ask_row`: Pinned under the results. Ctrl+Return asks from anywhere in the window.

#### Answer foot mirrors Mac QuickRecallAnswerFoot
`QuickRecall::render_answer_foot`: The foot of an answer: where it was answered and what it read, Copy,
and the way into the full Ask screen (`QuickRecallAnswerFoot`).

### `LinuxWindows/crates/lokalbot-app/src/windows/quick_recall/answer.rs`

#### Answer view built separately from Ask page; shares parser, renderer, scope
The answer inside the Quick Recall window (`ChatTranscriptView` in its
compact style, `QuickRecallAnswerSources`): each question under "You" and
its time, the answer, and its sources as numbered rows laid out like the
window's results, with the passage quoted and the question's words marked.
Opening a source shows it in the main window, or in its own app for a file
or an agent note. It reads the conversation the engine saves and the
answer being written; it never asks anything itself.

Built on its own rather than on the Ask page, so the window keeps working
while Ask changes; what it shares with Ask is the citation parser, the
answer renderer, the question scope and the sources menu's words for it.

#### Fixed id for the answer being written before engine saves it
`STREAM_ID`: Id of the answer being written before the engine saves it.

#### Opening a source closes window, raising main window when source shows there
`AnswerEvent`: A source was opened from the answer: the window closes, bringing the main
window forward when that is where the source shows.

#### Saved conversation exists only once the engine has written it
`QuickRecallAnswer.conversation`: The conversation as saved, once the engine has written it.

#### Hold asked scope until saved conversation records it
`QuickRecallAnswer.asked_scope`: What the question asked from this window was limited to, until the
saved conversation says it.

#### None marks transcript still loading for the quoted line
`QuickRecallAnswer.transcripts`: Cited meetings' transcripts, for the quoted line; `None` while loading.

#### Cited line is last one started by then; mirrors Mac CitationPassage
`TranscriptLines::line_at`: The line said at `seconds`: the last one that started by then
(`CitationPassage.line(at:)`).

#### Reads run off UI thread; stale earlier-started reads are discarded
`QuickRecallAnswer::reload`: Reads the saved conversation off the UI thread. A read that started
earlier and finished later is out of date.

#### Follow-up scope is None until known, never a wider guess
`QuickRecallAnswer::follow_up_scope`: What a follow-up asks within: the latest question's scope
(`currentQuestionScope`). `None` until it is known, rather than a wider
guess.

#### Latest answer is available only once written; mirrors Mac foot
`QuickRecallAnswer::latest_answer`: The text of the answer that ends the conversation, once it is written
(`QuickRecallAnswerFoot.latestAnswer`).

#### Remember receipts need no model, so foot names no place
`QuickRecallAnswer::ends_with_receipt`: A "Remember …" receipt was saved without any model, so the foot names
no place.

#### Scope label is All sources, one meeting title, or counts
`QuickRecallAnswer::scope_label`: What the last question was limited to: "All sources", one meeting's
title, or how many meetings and screen moments.

#### Files and notes resolve only while their settings are on, as in Ask
`QuickRecallAnswer::load_sources`: Reads what the citations point at and is not known yet, off the UI
thread. Files and agent notes resolve only while their own settings
are on, as on the Ask screen.

#### Unreadable transcript leaves the quoted line empty
`QuickRecallAnswer::load_sources`: A transcript that can't be read leaves the line empty.

#### Remember statement shown as said, saved without any model
`QuickRecallAnswer::render_answer`: A "Remember …" statement saved as said, without any model.

#### Source rows numbered as in answer; mirrors Mac QuickRecallAnswerSources
`QuickRecallAnswer::render_sources`: The sources under an answer: a row per citation, numbered as in the
answer (`QuickRecallAnswerSources`).

#### Missing source shows kind name with nothing to open; mirrors placeholderTitle
`Source::missing`: A source still loading, gone from this computer, or not read now: its
kind's name, and nothing to open (`placeholderTitle`).

#### Stopped-turn text detection mirrors Mac isStoppedTurn
`is_stopped`: A stopped turn's text (`isStoppedTurn`).

#### Strip search excerpt marks so quote marks the question's words instead
`strip_marks`: A search excerpt's «» marks, so the quote marks the question's words instead.

### `LinuxWindows/crates/lokalbot-app/src/windows/quick_recall/model.rs`

#### Model only lists and selects; it never searches, stores or sends
What the Quick Recall window lists and where its keyboard is
(`QuickRecallResults.swift`): results grouped by kind and capped, the
recent items shown before typing, the selection, and what an answer asked
from the window reads. Nothing here searches, stores or sends anything.

#### Cap rows per kind at 3 because many screen matches hid meetings
`ROWS_PER_KIND`: Rows of one kind listed before "Show all". A large number of screen
matches used to push every meeting out of view.

#### Saved moments read serve the recent list and saved-match marking
`SAVED_MOMENTS`: Saved moments read for the recent list and to mark saved matches.

#### Variant order is the order the window lists groups
`GroupKind`: The kind of a group of rows, in the order the window lists them.

#### Commands matching only inside a word are listed last
`GroupKind::LooseCommands`: Commands that only hold the typed words inside a word: listed last.

#### Show all narrows Ask to source; commands list in place, recents never cut
`GroupKind::ask_source`: The Ask source a "Show all" link narrows the Ask page to
(`QuickRecallGroup.Kind.askSource`). Commands are listed in place
instead, and recent items are never cut.

#### Group mirrors Mac QuickRecallGroup
`Group`: One group of rows under a heading (`QuickRecallGroup`).

#### Capped means search hit its limit so total is a floor
`Group.capped`: The search stopped at its own limit, so `total` is a floor.

#### Show 40+ when capped, never an inexact count as exact
`Group::total_label`: "7", or "40+" when the search stopped at its limit: never a count that
reads as exact when it is not.

#### Loose commands go last so a word inside a name doesn't take Return
`Found.loose_commands`: Commands that only hold the typed words somewhere. They are listed
last, so a search word that happens to sit inside a command's name
does not put that command under Return.

#### Saved moments can fold two sources into one row, hiding truncation
`Found.screen_source_count`: Screen sources the search listed. Saved moments can fold two of them
into one row, so the rows alone can hide that the list was cut.

#### Fixed group order; empty groups omitted; agent notes only when source is on
`groups`: The groups for a typed search, in a fixed order: commands (only when the
typed words start words of one), meetings, screens, files, agent notes
while that source is on, then commands that only hold the words. Empty
groups are left out. `expanded` lists the kinds whose heading was asked to
show everything in place.

#### Commands are counted, never capped by the search limit
`groups`: Commands are counted here, never cut by a search limit.

#### Return never selects loose commands so a stray word can't start recording
`selectable_rows`: The rows Return may land on as a list appears: every row but the commands
that only hold the typed words inside a word. Those come last, and when
nothing else is listed none is selected, so Return never runs one ("cord"
must not start a recording); the arrow keys still reach them.

#### Recents merge meetings and moments newest first; ties list meeting first
`recent`: Recent meetings and saved screen moments as one list, newest first
(`QuickRecallRecent.rows`). A meeting and a moment of the same instant list
the meeting first.

#### Cursor mirrors Mac QuickRecallCursor; Return opens row or asks on Ask row
`Cursor`: Where the keyboard is in the list: on a row, or on the Ask row pinned
under the results (`QuickRecallCursor`). Return opens a row and asks on
the Ask row; Ctrl+Return asks from anywhere.

#### None selection makes Return do nothing instead of asking by surprise
`Cursor.index`: The selected position: rows first, then the Ask row. `None` when
nothing is selected, so Return does nothing instead of asking by
surprise.

#### Select first row if any; Ask row waits for arrow or Ctrl+Return
`Cursor::reset`: The first row is selected when there is one. With no rows nothing is,
and the Ask row waits for an arrow key or Ctrl+Return.

#### Keep Ask row selected as rows above it change
`Cursor::select`: Keeps the Ask row selected when the rows above it change.

#### Words limit to listed matches; full questions read all; matches Ask's AnswerScope
`ask_scope`: What an answer asked from Quick Recall reads (`QuickRecallAskScope`). A
word or a short phrase is a search the person then asks about: the answer
is limited to the listed meetings and screen moments. A full question
reads everything in every source; so does a "Remember …" statement, and a
search that listed no meeting or screen moment to limit it to. Which is
which is Ask's own rule (`AnswerScope`), so both decide alike.

#### Listed-matches scope mirrors Ask's selectEvidence: only meetings and screens
`ask_scope`: The same narrowing as Ask's handed-over matches (`selectEvidence`):
only meetings and screens, each to the listed ones.

#### Ask row claims listed matches while they are still being found
`reads_listed_matches`: Whether the Ask row should say the answer comes from the listed matches.
While a word's matches are still being found it does: the question waits
for them.

#### Place mirrors Ask composer inference, naming remote host
`place`: Where Think answers, as the Ask composer says it (`composer::inference`),
with the remote host named.

#### A plan uses its own approval entry, never a URL origin
`place`: A plan has its own approval entry, never a URL origin.

#### Name a remote model so nothing is sent by surprise
`ask_row_detail`: The Ask row's grey line: what the answer will read, and where it is
written. A remote model is named, so nothing is sent by surprise.

#### Foot shows where answered and what it read
`answer_foot_label`: The foot of an answer: where it was answered, then what it read ("All
sources", a meeting's title, "Meetings, Screen").

#### Scope wording matches Ask sources menu and Mac AskScopeSummary
`scope_label`: What a question was limited to, in the words the Ask screen's sources menu
uses: "All sources" or the sources by name; when it was bound to matches,
one meeting's title or how many meetings and screen moments
(`AskScopeSummary.narrowedTo ?? title`, with no filter).

#### Stop words mirror SearchIndex.stopWords so quotes never mark them
`STOP_WORDS`: Words the search index ignores (`SearchIndex.stopWords`), so a quote never
marks them.

#### Marked quote terms: three letters or more, each once
`quote_terms`: The words of a question worth marking in a source's quote: three letters
or more, each once (`QuickRecallQuote.terms`).

#### Mark words starting with a term in « » like search results
`marked`: `text` with each word that starts with one of `terms` between « and », so
a source's quote reads like a search result (`QuickRecallQuote.marked`).

#### Source quote is text around question words, cut to limit, marked
`quote_line`: A source's line under an answer: `text` around the question's words, cut
to `limit` characters, with those words marked (`QuickRecallQuote.line`).

#### Date label formats mirror Mac QuickRecallDateLabel
`date_label`: "Today 10:43 AM", "Yesterday 4:00 PM", "Wed 11:47 AM" within a week, else
"Sep 25" (or "Sep 25, 2025" in another year): `QuickRecallDateLabel`.

#### Agent notes group appears only while its setting is on
`groups_come_in_a_fixed_order_and_skip_empty_kinds`: Agent notes are a source only while their own setting is on.

#### Folded saved moments must still count as capped
`a_search_stopped_at_its_limit_reads_as_a_floor`: Saved moments folded two sources into one row: still capped.

### `LinuxWindows/crates/lokalbot-app/src/windows/quick_recall/rows.rs`

#### Row layout mirrors Mac QuickRecallRow: title, qualifier, when, matching line
One row of the Quick Recall window (`QuickRecallRowModel.swift`,
`QuickRecallRow.swift`): a meeting, a screen moment, a file, a saved agent
note or a command. Line one is the title, a grey qualifier (the app, the
folder, a meeting's length) and when; line two is the matching line,
starting with who said it for a meeting.

#### Lead tile size matches Mac QuickRecallLeadView.size
`LEAD_WIDTH`: A row's leading tile (`QuickRecallLeadView.size`).

#### Saved moment named by note; untitled window named by app, not twice
`RowModel::screen`: A screen moment: a saved one by its note, otherwise its window. A
window without a title is named by its app, which is then not said
twice.

#### Meeting line lead is speaker for transcript hits; mirrors Mac meetingLead
`meeting_lead`: What starts a meeting's matching line: the speaker of a transcript line
when the hit names one, otherwise where the words are. A title match
needs neither (`QuickRecallRowModel.meetingLead`).

#### File lead is PDF page or recording time; mirrors Mac fileLead
`file_lead`: Where in the file the matching line is: a PDF's page, or the time in a
recording or video (`QuickRecallRowModel.fileLead`).

#### Flattened list order is the keyboard order
`flatten`: The rows of `groups` in list order, which is the keyboard's order.

#### Answer sources share row text lines, adding meeting time after title
`row_text`: The two text lines of a row. An answer's sources use the same lines, with
a meeting's time after the title (`accessory`).

#### Reserve Return mark slot always so selection never reflows lines
`return_hint`: The Return mark at the end of the selected row. Its slot is always
reserved, so selection never reflows a line.

#### Heading right padding ends where a row's when ends
`group_header`: Ends where a row's "when" ends.

#### Ask row mirrors Mac QuickRecallAskRow; Return asks once selected
`ask_row`: The quiet row pinned under the results (`QuickRecallAskRow`). Ctrl+Return
asks from anywhere; Return asks once the arrow keys are on this row.

### `LinuxWindows/crates/lokalbot-app/src/windows/screen_image.rs`

#### Decrypted screen pixels live only in window memory, never exported or written
A captured screen at full size (`ScreenImageViewer.swift`). The decrypted
pixels live only in this window's memory: nothing is exported or written
to disk, and closing the window releases them.

#### Decode image to max longest side (0 full) off UI thread
`load`: Decrypts and decodes a moment's image, at most `max` pixels on its
longest side (0 keeps the full size). Runs off the UI thread.

#### GPUI draws BGRA so swap red and blue channels
`load`: GPUI draws BGRA.

### `LinuxWindows/crates/lokalbot-app/src/windows/selection_actions.rs`

#### Selection panel mirrors Mac view, 620x460, all data forgotten on close
The selection actions panel (`SelectionActionsView.swift`): the selected
text and where it came from, the actions that fit it, and the streamed
result with ways to use it. A 620×460 window; everything it shows comes from
the engine and is forgotten when it closes.

#### Windows uses PopUp tool window; X11 focus needs managed Normal window
`open`: Windows takes a borderless, topmost tool window; X11 only gives
keyboard focus to managed windows, so Linux uses a normal one.

#### Typed instructions read meetings and work memory unless turned off
`SelectionActions.instruction_uses_memory`: Typed instructions read matching meetings and work memory unless this
is turned off.

#### A new press with panel open resets query and selection
`SelectionActions::new`: A new press with the panel still open starts over.

#### Any window close sends PanelClosed so the selection is dropped
`SelectionActions::new`: However the window goes away, the selection goes with it.

#### Input focused while choosing; panel takes Enter and shortcuts for results
`SelectionActions::focus_for_phase`: The input while choosing; the panel itself takes Enter and the
shortcuts while a result shows.

#### Built-in action titles are translated; typed instructions stay as the user wrote
`action_title`: Built-in titles are interface text; a typed instruction is the user's.

### `LinuxWindows/crates/lokalbot-app/src/windows/settings.rs`

#### Settings opens in one separate window via AppData::open_settings
Settings in its own window, as on the Mac (`Window("Settings", id:
"settings")`): Ctrl+, the sidebar's Settings row, the tray, the command
palette, links from pages, notifications and `lokalbot-cli open settings`
open it or bring it forward, so the main window stays on your work. There
is one at a time. It opens on `AppData::settings_category`; everything
reaches it through `AppData::open_settings`.

#### Settings window sizes mirror the Mac SettingsView.defaultSize and minimum
`WIDTH/HEIGHT/MIN_WIDTH/MIN_HEIGHT`: `SettingsView.defaultSize` and its minimum.

#### Call AppData::open_settings, not open, so the page is picked too
`settings::open`: Opens the Settings window, or brings it forward. Call
`AppData::open_settings` instead, which also picks the page.

#### Run an action on Settings, opening it first, for questions beside a page
`settings::with_window`: Runs `action` on the Settings window, opening it first when it is closed:
for a question that belongs beside a Settings page, such as a phone
asking to pair.

#### The page draws the window bar itself, like the Mac, and the strip moves the window
`SettingsWindow::render`: The page draws the window's bar itself, over its right side, as
the Mac's runs to the top edge beside the category list: back,
forward and the page's name, with the window's buttons. The strip
above the list's search moves the window too.

### `LinuxWindows/crates/lokalbot-app/src/windows/settings_approval.rs`

#### Only the approval window can approve; Deny changes nothing; no key press approves
The approval window (`SettingsApprovalView.swift`): one card for each terminal
request waiting for the person, listing every change it makes in full. Approve
applies exactly those changes through the same paths as Settings; Deny changes
nothing. Only this window can approve, and no key press does it.

#### Track whether a request was shown so the window closes after the last
`SettingsApproval.showed_request`: Whether this window has shown a request, so it can go with the last one.

#### Window closes once the last request it showed is gone
`SettingsApproval::new`: The window goes away with the last request it was showing.

#### Show every value in full because it is what the person approves
`SettingsApproval card rows`: Every value in full: this is what the person approves.

#### Counts match the Settings retention review; approving deletes exactly this
`retention_lines`: The same counts the retention review in Settings shows. Approving deletes
exactly this.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
