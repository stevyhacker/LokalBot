# 0082. Windows and Linux: app — ui

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-app/src/ui/`, `LinuxWindows/crates/lokalbot-app/src/ui/action_row/`.

## Decisions

### `LinuxWindows/crates/lokalbot-app/src/ui/action_row.rs`

#### Action row mirrors the Mac everywhere; thread_row for lists, primitives for meetings
The action row as the Mac draws it everywhere (`ActionThreadRow`,
`OutcomeActionRow`, `EvidencePill`, `MeetingPlayTimeButton`): an 18px
completion circle, the action, a meta line and the "…" menu.

Pages that list action threads use [`thread_row`], which builds the whole
row from an `ActionThread` with the Mac's meta line and menu:

```ignore
use crate::ui::action_row::{self, ThreadRowOptions};

let row = action_row::thread_row(
    format!("today-thread-{ix}").into(), // unique on the page
    thread,
    ThreadRowOptions { hint: hints.get(&thread.id), ..Default::default() },
    &data, // Entity<AppData>
    cx,
);
```

Rows of a single meeting's actions (a meeting's Summary) compose the
primitives instead: [`status_toggle`], [`meta_link`], [`due_text`] with a
[`DueTone`], [`evidence_pill`] or [`play_time`], [`options_menu`] and
[`action_row_with`].

The Actions page draws the row in its list style with [`list_row`]
(`ActionListRowStyle`): its own wording, selection and status handling.

#### Toggle shows open, done check, or minus when meetings disagree
`status_toggle`: The round toggle: open circle, filled teal check when done, minus for a
thread whose meetings disagree.

#### Evidence pill mirrors Mac EvidencePill; tooltip is the excerpt
`evidence_pill`: `EvidencePill`: quote bubble + "00:00:26" in teal; the tooltip is the excerpt.

#### Only open work is overdue or due soon; done and deferred are calm
`DueTone`: How a due date reads in a row: red once it has passed, amber within the
week ahead, quiet after that (`ActionThreadRow.dueColor`). Only open work
is overdue or due soon; done and deferred work reads quiet.

#### Due soon window matches the attention order, today through seven days
`DueTone::of`: The tone of work due on `due` (its resolved day), seen on `today`.
The week is `DUE_SOON_WINDOW_DAYS`: today through seven days ahead,
the window the attention order uses.

#### A thread is open when any of its meetings has it open
`DueTone::of_thread`: A thread is open when any of its meetings still has it open.

#### Overdue gets a tooltip too since colour alone carries it
`due_text`: The due words in a row's meta line ("Due Thu, Nov 19 · said “Thursday”"),
coloured by `tone`. Overdue work also says so to a tooltip, since colour
alone carries it.

#### Stamp format 0:24, or 1:05:03 past an hour, matches the Mac
`short_stamp`: "0:24", or "1:05:03" past an hour (`Transcript.shortStamp`).

#### Play time button opens the meeting playing from that moment
`play_time`: `MeetingPlayTimeButton`: "▶ 0:24" in teal, opening the meeting playing
from there; the tooltip is what was said.

#### Takes prebuilt text so Find can mark matches
`action_row_with`: `action_row` with its text already built (Find marks matches in it).

#### Done and deferred work is never late
`tests::due_dates_read_red_when_passed_and_amber_within_the_week`: Done and deferred work is never late.

### `LinuxWindows/crates/lokalbot-app/src/ui/action_row/list.rs`

#### Action row mirrors macOS ActionThreadRow; other-page links live in details pane
The action row as the Actions page draws it (`ActionThreadRow` with an
`ActionListRowStyle` in `OutcomeOverviewViews.swift`): the page's own
source and due wording, a selection the page owns, and status changes the
page confirms and keeps in view. The links a row has on other pages live
in that page's details pane, so the meta line is plain text here.

```ignore
let row = action_row::list_row(
    format!("actions-row-{ix}").into(),
    thread,
    ListRowStyle { source, due, selected, batch, hint, on_click, on_status, on_edit, on_not_mine },
    &data,
    cx,
);
```

#### ListRowStyle is what a page passes per row, mirroring ActionListRowStyle
`ListRowStyle`: What a page passes for each row (`ActionListRowStyle`).

#### Source is the meeting as the page words it; empty means none
`ListRowStyle.source`: The meeting it came from, as the page words it; empty for none.

#### With several rows selected, a row's menu shows only under the pointer
`ListRowStyle.batch`: Several rows are selected: a row's menu shows only under the pointer.

#### Hint is the evidence beside Looks done?, shown when a later screen suggests completion
`ListRowStyle.hint`: The evidence beside "Looks done?" ("Mail showed “Message sent” · Mon
5:48 PM"), when a later screen suggests the action is done.

#### Hand-off menu lists Agent then installed coding agents, mirroring ActionThreadRow.handOffItems
`hand_off_items`: Agent, then each coding agent installed on this computer, by name: the
Actions page's "Hand off" (`ActionThreadRow.handOffItems`).

#### Row menu and context menu share entries; Draft next steps omitted, no Follow Through
`list_menu`: The row's "…" menu and its context menu: the same entries (`listMenu`).
"Draft next steps…" is left out: this app has no Follow Through.

#### List row click routing and menu visibility; id must be unique per page
`list_row`: One row of the Actions list: completion circle, the action, a quiet line
with its source and due words, a "Looks done?" line when a later screen
suggests it, and the "…" menu on the selected row and under the pointer.
A click goes to `style.on_click`; the circle and the menu keep their
clicks to themselves. `id` must be unique on the page.

#### Menu stays in tree so an open menu survives pointer moving onto items
`list_row`: The menu shows on the selected row and under the pointer. It stays in
the tree either way, so an open menu is not taken away when the pointer
moves onto its items.

### `LinuxWindows/crates/lokalbot-app/src/ui/action_row/thread.rs`

#### Shared action-thread row mirrors ActionThreadRow; used through ui::action_row::thread_row
The action-thread row every page draws (`ActionThreadRow` in
`OutcomeOverviewViews.swift`) and what it does: status changes (asking
first when a thread spans meetings), the sources dialog, the "Looks
done?" and "Still open?" lines, and the hand-off menu items. Use it
through `ui::action_row::thread_row`.

#### Looks done? reads only consented text and only when the setting is on
`suggests_completion`: "Looks done?" reads only text kept with consent, and only when asked to
(`refreshActionCompletionHints`).

#### Not Yet on Looks done? remembers the dismissal
`hint_line`: "Looks done?" for `thread`, with Not Yet remembering the dismissal.

#### Age wording follows macOS RelativeDateTimeFormatter for old work
`age_label`: "3 weeks ago", as `RelativeDateTimeFormatter` says it for old work.

#### Still open? either answer uses normal status path; deferred work stops asking
`still_open_line`: "Still open?": open work nobody has mentioned for weeks. Either answer
goes through the normal status path; deferred work stops asking
(`StillOpenLine`).

#### Looks done? is only a suggestion; nothing changes until Mark Done
`completion_hint_line`: "Looks done?": a later capture shows the action's words with a completion
phrase. A suggestion only; nothing changes until Mark Done
(`ActionCompletionHintLine`).

#### Status changes ask first when a thread spans several meetings
`set_thread_status`: Sets a thread's status, asking first when it spans several meetings.

#### Row options mirror ActionThreadRow's options beyond the action itself
`ThreadRowOptions`: What a row adds beyond the action (`ActionThreadRow`'s options).

#### Projects show owner when the work is someone else's
`ThreadRowOptions.show_owner`: Projects show whose work it is when it is someone else's.

#### People show deferred work as deferred and ask about weeks-old open work
`ThreadRowOptions.show_staleness`: People show deferred work as deferred and ask about open work nobody
has mentioned for weeks.

#### Timeline meeting preview hides the single-meeting link since the meeting is already listed
`ThreadRowOptions.hide_single_meeting_link`: Timeline's meeting preview lists that meeting's actions, so a row
from one meeting does not name it again.

#### People show a play-time that opens the meeting at that moment, not a quote pill
`ThreadRowOptions.plays_evidence`: People show the moment as a ▶ time that opens the meeting at that
moment, like the notes beside it, instead of the quote pill.

#### Shared action row layout across Today, Timeline, People, Projects; due color thresholds; unique id
`thread_row`: The shared action row (`ActionThreadRow` on Today, Timeline, People and
Projects): completion circle, the action, a meta line (owner, mixed or
deferred status, source meeting link or "Mentioned in N meetings", due
text red when overdue and amber when due within a week, "Deadline
updated", the time it was said) and the "…" menu; then a "Looks done?" or
"Still open?" line. `id` must be unique on the page.

#### Sources dialog keeps each source attached to its meeting and splittable from thread
`open_sources`: Every meeting a thread came up in (`ActionThreadSourcesView`). Each source
stays attached to its meeting, and can be split off the thread.

### `LinuxWindows/crates/lokalbot-app/src/ui/answer_text.rs`

#### Answer rendering is a Markdown subset with teal citations mirroring macOS SelectableDigestText
Renders assistant answers and generated notes: a small Markdown subset
(paragraphs, headings, lists, quotes, code, bold, italic, links) with
inline `[n]` citations in teal on a teal wash, like `SelectableDigestText`
with `ChatCitationParser.extract(…, linked: true)` on macOS.

#### Emphasis span valid only if non-empty and not bounded by whitespace
`closing`: Length of the content before the closing `marker`, if the span is valid:
non-empty, not starting or ending with whitespace.

#### Underscore closes only at word boundary so snake_case stays literal
`closing`: `_` closes only at a word boundary, so snake_case stays literal.

#### Cite handler receives the 0-based citation index
`CiteHandler`: Called with the 0-based citation index when a `[n]` is clicked.

#### Link handler is called only for non-web link targets
`LinkHandler`: Called with a link's target when it isn't a web link.

#### Render id must be unique within the window
`render`: Lays out the parsed answer. `id` must be unique in the window.

#### Non-web links do nothing unless an on_link handler is given
`render_linked`: [`render`], with `on_link` deciding what a non-web link opens. Without it such
a link does nothing.

#### Inter ships without italics, so medium weight carries emphasis
`render_linked`: Inter ships without italics here; medium weight carries the emphasis.

### `LinuxWindows/crates/lokalbot-app/src/ui/citations.rs`

#### Citation markers in answers mirror ChatCitationParser; shown as deduped numbered references
Evidence markers in Ask answers (`ChatCitationParser.swift`).

The assistant writes `[meeting:<id>@m:ss]`, `[meeting:<id>]` or
`[screen:<n>]`, `[file:<n>]` or `[note:<hex id>]` inline. The UI shows them as numbered `[n]` references,
deduped in order of first appearance, so a repeated source keeps its number.

#### Screen citations load off UI thread; None means moment deleted or expired
`ScreenCitations`: Screen moments that citations name, loaded off the UI thread; `None`
once a moment is known to be gone (deleted or expired).

#### File citations share one table since files never change with a conversation
`FILE_CITATIONS`: Files that citations name, loaded off the UI thread; `None` once a file has
left the index. Files never change with a conversation, so one table serves
every answer on screen.

#### Note citations load off UI thread; None once note left the saved copy
`NOTE_CITATIONS`: Saved coding-agent notes that citations name, loaded off the UI thread;
`None` once a note has left the saved copy.

#### Meeting ids may be full UUIDs or short-id prefixes
`CitationSource`: One cited source. Meeting ids may be full UUIDs or short-id prefixes.

#### Note ids are lowercase hex ids saved by coding agents
`CitationSource::Note`: A note one of the person's coding agents saved, by its lowercase hex id.

#### Cited text replaces markers with [n] and records where each landed
`CitedText`: Text with markers replaced by `[n]`, plus where each `[n]` landed.

#### Markers hold byte ranges of each [n] with 0-based citation index
`CitedText.markers`: Byte range of each `[n]` in `text`, with its 0-based citation index.

#### Invalid markers stay as written; spacing tidied the way the macOS parser does
`split`: Splits `text` into plain pieces and numbered citations. Invalid markers
stay as written. Spaces before punctuation and doubled spaces left around
markers are tidied the way the macOS parser does.

#### Meeting ids resolve as full UUID or unique dashless prefix, matching SessionLookup.find
`resolve_meeting`: Full UUIDs, or a unique prefix of the dashless id (`SessionLookup.find`).

#### Note markers need at least eight hex characters and never a time
`parse_marker`: At least eight hex characters, never with a time.

#### Drop spaces before punctuation and collapse repeated spaces after marker text
`tidy`: Drops spaces before punctuation and collapses repeated spaces after text.
`after_text` says whether the piece follows visible text (a marker).

### `LinuxWindows/crates/lokalbot-app/src/ui/controls.rs`

#### Bordered button mirrors macOS .bordered: soft grey fill, accent text from theme
`bordered`: macOS `.bordered` button for secondary actions ("Review Actions…"): a soft
grey fill with accent text (colors come from the theme's secondary button).

### `LinuxWindows/crates/lokalbot-app/src/ui/markdown_view.rs`

#### Markdown headings scaled to sit under LokalBot's section titles
Markdown for summaries and digests, with headings scaled to sit under
LokalBot's section titles instead of dwarfing them.

### `LinuxWindows/crates/lokalbot-app/src/ui/mod.rs`

#### UI helpers match DesignSystem.swift; pages compose them to keep radii and colors consistent
LokalBot's building blocks, matching `DesignSystem.swift`:
grouped surfaces, section cards, chips, status dots, icon tiles, evidence
pills and the proportion bar. GPUI Kit supplies inputs, buttons, switches
and menus; these helpers cover what it does not.

Page code should compose these instead of restyling raw `div`s so every
page keeps the same radii, paddings and colors.

The redesign's shared parts: [`section_panel`] (a section of a page on its
own raised surface, with its pills, bands and lead variant) and
[`action_row`] (the action row every page draws).

#### Grouped surface is the rounded well behind Recap, Action Items, Decisions, settings groups
`grouped_surface`: The rounded well behind Recap, Action Items, Decisions and settings groups.

#### Standard panel padding is 14px
`panel`: A grouped surface with the standard 14px padding.

#### Status surface uses a 10% tint fill and 28% stroke
`status_surface`: A tinted status surface: 10% fill, 28% stroke (recording, attention).

#### Stat chip mirrors macOS StatTile: icon, bold value, label
`stat_chip`: `StatTile`: icon + bold value + label, in a chip ("3h 50m tracked").

#### Status dot is a filled circle, 8px by default
`status_dot`: A filled circle, 8px by default.

#### Icon tile mirrors macOS IconTile: rounded square with tinted fill
`icon_tile`: Rounded square with a tinted fill and a centered symbol (`IconTile`).

### `LinuxWindows/crates/lokalbot-app/src/ui/profile.rs`

#### Profile helpers are shared by People and Projects pages
Pieces shared by People and Projects: name tints, the project monogram,
relative days, durations and links.

#### Project monogram radius 0.26x size; untracked suggestion draws dashed outline
`monogram`: A project's first letter on a rounded square tinted from its name
(`ProjectMonogram`, radius 0.26× size). A suggestion, which nobody tracks
yet, is a dashed outline.

#### Relative day wording matches PersonDetailView.relativeDay
`relative_day`: "today", "yesterday", "3 days ago", then "Oct 3" (`PersonDetailView.relativeDay`).

#### Duration format matches ProjectDetailView.duration
`duration`: "3h 10m" or "48m" (`ProjectDetailView.duration`).

#### Link styled like macOS .workspaceLink
`link`: A link styled like `.workspaceLink`.

### `LinuxWindows/crates/lokalbot-app/src/ui/result_row.rs`

#### Search snippets shared by Ask and Quick Recall, mirroring ResultRow.swift
Search snippets shared by Ask and Quick Recall (`ResultRow.swift`):
«matched» words in bold, and no lines that only repeat the row's title.

#### FTS snippet markers split like SnippetHighlighter.segments; returns byte ranges
`snippet_matches`: Splits an FTS snippet on «» markers (`SnippetHighlighter.segments`).
Returns the plain text and the byte ranges of the matched runs.

#### Leading snippet lines repeating the title are dropped, matching SnippetCleaner
`without_title_echo`: Drops leading snippet lines that only repeat the row title and collapses
whitespace (`SnippetCleaner.withoutTitleEcho`). Markers survive.

### `LinuxWindows/crates/lokalbot-app/src/ui/rule_list.rs`

#### Exclusion lists mirror ExclusionRulesEditor and are stored comma-separated in settings
Editable exclusion lists (`ExclusionRulesEditor.swift`): apps or sites that
LokalBot never captures or suggests in. Stored comma-separated in settings.

#### Capture rules: a URL with a path excludes that URL prefix
`RuleKind::Domains`: Capture rules: a URL with a path excludes that URL prefix.

#### Writing rules: a pasted URL applies to its whole domain
`RuleKind::WritingDomains`: Writing rules: a pasted URL applies to its whole domain.

#### Folder rules are comma-stored so a path cannot contain a comma
`RuleKind::Folders`: Folders are stored with commas between them, like the other two, so a
path can't hold one (`ExclusionRulesEditor.folders`).

#### Changed carries the new comma-separated value
`RuleListEvent::Changed`: The new comma-separated value.

#### Picker choice goes through the same checks as typing, failures shown
`RuleList::choose`: "Choose App…" and "Choose Folder…": the file picker's choice goes
through the same checks as typing it, and any failure is shown.

#### Legacy or hand-edited invalid rules stay until removed and are flagged
`is_valid_rule`: Rules saved before these checks, or typed into a settings file, stay until
removed, and say so (`ExclusionRulesEditor.isValid`).

#### Folders under home are abbreviated to ~/ as the Mac does
`folder_rule`: `~/…` for a folder under the home folder, as the Mac abbreviates it.

#### App rules prefer launcher class or command over translated window names; Windows uses file name
`application_rule`: What an excluded app is matched by. A window's name changes with the
language, so a launcher's window class or command wins over it, and a
Windows program is known by its file name.

#### Desktop entry rule uses StartupWMClass, else the program Exec runs
`desktop_entry_rule`: `StartupWMClass`, else the program `Exec` runs.

#### Test expects each platform's own path separator in rules
`folders_abbreviate_home`: Each platform's own separator: a rule reads like the paths around it.

### `LinuxWindows/crates/lokalbot-app/src/ui/screen_thumbnail.rs`

#### Sealed screen images decrypted off UI thread, memory only, never written to disk
Small images of screen moments for lists (`ScreenThumbnailView`). Sealed
images are decrypted off the UI thread and kept in memory only: nothing is
written to disk, and the textures go when they fall out of the cache or the
list's window closes. A moment with no pixels, or one this install can't open,
shows a stand-in.

#### Cache keeps 48 decrypted images; lists show about twenty at once
`MAX_THUMBNAILS`: Decrypted images one surface keeps. Lists show about twenty at a time.

#### Image loads on first request; store locates the cache on the owning view
`ScreenThumbnails::image`: A moment's image, loading it the first time it is asked for. `store` finds
this cache on the view that owns it.

#### A load finishing after its moment was evicted is discarded
`ScreenThumbnails::finished`: Stores what a load gave, unless the moment fell out while it ran.

#### Evicted textures must be freed; call while rendering
`ScreenThumbnails::drop_released`: Frees the textures of images that left the cache. Call while rendering.

#### Test: a load finishing after eviction keeps nothing
`the_cache_keeps_only_the_newest_images`: A load that finishes after its moment left the cache keeps nothing.

### `LinuxWindows/crates/lokalbot-app/src/ui/section_panel.rs`

#### Section panel structure mirrors SectionPanel.swift; usage and layering on page_surface
Section panels (`SectionPanel.swift`): one section of a page on its own
raised surface. Today, a meeting's Summary, Transcript and Notes, and
Timeline's day are made of these.

A panel has a header bar (the section's icon, its title, a count pill, an
optional red alert pill or status pill, and one trailing link),
a hairline, a body, and an optional footer strip on a faint fill for the
one extra line a section has.

```ignore
use crate::ui::section_panel::{SectionPanel, Pill, footer_text};

SectionPanel::new("today-attention", lokalbot_i18n::tr("Needs attention"))
    .section(Section::Actions) // the sidebar destination's icon
    .count(open)
    .when(overdue > 0, |p| p.alert(overdue_label))
    .trailing_link("today-all-actions", lokalbot_i18n::tr("All actions"), |_, cx| {
        AppData::global(cx).update(cx, |data, cx| data.open_actions(cx))
    })
    .rows(threads.iter().enumerate().map(|(ix, thread)| {
        action_row::thread_row(format!("today-thread-{ix}").into(), thread,
            Default::default(), &data, cx)
    }))
    .footer(footer_text(showing))
    .footer(panel_link("today-more-actions", more, |_, cx| { /* open Actions */ }, cx))
```

Put panels on [`page_surface`] (the grey page behind them) so they read
as raised, and stack them in a [`panel_column`].

#### Use count_pill for numbers rather than pill
`pill`: A count, overdue or done pill. Use [`count_pill`] for a number.

#### Band carries footer fill with hairline; follows_rows adds a top hairline
`panel_band`: A labelled band across a panel's body over a group of its rows ("For you
· 2") (`SectionPanelBand`). It carries the footer's fill with a hairline
under it; `follows_rows` also draws the hairline above, for a band after
rows.

#### Footer words take strip width and wrap; trailing link stays at edge
`footer_text`: The words of a footer strip: they take the strip's width and wrap, and a
link after them keeps to the trailing edge (`sectionPanelFooterText`).

#### Panel column spacing matches the Mac's gap between panels
`panel_column`: A column of panels with the space the Mac leaves between them.

#### Panel surface (panel fill, faint edge, soft shadow) mirrors todayCardSurface
`panel_surface`: The raised surface every panel and lead uses: the panel fill, a faint
edge and a soft shadow (`todayCardSurface`).

#### SectionPanel build order: header, body parts in order added, footer, disclosure
`SectionPanel`: One section of a page on its own raised surface. Build it with the
methods below; it draws when added as a child.

- Header: `icon` or `section`, the title,
  `count`, `alert` (red) or
  `status`, then one `trailing_link`.
- Body, in the order added: `rows` (inset rows divided by
  inset hairlines, like Needs attention), `band` and free
  `child` content.
- `footer`: each call adds to the strip; use
  [`footer_text`] for its words.
- `disclosure`: a collapsed panel whose header opens
  it in place (Full summary).

#### Section icon is taken as the Mac takes it from NavSection.symbol
`SectionPanel::section`: The icon of the sidebar destination this section leads to, as the
Mac takes it from `NavSection.symbol`.

#### Free body content is edge to edge; pad with PANEL_INSET
`SectionPanel::child`: Free body content, edge to edge: pad it with `metric::PANEL_INSET`.

#### Footer adds in order: words first, then trailing-edge link
`SectionPanel::footer`: Adds to the footer strip, in order: words first
([`footer_text`]), then a [`panel_link`] that keeps to the trailing
edge.

#### Panel link is a Button so keyboard can reach it
`panel_link`: A teal link in a panel's header or footer ("All actions", "2 more in
Actions", "Update") (`.workspaceLink`). A button, so the keyboard reaches
it.

#### Lead panel without header mirrors SectionPanelLead; below runs edge to edge
`SectionPanelLead`: A panel with no header bar: what a page leads with, such as a meeting's
recap or a session's title (`SectionPanelLead`). The content is padded;
`below` runs edge to edge under a hairline.

```ignore
SectionPanelLead::new("meeting-recap")
    .child(recap_text)
    .below(player_bar)
```

### `LinuxWindows/crates/lokalbot-app/src/ui/segmented_tabs.rs`

#### Control height includes the 3px track inset
`HEIGHT`: Height of the whole control, including the 3px track inset.

### `LinuxWindows/crates/lokalbot-app/src/ui/settings_row.rs`

#### Settings forms mirror SettingsView.swift label, help, details and grouped sections
Grouped settings forms (`SettingsLabel`, `SettingsHelp`, `SettingsDetails`
and the grouped `Form` sections of `SettingsView.swift`).

A section is a bold title over a rounded panel; each row puts the label and
its help text on the left and the control on the right.

#### Long language menus must scroll; GPUI only auto-enables scrolling for with_menu_items
`picker`: The language list is taller than onboarding's window. GPUI
only enables scrolling automatically for with_menu_items().

### `LinuxWindows/crates/lokalbot-app/src/ui/shortcut_field.rs`

#### Shortcut recorder mirrors ShortcutRecorder.swift; Escape cancels; values like Ctrl+Shift+Space
A shortcut recorder (`ShortcutRecorder.swift`): click, then press the
shortcut. Escape cancels. Values read like "Ctrl+Shift+Space".

#### Recording events let global shortcuts pause meanwhile
`ShortcutEvent::Recording`: Recording started or stopped, so global shortcuts can pause meanwhile.

#### Held modifiers with no key become a chord when all released
`ShortcutField.chord`: Modifiers held since recording began, with no key yet: a chord when they
are all let go (`ShortcutRecorder.handleModifiers`).

#### A key ends the chord, so Ctrl+Alt then D records Ctrl+Alt+D
`ShortcutField::modifiers_changed`: A key ends the chord: Ctrl+Alt then D records Ctrl+Alt+D, not Ctrl+Alt.

#### Shortcuts require Ctrl, Alt or Super; otherwise none
`format_keystroke`: "Ctrl+Shift+Space"; `None` without Ctrl, Alt or Super.

### `LinuxWindows/crates/lokalbot-app/src/ui/side_column.rs`

#### Section gap mirrors WorkspaceMetric.sectionGap
`SECTION_GAP`: Between a page's sections, and between the side column's blocks
(`WorkspaceMetric.sectionGap`).

#### Side column width 252 at standard text size, matching PageSideColumnLayout.sideWidth
`WIDTH`: The side column's width at the standard text size
(`PageSideColumnLayout.sideWidth`).

#### Side column sits beside page only if pane fits both, else under
`beside`: Where the side column goes (`PageSideColumnLayout`): beside the page
while the pane has room for both, under it otherwise.

#### Page column takes what side column leaves, else reading width
`main_width`: How wide the page's own column is (`PageWithSideColumn`), for content
that picks its layout by width: beside the side column it takes what the
column leaves, under it the page keeps to the reading width.

#### Narrow panes put side blocks under page; with no main content blocks are the page
`page`: A scrolling page with a side column of reference blocks at its trailing
edge, divided by a line that runs the pane's height (`PageWithSideColumn`).
A narrow pane puts the blocks under the page. With nothing for the page
itself, the blocks are the page.

#### People name the meeting quietly; Projects show it with date as accent link
`decision_row`: A decision with the meeting it was made in at the trailing edge
(`PageDecisionRow`). People names the meeting quietly; Projects, whose
decisions come from many meetings, shows it with its date as an accent
link (`accent`). `description` is the meeting with its date, on hover.

### `LinuxWindows/crates/lokalbot-app/src/ui/split.rs`

#### Split pane width persists in settings under its key; only dragging changes it
A pane beside the rest of its page, with a divider to drag (`HSplitView`
with `splitPaneAccessibilityLabel`'s `autosaveName`). A pane's width is
kept in settings under its key; dragging is the only thing that changes it.

#### List column limits mirror contentColumnMinWidth and maxWidth 340
`LIST_RANGE`: The list column's limits (`contentColumnMinWidth`, `maxWidth: 340`).

#### Details pane limits mirror detailsMinWidth and detailsMaxWidth in Actions
`DETAILS_RANGE`: The details pane's limits in Actions (`detailsMinWidth`, `detailsMaxWidth`).

#### Pane opens at default until first drag; caller may recompute default per window
`trailing_pane`: `content` filling the page, at least `content_minimum` wide, then `pane`
at a remembered width (Timeline's rail). Until the divider is first
dragged the pane opens at `default`, which the caller may work out from
the window each time.

### `LinuxWindows/crates/lokalbot-app/src/ui/text.rs`

#### GPUI wraps shaped RTL lines in glyph order, so break at Unicode opportunities before shaping
Plain interface paragraphs with logical-order line breaking.

GPUI 0.3.9 wraps an already-shaped line in glyph order. That order is not
logical text order for Arabic/Urdu and can produce overflowing, reversed
rows. Break at Unicode opportunities before shaping each display line.
This adapter leaves the source string, input editors and dependency pins
intact. Single-line/truncated controls retain GPUI's native text element.

#### Prefix direction mark for shaping only, never stored or copied
`paragraph shaping`: Preserve the paragraph's base direction when a wrapped row
happens to begin with a Latin product name or a number.
The mark is for shaping only; it is never stored or copied.

#### Wrap ranges are contiguous: no reordering, lost spaces, or split graphemes
`wrap_ranges`: Contiguous source ranges: no reordering, lost spaces or split graphemes.

### `LinuxWindows/crates/lokalbot-app/src/ui/waveform.rs`

#### Waveform bars are 2px wide at 4px spacing
`BAR_STEP`: Distance between bar starts; bars are 2px wide.

#### Flat line shown until peaks are available, as on macOS
`waveform draw`: Flat line until peaks are available, as on macOS.

#### Draw a filled play triangle because Lucide's play is outlined
`play_glyph`: A filled play triangle (Lucide's play symbol is outlined).

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
