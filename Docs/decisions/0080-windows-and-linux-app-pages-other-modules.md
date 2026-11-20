# 0080. Windows and Linux: app — pages, other modules

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-app/src/pages/`, `LinuxWindows/crates/lokalbot-app/src/pages/people/`.

## Decisions

### `LinuxWindows/crates/lokalbot-app/src/pages/mod.rs`

#### Settings is a separate window, not a page of the main window
One module per sidebar destination. Each page is a GPUI view that also
supplies its toolbar title, subtitle and items to the window shell.
Settings is not a page of the main window: it has its own window
(`windows::settings`).

#### Every section's toolbar keeps the same height with or without a subtitle
`Page.subtitle`: A smaller second line under the title (`navigationSubtitle`): Today's
date, Actions' "2 open". Every section's toolbar keeps the same
height with or without it.

#### A title control replaces title and subtitle text; None draws them as text
`Page.title_control`: A control drawn in the title's place, as Timeline's date opens its
calendar. `None` draws `title` and `subtitle` as text.

### `LinuxWindows/crates/lokalbot-app/src/pages/people.rs`

#### People is listed by time only and stays apart from voice profiles
People (`PeopleWorkspaceView.swift`, `PersonPageView.swift`): everyone
from your meetings, listed by time only (Coming up, Last 2 weeks,
Earlier), and each person's page. The page leads with the next calendar
meeting together and Prepare, then what is open between you, what the
last meeting said and what you decided together; projects, meetings and
other names sit in a side column. People stays apart from voice profiles.

#### Rematch the coming week every 60 seconds so started meetings leave Coming up
`UPCOMING_REFRESH`: How often the coming week is matched again while People is open: a
meeting that has started or ended still has to leave "Coming up" without
a visit elsewhere.

#### Key stops redraws from matching the coming week again
`UpcomingKey`: What the coming week was last matched from, so a page redraw does not
match it again.

#### The user's own names are left out of Coming up
`PeoplePage.self_names`: The user's own names, left out of Coming up.

#### Newest small meeting with outcomes per person feeds Draft follow-up
`PeoplePage.follow_ups`: The newest small meeting with outcomes for each person, for "Draft
follow-up".

#### Next meeting per person by ID; empty without calendar use
`PeoplePage.upcoming`: Each person's next calendar meeting in the coming week, by person ID.
Empty without calendar use.

#### Generation bumps when people, hidden entries or coming week change, rebuilding the list
`PeoplePage.generation`: Bumped whenever the people, the hidden entries or the coming week
change, so the list is built again.

#### Per-person page state resets when another person is chosen
`PeoplePage.shows_all_decisions`: The page's own state, reset when another person is chosen.

#### Coming week is read only with calendar use on and read; nothing is stored
`PeoplePage.refresh_upcoming`: Reads the coming week only while calendar use is on and the calendar
has been read, and matches its meetings to people by the directory's
keys (`refreshUpcoming`). Nothing is stored.

#### A recording storing its calendar event stands in for the upcoming event
`PeoplePage.refresh_upcoming`: A recording that stores its calendar event stands in for it.

#### Empty rename reverts to the name from meetings (PeopleStore.rename)
`PeoplePage.rename`: `PeopleStore.rename`: an empty name goes back to the name from meetings.

#### Merge keeps target's name and selection follows the person the source joined
`PeoplePage.merge`: `PeopleStore.merge`: the target keeps its name, and the selection
follows the person the source joined.

#### Focused person from another page may sit far down the list, so scroll to it
`PeoplePage.take_focus`: Selects a person another page asked to show; they may sit far down
the list.

#### List is rebuilt only when what it shows changed
`PeoplePage.list_content`: The list as drawn, built again only when what it shows changed
(`PeopleListCache`).

#### Merge keeps selection via folded IDs; with nothing chosen the first row's person
`PeoplePage.selected_person`: A merge keeps the selection: an ID folded into someone else finds the
person it joined. With nothing chosen, the first row's person.

#### Looks done? hints for open work are computed only with consent
`hints_for`: "Looks done?" for each person's open work of yours, only with consent.

#### Follow-up meeting must be small enough to be with the person, not a team call
`follow_up_meetings`: The newest meeting with outcomes that was small enough to be with each
person, rather than a team call they happened to attend (`followUpMeeting`).

### `LinuxWindows/crates/lokalbot-app/src/pages/people/detail.rs`

#### Side column sits beside the page when the pane has room, else under it
`PeoplePage.render_detail`: Beside the page while the pane has room for both, under it
otherwise (`PageWithSideColumn`).

#### Summary sizes to its longest line; Prepare wraps under it when they do not fit
`PeoplePage.next_meeting_card`: As wide as its longest line (`ViewThatFits`): when that and Prepare
do not fit one row, Prepare wraps under the words.

#### A call recorded in parts is one meeting opening its longest recording
`PeoplePage.series_row`: A single meeting opens; a series opens to list each date. A call
recorded in parts is one meeting that opens its longest recording
(`MeetingSeriesRow`).

### `LinuxWindows/crates/lokalbot-app/src/pages/people/model.rs`

#### Last 2 weeks group reaches 14 days back
`RECENT_DAYS`: "Last 2 weeks" reaches this many days back.

#### A call recorded in several parts is one occasion with recordings newest first
`Occasion`: One meeting as it happened (`PersonProfile.Occasion`): a call recorded in
several parts is one occasion with several recordings, newest first.

#### The longest recording is the one worth opening
`Occasion.primary`: The longest recording, which is the one worth opening.

#### Series groups occasions sharing a title, newest first
`Series`: Occasions that share a title, such as a weekly standup
(`PersonProfile.Series`). Newest first.

#### Series key is stable across reloads while the title stays
`Series.key`: Stable across reloads while the series keeps its title.

#### Badge shows the user's owed work first when both directions are open
`Badge`: Which way open work runs, as one badge. Work the user owes shows first:
when both directions are open, the badge counts the user's.

#### Amber marks the user's own work; the other person's is quiet
`Badge.needs_attention`: Amber for the user's own work, quiet for the other person's.

#### Detail is the next meeting's title under Coming up, else the latest
`Row.detail`: The next meeting's title under Coming up, else the latest one's.

#### When is the next meeting's time, else the day last met
`Row.when`: The next meeting's time, else the day you last met.

#### Row index counts each group's heading row so the list can scroll to it
`ListContent.child_index`: Where a person's row sits among the list's children, counting each
group's heading row, so the list can scroll to it.

#### Upcoming is empty without calendar use so no Coming up; query matches any name
`ListContent.build`: `upcoming` holds each person's next calendar meeting, by person ID;
it is empty without calendar use, and then there is no Coming up.
`query` matches a person's name or any other name they appear as.

#### Short date adds the year once it is not this year
`short_date`: "Nov 10", with the year once it is not this year
(`lokalbot_i18n::short_date` on the local days).

#### Day label: Today, Yesterday, weekday date for past week, then short date
`day`: "Today", "Yesterday", "Fri, Nov 6" for the rest of the past week, then
"Oct 27" (`lokalbot_i18n::day_label` on the local days).

#### Time alone for today else weekday and time; in-progress meetings show start
`upcoming_time`: "Thu 2:00 PM", or the time alone for a meeting today. A meeting under way
still shows when it started.

#### Twelve-hour ranges show AM or PM once when both ends share it, as on the Mac
`time_range`: "2:00 – 2:30 PM": a twelve-hour clock says AM or PM once when both ends
share it, as the Mac's interval format does.

#### List wording is made for one local day, such as Today and Thu
`local_day`: The day the list's wording was made for: rows say "Today" and "Thu".

#### Below 720 px the toolbar's Ask button shows its icon alone
`COMPACT_TOOLBAR_WIDTH`: Below this width the toolbar's Ask button shows its icon alone.

#### Fixed local Tuesday noon keeps day words independent of machine time zone
`tests::now`: A Tuesday at noon, local time, so the day words do not depend on the
machine's time zone.

### `LinuxWindows/crates/lokalbot-app/src/pages/people/sheets.rs`

#### Chosen name keeps meeting names as other names; Use Name from Meetings shows only after choosing
`PeoplePage.open_rename`: Chooses the name People shows for someone. The names meetings used
stay as other names, and the chosen one is recognized in notes and
owners. "Use Name from Meetings" shows only once a name was chosen.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
