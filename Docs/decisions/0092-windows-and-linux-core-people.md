# 0092. Windows and Linux: core — people

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-core/src/people.rs`, `LinuxWindows/crates/lokalbot-core/src/people/`.

## Decisions

### `LinuxWindows/crates/lokalbot-core/src/people.rs`

#### Attendee emails are private join keys, never in profile or ID
People: profiles joined from calendar attendees, speaker names the user
applied and action owners (`PeopleDirectory.swift`, `PersonNotes.swift`).
Attendee email addresses are private join keys only: they never appear
in a profile, its ID or anything derived from it.

#### At most eight decisions are kept per person
`MAXIMUM_DECISIONS`: Decisions kept per person.

#### Meetings with at most two others count as with each of them
`SMALL_MEETING_SIZE`: A meeting with at most this many other named people counts as "with"
each of them for the user's own commitments.

#### Decisions from meetings this small belong to every attendee
`DECISION_MEETING_SIZE`: Decisions from meetings this small belong to every attendee.

#### Same-title recordings within 15 minutes are the same call
`RECORDING_GAP_TOLERANCE_SECONDS`: A second recording within this long of the first one's end, with the
same title, is the same call.

#### Person ID format and join key shapes, matching macOS
`person_id`: `person-%016llx` of a join key (`email:<address>` or `name:<normalized>`).

#### Folded alphanumeric words, matching PeopleDirectory.normalized on macOS
`normalized`: Folded alphanumeric words (`PeopleDirectory.normalized`).

#### User name: configured autocomplete name, else OS account full name
`user_full_name`: The user's own name: the configured autocomplete name when set, else
the operating-system account's full name (`NSFullUserName` on macOS).

#### Null buffer with size 0 only queries required length
`windows_full_name`: SAFETY: a null buffer with size 0 only queries the required length.

#### Buffer holds size UTF-16 units plus terminator, as requested
`windows_full_name`: SAFETY: `buffer` holds `size` UTF-16 units plus a terminator, as requested.

#### Strip merge suffixes like source 2 and trailing parenthetical notes
`cleaned_name`: Removes merge suffixes ("· source 2") and trailing notes ("(host)").

#### Speaker labels and collective words name no one
`is_placeholder`: Speaker labels and collective words name no one.

#### A person name is one to four words without group or role words
`is_person_name`: One to four name-like words with no group or role words.

#### Mentions match whole words: full name or first name of 3+ letters
`mentions`: Whole-word match of a full name or a first name of 3+ letters.

#### Capitalized first names of 3+ letters count unless common sentence-start words
`is_named`: Whether `text` names the person: the full name, or a capitalized first
name of 3+ letters that is not a common word starting a sentence.

#### Mirrors PeopleDirectory.SelfMatcher on macOS
`SelfMatcher`: Matches the user's own names (`PeopleDirectory.SelfMatcher`).

#### Mirrors MeetingAppliedSpeakerNames: speaker names the user applied per meeting
`AppliedNames`: Speaker names the user applied in one meeting (`MeetingAppliedSpeakerNames`).

#### Names are suggested from address local parts only when no name exists
`name_from_address`: A name suggested by an attendee address ("dragan@…", "ana.petrovic@gmail…").

#### Join by address when present, otherwise by full normalized name
`Registry`: Joins calendar identities by address when present, otherwise by full
normalized name (`PeopleDirectory.Registry`).

#### Exact full-name match first, then unique first-name match
`Registry::resolve`: Exact full-name match first, then a unique first-name match.

#### A lone first name joins the one person whose full name starts with it
`Registry::merge_first_names_into_full_names`: A first name alone joins the one person whose full name starts with it.

#### Names rank fullest first, then most frequent spelling
`ranked_names`: The fullest name first, then the most frequent spelling.

#### Mirrors PeopleDirectory.build; most recently met person first
`build_people`: Builds every person profile (`PeopleDirectory.build`), most recently met first.

#### Recordings group into occasions, newest first
`occasions`: Recordings grouped into the meetings they belong to, newest first.

#### Same occasion: same day and event, or same title within 15 minutes
`same_occasion`: Same local day and calendar event, or same title within 15 minutes.

#### An occasion's primary recording is its longest one
`primary`: The occasion's longest recording, the one worth opening.

#### Mirrors PersonNotes.SummaryLine on macOS
`SummaryLine`: One summary bullet (`PersonNotes.SummaryLine`).

#### Summary lines exclude action and decision sections, as PersonNotes.lines
`summary_lines`: Summary bullets outside action/decision sections (`PersonNotes.lines`).

#### A line is about the person if they said it or it names them
`line_is_about`: Whether a summary line was said by the person or names them.

#### Note points mirror PersonNotes.point; None when line is about someone else
`note_point`: A summary line said by the person or naming them, as shown on their page
(`PersonNotes.point`); `None` when the line is about someone else.

#### Mirrors PersonProfile.RecentNotes on macOS
`RecentNotes`: What the newest meeting notes about a person say (`PersonProfile.RecentNotes`).

#### Newest meeting about the person: up to three lines or small-meeting overview
`recent_notes`: The newest meeting whose notes say something about the person
(`PersonNotes.recentNotes`): up to three lines, or a small meeting's
overview when no line names them.

#### Follow-up offered only for small meetings, not team calls they attended
`follow_up_candidates`: The meetings to offer "Draft Follow-up" for, newest first: each occasion's
main recording when it was small enough to be with this person, rather
than a team call they happened to attend (`followUpMeeting`).

#### Mirrors PersonDetailView.preparationPrompt on macOS
`preparation_prompt`: The "Prepare in Agent…" prompt (`PersonDetailView.preparationPrompt`).

#### The user's own names are excluded from people
`Library::self_names`: The user's own names, excluded from people.

#### An empty curation deletes the file instead of writing it
`Library::save_people_curation`: Saves corrections; an empty curation deletes the file.

#### People are ordered most recently met first, with notes and projects
`Library::people`: Everyone the user meets, most recently met first, with recent notes
and the projects named around them.

#### Test fixture is curation.json as macOS PeopleStore writes it
`curation_reads_and_writes_the_mac_format`: `people/curation.json` as `PeopleStore` writes it (sorted, pretty keys).

#### Folded profile lists both ids so Separate finds the merge
`merging_folds_names_and_offers_separate`: The folded profile lists both ids, so Separate finds the merge.

### `LinuxWindows/crates/lokalbot-core/src/people/upcoming.rs`

#### Upcoming matching uses directory keys, stores nothing, holds names only
Who People shows as coming up (`PeopleUpcomingMeetings.swift`): the
calendar's next week matched to people through the keys the directory
already registers for an attendee, the address and then the name.
Nothing is stored; a match lasts as long as the page shows it, and it
holds names only.

#### Invited addresses without display names are left out of others
`PersonUpcomingMeeting`: The next calendar meeting with one person (`PersonUpcomingMeeting`). An
invited address without a display name is left out of `others`.

#### Others lists invitees by display name in order, excluding person and user
`PersonUpcomingMeeting.others`: Everyone else invited, by display name, in the invitation's order.
The person and the user are not listed.

#### People reads calendar only when enabled and ready, never personal appointments
`readable_events`: The calendar's meetings People may read: only while calendar use is on
and the calendar has been read, and never a personal appointment. `None`
otherwise, and then nobody has a next meeting.

#### Attendee matching rules; shared names never guessed; recorded or past events skipped
`match_people`: The soonest event in the next week for each person, by person ID.

An attendee with an address is the person registered under that address,
or the one still known only by that full name. An attendee without an
address is the one person carrying that full name, or, for a lone first
name, the one person whose full name starts with it. Two people who share
a name are never guessed between. An event already recorded (its
occurrence ID in `recorded_event_ids`) or already over is left out.

#### Attendees matched via hashed directory keys, never holding an address
`Index`: Looks attendees up by the directory's own keys without ever holding an
address: a person's IDs are hashes of those keys.

#### Name-only person takes the address later; other-address people stay distinct
`Index::person_for`: A person so far known only by this name takes the address when
the directory next sees it; someone registered under another
address stays a different person.

#### Personal appointment fixture: only the user, no link, non-meeting title
`personal_appointments_are_not_read`: Only the user, no link, a title that names no meeting.

#### A new address under a shared name matches nobody
`a_name_finds_only_the_one_person_who_carries_it`: A new address under a shared name is nobody People knows.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
