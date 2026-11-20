# 0018. Mac app: Components

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Views/Components/`.

## Decisions

### `LokalBot/Views/Components/FocusOwningTextField.swift`

#### Retry focus across scene transition; AppKit editor may enter tree before window key
`FocusOwningTextField`: An AppKit editor can enter the view tree before a newly opened SwiftUI
window becomes active or key. Keep focus acquisition with the native
control and retry across that short scene transition instead of relying on
a single next-run-loop `makeFirstResponder` call.

#### AppKit ignores SwiftUI layout direction; mirror it for right-to-left windows
`FocusOwningTextField.apply`: AppKit controls don't read SwiftUI's layout direction. Mirror it so the
field and its placeholder start at the leading edge of a right-to-left
window; the text's own bidi order is unaffected.

#### Start editing session so AX reports keyboard focus once window is key
`FocusOwningTextField.attemptFocus`: NSTextField delegates editing to the window's field editor.
Starting that editing session makes the AX text field report
keyboard focus as soon as its containing window becomes key.

### `LokalBot/Views/Components/MarkdownText.swift`

#### Close open emphasis and code spans in streamed text so it renders as final
`StreamingMarkdown`: Answers arrive a few tokens at a time, so the text on screen often stops
inside an emphasis or code span. Closing the span lets it render as it
will once complete, instead of showing its raw markers until it does.

#### Strip trailing markers with nothing inside yet to style
`StreamingMarkdown.closingOpenSpans`: Markers still arriving, with nothing yet inside them to style.

#### Only asterisks touching text open emphasis; '2 * 3' and bullets do not
`StreamingMarkdown.openingAsterisks`: Asterisks that touch text. "2 * 3" and a "* item" bullet open nothing.

#### One attributed Text gives continuous selection; editorial mode keeps Ask's hierarchy
`SelectableDigestText`: A selectable Markdown renderer backed by one SwiftUI `Text`. Keeping the
whole document in one attributed string gives macOS one continuous
selection range, so users can drag across lines and copy only the portion
they need. It supports headings, lists, quotes, fenced code, and GitHub
tables while preserving inline formatting. Editorial mode preserves Ask's
compact type hierarchy and citation treatment without splitting the answer
into selection islands.

#### Extra line spacing for larger reading text overrides style's own
`SelectableDigestText.readingLineSpacing`: Extra space between lines for larger reading text, in place of the
style's own.

#### Agent text and SwiftUI summaries share exactly one parser
`SelectableDigestText.RenderedLine`: Both native Agent text and SwiftUI summaries share exactly one parser.

#### Attributes preserve text selection and accessibility value
`SearchHighlightedText`: Plain transcript text with the same find highlighting used by summary
Markdown. Attributes preserve text selection and accessibility value.

#### Catalog wording until a search needs matches marked
`SearchHighlightedText.interfaceText`: Interface copy as a `Text`, for a place that takes one (a panel's
title): the catalog's wording until a search needs its matches marked.

#### All Markdown uses one AttributedString renderer so selection and syntax do not drift
`MarkdownText`: Compatibility wrapper for older call sites. All Markdown now goes through
the same continuous AttributedString renderer so selection and supported
syntax do not drift between surfaces.

### `LokalBot/Views/Components/SectionPanel.swift`

#### Panel sizes are points at unscaled text size
`SectionPanelMetric`: Sizes the panels share, in points at the unscaled text size.

#### Panel titles sit one step above 13 pt headline
`SectionPanelMetric.titleFont`: Panel titles sit one step above the 13 pt headline.

#### Today and meeting Summary, Transcript, Notes sections are built from these panels
`SectionPanel`: One section of a page on its own raised surface: a header bar with the
section's symbol, name, count and one link; rows under a hairline; and a
footer strip for the one extra line a section has. Today, and a meeting's
Summary, Transcript and Notes, are made of these.

#### Section with sidebar destination uses that destination's symbol
`SectionPanel.systemImage`: The symbol beside the title; for a section with a sidebar destination,
that destination's symbol.

#### Alert is a red badge beside the count
`SectionPanel.alert`: A red badge beside the count, such as "1 overdue".

#### Status badge says where the section stands
`SectionPanel.status`: A badge that says where the section stands, such as "2 open" or
"All done".

#### Panel title identifier is identifier plus .title
`SectionPanel.identifier`: Names the panel; its title is `<identifier>.title`.

#### titleID is where a scroll to the heading lands
`SectionPanel.titleID`: Where a scroll to the section's heading lands.

#### Trailing field takes room title leaves, up to its maximum
`SectionPanel.trailingFills`: The trailing control is a field: it takes the room the title leaves,
up to its own maximum, where a link keeps its own width.

#### Long title may wrap to second line in narrow panel
`SectionPanel.titleLineLimit`: A long title may take a second line in a narrow panel instead of
being cut short.

#### Plain text title: selectable text with header trait loses words for assistive tools
`SectionPanel.header`: Plain text: selectable text with the header trait loses its
words for assistive tools.

#### Header keeps button role so it is named by title and reports open state
`SectionPanel.disclosureHeader`: The header as one button. It keeps the button's role, so it is named
by its title and says whether the body is open.

#### Title layout priority before spacer, which would take half the bar
`SectionPanel.titleText`: Before the spacer, which would otherwise take half the bar.

#### Supporting colour stays above 4.5:1 on strip fill
`SectionPanel.footer`: The supporting colour stays above 4.5:1 on the strip's fill.

#### Headerless lead panel; below body under edge-to-edge hairline
`SectionPanelLead`: A panel with no header bar: what a page leads with, such as a meeting's
recap or the title of a session. `below` is a body under a hairline that
runs edge to edge, for a lead that also holds what it names.

#### Scrolling body stays inside rounded corners
`SectionPanelLead.body`: A body that scrolls stays inside the rounded corners.

#### Footer words take strip width and wrap; link stays trailing
`sectionPanelFooterText`: The words of a panel's footer: they take the strip's width and wrap,
and the link after them keeps to the trailing edge.

#### Band carries footer fill and hairline below; band after rows adds hairline above
`SectionPanelBand`: A labelled band across a panel's body, over a group of its rows ("For
you · 2"). It carries the footer strip's fill and a hairline under it; a
band after rows also draws the hairline above.

#### Supporting colour stays above 4.5:1 on band fill
`SectionPanelBand.body`: The supporting colour stays above 4.5:1 on the band's fill.

### `LokalBot/Views/Components/WorkspacePageBlocks.swift`

#### No header trait: it changes accessibility element, breaking static-text queries
`PageSectionHeading.body`: No header trait: a header becomes a different accessibility
element, which static-text queries no longer find.

#### People names meeting quietly; Projects shows it with date as link
`PageDecisionRow`: A decision with the meeting it was made in at the trailing edge. People
names the meeting quietly; Projects, whose decisions come from many
meetings, shows it with its date as a link.

#### Meeting with date, shown on hover and for VoiceOver
`PageDecisionRow.linkDescription`: The meeting with its date, on hover and for VoiceOver.

#### Side column beside page when pane fits both; widths grow with text size
`PageSideColumnLayout`: Where the side column goes: beside the page while the pane has room for
both, under it otherwise. Both widths grow with the text size.

#### Page keeps at least this width beside the column
`PageSideColumnLayout.pageMinimumWidth`: The page keeps at least this much beside the column.

#### Side column at trailing edge; narrow pane puts blocks under page
`PageWithSideColumn`: A scrolling page with a side column of reference blocks at its trailing
edge, divided by a line that runs the pane's height. A narrow pane puts
the blocks under the page. With nothing for the page itself, the blocks
are the page.

#### Amber chip for attention; selected row uses row's own foreground
`LabelChip`: A capsule label: amber for what needs the reader, quiet otherwise. On a
selected list row it takes the row's own foreground.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
