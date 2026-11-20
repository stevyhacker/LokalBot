# 0075. Windows and Linux: app — pages / meetings

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-app/src/pages/meetings/`.

## Decisions

### `LinuxWindows/crates/lokalbot-app/src/pages/meetings/detail.rs`

#### Meeting detail layout: pinned player, 24px gutters, panels per Summary section
A saved meeting's page (`MeetingWorkspaceView.swift`, v2): one compact
title block and the player pinned above content that fills the pane with
24px gutters. Summary is a recap lead panel, Decisions, Actions (For you /
For others), Open questions and a closed Full summary panel; Notes is one
panel with the save status in its footer. The Transcript tab is in
`transcript.rs`, the naming sheet in `naming.rs`.

#### Sample meeting setup holds the pane until models arrive or cancel
`MeetingsPage::render_detail`: "Try a sample meeting" holds the pane until its models are here or it is cancelled.

#### Title, speakers and player stay fixed; only tab content scrolls
`MeetingsPage::render_detail`: The title, who spoke and the player stay put on every tab; only
the tab's content scrolls beneath them.

#### Unnamed voices are named from the title block
`MeetingsPage::render_title_block`: The meeting's one title: name, a date line, and who spoke. Unnamed
voices are named from here (`MeetingDetailHeader`).

#### Date-line parts need the right-to-left mark to keep Arabic numbers
`MeetingsPage::render_date_line`: Each part is its own line: "25 دقيقة" keeps its number in
Arabic only with the right-to-left mark (as page search sees it).

#### Status lines follow the Mac's order
`MeetingsPage::render_status`: The status lines above the tab's content, in the Mac's order
(`meetingStatusContent`).

#### Empty first summary explains what will appear; refresh keeps earlier summary
`MeetingsPage::render_stage`: With nothing written yet, say what will appear and offer
the transcript meanwhile. A refresh keeps the earlier
summary below.

#### Refresh offered only after name changes; destination shown as consent boundary
`MeetingsPage::render_refresh_banner`: Offered only after speaker names changed. The summary written before
the change stays on the page until the refresh finishes. Where the
refresh runs is said beside the button, as the consent boundary is.

#### Previous notes shown during a refresh cannot change action status
`MeetingsPage::render_action`: Previous notes kept on screen during a refresh can't change state.

#### Owner chip turns amber while owner is missing or an unnamed voice
`MeetingsPage::owner_chip`: Someone else's action carries its owner as a small menu; it turns
amber while the owner is missing or still an unnamed voice
(`MeetingActionOwnerMenu`).

#### Time plays from first appearance; capture opens in Timeline; address reopenable
`MeetingsPage::render_screen_materials`: `MeetingScreenMaterialsSection`. The time plays the recording from
when it first appeared, the capture opens in Timeline and a page whose
address was captured can be reopened.

#### Cap thumbnails at 32; later rows keep their icon
`MeetingsPage::screen_thumbnail.MAX`: A call shows few documents; later rows keep their icon.

#### Thumbnail load results are dropped if the meeting was left
`MeetingsPage::screen_thumbnail`: A meeting that was left meanwhile gave its entries up.

#### Release decrypted thumbnails when another meeting is shown
`MeetingsPage::release_screen_thumbnails`: Lets go of another meeting's pixels.

#### Play in place; without a recording show the transcript line
`MeetingsPage::play_in_place`: A ▶ time on a decision or action: play from there and stay on the
page. Without a recording, the line is shown in the transcript instead.

#### Show in transcript goes to the line without interrupting playback
`MeetingsPage::show_in_transcript`: The player's "Show in transcript": go to the line being said, without
interrupting playback.

#### Actions become editable only when the notes finish
`MeetingsPage::open_correction`: Actions become editable when the notes finish.

#### Text outside the overview scroll view is marked with anchored off
`MeetingsPage::find_marked`: `find_text`, for text that isn't in the overview's scroll view and so
has nothing to scroll with `anchored` off.

#### Shown text differing from source keeps ranges only if words match
`MeetingsPage::find_marked`: A shown text that differs from its source (names filled in) keeps
its ranges only when they still land on the same words.

#### Caption is the latest started line, or the first before speech
`caption_at`: The line being said at `seconds`: the latest that has started, or the
first before any speech (`PlayheadIndex.caption`).

#### Omit the source when the title already names it
`screen_detail`: "Gmail · 4 min on screen"; the source is left out when the title already
names it.

### `LinuxWindows/crates/lokalbot-app/src/pages/meetings/dialogs.rs`

#### Stored owner "Me" is what core, follow-ups and notes read as the user
`OWNER_ME`: The stored owner for the user's own action, as macOS writes it. The core,
follow-ups and notes read only this value as the user.

#### Stored as macOS writes it, shown in interface language
`OWNER_UNRESOLVED`: Stored as macOS writes it, shown in the interface language.

#### Owner labels follow interface language; stored values never do
`owner_choices`: The owner menu as (label, stored value): labels follow the interface
language, stored values never do.

#### Sealed speaker journal only reaches the speaker sheet and recognized line
`NameSpeakerSheet.identity`: The sealed speaker journal, for the review controls.

#### Save the calendar guest's opaque id, never the address
`NameSpeakerSheet::save`: The chosen calendar guest's opaque id, never the address.

#### Keep a suggestion's person only while the name still matches it
`NameSpeakerSheet::save`: A suggestion's person only while the name still is that suggestion.

#### Changes to who spoke close the sheet and teach the voice
`NameSpeakerSheet::perform`: Runs one speaker choice and saves the transcript it gives. Anything
that changes who spoke closes the sheet and teaches the voice.

#### Deleting evidence keeps names and remembered voices
`NameSpeakerSheet::delete_evidence`: `onDeleteEvidence`: names and remembered voices stay.

#### Transcribe joined audio first so a partial merged transcript never feeds the summary
`MergeSheet`: A partial merged transcript must never satisfy the
summary: transcribe the joined audio first.

#### Boundaries are on the original playback timeline
`BoundarySheet`: "Meeting boundaries" (`MeetingBoundaryEditor.swift`): which part of the
recording belongs to the meeting, on the original playback timeline.

### `LinuxWindows/crates/lokalbot-app/src/pages/meetings/follow_up.rs`

#### Follow-up draft is never sent by LokalBot; rewrite uses local Think
The follow-up draft (`FollowUpDraftSheet.swift`): review the outline
built from a meeting's outcomes, rewrite it with the local Think model,
copy it, or save it with the meeting. LokalBot never sends it.

#### A rewrite started before reopening still lands in the sheet
`FollowUpSheet::open`: A rewrite started before the sheet was reopened still lands here.

### `LinuxWindows/crates/lokalbot-app/src/pages/meetings/list.rs`

#### Import button sits beside Record because there is no File menu
`MeetingsPage::render_list_column`: The header is the search field and Record (`MeetingListView`).
Importing has no File menu here, so its button stays beside Record.

#### Narrow column: merge action shares title row, explanation full width
`MeetingsPage::render_list_column`: The column is narrow: the action shares the title row and the
explanation gets the full width below it.

### `LinuxWindows/crates/lokalbot-app/src/pages/meetings/live.rs`

#### Engine reports track state; levels fill in only until first update
`MeetingsPage::render_health`: The engine reports each track's state; levels only fill in until
its first update arrives.

### `LinuxWindows/crates/lokalbot-app/src/pages/meetings/mod.rs`

#### Review tab removed; naming sheet, owner menu and refresh banner replace it
`TABS`: Summary, Transcript and Notes. The Review tab is gone: its jobs are the
naming sheet, the owner menu on each action and the refresh banner.

#### Set while editor text is replaced programmatically
`NotesEditor.loading`: Set while the editor's text is replaced programmatically.

#### On the Transcript tab the find bar is always shown
`FindBar.open`: Opened with Find; on the Transcript tab the bar is always shown.

#### Full-text list filter is debounced
`MeetingsPage.content_matches`: Meetings whose transcript or notes match the query (full-text, debounced).

#### Selection equals selected unless Ctrl- or Shift-clicked
`MeetingsPage.selection`: Every selected meeting, for merging and deleting several at once;
just `selected` unless Ctrl- or Shift-clicked.

#### Transcript row of focus_at computed once per render
`MeetingsPage.focused_row`: Transcript row of `focus_at`, computed once per render.

#### Live transcript follows new lines until the user scrolls up
`MeetingsPage.live_scroll`: The live transcript list: follows new lines until the user scrolls up.

#### Back button bounds keep the tab switcher from covering it
`MeetingsPage.back_bounds`: Where the Back button at the toolbar's leading edge is, so the tab
switcher never covers it.

#### Decrypted thumbnail pixels stay in memory only for the shown meeting
`MeetingsPage.screen_thumbnails`: Small images of what was on screen, by snapshot. Decrypted pixels stay
in memory for the meeting on the page.

#### Ctrl+F is a global binding; text fields hand it on as Search
`bind_find`: Ctrl+F opens Find from anywhere on the meeting page, whatever has focus or
nothing at all (`requestSelectedMeetingSearch`), so it can't live on one
element. A text field hands the shortcut on as its own `Search`.

#### Ctrl+F ignored when another window is active
`bind_find`: Other windows keep the shortcut to themselves.

#### Palette's Draft follow-up opens once the meeting is showing
`MeetingsPage::open_requested_follow_up`: Applies navigation requests and reloads after library changes.
The palette's "Draft follow-up" opens the sheet once the meeting is showing.

#### Already-open meeting needs explicit reveal since no load follows
`MeetingsPage`: The meeting is already open (a citation from Ask about the
meeting shown before): no load follows to reveal the moment.

#### Ctrl adds/removes, Shift selects range from last plain click
`MeetingsPage::click_row`: A row click: Ctrl (Cmd on macOS) adds or removes one meeting, Shift
selects the rows from the last plain click, anything else selects one.

#### Reopen player when a recording ends since it knew only the first part
`MeetingsPage::load_doc`: A recording that just ended has new audio: a player opened
while it was still being written knows only its first part.

#### A name recorded just before a crash still reaches the transcript
`MeetingsPage::recover_saved_names`: A name recorded just before a crash still reaches the transcript.

#### Undrawn rows have no height, so scroll to the previous row's top
`MeetingsPage::reveal_focus`: Item 0 is the header, so row r is item r + 1. Rows the list has
not drawn yet (the transcript tab was not open) have no height,
and revealing them would not move: put the row before it at
the top instead.

#### Full-text list filter runs 160 ms after typing stops
`MeetingsPage::search_content`: Full-text matches for the list filter, 160 ms after typing stops.

#### Overview matches mark and scroll themselves when painted
`MeetingsPage::reveal_find_match`: Brings the current match into view: its tab, its row in a transcript,
and its words in the notes. On the overview, its text marks itself and
scrolls when it paints.

#### Notes find uses native selection with focus kept in Find field
`MeetingsPage::reveal_find_match`: Native selection lands Find in the editable notes
(`SearchableNotesEditor`). Focus stays in the Find field, and the
selection shows while it does.

#### Exported audio stays local until the person saves it elsewhere
`MeetingsPage::export_audio`: `exportAudio`: the tracks mixed into one file. Audio stays on this
computer until the person saves it somewhere else.

#### Live view re-renders five times a second for timer and meters
`MeetingsPage::sync_tick`: Re-renders the live view five times a second for the timer and meters.

#### Tabs centered but clear of toolbar items and Back, RTL-aware
`tabs_geometry`: Where the tab switcher sits over `page`: centered, but clear of the
toolbar items and window controls on the right and of Back at the leading
edge (`back`, on the right in right-to-left languages) when it shows.
Returns x, segment width.

#### Only a live recording sets the toolbar title; saved meetings carry their own
`MeetingsPage::title`: A recording in progress keeps its own title. Every state of the saved
library shares one toolbar without one: a meeting's page carries its
own title, and the toolbar read it as the list's.

#### Back sits at the leading edge so centered tabs can't cover it
`MeetingsPage::title_control`: Back to the page the meeting was opened from, at the toolbar's leading
edge (the Mac's `.navigation` placement), where the centered tab
switcher can't cover it at any window width.

#### Draft follow-up needs outcomes not currently being rewritten
`MeetingsPage::toolbar`: `Draft follow-up…` needs outcomes that are not being rewritten right
now; a queued or waiting meeting keeps its current outcomes.

#### Find is in the menu because Linux and Windows have no Edit menu
`MeetingsPage::toolbar`: Linux and Windows have no Edit menu to carry
Find; Ctrl+F works everywhere on the page.

#### Default window once put tabs over Back; test guards every width and RTL
`the_tabs_never_cover_back`: The default window (a page about 1015 px wide) used to put the tabs
over Back; at the leading edge it stays clear of them at any width,
on the left or, right to left, on the right.

### `LinuxWindows/crates/lokalbot-app/src/pages/meetings/model.rs`

#### Sealed speaker journal is private to speaker sheet and recognized line
`MeetingDoc.identity`: The sealed speaker journal, when this computer can open it. Private:
it only ever reaches the speaker sheet and the recognized-voices line.

#### Moved-aside outcomes stay shown until the refreshed notes are written
`MeetingDoc.previous_actions`: The outcomes a refresh moved aside: what the summary shows until the
new notes are written (`previousReviewProjection`).

#### Set when recording-health.json reports a problem
`MeetingDoc.capture_needs_attention`: `recording-health.json` reports a problem.

#### Crash audio from a Mac with unverified checkpoints needs attention
`MeetingDoc.recovery_needs_attention`: Crash audio from a Mac whose checkpoints were never verified.

#### Show saved outcomes, or moved-aside ones while none are saved
`MeetingDoc::shows_previous`: The outcomes the page shows: the saved ones, or while none are saved
the ones a refresh moved aside, which stay readable until it finishes
(`shownProjection`).

#### Row lookup falls back to the nearest row before the time
`MeetingDoc::row_at`: Row index whose segment contains `seconds` (or the nearest before it).

#### User's actions go under For you and show no owner
`MeetingAction.is_for_user`: Yours: it goes under "For you" and shows no owner.

#### Me reads You, Them reads Other speaker, stored owner localized
`display_label`: `SpeakerDisplayName.label`: "Me" (as the user) reads "You", "Them" reads
"Other speaker" and "Them 2" reads "Speaker 2". The stored owner
"Unresolved speaker" also reads in the interface language.

#### Meeting load runs on a background thread
`load`: Reads and projects one meeting. Runs on a background thread.

#### Finished partial parts show in place of final notes while writing
`load`: Finished parts show in place of final notes while the rest is written.

#### Audio is WAV tracks or a macOS library's m4a; player and waveform read both
`load`: The WAV tracks this app records, or the `.m4a` a macOS library keeps:
the player and the waveform read both.

#### Saved edits follow matching actions as when the notes finish
`load`: Saved edits follow the actions they match, as they will when
the notes finish.

#### Skip opening the credential store when no speaker journal exists
`load`: No journal means no reason to open the credential store.

#### Duration minutes are floored, as on macOS
`duration_label`: Duration chip text: "2 min", "1 hr 5 min" (minutes floored, as on macOS).

#### Merged meetings omit the app; the sample labels itself
`row_detail`: List row metadata, "10:57 AM · 2 min · Zoom": when, how long, then where
(`MeetingDetailPresentation.rowSubtitle`). Merged meetings omit the app;
the sample says what it is where a meeting names its app.

#### Never delete the meeting being recorded; recorder still writes its folder
`deletable`: The meetings a delete may remove: never the one being recorded, whose
folder the recorder is still writing into.

### `LinuxWindows/crates/lokalbot-app/src/pages/meetings/naming.rs`

#### Naming sheet saves all picks as if each speaker were named alone; recognized voice applies only on save
One sheet to name a meeting's unnamed voices (`MeetingSpeakerNamingSheet`):
play a sample, read what that voice said, then pick an invited name or
type one. Names are saved together, each as if that speaker had been named
on its own; a voice left alone stays unnamed. A voice recognized from
earlier meetings starts picked and is applied only when the person saves.

#### Names save one at a time; a mid-way failure leaves earlier ones saved
`NamingSheet::save`: Saves every name picked, one at a time as if each speaker had been
named on its own; a failure midway leaves the earlier ones saved.

#### Names must pass the same safe-name check: no address, link or secret
`NamingSheet::save`: The same check as naming one speaker: a person's name, never an
address, link or secret.

#### Store the guest's opaque id, never the address
`NamingSheet::save`: The chosen guest's opaque id, never the address.

#### A newly remembered voice can name speakers in other recent meetings
`NamingSheet::save`: A newly remembered voice can name speakers in
other recent meetings.

#### Recognized voice that is also a guest shows as that guest's picked chip
`NamingSheet::voice_row`: A recognized voice that is also a guest is that guest's chip,
already picked; otherwise it gets a chip of its own.

### `LinuxWindows/crates/lokalbot-app/src/pages/meetings/page_search.rs`

#### Find matching ignores case, diacritics and width; source text keeps location for scroll agreement
Matching for Find on a meeting page (`MeetingPageSearch.swift`): one source
per visible text node, in reading order. Matching ignores case, diacritics
and character width. Keeping the location beside the exact text makes
matching and scrolling agree.

#### Transcript field searches its tab only; panel titles are not searched
`sources`: `searchSources`: every visible text node in reading order. The field in
the Transcript panel searches only that tab; Ctrl+F searches the page.
`notes` is the editor's text, which can be newer than `doc`. Panel titles
are not searched: a panel's header can't mark its words.

#### Imported files carry no Mic only chip
`audio_chip`: "Mic only", the date line's one capture limitation. An imported file's
audio came from neither this PC's microphone nor its system audio, so it
carries none.

#### Lowercasing İ changes byte length; ranges must stay on boundaries
`ranges_cut_on_character_boundaries_when_lengths_change`: "İ" lowercases to two chars and changes byte length.

#### An owner match must not mark the action text's bytes
`fields_of_one_action_keep_their_own_ranges`: An owner's match must not mark the same bytes of the action's text.

### `LinuxWindows/crates/lokalbot-app/src/pages/meetings/playback.rs`

#### Playback polls position at 10 Hz while playing
Meeting playback through `lokalbot_audio::Player`: play/pause, seeking,
speed, and a 10 Hz position poll while playing that drives the waveform
playhead and the transcript highlight.

#### The playing segment is highlighted like cited evidence
`MeetingsPage::sync_player`: The playing segment is highlighted like cited evidence.

### `LinuxWindows/crates/lokalbot-app/src/pages/meetings/presentation.rs`

#### Meeting presentation values are display-only, never stored or sent to a model
Display-only values for a saved meeting's page (`MeetingDetailPresentation`,
`MeetingSpeakerNaming`): who spoke, whose each action is, the owner
choices on a row, what the naming sheet lists and what it saves. Nothing
here is stored, sent to a model, or treated as an identity decision.

#### Speaker key is the transcript's canonical key such as "me" or "them 2"
`Speaker.key`: The transcript's canonical speaker key ("me", "them 2").

#### Speakers listed with the user first, then by first speaking
`speakers`: Everyone who spoke, you first, then in order of first speaking.

#### Unnamed call voices are listed in order of first speaking
`unnamed_speaker_keys`: Call voices without a saved name, in order of first speaking.

#### Meeting date reads Today at, Yesterday at, then full date with time
`date_text`: "Today at 1:00 PM", "Yesterday at 3:10 PM", then "Nov 6, 2026 at 3:00 PM".

#### Row subtitle is time, duration, source; RTL languages start with a right-to-left mark
`row_subtitle`: "1:00 PM · 50 min · Zoom": when, how long, then where it happened. In
Arabic and Urdu it starts with the right-to-left mark that keeps the
leading time.

#### Speech seconds per speaker key are computed from segment bounds
`speech_seconds`: Seconds of transcribed speech per speaker key, from segment bounds.

#### Speech minutes are rounded whole minutes, with any speech showing as at least one
`speech_minutes`: Whole minutes for "12 min of speech"; any speech at all reads as one.

#### Both action bands show whenever actions exist; rows index shown actions in order
`ActionsPanel`: What the Actions panel says about itself: one count in its header, then a
band for your actions and one for everyone else's. Both bands show
whenever the meeting has actions, so a side with none says so instead of
leaving a gap. Rows are indices into the shown actions, in their order.

#### A meeting without actions shows no count pill
`ActionsPanel.count`: The header's pill. A meeting without actions has no count.

#### Also-in-Actions link needs a user action from saved outcomes of a real meeting
`ActionsPanel.shows_actions_link`: "Also in Actions" leads to your open work, so it needs an action of
yours that the Actions list holds: saved outcomes of a real meeting,
not a sample or notes that are still being written.

#### Placeholder voice names mirror Transcript.isPlaceholderSpeakerName on the Mac
`is_placeholder_speaker_name`: "Them", "Them 2", "Speaker", "Speaker 3", "Speaker unclear" and "Local
speaker" are voices, not names (`Transcript.isPlaceholderSpeakerName`).

#### Someone else's action with missing or placeholder owner asks for a real owner
`owner_needs_attention`: Someone else's action whose owner is missing or only a placeholder voice
("Speaker 2"): the row asks for a real owner.

#### You and No owner titles are interface words, translated for display
`OwnerOption.title`: What the menu shows ("You" and "No owner" are interface words).

#### Value is what is saved as owner; empty clears it
`OwnerOption.value`: What is saved as the owner; empty clears it.

#### You and No owner are localized; person names are shown as is
`OwnerOption.label`: The menu's words: "You" and "No owner" in the interface language, a
person's name as it is.

#### Speakers offered by displayed name but saved by transcript name
`owner_options`: Owner choices for one action: you, this meeting's other speakers, invited
people who are not already among them, and no owner. Speakers are offered
by the name the page shows and saved by the name the transcript uses.

#### Owner selection matches by name, not voice, until someone names the voice
`owner_options`: By name, not by voice: "Them" on an action is not the person that
voice was named as afterwards, until someone says so.

#### Owner correction: Some(None) clears; unchanged owner saves nothing; wording and due date stay
`owner_correction`: The owner to save from a row's menu: `Some(None)` clears it. Nothing when
the choice already is the action's owner. A corrected wording and due
date stay as they are.

#### Owners are saved under the transcript's own speaker name, whatever the page shows
`stored_speaker_names`: The name the transcript itself uses for each speaker ("Them 2", or a
saved alias): what an owner is saved as, whatever the page shows.

#### Owner names compare ignoring case, accents and outer spaces
`owner_key`: Compares names the way people read them: case, accents and outer spaces
don't count.

#### Sample is the clearest excerpt's start time and its text
`NamingVoice.sample`: When the clearest excerpt starts, and what was said.

#### Recognized name is offered already picked but still needs saving
`NamingVoice.recognized_name`: A name this voice matched from earlier meetings. It is offered
already picked, and still needs saving.

#### Distinguishes voice-recognition names from names the person chose
`NamingKnown.was_recognized`: Named by voice recognition, not by the person reading the meeting.

#### Voices with actions come first; the user's own voice is in neither list
`naming_lists`: Voices to name, those with actions first (the order of `review`), and the
speakers already named. The user's own voice is in neither list.

#### One person is one voice: picking a name for a second voice takes it from the first
`NamingDraft`: What has been picked in the naming sheet before it is saved. One person
is one voice: picking a name for a second voice takes it from the first.

#### Recognized voices start picked in the naming draft
`NamingDraft.new`: Recognized voices start picked.

#### Two voices cannot both start as the same guest
`NamingDraft.new`: Two voices cannot both start as the same guest.

#### Picking the same name again clears the pick
`NamingDraft.toggle`: Picks a name for a voice; picking the same name again clears it.

#### Names saved in sheet order; untouched voices skipped; typed names supplied by caller
`NamingDraft.choices`: The names to save, in the sheet's order. Voices left alone are
skipped; `typed` gives what was typed for a voice.

#### A recognized name matching an invited guest keeps the guest's calendar identity
`recognized_pick`: The pick for a name recognized by voice. When that name is one of the
suggestions (an invited guest), it is that suggestion's pick, so the
guest's calendar identity is kept.

#### Meeting page widths at default text size; page fills pane, only prose keeps a measure
`layout`: Widths of a saved meeting's page at the default text size. The page
fills the detail pane; only prose keeps a reading measure.

#### Gutter is space between pane edge and title, player and panels
`layout::GUTTER`: Space between the pane's edge and the title, the player and panels.

#### Panel gap also separates a notice from the panel under it
`layout::PANEL_GAP`: Space between two panels, and between a notice and the panel under it.

#### Column max is the page's widest; ultra-wide panes centre the column
`layout::COLUMN_MAX`: The page's widest; an ultra-wide pane centres the column.

#### Prose width is the measure for recap and full summary inside panels
`layout::PROSE`: The measure of the recap and the full summary inside their panels.

#### Find field in the Transcript header ranges between its widest and narrowest widths
`layout::FIND_FIELD`: Find in the Transcript panel's header, at its widest and narrowest.

#### Transcript time column is wide enough for 1:02:09
`layout::TIME_COLUMN`: The transcript's time column: wide enough for "1:02:09".

#### A line's highlight extends this far past its text on each side
`layout::LINE_INSET`: A line's highlight reaches this far past its text on each side.

#### Text-bound widths scale with the app's text size
`layout::scaled`: A text-bound width at the app's text size.

#### Whole-meeting search is pinned under the player because matches move between tabs
`FindPlacement::PinnedBar`: Ctrl+F's search of the whole meeting, pinned under the player because
its matches move between tabs.

#### You on an action stored as Me but not yet yours is saved again
`choosing_the_current_owner_saves_nothing_and_no_owner_clears`: "You" on an action stored as "Me" but not yet yours is saved again.

### `LinuxWindows/crates/lokalbot-app/src/pages/meetings/speaker_identity.rs`

#### Speaker evidence stays out of transcript model, search and export; only accepted names reach them
Speaker review inside Name Speaker (`SpeakerIdentityReview`). Evidence
stays out of the transcript model and its search and export paths; only
names a person accepts reach them. Names recognized from earlier meetings
start picked in the naming sheet (`naming.rs`) and are applied only when
the person saves.

### `LinuxWindows/crates/lokalbot-app/src/pages/meetings/speaker_suggestions.rs`

#### Chosen guest keeps opaque identity with the name; attendance alone never names a voice
Suggested names in Name Speaker (`MeetingSpeakerRenameSheet`): the
meeting's calendar guests and name hints. Choosing a guest keeps its
opaque identity with the name (`speakerCalendarIdentityIDs`), so same-named
guests stay apart; attendance alone never names a voice. Typing in the
name input searches the suggestions.

#### Query searches suggestions and is cleared by a choice so the full list shows
`SpeakerSuggestions.query`: The name as last typed, which searches the suggestions. A choice
clears it, so the whole list shows again.

#### Remember the tallest list height so filtering never shrinks the sheet
`SpeakerSuggestions.list_height`: The tallest the list has been, so filtering never shrinks the sheet.

#### Calendar identity saved is the chosen guest's, only while a guest is chosen
`SpeakerSuggestions.identity_for_save`: The calendar identity to save with `name`: the chosen guest's, while
a guest is chosen.

#### Chosen guest stays listed while its name is edited because saving keeps it
`SpeakerSuggestions.visible`: Matches for the typed name. The chosen guest stays listed while its
name is edited, since saving keeps that guest.

#### Enter fills the top unchosen match; with none, it saves the typed name
`SpeakerSuggestions.return_choice`: The top match not already chosen, which Enter fills in. With none,
Enter saves the name as typed.

#### A typed hint name already is that suggestion, so Enter saves it
`enter_saves_when_nothing_new_matches`: A typed hint name is already that suggestion, so Enter saves it.

### `LinuxWindows/crates/lokalbot-app/src/pages/meetings/spoken.rs`

#### Spoken summary stops when the meeting being read is no longer shown
`MeetingsPage.stop_spoken_summary`: The meeting being read is no longer the one shown.

### `LinuxWindows/crates/lokalbot-app/src/pages/meetings/transcript.rs`

#### Transcript list is virtualized so the panel is drawn in header, line and footer pieces
The Transcript tab (`MeetingTranscriptList`): one panel with Find in its
header and "Transcribed with …" in its footer, speaker turns on its
surface with a quiet time before each line. The list is virtualized, so
the panel is drawn in pieces: its top with the header, one piece per line,
and its bottom with the footer.

#### Ctrl+F whole-meeting search is pinned under the player because matches move between tabs
`MeetingsPage.render_find_bar`: Ctrl+F's search of the whole meeting, pinned under the player because
its matches move between tabs.

#### Item 0 is status lines and panel top; item r+1 is line r, last closes panel
`MeetingsPage.render_transcript_item`: One piece of the page: item 0 is the status lines and the panel's
top; item r + 1 is line r, the last one closing the panel.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
