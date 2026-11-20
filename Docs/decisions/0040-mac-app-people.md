# 0040. Mac app: People

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Models/People/`, `LokalBot/Services/People/`, `LokalBot/Views/People/`, `LokalBotTests/Models/People/`, `LokalBotTests/Services/People/`.

## Decisions

### `LokalBot/Models/People/PeopleCuration.swift`

#### Corrections saved in people/curation.json keyed by opaque person ids, never addresses
`PeopleCuration`: Corrections the person made in People: names they chose, people they
merged, and entries hidden as not a person. Saved as
`people/curation.json` in the library. Everything else about a person is
derived from the library each time it is shown. Keys are the opaque
person ids from `PeopleDirectory`, never attendee addresses.

#### Merges applied in order after automatic joins
`PeopleCuration.merges`: Applied in order, after the automatic joins.

#### Read-only load for code without the app's store, such as CLI
`PeopleCuration.load`: Read-only load for code without the app's store, such as the CLI.

### `LokalBot/Models/People/PeopleDirectory.swift`

#### Read only user-applied names and calendar links, never speaker evidence
`MeetingAppliedSpeakerNames`: Speaker names applied in one meeting's transcript. Only user-applied
display names and their calendar-attendee links are read; speaker
evidence, suggestions, and voice-profile identities never are.

#### Key names by canonical speaker key so summary lines reach the person
`MeetingAppliedSpeakerNames.namesBySpeakerKey`: Applied name keyed by the speaker label's canonical key ("them 4"),
so a summary line or decision by that speaker reaches the person.

#### User's own microphone label is not another person
`MeetingAppliedSpeakerNames.load`: The user's own microphone label is not another person.

#### Attendee emails are private join keys, never in profile or id
`PersonProfile`: One person the user meets, assembled from local meeting metadata:
calendar attendee names, speaker names the user applied, and action
owners. Attendee email addresses are used only as private join keys and
never appear in a profile, its id, or anything derived from it.

#### Parts of one call recorded separately share a calendar event
`PersonProfile.MeetingRef.calendarEventID`: The calendar event the recording belongs to. Parts of one call
recorded separately share it.

#### Counts named people other than the user
`PersonProfile.MeetingRef.participantCount`: Named people in the meeting other than the user.

#### A call recorded in several parts is one occasion
`PersonProfile.Occasion`: One meeting as it happened: a call recorded in several parts is one
occasion with several recordings.

#### Recordings are ordered newest first
`PersonProfile.Occasion.recordings`: Newest first.

#### Longest recording is the primary one worth opening
`PersonProfile.Occasion.primary`: The longest recording, which is the one worth opening.

#### Occasions sharing a title form a series, such as a weekly standup
`PersonProfile.Series`: Occasions that share a title, such as a weekly standup.

#### Series occasions are ordered newest first
`PersonProfile.Series.occasions`: Newest first.

#### Speaker is nil for the person's own and unnamed lines
`PersonProfile.NotePoint.speaker`: Who said it when that is someone other than the person: "You" or
a named speaker. Nil for the person's own lines and unnamed ones.

#### Points reference the specific part recording, since parts have separate notes
`PersonProfile.NotePoint.meetingID`: The recording the line is from; a call recorded in parts has
notes for each part.

#### Link id is the project's id on the Projects page
`PersonProfile.ProjectLink.id`: The project's id on the Projects page.

#### Keep all folded person ids so earlier corrections still apply after joins change
`PersonProfile.memberIDs`: Every person id folded into this one, its own first; corrections
saved under an earlier id still apply after automatic joins change.

#### Meetings newest first, including every part of a split call
`PersonProfile.meetings`: Newest first; every recording, including parts of one call.

#### Holds open or deferred work this person owns
`PersonProfile.theirActions`: Open or deferred work this person owns.

#### User's open work naming the person or from a small meeting with them
`PersonProfile.myActions`: The user's open work that names this person or came from a small
meeting with them.

#### Filled by WorkMemoryConnections from meeting summaries
`PersonProfile.recentNotes`: Filled by `WorkMemoryConnections` from meeting summaries.

#### Filled by WorkMemoryConnections once projects are known
`PersonProfile.projects`: Filled by `WorkMemoryConnections` once projects are known.

#### Recordings grouped into meetings, newest first
`PersonProfile.occasions`: Recordings grouped into the meetings they belong to, newest first.

#### Meetings this small count as 'with' each person for user's commitments
`PeopleDirectory.smallMeetingSize`: A meeting with at most this many other named participants counts as
"with" each of them for the user's own commitments.

#### Only small meetings give decisions to every attendee; larger ones only speaker or named person
`PeopleDirectory.decisionMeetingSize`: Decisions from meetings this small belong to every attendee; an
all-hands decision is not a decision made "with" each attendee, so
in larger meetings only the person who said it or is named gets it.

#### Same-title recording within 15 minutes with no calendar event is the same call
`PeopleDirectory.recordingGapTolerance`: A second recording that starts within this long after the first one
ends, with the same title and no calendar event, is the same call.

#### User's own names default to Mac account name and are never listed as others
`PeopleDirectory.Input.selfNames`: The user's own names (the Mac account's full name by default);
matching names are never listed as other people.

#### A chosen name also identifies the person in owners and notes
`PeopleDirectory.build`: A chosen name also identifies the person in owners and notes.

#### Resolve stored roster keys to the person they now belong to after merges
`PeopleDirectory.build`: Rosters were recorded while people were still being merged; resolve
each stored key to the person it now belongs to.

#### Owners first seen in actions can be merged only after registering them
`PeopleDirectory.build`: Owners first seen in actions can be merged only now.

#### Recordings merge by calendar event, else same title within the gap tolerance
`PeopleDirectory.occasions`: Recordings grouped into the meetings they belong to, newest first. Two
recordings on one day are one meeting when they share a calendar
event, or, without one, a title and the second started within
`recordingGapTolerance` of the first one ending.

#### Name match needs full name or capitalized 3+ letter first name; common-word names ignored at sentence start
`PeopleDirectory.isNamed`: Whether text names the person: their full name, or a first name of
three or more letters, written with a capital as names are. A name
that is also a common word ("Will", "May") does not count at the
start of a sentence.

#### Resolve owners by meeting roster first, then unique full-name match
`PeopleDirectory.person(forOwner:meetingID:in:)`: Resolves an owner label written in one meeting to a person, using the
same rules as the directory: that meeting's roster first, then a
unique full-name match across everyone.

#### Speaker labels are per meeting and collective words name no one
`PeopleDirectory.isPlaceholder`: Speaker labels are per meeting ("Them 4" is someone different in
every call) and collective words name no one, so neither is a person.

#### Strip meeting-merge source suffixes and trailing parenthetical notes from names
`PeopleDirectory.cleanedName`: Removes the "· source 2" suffixes meeting merges add to speaker names
and trailing notes such as "(Them 3)" or "(host)".

#### Model-written action owners often name groups; accept only one to four name-like words
`PeopleDirectory.isPersonName`: Action owners are model-written and often name a group or a role
("Engineering team", "Product/research", "Go roadmap owner"). Only
one to four name-like words count as a person.

#### Comma-separated owner lists name several people, so are not one person
`PeopleDirectory.isPersonName`: "Matt, John, and Emil" is several people.

#### Public-provider single-word mailboxes are handles; only first.last counts there
`PeopleDirectory.nameFromAddress`: The name the rename picker suggests from an attendee address. Company
mailboxes are usually a first name ("dragan@…"); on public providers a
single-word mailbox ("donaldkevlee@gmail…") is a handle, so only a
spelled-out "first.last" counts there.

#### Single-word account name also matches any full name starting with it
`PeopleDirectory.SelfMatcher`: Matches the user's own full name or a bare first name equal to theirs.
When the account name is a single word ("Stevan"), any name that
starts with it ("Stevan Bogosavljevic") is treated as the user too.

#### Person ids are FNV-1a hashes of private join keys, stable and opaque
`PeopleDirectory.opaqueID`: FNV-1a over the private join key gives a stable, opaque identifier.

#### Join by address, else name; name-only merges into a unique address-keyed person
`PeopleDirectory.Registry`: Joins calendar identities by address when present, otherwise by full
normalized name. A name-only person merges into an address-keyed one
when exactly one address-keyed person carries that full name.

#### Merged-away keys redirect so stored roster keys still resolve
`PeopleDirectory.Registry.redirects`: A merged-away key points to the person it joined, so keys stored
before the merge (meeting rosters) still reach the right person.

#### Merge target keeps the name it was shown under
`PeopleDirectory.Registry.mergeTargetNames`: The name a merge target was shown under when the person merged
someone into it, so the target keeps its name.

#### Saved ids resolve to the current person from any of their keys
`PeopleDirectory.Registry.key(forID:)`: The person a saved id belongs to now, whichever of their keys
the id was made from.

#### Fold an earlier name-only entry into the address once seen
`PeopleDirectory.Registry`: Fold an earlier name-only entry into this address.

#### Exact full-name match first, then unique first-name match
`PeopleDirectory.Registry.resolve`: Exact full-name match first, then a unique first-name match.

#### Apply user merges in order; merges with absent people wait
`PeopleDirectory.Registry.applyMerges`: Merges the person chose, in the order they made them. A merge
whose people are not in the library (yet) waits.

#### Rank names by fullest first, then most frequent spelling
`PeopleDirectory.Registry.rankedNames`: The fullest name first ("Ana Petrović" over "Ana"), then the most
frequently seen spelling.

#### Lone first name joins the one full name starting with it; distinct addresses never join
`PeopleDirectory.Registry.mergeFirstNamesIntoFullNames`: A first name alone ("Dragan", often applied to a speaker) joins the
one person whose full name starts with it ("Dragan Cabarkapa").
Two different attendee addresses are never joined.

#### Name precedence: user-chosen, then merge target's, then best-ranked
`PeopleDirectory.Registry.profiles`: A name the person chose wins, then the name a merge target
had, then the best-ranked name.

#### Sort decisions by date then id for stable order between rebuilds
`PeopleDirectory.Registry.profiles`: Decisions of one meeting keep one order between rebuilds.

### `LokalBot/Models/People/PeopleListPresentation.swift`

#### People list is search-filtered, grouped by time only, wording prebuilt
`PeopleListContent`: The People list as it is drawn: who matches the search, grouped by time
only, with each row's wording already made.

#### Coming up is next week's calendar meetings; others by last meeting
`PeopleListContent.Group`: Calendar meetings in the next week, then when you last met.

#### Title is a localization catalog key
`PeopleListContent.Group.title`: The catalog key of the group's heading.

#### Badge shows work user owes first when both directions are open
`PeopleListContent.Badge`: Which way open work runs, as one badge. Work the user owes shows
first: when both directions are open, the badge counts the user's.

#### Amber for user's own work, quiet for the other person's
`PeopleListContent.Badge.needsAttention`: Amber for the user's own work, quiet for the other person's.

#### Next meeting's title under Coming up, else the latest meeting's
`PeopleListContent.Row.detail`: The next meeting's title under Coming up, else the latest one's.

#### Next meeting's time, else the day last met
`PeopleListContent.Row.when`: The next meeting's time, else the day you last met.

#### Last 2 weeks group reaches back 14 days
`PeopleListContent.recentDays`: "Last 2 weeks" reaches this many days back.

#### Upcoming is empty without Calendar access; query matches any of a person's names
`PeopleListContent.build`

- Parameters:
  - upcoming: each person's next calendar meeting, by person id; empty
without Calendar access, and then there is no Coming up group.
  - query: matches a person's name or any other name they appear as.

#### Wording is built from counts, dates, names; localize looks up catalog keys
`PeopleWording`: Wording on a person's page that is put together from counts, dates and
names. `localize` looks a catalog key up in the interface language.

#### Three decisions show before the Show more control
`PeopleWording.visibleDecisions`: Decisions shown before "Show N more".

#### Eight meeting titles show in the side column before Show more
`PeopleWording.visibleSeries`: Meeting titles shown in the side column before "Show N more".

#### Three other invitees are named on the next-meeting card
`PeopleWording.visibleInvitees`: Other invited people named on the next-meeting card.

#### Meeting today shows time alone; in-progress meeting still shows its start
`PeopleWording.upcomingTime`: "Thu 2:00 PM", or the time alone for a meeting today. A meeting under
way still shows when it started.

#### Day distance comes from the system in the interface language
`PeopleWording.nextMeetingLine`: "Next meeting in 2 days · Thu, Nov 12, 2:00 – 2:30 PM". The distance
in days comes from the system in the interface language.

#### Series shows count and date; single meeting shows date alone
`PeopleWording.seriesDetail`: Under a title in the side column: "22 meetings · Nov 10" for a
series, the date alone for a single meeting.

#### Year shown only when the date is not this year
`PeopleWording.shortDate`: "Nov 10", with the year once it is not this year.

#### Use interface language formats with reader's clock so 24-hour preference holds
`PeopleWording.formattingLocale`: The interface language's formats with the reader's own clock, so a
24-hour preference holds under any interface language and a meeting
reads the same here as on Today.

#### Prepare hands Agent newest notes, projects, open work, decisions; not the calendar event
`PersonPreparation`: What "Prepare" hands to Agent: the person's newest notes, projects, open
work in both directions and recent decisions. The calendar event that
offered it adds nothing.

### `LokalBot/Models/People/PeopleUpcomingMeetings.swift`

#### Holds names only; invited addresses without display name are left out
`PersonUpcomingMeeting`: The next calendar meeting with one person, as People shows it. It holds
names only: an invited address without a display name is left out.

#### Other invitees by display name in invitation order, excluding person and user
`PersonUpcomingMeeting.others`: Everyone else invited, by display name, in the invitation's order.
The person and the user are not listed.

#### Match attendees via directory keys, address then name; nothing stored
`PeopleUpcomingMeetings`: Matches upcoming calendar events to people through the keys
`PeopleDirectory` already registers for an attendee: the address, then the
name. Nothing is stored; a match lasts as long as the page shows it.

#### Coming up looks 7 days ahead
`PeopleUpcomingMeetings.windowDays`: "Coming up" looks this many days ahead.

#### Attendee matching by address or full name; ambiguous names never guessed; nil events means no calendar
`PeopleUpcomingMeetings.match`: The soonest event for each person, keyed by person id. `events` is nil
while Calendar use is off or access is missing, and then nobody has one.

An attendee with an address is the person registered under that
address, or the one still known only by that full name. An attendee
without an address is the one person carrying that full name, or, for a
lone first name, the one person whose full name starts with it. Two
people who share a name are never guessed between.

#### Calendar read only when enabled and authorized; otherwise nothing fetched or requested
`PeopleUpcomingMeetings.events`: Calendar events are read only while Calendar use is on and access has
been granted. Otherwise nothing is fetched and nothing is asked for.

#### Match by hashed directory keys without ever holding an address
`PeopleUpcomingMeetings.Index`: Looks attendees up by the directory's own keys without ever holding an
address: a person's ids are hashes of those keys.

#### Name-only person takes the address later; different address stays a different person
`PeopleUpcomingMeetings.Index`: A person so far known only by this name takes the address
when the directory next sees it; someone registered under
another address stays a different person.

### `LokalBot/Models/People/PersonNotes.swift`

#### Deterministic line matching over local summaries; no model reads anything
`PersonNotes`: What saved meeting notes say about one person, and the projects named
around them. Deterministic line matching over summaries already on this
Mac; no model reads anything here.

#### Search the newest 8 meetings for notes about the person
`PersonNotes.maximumMeetingsSearched`: Newest meetings searched for notes about the person.

#### 20 meetings can link a person to a project
`PersonNotes.projectMeetingsSearched`: Meetings whose lines can link the person to a project.

#### Skip sections shown elsewhere or restating meeting facts
`PersonNotes.skippedSections`: Sections already shown elsewhere on a person's page (actions and
decisions), or that only restate the meeting's facts.

#### Overview sections serve meetings held only with the person
`PersonNotes.overviewSections`: Sections that sum the meeting up, for a meeting that is only with
the person.

#### Checkbox bullets are actions and are skipped
`PersonNotes.lines(fromSummary:)`: Checkbox bullets are actions.

#### Strip transcript stamp forms and return the first as seek time
`PersonNotes.trailingTimestamp`: Removes the transcript stamps notes carry — a trailing
"— [00:01:54]", a range "([00:40:44]–[00:44:40])", or stamps inside
the line — and returns the first one as the moment to open.

#### Long notes are cut at a word near 280 characters
`PersonNotes.maximumCharacters`: Long notes are cut at a word near this length.

#### Keep lines said by or naming the person; nil for lines about others
`PersonNotes.point`: A summary line said by the person or naming them, as shown on their
page; nil when the line is about someone else.

#### Newest matching meeting, up to three lines; solo meetings fall back to overview lines
`PersonNotes.recentNotes`: The newest meeting whose notes say something about the person, with
up to three lines. A meeting only with them (at most
`PeopleDirectory.smallMeetingSize` others) offers its overview lines
when no line names them.

#### Link projects named in person's lines, work, decisions; tracked first, then frequency
`PersonNotes.projects`: Projects whose names appear in the person's own lines, the lines
naming them, their open work, and decisions with them. Tracked
projects first, then by how often they come up.

#### Cheap substring prefilter before the word-by-word name match
`PersonNotes.mayName`: A cheap check before the word-by-word one.

### `LokalBot/Services/People/PeopleStore.swift`

#### Curation saved as people/curation.json, small JSON written on main actor
`PeopleStore`: The person's corrections in People — chosen names, merges, and entries
hidden as not a person — saved as `people/curation.json` in the library.
A small JSON file, written on the main actor.

#### Not a Person hides entry from People, Projects and CLI
`PeopleStore.hide`: "Not a Person": the entry no longer appears in People, Projects, or
the CLI.

### `LokalBot/Services/People/WorkMemoryConnections.swift`

#### People and Projects derived each refresh; nothing persisted, deletions reflected
`WorkMemoryConnections`: Builds the People and Projects read models off the main actor from local
meeting metadata, summaries, transcripts, outcomes, applied speaker names,
tracked projects, People corrections, Dream projects, and activity
titles. Nothing is persisted here; every refresh derives from the current
library, so deletions and corrections are reflected immediately.

#### Applied names read from 180-day window, cached by file date
`WorkMemoryConnections.transcriptLookbackDays`: Applied speaker names are read from transcripts; only meetings from
this window are opened, and results are cached by file date.

#### Summaries matched whole; cap guards only runaway files
`WorkMemoryConnections.maximumSummaryCharacters`: Summaries are matched whole; this only guards against a runaway file.

#### Coalesce bursts of changes with 250 ms delay
`WorkMemoryConnections.refresh`: Coalesce bursts of outcome and library changes.

#### Uncached profile builder for phones and tablets outside views
`WorkMemoryConnections.profiles(for:)`: The people and projects one refresh would publish, without caches,
for builders that run outside the app's views (phones and tablets).

#### Project names spoken in calls count even without summary mention
`WorkMemoryConnections.compute`: Project names said in the call count even when the summary
leaves them out or the meeting has no summary.

#### People, user and apps never become projects
`WorkMemoryConnections.excludedTopicWords`: People, the user, and apps are recurring capitalized words but never
projects of their own.

#### Exclude 3-4 letter short forms of long names
`WorkMemoryConnections.excludedTopicWords`: Short forms people are called by ("Ben" for Benjamin).

### `LokalBot/Views/People/PeopleWorkspaceView.swift`

#### People list is grouped by time only; names, merges and hides live in PeopleStore
`PeopleWorkspaceView`: Everyone the user meets, joined across calendar attendees, names applied
to speakers, and action owners. The list is grouped by time only: people
in calendar meetings in the next week, the last two weeks, and earlier.
The page beside it leads with the next meeting, then what is open between
you, what the last meeting said and what you decided together. Names,
merges, and hidden entries the person chose live in `PeopleStore`.

#### Upcoming meetings are empty without Calendar access
`PeopleWorkspaceView.upcoming`: Each person's next calendar meeting in the coming week, by person id.
Empty without Calendar access.

#### Calendar is re-read every 60 seconds while People is open
`PeopleWorkspaceView.upcomingRefreshSeconds`: How often the coming week's calendar is read again while People is open.

#### Poll calendar so started or ended meetings leave Coming up without navigating
`PeopleWorkspaceView.body`: The coming week changes slowly; a meeting that has started or
ended still has to leave "Coming up" without a visit elsewhere.

#### Read calendar only when Calendar use is on and access granted
`PeopleWorkspaceView.refreshUpcoming`: Reads the calendar only while Calendar use is on and access is
granted, and matches its events to people by the directory's keys.

#### Merge keeps selection by following folded ids; default is first row
`PeopleWorkspaceView.selectedPerson`: A merge keeps the selection: an id folded into someone else finds
the person it joined. With nothing chosen, the first row's person.

#### Follow-up uses newest outcome meeting small enough to be with this person
`PeopleWorkspaceView.followUpMeeting`: The newest meeting with outcomes that was small enough to be with
this person, rather than a team call they happened to attend.

#### Heading rows scroll with people and arrow keys skip them
`PeopleListColumn`: A heading row, as in the Meetings list: it scrolls
with its people and arrow keys pass over it.

#### Scroll to a person opened from elsewhere since it may be far down
`PeopleListColumn`: A person opened from Actions, Projects, a meeting or Ask
may sit far down the list.

#### Cache list by inputs because page redraws far more often than they change
`PeopleListCache`: Remembers the list for the inputs it was built from: the page redraws far
more often than its people, their calendar or the search change.

#### Selection comes from list; supporting grey is unreadable on teal highlight
`PersonRow.isSelected`: From the list's selection, like the meeting rows: the supporting grey
does not read on the teal highlight.

#### Chosen name keeps meeting names as other names and is recognized in notes
`PersonNameSheet`: Chooses the name People shows for someone. The names meetings used stay
as other names, and the chosen one is recognized in notes and owners.

### `LokalBot/Views/People/PersonPageView.swift`

#### Next meeting leads; empty sections hidden; side column keeps page short
`PersonDetailView`: One person's page. The next calendar meeting with them leads when there
is one, then what is open between you, what the last meeting said, and
what you decided together. Projects, meetings and other names sit in a
side column, so a long history fits one screen and someone met once has a
short page. A section with nothing in it is not shown.

#### Next meeting is nil without Calendar access, page starts with open work
`PersonDetailView.nextMeeting`: The next calendar meeting with the person in the coming week. Nil
without Calendar access, and then the page starts with open work.

#### Stale work keeps its Still open line
`PersonDetailView.openWork`: One section, two labelled parts: what the user owes, then what the
person owes. Stale work keeps its "Still open?" line.

#### A call recorded in parts is one meeting opening its longest recording
`MeetingSeriesRow`: A meeting title in the side column: a single meeting opens, and a series
opens to list each date. A call recorded in parts is one meeting that
opens its longest recording.

### `LokalBotTests/Models/People/PeopleDirectoryTests.swift`

#### All-hands decisions are not attributed to every attendee
`PeopleDirectoryTests.testMyActionsNameThePersonOrComeFromASmallMeeting`: All-hands decisions are not attributed to every attendee.

#### Fixture: calendar-less 1:1 with applied speaker name plus later calendar meeting
`PeopleDirectoryTests.testMergedPeopleKeepTheirMeetingActionsAndDecisionsInEitherInputOrder`: A 1:1 recorded without a calendar event, where the user applied the
speaker name, and a later calendar meeting with the same person.

#### A first name shared by two people stays separate
`PeopleDirectoryTests.testAFirstNameJoinsTheOnePersonWithThatFullName`: Two people share the first name, so "Ana" alone stays separate.

### `LokalBotTests/Models/People/PeopleListPresentationTests.swift`

#### Fixture people and when each last met and what is open
`PeopleListPresentationTests.library`: Ana: met yesterday, work open both ways. Marko: three days ago, owes
one. Petar: an hour ago. Ivana: 20 days ago. Lena: 40 days ago.

#### Times use narrow and thin spaces; compare words
`PeopleListPresentationTests.plain`: Times come with narrow and thin spaces; compare the words.

### `LokalBotTests/Models/People/PeopleUpcomingMeetingsTests.swift`

#### Fixture: two people share a full name; a third known only by speaker name
`PeopleUpcomingMeetingsTests.testANameFindsOnlyTheOnePersonWhoCarriesIt`: Two people share a full name under different addresses; a third is
known only by a name the user gave a speaker.

#### A new address under a shared name is nobody People knows
`PeopleUpcomingMeetingsTests.testANameFindsOnlyTheOnePersonWhoCarriesIt`: A new address under a shared name is nobody People knows.

#### A name-only invitation cannot choose between same-named people
`PeopleUpcomingMeetingsTests.testANameFindsOnlyTheOnePersonWhoCarriesIt`: A name-only invitation cannot choose between the two either.

#### Person known only by name matches an address, bare name or lone first name
`PeopleUpcomingMeetingsTests.testANameFindsOnlyTheOnePersonWhoCarriesIt`: Someone known only by name takes an address, a bare name, or a lone first name.

### `LokalBotTests/Services/People/WorkMemoryConnectionsProjectTests.swift`

#### Projects read whole summaries and transcripts (4,000-char cut dropped meetings)
`WorkMemoryConnectionsProjectTests`: Projects read whole summaries and transcripts from the library folders.
2026-10-16: summaries were cut to 4,000 characters and transcripts were
never read, so meetings that named a project late or only aloud dropped out.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
