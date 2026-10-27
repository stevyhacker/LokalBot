//! iCalendar (RFC 5545) to meeting candidates.
//!
//! Parsing, time zone names (IANA, Windows and Outlook's "(UTC+01:00) …"
//! labels, `X-LIC-LOCATION`) and RRULE iteration come from `calcard`. This
//! module groups each series with its `RECURRENCE-ID` overrides, applies them
//! by instant (a moved or cancelled occurrence replaces the original whatever
//! its `SEQUENCE`), and maps each occurrence through the macOS filter
//! (`EventKitCalendarEventProvider.candidate(from:)`).

use std::collections::HashMap;
use std::str::FromStr as _;

use calcard::common::timezone::Tz;
use calcard::common::{DateTimeResult, PartialDateTime};
use calcard::icalendar::dates::TimeOrDelta;
use calcard::icalendar::{
    ICalendar, ICalendarComponent, ICalendarComponentType, ICalendarEntry, ICalendarParameterName,
    ICalendarParameterValue, ICalendarParticipationStatus, ICalendarProperty, ICalendarStatus,
    ICalendarTransparency, ICalendarUserTypes, ICalendarValue, Uri,
};
use chrono::{DateTime, Local, TimeZone as _, Utc};
use lokalbot_core::calendar::{
    CalendarEvent, RawCalendarEvent, first_meeting_url, is_recordable_meeting, sanitize_agenda,
};
use lokalbot_core::model::CalendarParticipantIdentity;

/// What a parse needs besides the text.
#[derive(Clone, Debug)]
pub struct ParseOptions {
    /// `calendarProvider` for the events ("ics", "caldav", "eds").
    pub provider: String,
    /// Occurrences overlapping `[from, to)` are returned.
    pub from: DateTime<Utc>,
    pub to: DateTime<Utc>,
    /// The user's own addresses, lowercased: never listed as a participant,
    /// and their `PARTSTAT=DECLINED` drops the event.
    pub my_addresses: Vec<String>,
    /// The calendar's name when the source knows it better than the feed.
    pub calendar_title: Option<String>,
    /// Zone for floating times and unknown `TZID`s; `None` uses this computer's.
    pub default_zone: Option<String>,
}

/// A series whose rule never ends is expanded in growing steps until it
/// passes the window; this caps the work for a pathological rule.
const MAX_OCCURRENCES: usize = 1 << 20;
const FIRST_STEP: usize = 2_048;

/// Recordable meetings in `text` overlapping the window, by start.
pub fn parse_events(text: &str, options: &ParseOptions) -> anyhow::Result<Vec<CalendarEvent>> {
    let mut calendar = ICalendar::parse(text)
        .map_err(|entry| anyhow::anyhow!("not an iCalendar document ({entry:?})"))?;
    name_unknown_zones(&mut calendar, options.default_zone.as_deref());
    Ok(events_in(&calendar, options))
}

/// Same as [`parse_events`] for components that arrive one at a time (EDS
/// returns each `VEVENT` on its own, with time zones fetched separately).
pub fn parse_components(
    events: &[String],
    timezones: &[String],
    options: &ParseOptions,
) -> Vec<CalendarEvent> {
    let mut text = String::from("BEGIN:VCALENDAR\r\nVERSION:2.0\r\n");
    for component in timezones.iter().chain(events) {
        text.push_str(component.trim());
        text.push_str("\r\n");
    }
    text.push_str("END:VCALENDAR\r\n");
    match ICalendar::parse(&text) {
        Ok(mut calendar) => {
            name_unknown_zones(&mut calendar, options.default_zone.as_deref());
            events_in(&calendar, options)
        }
        Err(entry) => {
            log::warn!("calendar components could not be read ({entry:?})");
            Vec::new()
        }
    }
}

/// A `VTIMEZONE` whose name `calcard` cannot place (Outlook's "Customized
/// Time Zone") gets an `X-LIC-LOCATION`: this computer's zone when its
/// standard and daylight offsets match, else the fixed standard offset.
/// Without it, its times would be read in this computer's zone regardless.
fn name_unknown_zones(calendar: &mut ICalendar, default_name: Option<&str>) {
    let zone_indices = indices(calendar, ICalendarComponentType::VTimezone);
    for index in zone_indices {
        if calendar.components[index].timezone().is_some() {
            continue;
        }
        let mut standard = None;
        let mut daylight = None;
        for &child in &calendar.components[index].component_ids {
            let Some(component) = calendar.components.get(child as usize) else {
                continue;
            };
            let offset = component
                .property(&ICalendarProperty::Tzoffsetto)
                .and_then(|e| e.values.first())
                .and_then(|value| match value {
                    ICalendarValue::PartialDateTime(offset) => {
                        let seconds = i32::from(offset.tz_hour?) * 3600
                            + i32::from(offset.tz_minute.unwrap_or_default()) * 60;
                        Some(if offset.tz_minus { -seconds } else { seconds })
                    }
                    _ => None,
                });
            match component.component_type {
                ICalendarComponentType::Standard => standard = standard.or(offset),
                ICalendarComponentType::Daylight => daylight = daylight.or(offset),
                _ => {}
            }
        }
        let Some(standard) = standard.or(daylight) else {
            continue;
        };
        let local = default_name
            .map(str::to_string)
            .or_else(|| iana_time_zone::get_timezone().ok());
        let name = match daylight.filter(|d| *d != standard) {
            Some(daylight) => local
                .filter(|name| {
                    zone_offsets(name) == Some((standard.min(daylight), standard.max(daylight)))
                })
                .or_else(|| fixed_zone_name(standard)),
            None => fixed_zone_name(standard),
        };
        if let Some(name) = name {
            calendar.components[index].entries.push(ICalendarEntry {
                name: ICalendarProperty::Other("X-LIC-LOCATION".into()),
                params: Vec::new(),
                values: vec![ICalendarValue::Text(name)],
            });
        }
    }
}

/// The smaller and larger UTC offsets of an IANA zone this year (January and July).
fn zone_offsets(name: &str) -> Option<(i32, i32)> {
    use chrono::{Datelike as _, Offset as _};
    let zone = Tz::from_str(name).ok()?;
    if zone.is_floating() {
        return None;
    }
    let year = Utc::now().year();
    let offset = |month: u32| -> Option<i32> {
        let at = chrono::NaiveDate::from_ymd_opt(year, month, 1)?.and_hms_opt(12, 0, 0)?;
        Some(zone.offset_from_utc_datetime(&at).fix().local_minus_utc())
    };
    let (january, july) = (offset(1)?, offset(7)?);
    Some((january.min(july), january.max(july)))
}

/// `Etc/GMT-1` for UTC+01:00 (the sign is inverted in that namespace).
fn fixed_zone_name(seconds: i32) -> Option<String> {
    if seconds % 3600 != 0 {
        return None;
    }
    let hours = seconds / 3600;
    Some(match hours {
        0 => "Etc/UTC".to_string(),
        h if h > 0 => format!("Etc/GMT-{h}"),
        h => format!("Etc/GMT+{}", -h),
    })
}

fn events_in(calendar: &ICalendar, options: &ParseOptions) -> Vec<CalendarEvent> {
    let default_zone = default_zone(options.default_zone.as_deref());
    let resolver = calendar.build_tz_resolver().with_default(default_zone);
    let calendar_title = options
        .calendar_title
        .clone()
        .or_else(|| calendar_name(calendar));
    let mut my_addresses = options.my_addresses.clone();
    // Google names a primary calendar after its owner's address.
    if let Some(owner) = calendar_name(calendar)
        .and_then(|name| CalendarParticipantIdentity::normalized_email_address(&name))
        .filter(|name| name.contains('@') && name.contains('.'))
    {
        my_addresses.push(owner);
    }
    let context = Context {
        options,
        resolver: &resolver,
        calendar_title,
        my_addresses,
    };

    let timezones: Vec<usize> = indices(calendar, ICalendarComponentType::VTimezone);
    let mut series: HashMap<String, Series> = HashMap::new();
    let mut order: Vec<String> = Vec::new();
    for index in indices(calendar, ICalendarComponentType::VEvent) {
        let component = &calendar.components[index];
        let uid = text_property(component, &ICalendarProperty::Uid)
            .unwrap_or_else(|| format!("no-uid-{index}"));
        let entry = series.entry(uid.clone()).or_insert_with(|| {
            order.push(uid.clone());
            Series::default()
        });
        if component
            .property(&ICalendarProperty::RecurrenceId)
            .is_some()
        {
            entry.overrides.push(index);
        } else if entry.master.is_none() {
            entry.master = Some(index);
        }
    }

    let mut events: Vec<CalendarEvent> = Vec::new();
    for uid in order {
        let Some(group) = series.get(&uid) else {
            continue;
        };
        for occurrence in context.expand(calendar, &timezones, &uid, group) {
            if occurrence.end > options.from
                && occurrence.start < options.to
                && let Some(event) = context.candidate(&uid, &occurrence)
            {
                events.push(event);
            }
        }
    }
    events.sort_by(|a, b| a.start.cmp(&b.start).then(a.end.cmp(&b.end)));
    events.dedup_by(|a, b| a.external_id == b.external_id);
    events
}

#[derive(Default)]
struct Series {
    master: Option<usize>,
    overrides: Vec<usize>,
}

/// One occurrence: the component that describes it and its times.
struct Occurrence<'a> {
    component: &'a ICalendarComponent,
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    all_day: bool,
}

struct Context<'a> {
    options: &'a ParseOptions,
    resolver: &'a calcard::icalendar::timezone::TzResolver<&'a str>,
    calendar_title: Option<String>,
    my_addresses: Vec<String>,
}

impl Context<'_> {
    fn expand<'c>(
        &self,
        calendar: &'c ICalendar,
        timezones: &[usize],
        uid: &str,
        group: &Series,
    ) -> Vec<Occurrence<'c>> {
        let mut overrides: Vec<(Option<DateTime<Utc>>, &'c ICalendarComponent)> = group
            .overrides
            .iter()
            .map(|&i| {
                let component = &calendar.components[i];
                (
                    self.recurrence_instant(component, group, calendar),
                    component,
                )
            })
            .collect();
        let mut result = Vec::new();
        if let Some(master_index) = group.master {
            let master = &calendar.components[master_index];
            let all_day = is_all_day(master);
            let recurring = master.property(&ICalendarProperty::Rrule).is_some()
                || master.property(&ICalendarProperty::Rdate).is_some();
            let instances = if recurring {
                self.expand_series(calendar, timezones, master_index, uid)
            } else {
                self.single(master).into_iter().collect()
            };
            for (start, end) in instances {
                match overrides
                    .iter()
                    .position(|(instant, _)| *instant == Some(start))
                {
                    Some(at) => {
                        let (_, component) = overrides.remove(at);
                        if let Some((start, end)) = self.single(component) {
                            result.push(Occurrence {
                                component,
                                start,
                                end,
                                all_day: is_all_day(component),
                            });
                        }
                    }
                    None => result.push(Occurrence {
                        component: master,
                        start,
                        end,
                        all_day,
                    }),
                }
            }
        }
        // Overrides of occurrences outside the expansion (or of a series the
        // feed did not include) still describe a meeting of their own.
        for (_, component) in overrides {
            if let Some((start, end)) = self.single(component) {
                result.push(Occurrence {
                    component,
                    start,
                    end,
                    all_day: is_all_day(component),
                });
            }
        }
        result
    }

    /// The series' occurrences (EXDATEs applied by `calcard`), in steps that
    /// grow until the expansion passes the window or the rule ends.
    fn expand_series(
        &self,
        calendar: &ICalendar,
        timezones: &[usize],
        master: usize,
        uid: &str,
    ) -> Vec<(DateTime<Utc>, DateTime<Utc>)> {
        let mut single = ICalendar {
            components: vec![ICalendarComponent {
                component_type: ICalendarComponentType::VCalendar,
                ..Default::default()
            }],
        };
        for &index in timezones.iter().chain(std::iter::once(&master)) {
            let mut component = calendar.components[index].clone();
            component.component_ids.clear();
            single.components.push(component);
        }
        single.components[0].component_ids = (1..single.components.len() as u32).collect();

        // `calcard` iterates a start without a TZID in the default zone, even
        // a UTC one ("…T150000Z"): expand those in their own offset instead.
        let master_start = calendar.components[master].property(&ICalendarProperty::Dtstart);
        let default_zone = master_start
            .filter(|entry| entry.tz_id().is_none())
            .and_then(date_time)
            .and_then(|value| value.tz())
            .unwrap_or_else(|| self.resolver.resolve_or_default(None));
        let mut limit = FIRST_STEP;
        let mut previous = usize::MAX;
        loop {
            let expansion = single.expand_dates(default_zone, limit);
            for error in &expansion.errors {
                log::debug!(
                    "calendar series {} could not be expanded: {:?}",
                    short(uid),
                    error.error
                );
            }
            let instances: Vec<(DateTime<Utc>, DateTime<Utc>)> = expansion
                .events
                .iter()
                .filter_map(|event| {
                    let start = to_utc(&event.start)?;
                    let end = match &event.end {
                        TimeOrDelta::Time(end) => to_utc(end)?,
                        TimeOrDelta::Delta(delta) => start + *delta,
                    };
                    Some((start, end.max(start)))
                })
                .collect();
            let passed_window = instances.iter().any(|(start, _)| *start >= self.options.to);
            if passed_window || instances.len() == previous || limit >= MAX_OCCURRENCES {
                return instances;
            }
            previous = instances.len();
            limit = (limit * 4).min(MAX_OCCURRENCES);
        }
    }

    /// DTSTART to DTEND (or DURATION) of one component.
    fn single(&self, component: &ICalendarComponent) -> Option<(DateTime<Utc>, DateTime<Utc>)> {
        let start_entry = component.property(&ICalendarProperty::Dtstart)?;
        let start_zone = start_entry.tz_id();
        let start_value = date_time(start_entry)?;
        let start = self.instant(&start_value, start_zone)?;
        let end = if let Some(end_entry) = component.property(&ICalendarProperty::Dtend) {
            let end_value = date_time(end_entry)?;
            self.instant(&end_value, end_entry.tz_id().or(start_zone))?
        } else if let Some(ICalendarValue::Duration(duration)) = component
            .property(&ICalendarProperty::Duration)
            .and_then(|e| e.values.first())
        {
            start + duration.to_time_delta()?
        } else if is_all_day(component) {
            start + chrono::Duration::days(1)
        } else {
            start
        };
        Some((start, end.max(start)))
    }

    /// The instant an override's `RECURRENCE-ID` names, in the zone of its own
    /// `TZID` or else the series start's.
    fn recurrence_instant(
        &self,
        component: &ICalendarComponent,
        group: &Series,
        calendar: &ICalendar,
    ) -> Option<DateTime<Utc>> {
        let entry = component.property(&ICalendarProperty::RecurrenceId)?;
        let master_zone = group
            .master
            .and_then(|i| calendar.components[i].property(&ICalendarProperty::Dtstart))
            .and_then(ICalendarEntry::tz_id);
        self.instant(&date_time(entry)?, entry.tz_id().or(master_zone))
    }

    fn instant(&self, value: &DateTimeResult, zone: Option<&str>) -> Option<DateTime<Utc>> {
        let zone = self.resolver.resolve_or_default(zone);
        to_utc(&value.to_date_time_with_tz(zone).or_else(|| {
            // A local time skipped by a DST change: read it one hour later.
            let later = DateTimeResult {
                date_time: value.date_time + chrono::Duration::hours(1),
                offset: value.offset,
            };
            later.to_date_time_with_tz(zone)
        })?)
    }

    fn candidate(&self, uid: &str, occurrence: &Occurrence) -> Option<CalendarEvent> {
        let component = occurrence.component;
        let title = text_property(component, &ICalendarProperty::Summary)
            .map(|t| t.trim().to_string())
            .filter(|t| !t.is_empty());
        let description = text_property(component, &ICalendarProperty::Description);
        let meeting_url = meeting_url(component, description.as_deref());
        let attendees = attendees(component);
        let declined_by_me = attendees.iter().any(|attendee| {
            attendee.declined
                && attendee
                    .email
                    .as_ref()
                    .is_some_and(|email| self.my_addresses.contains(email))
        });
        let raw = RawCalendarEvent {
            title: title.clone(),
            is_all_day: occurrence.all_day,
            is_canceled: matches!(
                component
                    .property(&ICalendarProperty::Status)
                    .and_then(|e| e.values.first()),
                Some(ICalendarValue::Status(ICalendarStatus::Cancelled))
            ) || other_text(component, "STATUS")
                .is_some_and(|s| s.eq_ignore_ascii_case("CANCELLED")),
            is_declined_by_me: declined_by_me,
            availability_free: is_transparent(component)
                || busy_status(component).is_some_and(|s| s == "FREE"),
            availability_unavailable: busy_status(component).is_some_and(|s| s == "OOF"),
            has_attendees: !attendees.is_empty(),
            has_meeting_url: meeting_url.is_some(),
        };
        if !is_recordable_meeting(&raw) {
            return None;
        }
        let identities: Vec<CalendarParticipantIdentity> = attendees
            .iter()
            .filter(|a| !a.declined && !a.is_resource)
            .filter(|a| {
                a.email
                    .as_ref()
                    .is_none_or(|email| !self.my_addresses.contains(email))
            })
            .filter_map(|a| {
                CalendarParticipantIdentity::new("", a.name.as_deref(), a.email.as_deref())
            })
            .collect();
        let identities = CalendarParticipantIdentity::normalized(&identities);
        Some(CalendarEvent {
            provider: self.options.provider.clone(),
            external_id: CalendarEvent::occurrence_id(uid, occurrence.start),
            title: title?,
            start: occurrence.start,
            end: occurrence.end,
            meeting_url,
            source_calendar_title: self.calendar_title.clone(),
            participant_names: identities.iter().filter_map(|i| i.name.clone()).collect(),
            participant_identities: identities,
            agenda: sanitize_agenda(description.as_deref()),
        })
    }
}

struct Attendee {
    name: Option<String>,
    email: Option<String>,
    declined: bool,
    is_resource: bool,
}

fn attendees(component: &ICalendarComponent) -> Vec<Attendee> {
    component
        .properties(&ICalendarProperty::Attendee)
        .map(|entry| {
            let value = entry.values.first().and_then(value_text);
            let email = value
                .as_deref()
                .and_then(CalendarParticipantIdentity::email_from_participant_uri)
                .or_else(|| {
                    parameter_text(entry, &ICalendarParameterName::Email)
                        .and_then(|e| CalendarParticipantIdentity::normalized_email_address(&e))
                });
            let declined = entry
                .parameters(&ICalendarParameterName::Partstat)
                .any(|value| match value {
                    ICalendarParameterValue::Partstat(status) => {
                        *status == ICalendarParticipationStatus::Declined
                    }
                    other => other
                        .as_text()
                        .is_some_and(|t| t.eq_ignore_ascii_case("DECLINED")),
                });
            let is_resource = entry
                .parameters(&ICalendarParameterName::Cutype)
                .any(|value| match value {
                    ICalendarParameterValue::Cutype(kind) => {
                        matches!(
                            kind,
                            ICalendarUserTypes::Room | ICalendarUserTypes::Resource
                        )
                    }
                    other => other.as_text().is_some_and(|t| {
                        t.eq_ignore_ascii_case("ROOM") || t.eq_ignore_ascii_case("RESOURCE")
                    }),
                });
            Attendee {
                name: parameter_text(entry, &ICalendarParameterName::Cn),
                email,
                declined,
                is_resource,
            }
        })
        .collect()
}

/// The event link, conferencing properties, location, then notes
/// (`EventKitCalendarEventProvider`: url, location, notes).
fn meeting_url(component: &ICalendarComponent, description: Option<&str>) -> Option<String> {
    let url = component
        .property(&ICalendarProperty::Url)
        .and_then(|e| e.values.first())
        .and_then(value_text);
    let candidates = [
        url,
        other_text(component, "X-GOOGLE-CONFERENCE"),
        other_text(component, "X-MICROSOFT-SKYPETEAMSMEETINGURL"),
        other_text(component, "X-MICROSOFT-ONLINEMEETINGCONFLINK"),
        text_property(component, &ICalendarProperty::Location),
        description.map(str::to_string),
    ];
    candidates
        .iter()
        .find_map(|text| first_meeting_url(text.as_deref()))
}

fn is_transparent(component: &ICalendarComponent) -> bool {
    match component
        .property(&ICalendarProperty::Transp)
        .and_then(|e| e.values.first())
    {
        Some(ICalendarValue::Transparency(ICalendarTransparency::Transparent)) => true,
        Some(other) => value_text(other).is_some_and(|t| t.eq_ignore_ascii_case("TRANSPARENT")),
        None => false,
    }
}

/// Outlook's `X-MICROSOFT-CDO-BUSYSTATUS` (FREE, TENTATIVE, BUSY, OOF).
fn busy_status(component: &ICalendarComponent) -> Option<String> {
    other_text(component, "X-MICROSOFT-CDO-BUSYSTATUS").map(|s| s.trim().to_ascii_uppercase())
}

fn is_all_day(component: &ICalendarComponent) -> bool {
    component
        .property(&ICalendarProperty::Dtstart)
        .and_then(|e| e.values.first())
        .is_some_and(|value| matches!(value, ICalendarValue::PartialDateTime(dt) if !dt.has_time()))
}

fn date_time(entry: &ICalendarEntry) -> Option<DateTimeResult> {
    match entry.values.first()? {
        ICalendarValue::PartialDateTime(value) => PartialDateTime::to_date_time(value),
        _ => None,
    }
}

fn to_utc(value: &DateTime<Tz>) -> Option<DateTime<Utc>> {
    if value.timezone().is_floating() {
        Local
            .from_local_datetime(&value.naive_local())
            .earliest()
            .map(|local| local.with_timezone(&Utc))
    } else {
        Some(value.with_timezone(&Utc))
    }
}

/// This computer's zone (or `name`) for floating times and unknown `TZID`s.
fn default_zone(name: Option<&str>) -> Tz {
    name.map(str::to_string)
        .or_else(|| iana_time_zone::get_timezone().ok())
        .and_then(|name| Tz::from_str(&name).ok())
        .unwrap_or(Tz::Floating)
}

fn indices(calendar: &ICalendar, kind: ICalendarComponentType) -> Vec<usize> {
    calendar
        .components
        .iter()
        .enumerate()
        .filter(|(_, c)| c.component_type == kind)
        .map(|(i, _)| i)
        .collect()
}

fn calendar_name(calendar: &ICalendar) -> Option<String> {
    calendar
        .components
        .iter()
        .find(|c| c.component_type == ICalendarComponentType::VCalendar)
        .and_then(|root| other_text(root, "X-WR-CALNAME"))
        .map(|name| name.trim().to_string())
        .filter(|name| !name.is_empty())
}

fn text_property(component: &ICalendarComponent, property: &ICalendarProperty) -> Option<String> {
    component
        .property(property)
        .and_then(|e| e.values.first())
        .and_then(value_text)
}

/// An `X-` property, by case-insensitive name.
fn other_text(component: &ICalendarComponent, name: &str) -> Option<String> {
    component
        .entries
        .iter()
        .find_map(|entry| match &entry.name {
            ICalendarProperty::Other(other) if other.eq_ignore_ascii_case(name) => {
                entry.values.first().and_then(value_text)
            }
            _ => None,
        })
}

fn parameter_text(entry: &ICalendarEntry, name: &ICalendarParameterName) -> Option<String> {
    entry
        .parameters(name)
        .find_map(|value| value.as_text())
        .map(|text| text.trim().to_string())
        .filter(|text| !text.is_empty())
}

fn value_text(value: &ICalendarValue) -> Option<String> {
    match value {
        ICalendarValue::Text(text) => Some(text.clone()),
        ICalendarValue::Uri(Uri::Location(location)) => Some(location.clone()),
        _ => None,
    }
}

/// The first characters of a UID, for logs.
fn short(uid: &str) -> String {
    uid.chars().take(12).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const GOOGLE: &str = include_str!("../../tests/fixtures/calendar/google.ics");
    const OUTLOOK: &str = include_str!("../../tests/fixtures/calendar/outlook.ics");
    const EDGE_CASES: &str = include_str!("../../tests/fixtures/calendar/edge-cases.ics");

    fn at(text: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(text)
            .unwrap()
            .with_timezone(&Utc)
    }

    fn options(from: &str, to: &str) -> ParseOptions {
        ParseOptions {
            provider: "ics".into(),
            from: at(from),
            to: at(to),
            my_addresses: Vec::new(),
            calendar_title: None,
            default_zone: Some("Europe/Belgrade".into()),
        }
    }

    fn summary(events: &[CalendarEvent]) -> Vec<(String, String)> {
        events
            .iter()
            .map(|e| {
                (
                    e.title.clone(),
                    e.start.format("%Y-%m-%dT%H:%MZ").to_string(),
                )
            })
            .collect()
    }

    fn pairs(expected: &[(&str, &str)]) -> Vec<(String, String)> {
        expected
            .iter()
            .map(|(title, start)| (title.to_string(), start.to_string()))
            .collect()
    }

    #[test]
    fn google_feed_applies_overrides_exdates_cancellations_and_dst() {
        let events = parse_events(
            GOOGLE,
            &options("2026-10-19T00:00:00Z", "2026-10-27T00:00:00Z"),
        )
        .unwrap();
        assert_eq!(
            summary(&events),
            pairs(&[
                // Moved an hour later by an override with a newer SEQUENCE.
                ("Team standup (moved)", "2026-10-19T09:00Z"),
                ("Design review, Q4", "2026-10-20T16:00Z"),
                // The 21st is an EXDATE and the 23rd a cancelled override.
                ("Morning sync", "2026-10-22T07:00Z"),
                ("Morning sync", "2026-10-23T07:00Z"),
                ("Morning sync", "2026-10-24T07:00Z"),
                // Central European summer time ends on the 25th: 09:00 local
                // moves from 07:00 to 08:00 UTC.
                ("Morning sync", "2026-10-25T08:00Z"),
                ("Morning sync", "2026-10-26T08:00Z"),
                ("Team standup", "2026-10-26T09:00Z"),
            ])
        );
        let standup = events.last().unwrap();
        assert_eq!(
            standup.external_id,
            format!(
                "standup-123@google.com#{}",
                at("2026-10-26T09:00:00Z").timestamp()
            )
        );
        assert_eq!(standup.end, at("2026-10-26T09:15:00Z"));
        assert_eq!(
            standup.meeting_url.as_deref(),
            Some("https://meet.google.com/abc-defg-hij")
        );
        // The owner (named by X-WR-CALNAME), the room and the guest who
        // declined are not participants.
        assert_eq!(standup.participant_names, ["Maya Lin"]);
        assert_eq!(
            standup.participant_identities[0].email_address.as_deref(),
            Some("maya@example.com")
        );
        assert_eq!(
            standup.source_calendar_title.as_deref(),
            Some("ana.owner@example.com")
        );
        assert_eq!(
            standup.agenda.as_deref(),
            Some("Standup notes\nAgenda:\nBlockers first")
        );
        assert_eq!(standup.provider, "ics");
        let review = &events[1];
        assert_eq!(
            review.meeting_url.as_deref(),
            Some("https://us02web.zoom.us/j/987654321?pwd=abc")
        );
        assert!(review.participant_names.is_empty());
    }

    #[test]
    fn outlook_feed_reads_windows_zone_names_and_busy_status() {
        let events = parse_events(
            OUTLOOK,
            &options("2026-10-19T00:00:00Z", "2026-10-27T00:00:00Z"),
        )
        .unwrap();
        // Out of office and a free hold without guests or a link are dropped.
        assert_eq!(
            summary(&events),
            pairs(&[
                ("Monthly planning", "2026-10-20T13:00Z"),
                // "Customized Time Zone" declares a fixed UTC+01:00.
                ("Partner review", "2026-10-22T11:00Z"),
            ])
        );
        let planning = &events[0];
        assert!(planning.meeting_url.as_deref().is_some_and(|url| {
            url.starts_with("https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc")
        }));
        assert_eq!(planning.agenda.as_deref(), Some("Quarterly numbers"));
        assert_eq!(planning.source_calendar_title.as_deref(), Some("Calendar"));

        // US daylight saving time ends on November 1st.
        let events = parse_events(
            OUTLOOK,
            &options("2026-10-30T00:00:00Z", "2026-11-03T00:00:00Z"),
        )
        .unwrap();
        assert_eq!(
            summary(&events),
            pairs(&[
                ("NY customer call", "2026-10-30T13:00Z"),
                ("NY customer call", "2026-10-31T13:00Z"),
                ("NY customer call", "2026-11-01T14:00Z"),
                ("NY customer call", "2026-11-02T14:00Z"),
            ])
        );
        assert!(events[0].meeting_url.is_none());
    }

    #[test]
    fn edge_cases_floating_orphans_moves_declines_and_old_series() {
        let mut options = options("2026-10-19T00:00:00Z", "2026-10-27T00:00:00Z");
        options.my_addresses = vec!["me@example.com".into()];
        let events = parse_events(EDGE_CASES, &options).unwrap();
        assert_eq!(
            summary(&events),
            pairs(&[
                // Weekdays since 2010: well past the first expansion step.
                ("Long-running daily", "2026-10-19T07:00Z"),
                ("Long-running daily", "2026-10-20T07:00Z"),
                // The 15th moved into the window; the 22nd moved out of it.
                ("Thursday review (moved to Tuesday)", "2026-10-20T15:00Z"),
                ("Long-running daily", "2026-10-21T07:00Z"),
                ("Long-running daily", "2026-10-22T07:00Z"),
                // Floating 13:00 is read in the default zone (CEST).
                ("Floating review", "2026-10-22T11:00Z"),
                ("Long-running daily", "2026-10-23T07:00Z"),
                // An override without its series is still a meeting.
                ("Orphan instance", "2026-10-23T10:00Z"),
                ("Long-running daily", "2026-10-26T07:00Z"),
            ])
        );
        let floating = &events[5];
        assert_eq!(floating.end, at("2026-10-22T11:45:00Z"));
        assert_eq!(floating.participant_names, ["Petrović, Ana"]);
    }

    #[test]
    fn evolution_components_are_read_with_their_zones() {
        let event = "BEGIN:VEVENT\r\nUID:eds-weekly-1\r\nDTSTAMP:20260101T000000Z\r\n\
            DTSTART;TZID=/freeassociation.sourceforge.net/Europe/Belgrade:\r\n 20260105T100000\r\n\
            DTEND;TZID=/freeassociation.sourceforge.net/Europe/Belgrade:\r\n 20260105T103000\r\n\
            RRULE:FREQ=DAILY\r\nSUMMARY:Daily standup\r\n\
            ATTENDEE;CN=Ana Petrović;PARTSTAT=ACCEPTED:mailto:ana@example.com\r\nEND:VEVENT"
            .to_string();
        let zone = "BEGIN:VTIMEZONE\r\nTZID:/freeassociation.sourceforge.net/Europe/Belgrade\r\n\
            X-LIC-LOCATION:Europe/Belgrade\r\nEND:VTIMEZONE"
            .to_string();
        let mut options = options("2026-10-25T00:00:00Z", "2026-10-27T00:00:00Z");
        options.provider = "eds".into();
        options.calendar_title = Some("Personal".into());
        let events = parse_components(&[event], &[zone], &options);
        assert_eq!(
            summary(&events),
            pairs(&[
                ("Daily standup", "2026-10-25T09:00Z"),
                ("Daily standup", "2026-10-26T09:00Z"),
            ])
        );
        assert_eq!(events[0].provider, "eds");
        assert_eq!(events[0].source_calendar_title.as_deref(), Some("Personal"));
        assert_eq!(events[0].participant_names, ["Ana Petrović"]);
    }

    /// Floating times and unknown zones are read in this computer's zone;
    /// on Windows its name comes from the system's time zone settings.
    #[test]
    fn this_computers_zone_is_known() {
        assert!(
            !default_zone(None).is_floating(),
            "{:?}",
            iana_time_zone::get_timezone()
        );
        assert!(!default_zone(Some("Central European Standard Time")).is_floating());
    }

    #[test]
    fn unreadable_text_is_an_error() {
        assert!(
            parse_events(
                "hello",
                &options("2026-10-19T00:00:00Z", "2026-10-27T00:00:00Z")
            )
            .is_err()
        );
    }
}
