# 0109. Windows and Linux: platform — calendar

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-platform/src/calendar/`.

## Decisions

### `LinuxWindows/crates/lokalbot-platform/src/calendar/eds.rs`

#### EDS reads synced local copy, no network; one D-Bus connection per refresh
Evolution Data Server over D-Bus: every enabled, selected calendar the
desktop knows, including those GNOME Online Accounts adds (Google,
Microsoft 365, Nextcloud). EDS keeps its own synced copy, so reading it
makes no network request of LokalBot's own.

`Sources5` lists the sources; `CalendarFactory.OpenCalendar` starts (or
reuses) a backend whose object lives only while this connection does, so
one connection serves a whole refresh.

#### Ok(None) means EDS is not installed
`fetch`: Events from every enabled EDS calendar. `Ok(None)` when EDS is not
installed (nothing owns or can start its source registry).

#### Open returns key,value pairs with GVariant-quoted values
`open_property`: `Open` returns `[key, value, key, value, …]` with GVariant-quoted values.

#### Pick the highest-numbered EDS bus name running or activatable
`newest_name`: The highest-numbered EDS bus name that is running or can be started
(`…Sources5`, `…Calendar8`).

#### Only enabled, selected calendars under an enabled collection with calendars on
`select_sources`: Calendars that are enabled and selected, under an enabled collection
whose calendars are turned on.

#### Live EDS test needs seeded Daily standup and dbus-run-session command
`live_evolution_calendar`: Reads the running EDS. Seed a calendar with a daily "Daily standup"
and run inside its session bus:
`LOKALBOT_EDS_LIVE_TEST=1 dbus-run-session -- cargo test -p lokalbot-platform live_evolution -- --ignored`

### `LinuxWindows/crates/lokalbot-platform/src/calendar/feed.rs`

#### Calendar link is a secret: redacted in logs, sent only encrypted or locally
Private calendar links: an iCalendar feed (Google's "secret address in
iCal format", Outlook's published calendar, iCloud's `webcal://` link) or
a CalDAV collection. Credentials can ride in the link
(`https://user:app-password@host/…`); the whole link is a secret, so only
[`redacted`] ever reaches a log or the screen, and it is sent only over an
encrypted connection or to this computer.

#### Feeds over 64 MiB are refused; a full Google history is a few MB
`MAX_BYTES`: Feeds larger than this are refused (a full Google history is a few MB).

#### Refuse http:// to other computers: link and password would cross network in clear
`LinkRefused::NotEncrypted`: `http://` to another computer. The link is fetched every few minutes,
and it and any password in it would cross the network in the clear.

#### Only scheme and host of a calendar link may be shown or logged
`redacted`: `scheme://host/…`: what may be shown or logged of a calendar link.

#### Refused links stay named by host so the person can tell which
`redacted`: Still named by its host, so the person can tell which link it is.

#### webcal becomes https; plain http accepted only for local calendar server
`normalize`: `webcal(s)://` becomes `https://`. Plain `http://` is accepted only for
a calendar server on this computer; anything else is refused.

#### Loopback check uses the request address without credentials
`normalize`: Judged on the address the request goes to, without the credentials.

#### iCalendar answer is a feed; otherwise ask as CalDAV collection
`fetch`: Events from one link overlapping `[from, to)`. A link that answers with
iCalendar is a feed; otherwise it is asked as a CalDAV collection.

#### CalDAV calendar-query returns whole series, expanded locally like a feed
`caldav_query`: CalDAV `calendar-query` for events overlapping the window (RFC 4791 §7.8).
The server returns whole series; they are expanded here like a feed.

#### Transport errors are described without the URL since links are secrets
`describe`: A transport failure in words that never repeat the link: some `ureq`
errors carry the whole URL, and a calendar link is a secret.

#### Encrypted links never follow a redirect to an unencrypted address
`agent`: The agent for `url`. An encrypted link never follows a redirect to an
unencrypted address.

#### Live CalDAV test needs a server URL env var and a Weekly review event
`live_caldav_report`: Asks a real CalDAV server: `LOKALBOT_CALDAV_TEST_URL=https://user:pass@host/cal/`
with a "Weekly review" event today.

#### Private-network http links are still refused; others can listen
`unencrypted_links_are_read_only_from_this_computer`: The private network is still a network others can listen on.

#### localhost@evil.example sends the request to evil.example
`unencrypted_links_are_read_only_from_this_computer`: The request would go to evil.example, whatever follows the `@`.

#### 192.0.2.0/24 is documentation range so nothing is contacted
`unencrypted_links_are_read_only_from_this_computer`: 192.0.2.0/24 is reserved for documentation: nothing is contacted.

### `LinuxWindows/crates/lokalbot-platform/src/calendar/ics.rs`

#### calcard parses; this module applies RECURRENCE-ID overrides by instant, mirroring macOS filter
iCalendar (RFC 5545) to meeting candidates.

Parsing, time zone names (IANA, Windows and Outlook's "(UTC+01:00) …"
labels, `X-LIC-LOCATION`) and RRULE iteration come from `calcard`. This
module groups each series with its `RECURRENCE-ID` overrides, applies them
by instant (a moved or cancelled occurrence replaces the original whatever
its `SEQUENCE`), and maps each occurrence through the macOS filter
(`EventKitCalendarEventProvider.candidate(from:)`).

#### Provider value is ics, caldav or eds
`ParseOptions::provider`: `calendarProvider` for the events ("ics", "caldav", "eds").

#### Own addresses are lowercased, not listed as participants; DECLINED drops the event
`ParseOptions::my_addresses`: The user's own addresses, lowercased: never listed as a participant,
and their `PARTSTAT=DECLINED` drops the event.

#### Source calendar name wins over the feed's name
`ParseOptions::calendar_title`: The calendar's name when the source knows it better than the feed.

#### Floating times and unknown TZIDs use default zone, else this computer's
`ParseOptions::default_zone`: Zone for floating times and unknown `TZID`s; `None` uses this computer's.

#### Endless rules expand in growing steps; cap bounds pathological rules
`MAX_OCCURRENCES`: A series whose rule never ends is expanded in growing steps until it
passes the window; this caps the work for a pathological rule.

#### EDS returns each VEVENT separately with time zones fetched apart
`parse_components`: Same as [`parse_events`] for components that arrive one at a time (EDS
returns each `VEVENT` on its own, with time zones fetched separately).

#### Name unplaceable VTIMEZONEs by local zone or fixed offset, else read in local zone
`name_unknown_zones`: A `VTIMEZONE` whose name `calcard` cannot place (Outlook's "Customized
Time Zone") gets an `X-LIC-LOCATION`: this computer's zone when its
standard and daylight offsets match, else the fixed standard offset.
Without it, its times would be read in this computer's zone regardless.

#### Zone offsets taken from January and July of this year
`zone_offsets`: The smaller and larger UTC offsets of an IANA zone this year (January and July).

#### Etc/GMT sign is inverted: UTC+01:00 is Etc/GMT-1
`fixed_zone_name`: `Etc/GMT-1` for UTC+01:00 (the sign is inverted in that namespace).

#### Google names a primary calendar after its owner's address
`events_in`: Google names a primary calendar after its owner's address.

#### Overrides outside expansion or without their series still count as meetings
`Context::expand`: Overrides of occurrences outside the expansion (or of a series the
feed did not include) still describe a meeting of their own.

#### Expand series in growing steps until past the window or rule ends
`Context::expand_series`: The series' occurrences (EXDATEs applied by `calcard`), in steps that
grow until the expansion passes the window or the rule ends.

#### calcard iterates TZID-less starts in default zone even UTC; expand in own offset
`Context::expand_series`: `calcard` iterates a start without a TZID in the default zone, even
a UTC one ("…T150000Z"): expand those in their own offset instead.

#### RECURRENCE-ID uses override's own TZID, else the series start's zone
`Context::recurrence_instant`: The instant an override's `RECURRENCE-ID` names, in the zone of its own
`TZID` or else the series start's.

#### Local time skipped by DST is read one hour later
`Context::instant`: A local time skipped by a DST change: read it one hour later.

#### Meeting link order: event URL, conferencing properties, location, notes
`meeting_url`: The event link, conferencing properties, location, then notes
(`EventKitCalendarEventProvider`: url, location, notes).

#### Outlook X-MICROSOFT-CDO-BUSYSTATUS values are FREE, TENTATIVE, BUSY, OOF
`busy_status`: Outlook's `X-MICROSOFT-CDO-BUSYSTATUS` (FREE, TENTATIVE, BUSY, OOF).

#### Default zone is the named one or this computer's
`default_zone`: This computer's zone (or `name`) for floating times and unknown `TZID`s.

#### Override with newer SEQUENCE moves standup an hour later
`google_feed_applies_overrides_exdates_cancellations_and_dst`: Moved an hour later by an override with a newer SEQUENCE.

#### The 21st is an EXDATE and the 23rd a cancelled override
`google_feed_applies_overrides_exdates_cancellations_and_dst`: The 21st is an EXDATE and the 23rd a cancelled override.

#### CEST ends on the 25th, shifting 09:00 local from 07:00 to 08:00 UTC
`google_feed_applies_overrides_exdates_cancellations_and_dst`: Central European summer time ends on the 25th: 09:00 local
moves from 07:00 to 08:00 UTC.

#### Owner, room and declined guest are not participants
`google_feed_applies_overrides_exdates_cancellations_and_dst`: The owner (named by X-WR-CALNAME), the room and the guest who
declined are not participants.

#### Out of office and free holds without guests or link are dropped
`outlook_feed_reads_windows_zone_names_and_busy_status`: Out of office and a free hold without guests or a link are dropped.

#### Customized Time Zone declares a fixed UTC+01:00
`outlook_feed_reads_windows_zone_names_and_busy_status`: "Customized Time Zone" declares a fixed UTC+01:00.

#### US daylight saving time ends on November 1st
`outlook_feed_reads_windows_zone_names_and_busy_status`: US daylight saving time ends on November 1st.

#### Weekdays since 2010 exceed the first expansion step
`edge_cases test`: Weekdays since 2010: well past the first expansion step.

#### Override moved into the window, another moved out of it
`edge_cases test`: The 15th moved into the window; the 22nd moved out of it.

#### Floating 13:00 is read in the default zone (CEST)
`edge_cases test`: Floating 13:00 is read in the default zone (CEST).

#### An override without its series is still a meeting
`edge_cases test`: An override without its series is still a meeting.

#### On Windows the zone name comes from system time zone settings
`this_computers_zone_is_known`: Floating times and unknown zones are read in this computer's zone;
on Windows its name comes from the system's time zone settings.

### `LinuxWindows/crates/lokalbot-platform/src/calendar/mod.rs`

#### Providers return recordable meetings; usage policy lives in lokalbot_core::calendar
Calendar providers (`CalendarEventProviding`): private iCalendar/CalDAV
links on both systems, and Evolution Data Server on Linux. Each returns
recordable meetings ([`lokalbot_core::calendar::CalendarEvent`]) in a time
window; the policy that uses them lives in `lokalbot_core::calendar`.

#### Links are secrets from the credential store
`CalendarSources::links`: Private links (secrets from the credential store).

#### Problem lines show links only redacted
`FetchReport::problems`: One line per source that failed; links appear only redacted.

#### Calendar fetch blocks: network for links, D-Bus for EDS
`fetch`: Reads every source. Blocking: network requests for links, D-Bus for EDS.

#### Same invitation in two calendars is kept once by external id
`fetch`: The same invitation can sit in two calendars; keep one.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
