# 0010. Mac app: Autocomplete

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Views/Autocomplete/`.

## Decisions

### `LokalBot/Views/Autocomplete/AutocompleteExperienceView.swift`

#### Readiness shared by page notices and Try it sheet
`AutocompleteReadiness`: What autocomplete runs on and whether it can run, shared by the page's
notices and the "Try it…" sheet.

#### Server autocomplete has nothing to download, only setup to finish
`AutocompleteReadiness.usesServer`: Autocomplete runs on a server: nothing to download, only setup to finish.

#### Notices only for what header lacks: macOS predictions, server setup or failure
`AutocompleteNotices`: What the Autocomplete page has to say that its header does not: macOS's
own predictions showing beside LokalBot's, and a server that is not set
up or has just failed. Nothing when there is nothing to say.

#### macOS inline predictions re-read each time LokalBot comes forward
`AutocompleteNotices.systemPredictionsOn`: macOS's own inline predictions, read again each time LokalBot comes forward.

#### Test runner keyboard settings must not change layout under test
`AutocompleteNotices.readSystemPredictions`: The test runner's own keyboard settings must not change the layout under test.

#### Two grey suggestions look broken; ask for macOS one off, as Cotypist does
`AutocompleteNotices.systemPredictionsNotice`: Two grey suggestions at the same caret look broken, so ask for the
macOS one to be turned off, as Cotypist does.

#### Rehearsal runs real prompt, model, normalizer without touching statistics or learning store
`AutocompleteTrySheet`: "Try it…" on Autocomplete: the rehearsal, over the page. It runs the real
prompt, model and normalizer with the page's settings, without touching
the acceptance statistics or the learning store.

#### Model downloadable here to try it; licence linked beside it
`AutocompleteTrySheet.body`: Download it here to try it; its licence is linked beside it.

#### No Return or Escape shortcut on Done; reply field owns both
`AutocompleteTrySheet.body`: No Return or Escape shortcut: both belong to the reply field,
where Escape dismisses a suggestion.

#### Server receives rehearsal text as it receives typing in other apps
`AutocompleteTrySheet.explanation`: What typing here does and does not send. A server receives the
rehearsal's text as it receives typing in other apps.

#### Context use is nil until a suggestion has been generated
`AutocompleteRehearsal.contextUse`: What the visible suggestion drew on; nil until one has been generated.

#### Each request starts one generation and ends the previous; view owns task
`AutocompleteRehearsal.request`: The text a suggestion is wanted for. Each new request starts one
generation and ends the one before; the view owns the task's life.

#### No identifier on container; it would replace identifiers of inner elements
`AutocompleteRehearsal.body`: No identifier here: on a container it would replace the
identifier of every element inside.

#### Accept or typing suggested characters keeps rest of ghost; other edits make it stale
`AutocompleteRehearsal.preview`: An accept or typing the suggested characters keeps the
rest of the ghost, as in another app; anything else is stale.

#### Re-run in-use rehearsal on grant change; setting alone must not load model
`AutocompleteRehearsal.preview`: Re-run a rehearsal that is in use so the change shows at
once; a setting alone should not load the model.

#### Expose ghost text as accessibility value since ghost is painted
`AutocompleteRehearsal.preview`: The text the button would insert: the ghost is painted,
so this is how assistive technology can read it.

#### Synthetic exchange is the text above the field for visible-text setting
`AutocompleteRehearsal.conversation`: A synthetic exchange the reply answers. It is the "text above the field"
for this rehearsal, so the visible-text setting has something to read.

#### Single accessibility element with explicit label; combining dot and text gave empty label
`AutocompleteRehearsal.contextSources`: One element with an explicit label: combining the
dot and the styled text left assistive technology
with an empty label.

#### Explain hidden answers so working model suggesting nothing does not look broken
`AutocompleteRehearsal.explanation`: Why the model's answer is not on screen, so a working model that
suggested nothing does not look like a broken one.

#### New request replaces earlier one; SwiftUI cancels its generation
`AutocompleteRehearsal.schedule`: Asks for a suggestion for the text as it stands. The request replaces
any earlier one, whose generation SwiftUI then cancels.

#### Never show suggestion for changed text; any change cancels this request
`AutocompleteRehearsal.generate`: Never show a suggestion for text that has since changed: any
change makes a new request and cancels this one.

#### Accept planned by same code as live field
`AutocompleteRehearsal.accept`: One accept keypress, planned by the same code as a live field: the
accept key takes the configured word or phrase and leaves the rest.

#### Keep ghost few words ahead using live-field rules
`AutocompleteRehearsal.topUp`: Keeps the ghost a few words ahead while it is accepted or typed
through, by the same rules as a live field.

#### Clear context rows when no suggestion is on screen
`AutocompleteRehearsal.dismiss`: No suggestion is on screen any more, so there is nothing its
context rows could describe.

#### Counters answer what benchmarks cannot: timing, landing in field, being kept
`AutocompleteMeasurements`: Counters and timings from typing in other apps. They answer what a model
benchmark cannot: whether suggestions arrive in time, whether an accepted
one lands in the field, and whether it is kept.

#### Show effective context state under switch; nothing while switch is off
`CotypingContextStateLabel`: The effective state of an optional context source, shown under its switch:
nothing while the switch is off, otherwise whether it can contribute now.

### `LokalBot/Views/Autocomplete/AutocompleteServerSetup.swift`

#### Typing goes to server only after origin approved for autocomplete; Think approval does not cover
`AutocompleteServerSetup`: The Autocomplete picker's server pane: Think's server with the same or
another model, or any OpenAI-compatible server, hosted or on the user's own
network. It edits a draft that Use model applies. Typing goes to a server
only after its origin is approved for autocomplete; Think's approval does
not cover it.

#### Approval belongs to one origin; show saved choice for new server
`AutocompleteServerSetup.body`: An approval belongs to one origin. Show the saved choice for a
newly entered server rather than carrying the checkbox over.

#### Approval checkbox states what is sent; none needed for loopback server
`AutocompleteServerSetup.access`: The approval checkbox, with what it sends. Nothing to approve for a
server on this Mac.

### `LokalBot/Views/Autocomplete/AutocompleteSettingsPage.swift`

#### Server receives enabled context; only this Mac can promise nothing kept
`AutocompleteSettingsSections.readingSection`: A server receives what is turned on here; only this Mac can
promise that nothing it reads is kept.

#### Model or server chosen in same picker Models settings uses
`AutocompleteSettingsSections.moreSection`: The model, or a server, is chosen in the same picker Models uses.

### `LokalBot/Views/Autocomplete/AutocompleteStatisticsView.swift`

#### Counts shown, taken and self-typed; prices keystrokes at user's typing speed
`AutocompleteStatisticsView`: Settings → Autocomplete → Statistics: how much autocomplete wrote for you. It
counts what was shown as well as what was taken, and what you typed
yourself, so it can say how often a suggestion is used and how much of
your text it wrote, and it prices keystrokes at your own typing speed.

#### Hide statistics when autocomplete never used and is off
`AutocompleteStatisticsView.body`: Nothing to show and nothing coming: autocomplete was never used and is off.

#### Period applies to everything below, so it sits with the title
`AutocompleteStatisticsView.body`: The period applies to everything below, so it sits with the title.

#### Tiles four across when they fit, else two by two, equal height
`AutocompleteStatisticsView.tiles`: Four across when they fit, otherwise two by two; tiles in a row share its height.

#### Model breakdown shown only when there is another model to compare
`AutocompleteStatisticsView.breakdowns`: A model column says something only once there is another to compare.

#### Wording and formats kept apart from the view so they can be tested
`AutocompleteStatisticsPresentation`: Wording and number formats for the statistics, apart from the view so
they can be tested.

#### Chart spans whole periods so first and last bars are not cut
`AutocompleteStatisticsPresentation.domain`: The chart spans whole periods, so the first and last bars are not cut in half.

#### Headroom above tallest bar; floor so quiet week is not full height
`AutocompleteStatisticsPresentation.wordCeiling`: Headroom above the tallest bar, and a floor so a quiet week is not drawn full height.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
