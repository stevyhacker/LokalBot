//! Who People shows as coming up (`PeopleUpcomingMeetings.swift`): the
//! calendar's next week matched to people through the keys the directory
//! already registers for an attendee, the address and then the name.
//! Nothing is stored; a match lasts as long as the page shows it, and it
//! holds names only.

use std::collections::{BTreeSet, HashMap, HashSet};

use chrono::{DateTime, Duration, Utc};

use super::{SelfMatcher, cleaned_name, is_placeholder, name_from_address, normalized, person_id};
use crate::calendar::CalendarEvent;
use crate::calendar::upcoming::{UpcomingKind, kind};
use crate::model::PersonProfile;

/// "Coming up" looks this many days ahead.
pub const WINDOW_DAYS: i64 = 7;

/// The next calendar meeting with one person (`PersonUpcomingMeeting`). An
/// invited address without a display name is left out of `others`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PersonUpcomingMeeting {
    pub event_id: String,
    pub title: String,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    /// Everyone else invited, by display name, in the invitation's order.
    /// The person and the user are not listed.
    pub others: Vec<String>,
}

impl PersonUpcomingMeeting {
    pub fn is_in_progress(&self, now: DateTime<Utc>) -> bool {
        self.start <= now && self.end > now
    }
}

/// The calendar's meetings People may read: only while calendar use is on
/// and the calendar has been read, and never a personal appointment. `None`
/// otherwise, and then nobody has a next meeting.
pub fn readable_events(
    calendar_enabled: bool,
    calendar_ready: bool,
    events: &[CalendarEvent],
) -> Option<Vec<CalendarEvent>> {
    if !calendar_enabled || !calendar_ready {
        return None;
    }
    Some(
        events
            .iter()
            .filter(|event| kind(event) != UpcomingKind::Personal)
            .cloned()
            .collect(),
    )
}

/// The soonest event in the next week for each person, by person ID.
///
/// An attendee with an address is the person registered under that address,
/// or the one still known only by that full name. An attendee without an
/// address is the one person carrying that full name, or, for a lone first
/// name, the one person whose full name starts with it. Two people who share
/// a name are never guessed between. An event already recorded (its
/// occurrence ID in `recorded_event_ids`) or already over is left out.
pub fn match_people(
    events: Option<&[CalendarEvent]>,
    people: &[PersonProfile],
    recorded_event_ids: &HashSet<String>,
    self_names: &[String],
    now: DateTime<Utc>,
) -> HashMap<String, PersonUpcomingMeeting> {
    let Some(events) = events else {
        return HashMap::new();
    };
    if events.is_empty() || people.is_empty() {
        return HashMap::new();
    }
    let window_end = now + Duration::days(WINDOW_DAYS);
    let mut upcoming: Vec<&CalendarEvent> = events
        .iter()
        .filter(|e| e.end > now && e.start < window_end)
        .filter(|e| !recorded_event_ids.contains(&e.external_id))
        .collect();
    upcoming.sort_by(|a, b| {
        a.start
            .cmp(&b.start)
            .then(a.end.cmp(&b.end))
            .then_with(|| a.external_id.cmp(&b.external_id))
    });
    if upcoming.is_empty() {
        return HashMap::new();
    }

    let index = Index::new(people);
    let is_self = SelfMatcher::new(self_names);
    let mut result: HashMap<String, PersonUpcomingMeeting> = HashMap::new();
    for event in upcoming {
        // Each attendee as (the person they are, the name to show).
        let mut attendees: Vec<(Option<String>, Option<String>)> = Vec::new();
        for identity in event.resolved_participant_identities() {
            let name = identity
                .name
                .clone()
                .or_else(|| name_from_address(&identity))
                .map(|name| cleaned_name(&name))
                .filter(|name| !is_placeholder(name));
            if name.as_deref().is_some_and(|name| is_self.matches(name)) {
                continue;
            }
            let person = index.person_id(identity.email_address.as_deref(), name.as_deref());
            let shown = person
                .as_ref()
                .and_then(|id| index.names.get(id).cloned())
                .or(name);
            attendees.push((person, shown));
        }
        let matched: BTreeSet<&String> = attendees.iter().filter_map(|(p, _)| p.as_ref()).collect();
        for person in matched {
            if result.contains_key(person) {
                continue;
            }
            let mut seen = HashSet::new();
            let others = attendees
                .iter()
                .filter(|(other, _)| other.as_ref() != Some(person))
                .filter_map(|(_, name)| name.clone())
                .filter(|name| seen.insert(normalized(name)))
                .collect();
            result.insert(
                person.clone(),
                PersonUpcomingMeeting {
                    event_id: event.external_id.clone(),
                    title: event.title.clone(),
                    start: event.start,
                    end: event.end,
                    others,
                },
            );
        }
    }
    result
}

/// Looks attendees up by the directory's own keys without ever holding an
/// address: a person's IDs are hashes of those keys.
struct Index {
    /// Every ID folded into a person, to that person's ID.
    person_by_member_id: HashMap<String, String>,
    /// Normalized full names (shown and other) to the people carrying them.
    people_by_name: HashMap<String, HashSet<String>>,
    /// First word of a full name of two or more words.
    people_by_first_name: HashMap<String, HashSet<String>>,
    names: HashMap<String, String>,
}

impl Index {
    fn new(people: &[PersonProfile]) -> Self {
        let mut index = Self {
            person_by_member_id: HashMap::new(),
            people_by_name: HashMap::new(),
            people_by_first_name: HashMap::new(),
            names: HashMap::new(),
        };
        for person in people {
            index.names.insert(person.id.clone(), person.name.clone());
            for id in std::iter::once(&person.id).chain(person.member_ids.iter()) {
                index
                    .person_by_member_id
                    .insert(id.clone(), person.id.clone());
            }
            for name in std::iter::once(&person.name).chain(person.other_names.iter()) {
                let key = normalized(name);
                if key.is_empty() {
                    continue;
                }
                let words: Vec<&str> = key.split(' ').collect();
                if words.len() >= 2 {
                    index
                        .people_by_first_name
                        .entry(words[0].to_string())
                        .or_default()
                        .insert(person.id.clone());
                }
                index
                    .people_by_name
                    .entry(key)
                    .or_default()
                    .insert(person.id.clone());
            }
        }
        index
    }

    fn person_id(&self, email: Option<&str>, name: Option<&str>) -> Option<String> {
        let name_key = name.map(normalized).filter(|key| !key.is_empty());
        let by_key = |key: String| self.person_by_member_id.get(&person_id(&key)).cloned();
        if let Some(email) = email {
            if let Some(person) = by_key(format!("email:{}", email.to_lowercase())) {
                return Some(person);
            }
            // A person so far known only by this name takes the address when
            // the directory next sees it; someone registered under another
            // address stays a different person.
            return name_key.and_then(|key| by_key(format!("name:{key}")));
        }
        let key = name_key?;
        let only = |set: &HashSet<String>| {
            (set.len() == 1)
                .then(|| set.iter().next().cloned())
                .flatten()
        };
        if let Some(exact) = self.people_by_name.get(&key) {
            return only(exact);
        }
        if key.contains(' ') || key.chars().count() < 3 {
            return None;
        }
        self.people_by_first_name.get(&key).and_then(only)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{CalendarParticipantIdentity, Meeting, PeopleCuration, PersonMerge};
    use crate::people::{PeopleInput, build_people};
    use chrono::TimeZone as _;

    fn now() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 11, 10, 12, 0, 0).unwrap()
    }

    fn past_meeting(
        title: &str,
        days_ago: i64,
        attendees: &[(Option<&str>, Option<&str>)],
    ) -> Meeting {
        let start = now() - Duration::days(days_ago);
        let mut meeting = Meeting::new(title, "Meet", start, &format!("meetings/{title}"));
        meeting.ended_at = Some(start + Duration::minutes(30));
        meeting.calendar_participant_identities = Some(
            attendees
                .iter()
                .enumerate()
                .filter_map(|(index, (name, email))| {
                    CalendarParticipantIdentity::new(&format!("{title}-{index}"), *name, *email)
                })
                .collect(),
        );
        meeting
    }

    fn people_with(
        meetings: &[Meeting],
        applied: HashMap<uuid::Uuid, crate::people::AppliedNames>,
        curation: PeopleCuration,
    ) -> Vec<PersonProfile> {
        build_people(&PeopleInput {
            meetings,
            projections: &[],
            applied: &applied,
            self_names: &["Sam Reed".to_string()],
            curation: &curation,
            today: now().date_naive(),
        })
    }

    fn people(meetings: &[Meeting]) -> Vec<PersonProfile> {
        people_with(meetings, HashMap::new(), PeopleCuration::default())
    }

    fn event(
        title: &str,
        in_hours: f64,
        id: Option<&str>,
        attendees: &[(Option<&str>, Option<&str>)],
        legacy_names: &[&str],
    ) -> CalendarEvent {
        let start = now() + Duration::seconds((in_hours * 3600.0) as i64);
        CalendarEvent {
            provider: "test".into(),
            external_id: id.unwrap_or(title).to_string(),
            title: title.to_string(),
            start,
            end: start + Duration::minutes(30),
            meeting_url: None,
            source_calendar_title: None,
            participant_names: legacy_names.iter().map(|n| n.to_string()).collect(),
            participant_identities: attendees
                .iter()
                .filter_map(|(name, email)| CalendarParticipantIdentity::new("", *name, *email))
                .collect(),
            agenda: None,
        }
    }

    fn matched(
        events: &[CalendarEvent],
        people: &[PersonProfile],
    ) -> HashMap<String, PersonUpcomingMeeting> {
        match_people(
            Some(events),
            people,
            &HashSet::new(),
            &["Sam Reed".to_string()],
            now(),
        )
    }

    fn id(name: &str, people: &[PersonProfile]) -> String {
        people
            .iter()
            .find(|p| p.name == name)
            .unwrap_or_else(|| panic!("no person named {name}"))
            .id
            .clone()
    }

    const ANA: (Option<&str>, Option<&str>) = (Some("Ana Petrović"), Some("ana@example.com"));
    const MARKO: (Option<&str>, Option<&str>) =
        (Some("Marko Jovanović"), Some("marko@example.com"));

    #[test]
    fn a_person_with_an_event_gets_it_and_a_person_without_gets_none() {
        let people = people(&[
            past_meeting("Design review", 1, &[ANA]),
            past_meeting("Vendor check-in", 20, &[MARKO]),
        ]);
        let result = matched(&[event("Atlas sync", 50.0, None, &[ANA], &[])], &people);
        let next = &result[&id("Ana Petrović", &people)];
        assert_eq!(next.title, "Atlas sync");
        assert_eq!(next.start, now() + Duration::hours(50));
        assert!(next.others.is_empty(), "nobody else is invited");
        assert!(!result.contains_key(&id("Marko Jovanović", &people)));
        assert_eq!(result.len(), 1);
    }

    #[test]
    fn two_people_in_one_event_each_see_the_other_but_never_the_user() {
        let people = people(&[past_meeting("Standup", 1, &[ANA, MARKO])]);
        let result = matched(
            &[event(
                "Atlas sync",
                26.0,
                None,
                &[
                    ANA,
                    MARKO,
                    (Some("Sam Reed"), Some("sam@example.com")),
                    (Some("Lena Novak"), Some("lena@example.com")),
                ],
                &[],
            )],
            &people,
        );
        assert_eq!(
            result[&id("Ana Petrović", &people)].others,
            ["Marko Jovanović", "Lena Novak"]
        );
        assert_eq!(
            result[&id("Marko Jovanović", &people)].others,
            ["Ana Petrović", "Lena Novak"]
        );
    }

    #[test]
    fn an_event_with_no_known_attendee_matches_nobody() {
        let people = people(&[past_meeting("Standup", 1, &[ANA])]);
        let events = [
            event(
                "Interview",
                5.0,
                None,
                &[(Some("Petar Lazić"), Some("petar@example.com"))],
                &[],
            ),
            event("Focus", 8.0, None, &[], &[]),
        ];
        assert!(matched(&events, &people).is_empty());
    }

    #[test]
    fn without_calendar_use_nothing_is_read_and_nobody_has_a_meeting() {
        let people = people(&[past_meeting("Standup", 1, &[ANA])]);
        let events = vec![event("Atlas sync", 5.0, None, &[ANA], &[])];
        assert_eq!(readable_events(false, true, &events), None);
        assert_eq!(readable_events(true, false, &events), None);
        assert!(match_people(None, &people, &HashSet::new(), &[], now()).is_empty());
        let read = readable_events(true, true, &events).unwrap();
        assert_eq!(matched(&read, &people).len(), 1);
    }

    #[test]
    fn personal_appointments_are_not_read() {
        // Only the user, no link, a title that names no meeting.
        let dentist = event("Dentist", 5.0, None, &[], &[]);
        let standup = event("Standup", 6.0, None, &[], &[]);
        let read = readable_events(true, true, &[dentist, standup]).unwrap();
        assert_eq!(
            read.iter().map(|e| e.title.as_str()).collect::<Vec<_>>(),
            ["Standup"]
        );
    }

    #[test]
    fn the_soonest_event_wins_and_ended_recorded_or_distant_ones_are_left_out() {
        let people = people(&[past_meeting("Standup", 1, &[ANA])]);
        let ana = id("Ana Petrović", &people);
        let ended = event("Ended", -2.0, None, &[ANA], &[]);
        let recorded = event("Recorded", 1.0, Some("recorded#1"), &[ANA], &[]);
        let later = event("Later this week", 70.0, None, &[ANA], &[]);
        let soonest = event("Tomorrow", 20.0, None, &[ANA], &[]);
        let distant = event("Next month", 8.0 * 24.0, None, &[ANA], &[]);
        let events = [
            distant.clone(),
            later,
            ended.clone(),
            soonest.clone(),
            recorded,
        ];
        let result = match_people(
            Some(&events),
            &people,
            &HashSet::from(["recorded#1".to_string()]),
            &[],
            now(),
        );
        assert_eq!(result[&ana].title, "Tomorrow");
        assert!(
            !matched(&[ended, distant], &people).contains_key(&ana),
            "only the next seven days count"
        );
        let under_way = event("Under way", -0.25, None, &[ANA], &[]);
        let current = matched(&[under_way, soonest], &people)[&ana].clone();
        assert_eq!(current.title, "Under way");
        assert!(current.is_in_progress(now()));
    }

    #[test]
    fn an_address_finds_the_person_after_a_merge() {
        let first = past_meeting("Roadmap", 3, &[ANA]);
        let second = past_meeting(
            "Pricing",
            2,
            &[(Some("Anna P."), Some("anna.p@example.org"))],
        );
        let unmerged = people(&[first.clone(), second.clone()]);
        let source = unmerged.iter().find(|p| p.name == "Anna P.").unwrap();
        let target = unmerged.iter().find(|p| p.name == "Ana Petrović").unwrap();
        let curation = PeopleCuration {
            merges: vec![PersonMerge {
                source_id: source.id.clone(),
                target_id: target.id.clone(),
                source_name: source.name.clone(),
            }],
            ..Default::default()
        };
        let merged = people_with(&[first, second], HashMap::new(), curation);
        assert_eq!(merged.len(), 1);
        let result = matched(
            &[event(
                "Atlas sync",
                30.0,
                None,
                &[(Some("A. Petrovic"), Some("anna.p@example.org"))],
                &[],
            )],
            &merged,
        );
        assert_eq!(
            result[&target.id].title, "Atlas sync",
            "the merged-in address still reaches the person"
        );
    }

    #[test]
    fn a_name_finds_only_the_one_person_who_carries_it() {
        let roadmap = past_meeting("Roadmap", 3, &[ANA]);
        let pricing = past_meeting(
            "Pricing",
            2,
            &[(Some("Ana Petrović"), Some("ana@elsewhere.example"))],
        );
        let chat = past_meeting("Chat", 1, &[]);
        let applied = HashMap::from([(
            chat.id,
            crate::people::AppliedNames {
                names: vec!["Dragan Ilić".into()],
                ..Default::default()
            },
        )]);
        let people = people_with(
            &[roadmap, pricing, chat],
            applied,
            PeopleCuration::default(),
        );
        assert_eq!(
            people.iter().filter(|p| p.name == "Ana Petrović").count(),
            2
        );
        let dragan = id("Dragan Ilić", &people);
        // A new address under a shared name is nobody People knows.
        let third = (Some("Ana Petrović"), Some("ana@third.example"));
        assert!(matched(&[event("Kickoff", 4.0, None, &[third], &[])], &people).is_empty());
        // A name-only invitation cannot choose between the two either.
        assert!(
            matched(
                &[event("Kickoff", 4.0, None, &[], &["Ana Petrović"])],
                &people
            )
            .is_empty()
        );
        // Someone known only by name takes an address, a bare name, or a lone
        // first name.
        let with_address = (Some("Dragan Ilić"), Some("dragan@example.com"));
        assert_eq!(
            matched(&[event("1:1", 4.0, None, &[with_address], &[])], &people)[&dragan].title,
            "1:1"
        );
        assert_eq!(
            matched(&[event("1:1", 4.0, None, &[], &["dragan ilic"])], &people)[&dragan].title,
            "1:1"
        );
        assert_eq!(
            matched(&[event("1:1", 4.0, None, &[], &["Dragan"])], &people)[&dragan].title,
            "1:1"
        );
    }

    #[test]
    fn an_address_without_a_name_is_never_shown() {
        let people = people(&[past_meeting("Standup", 1, &[ANA])]);
        let result = matched(
            &[event(
                "Review",
                3.0,
                None,
                &[
                    ANA,
                    (None, Some("kevlee88@gmail.com")),
                    (None, Some("maya.chen@gmail.com")),
                ],
                &[],
            )],
            &people,
        );
        let others = &result[&id("Ana Petrović", &people)].others;
        assert_eq!(
            others,
            &["Maya Chen"],
            "a spelled-out mailbox reads as a name"
        );
        assert!(!others.iter().any(|o| o.contains('@')));
    }

    #[test]
    fn the_shown_name_is_the_one_the_person_chose() {
        let meeting = past_meeting("Standup", 1, &[ANA, MARKO]);
        let marko = id("Marko Jovanović", &people(std::slice::from_ref(&meeting)));
        let curation = PeopleCuration {
            names: [(marko, "Marko J.".to_string())].into_iter().collect(),
            ..Default::default()
        };
        let renamed = people_with(&[meeting], HashMap::new(), curation);
        let result = matched(
            &[event("Atlas sync", 26.0, None, &[ANA, MARKO], &[])],
            &renamed,
        );
        assert_eq!(result[&id("Ana Petrović", &renamed)].others, ["Marko J."]);
    }
}
