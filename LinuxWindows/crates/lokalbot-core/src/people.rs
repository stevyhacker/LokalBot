//! People: profiles joined from calendar attendees, speaker names the user
//! applied and action owners (`PeopleDirectory.swift`, `PersonNotes.swift`).
//! Attendee email addresses are private join keys only: they never appear
//! in a profile, its ID or anything derived from it.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::sync::{LazyLock, OnceLock};

use anyhow::Result;
use chrono::NaiveDate;
use regex::Regex;
use uuid::Uuid;

use crate::actions::{attention_sorted, cluster_threads, normalized_words};
use crate::library::{Library, write_json};
use crate::model::*;

/// Decisions kept per person.
pub const MAXIMUM_DECISIONS: usize = 8;
/// A meeting with at most this many other named people counts as "with"
/// each of them for the user's own commitments.
pub const SMALL_MEETING_SIZE: usize = 2;
/// Decisions from meetings this small belong to every attendee.
pub const DECISION_MEETING_SIZE: usize = 4;
/// A second recording within this long of the first one's end, with the
/// same title, is the same call.
pub const RECORDING_GAP_TOLERANCE_SECONDS: i64 = 15 * 60;
const MAXIMUM_NOTE_POINTS: usize = 3;
const MAXIMUM_NOTE_MEETINGS: usize = 8;
const MAXIMUM_NOTE_CHARACTERS: usize = 280;

/// `person-%016llx` of a join key (`email:<address>` or `name:<normalized>`).
pub fn person_id(key: &str) -> String {
    format!("person-{}", crate::ids::fnv_hex(key))
}

/// The ID a name-only person gets.
pub fn person_id_for_name(name: &str) -> String {
    person_id(&format!("name:{}", normalized(name)))
}

/// Folded alphanumeric words (`PeopleDirectory.normalized`).
pub fn normalized(value: &str) -> String {
    normalized_words(value)
}

/// The user's own name: the configured autocomplete name when set, else
/// the operating-system account's full name (`NSFullUserName` on macOS).
pub fn user_full_name(configured: Option<&str>) -> Option<String> {
    if let Some(name) = configured.map(str::trim).filter(|n| !n.is_empty()) {
        return Some(name.to_string());
    }
    static OS_NAME: OnceLock<Option<String>> = OnceLock::new();
    OS_NAME.get_or_init(os_full_name).clone()
}

#[cfg(unix)]
fn os_full_name() -> Option<String> {
    let user = std::env::var("USER")
        .or_else(|_| std::env::var("LOGNAME"))
        .ok()?;
    let passwd = std::fs::read_to_string("/etc/passwd").ok()?;
    passwd_full_name(&passwd, &user)
}

#[cfg(windows)]
fn os_full_name() -> Option<String> {
    windows_full_name()
}

#[cfg(not(any(unix, windows)))]
fn os_full_name() -> Option<String> {
    None
}

/// The GECOS full name (before the first comma) of `user` in `/etc/passwd`.
pub fn passwd_full_name(passwd: &str, user: &str) -> Option<String> {
    passwd.lines().find_map(|line| {
        let fields: Vec<&str> = line.split(':').collect();
        if fields.len() < 5 || fields[0] != user {
            return None;
        }
        let name = fields[4].split(',').next().unwrap_or("").trim();
        (!name.is_empty()).then(|| name.to_string())
    })
}

#[cfg(windows)]
fn windows_full_name() -> Option<String> {
    use windows_sys::Win32::Security::Authentication::Identity::{GetUserNameExW, NameDisplay};
    let mut size: u32 = 0;
    // SAFETY: a null buffer with size 0 only queries the required length.
    unsafe { GetUserNameExW(NameDisplay, std::ptr::null_mut(), &mut size) };
    if size == 0 {
        return None;
    }
    let mut buffer = vec![0u16; size as usize + 1];
    // SAFETY: `buffer` holds `size` UTF-16 units plus a terminator, as requested.
    let ok = unsafe { GetUserNameExW(NameDisplay, buffer.as_mut_ptr(), &mut size) };
    if !ok {
        return None;
    }
    let name = String::from_utf16_lossy(&buffer[..size as usize])
        .trim()
        .to_string();
    (!name.is_empty()).then_some(name)
}

static SOURCE_SUFFIX: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)(\s*·\s*source\s*\d+)+\s*$").expect("valid regex"));
static PAREN_SUFFIX: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(\s*\([^)]*\))+\s*$").expect("valid regex"));
static PLACEHOLDER: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^(me|them|local|local speaker|speaker|remote|remote speaker|other speaker|unknown speaker|participant|guest)( \d+)?$")
        .expect("valid regex")
});

/// Removes merge suffixes ("· source 2") and trailing notes ("(host)").
pub fn cleaned_name(name: &str) -> String {
    let without_source = SOURCE_SUFFIX.replace(name, "");
    PAREN_SUFFIX.replace(&without_source, "").trim().to_string()
}

/// Speaker labels and collective words name no one.
pub fn is_placeholder(name: &str) -> bool {
    let key = normalized(&cleaned_name(name));
    const COLLECTIVE: &[&str] = &[
        "you",
        "we",
        "us",
        "team",
        "everyone",
        "all",
        "both",
        "someone",
        "nobody",
        "the team",
        "everybody",
        "group",
        "unknown",
        "owner unclear",
    ];
    key.is_empty() || COLLECTIVE.contains(&key.as_str()) || PLACEHOLDER.is_match(&key)
}

/// One to four name-like words with no group or role words.
pub fn is_person_name(name: &str) -> bool {
    if is_placeholder(name)
        || name.contains('/')
        || name.contains("'s ")
        || name.contains("’s ")
        || name.contains(',')
        || name.contains('&')
        || name.contains('+')
    {
        return false;
    }
    let key = normalized(name);
    let words: Vec<&str> = key.split(' ').filter(|w| !w.is_empty()).collect();
    const GROUP_WORDS: &[&str] = &[
        "team",
        "teams",
        "owner",
        "owners",
        "group",
        "department",
        "engineering",
        "research",
        "product",
        "design",
        "marketing",
        "sales",
        "legal",
        "ops",
        "operations",
        "support",
        "company",
        "client",
        "customer",
        "vendor",
        "partner",
        "partners",
        "folks",
        "people",
        "crew",
        "squad",
        "lead",
        "leads",
        "management",
        "committee",
        "board",
        "tbd",
    ];
    !words.contains(&"and")
        && (1..=4).contains(&words.len())
        && words.iter().all(|w| w.chars().all(char::is_alphabetic))
        && !words.iter().any(|w| GROUP_WORDS.contains(w))
}

/// Whole-word match of a full name or a first name of 3+ letters.
pub fn mentions(text: &str, name: &str) -> bool {
    let words = format!(" {} ", normalized(text));
    let full = normalized(name);
    if full.is_empty() {
        return false;
    }
    if words.contains(&format!(" {full} ")) {
        return true;
    }
    match full.split_once(' ') {
        Some((first, _)) if first.chars().count() >= 3 => words.contains(&format!(" {first} ")),
        _ => false,
    }
}

const COMMON_WORD_NAMES: &[&str] = &[
    "will", "may", "mark", "grant", "bill", "chase", "sue", "rob", "pat", "max", "hope", "frank",
    "june", "april", "august", "art", "joy", "faith", "dawn", "rich", "case",
];

/// Whether `text` names the person: the full name, or a capitalized first
/// name of 3+ letters that is not a common word starting a sentence.
pub fn is_named(name: &str, text: &str) -> bool {
    let name_words: Vec<String> = normalized(name)
        .split(' ')
        .filter(|w| !w.is_empty())
        .map(str::to_string)
        .collect();
    let Some(first) = name_words.first() else {
        return false;
    };
    let mut tokens: Vec<(String, String, bool)> = Vec::new();
    let mut starts_sentence = true;
    let mut current = String::new();
    let flush =
        |current: &mut String, tokens: &mut Vec<(String, String, bool)>, starts: &mut bool| {
            if !current.is_empty() {
                tokens.push((current.clone(), crate::ids::fold(current), *starts));
                *starts = false;
                current.clear();
            }
        };
    for c in text.chars() {
        if c.is_alphanumeric() {
            current.push(c);
        } else {
            flush(&mut current, &mut tokens, &mut starts_sentence);
            if ".!?:\n".contains(c) {
                starts_sentence = true;
            }
        }
    }
    flush(&mut current, &mut tokens, &mut starts_sentence);
    for (index, (word, folded, sentence_start)) in tokens.iter().enumerate() {
        if folded != first || !word.chars().next().is_some_and(char::is_uppercase) {
            continue;
        }
        if name_words.len() > 1
            && index + name_words.len() <= tokens.len()
            && tokens[index..]
                .iter()
                .zip(&name_words)
                .all(|(t, w)| t.1 == *w)
        {
            return true;
        }
        if first.chars().count() < 3 {
            continue;
        }
        if *sentence_start && COMMON_WORD_NAMES.contains(&first.as_str()) {
            continue;
        }
        return true;
    }
    false
}

/// Matches the user's own names (`PeopleDirectory.SelfMatcher`).
pub(crate) struct SelfMatcher {
    full: HashSet<String>,
    first: HashSet<String>,
    single: HashSet<String>,
}

impl SelfMatcher {
    pub(crate) fn new(names: &[String]) -> Self {
        let full: HashSet<String> = names
            .iter()
            .map(|n| normalized(n))
            .filter(|n| !n.is_empty())
            .collect();
        let first = full
            .iter()
            .filter_map(|n| n.split(' ').next().map(str::to_string))
            .collect();
        let single = full.iter().filter(|n| !n.contains(' ')).cloned().collect();
        Self {
            full,
            first,
            single,
        }
    }

    pub(crate) fn matches(&self, name: &str) -> bool {
        let key = normalized(&cleaned_name(name));
        if key.is_empty() {
            return false;
        }
        if self.full.contains(&key) {
            return true;
        }
        let Some(first) = key.split(' ').next() else {
            return false;
        };
        if !key.contains(' ') {
            return self.first.contains(&key);
        }
        self.single.contains(first)
    }
}

/// Speaker names the user applied in one meeting (`MeetingAppliedSpeakerNames`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct AppliedNames {
    pub names: Vec<String>,
    pub by_calendar_identity: HashMap<String, String>,
    pub by_speaker_key: HashMap<String, String>,
}

impl AppliedNames {
    pub fn from_transcript(transcript: &Transcript) -> Self {
        let aliases: BTreeMap<&String, &String> = transcript
            .speaker_aliases
            .iter()
            .filter(|(label, _)| {
                let key = Transcript::canonical_speaker_key(label);
                let local = key.rsplit(':').next().unwrap_or(&key).to_string();
                local != "me" && local != "local"
            })
            .collect();
        let mut by_calendar_identity = HashMap::new();
        for (label, identity) in &transcript.speaker_calendar_identity_ids {
            if let Some(name) = aliases.get(label) {
                by_calendar_identity.insert(identity.clone(), (*name).clone());
            }
        }
        let by_speaker_key = aliases
            .iter()
            .map(|(label, name)| (Transcript::canonical_speaker_key(label), (*name).clone()))
            .collect();
        let mut names: Vec<String> = aliases.values().map(|n| (*n).clone()).collect();
        names.sort();
        Self {
            names,
            by_calendar_identity,
            by_speaker_key,
        }
    }

    pub fn name_for_speaker(&self, label: &str) -> Option<&String> {
        self.by_speaker_key
            .get(&Transcript::canonical_speaker_key(label))
    }
}

/// Calendar attendees, deduplicated by address then by name.
fn resolved_identities(meeting: &Meeting) -> Vec<CalendarParticipantIdentity> {
    let raw: Vec<CalendarParticipantIdentity> = match &meeting.calendar_participant_identities {
        Some(identities) if !identities.is_empty() => identities.clone(),
        _ => meeting
            .participant_name_hints
            .iter()
            .flatten()
            .map(|name| CalendarParticipantIdentity {
                id: format!("legacy-name:{}", normalized(name)),
                name: Some(name.clone()),
                email_address: None,
            })
            .collect(),
    };
    let mut result: Vec<CalendarParticipantIdentity> = Vec::new();
    for mut identity in raw {
        identity.name = identity
            .name
            .map(|n| n.split_whitespace().collect::<Vec<_>>().join(" "))
            .filter(|n| !n.is_empty());
        identity.email_address = identity
            .email_address
            .map(|e| e.trim().to_lowercase())
            .filter(|e| {
                e.len() >= 3 && e.split('@').count() == 2 && !e.contains(char::is_whitespace)
            });
        if identity.name.is_none() && identity.email_address.is_none() {
            continue;
        }
        if let Some(email) = &identity.email_address
            && let Some(existing) = result
                .iter_mut()
                .find(|r| r.email_address.as_ref() == Some(email))
        {
            if existing.name.is_none() {
                existing.name = identity.name;
            }
            continue;
        }
        if let Some(name) = identity.name.as_ref().map(|n| normalized(n)) {
            let same_name: Vec<usize> = (0..result.len())
                .filter(|&i| result[i].name.as_ref().map(|n| normalized(n)) == Some(name.clone()))
                .collect();
            if identity.email_address.is_some()
                && let Some(&index) = same_name
                    .iter()
                    .find(|&&i| result[i].email_address.is_none())
            {
                result[index].email_address = identity.email_address;
                continue;
            }
            if identity.email_address.is_none() && same_name.len() == 1 {
                continue;
            }
        }
        result.push(identity);
    }
    result
}

const PUBLIC_MAIL_DOMAINS: &[&str] = &[
    "gmail.com",
    "googlemail.com",
    "yahoo.com",
    "hotmail.com",
    "outlook.com",
    "live.com",
    "msn.com",
    "icloud.com",
    "me.com",
    "mac.com",
    "aol.com",
    "proton.me",
    "protonmail.com",
    "gmx.com",
    "gmx.de",
    "mail.com",
    "yandex.com",
    "yandex.ru",
    "mail.ru",
    "qq.com",
    "163.com",
    "zoho.com",
    "fastmail.com",
    "hey.com",
];

/// A name suggested by an attendee address ("dragan@…", "ana.petrovic@gmail…").
fn name_from_address(identity: &CalendarParticipantIdentity) -> Option<String> {
    if identity.name.is_some() {
        return None;
    }
    let address = identity.email_address.as_ref()?;
    let (local, domain) = address.split_once('@')?;
    let local = local.split('+').next()?;
    let words: Vec<&str> = local
        .split(['.', '-', '_'])
        .filter(|w| !w.is_empty())
        .collect();
    if !(1..=4).contains(&words.len())
        || !words
            .iter()
            .all(|w| (1..=24).contains(&w.chars().count()) && w.chars().all(char::is_alphabetic))
    {
        return None;
    }
    const SHARED: &[&str] = &[
        "admin",
        "all",
        "calendar",
        "contact",
        "events",
        "hello",
        "info",
        "mail",
        "noreply",
        "notifications",
        "office",
        "reception",
        "room",
        "sales",
        "support",
        "team",
        "me",
        "you",
        "everyone",
        "presentation",
        "presenting",
        "sharedroom",
    ];
    if SHARED.contains(&words.concat().to_lowercase().as_str()) {
        return None;
    }
    let name = words
        .iter()
        .map(|w| capitalize(w))
        .collect::<Vec<_>>()
        .join(" ");
    if PUBLIC_MAIL_DOMAINS.contains(&domain) && !name.contains(' ') {
        return None;
    }
    Some(name)
}

fn capitalize(word: &str) -> String {
    let lower = word.to_lowercase();
    let mut chars = lower.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}

pub(crate) fn meeting_ref(meeting: &Meeting) -> MeetingRef {
    MeetingRef {
        id: meeting.id,
        title: meeting.display_title(),
        started_at: meeting.started_at,
        ended_at: meeting.ended_at,
        calendar_event_id: meeting.calendar_event_id.clone(),
        participant_count: 0,
    }
}

#[derive(Clone, Default)]
struct Entry {
    name_counts: BTreeMap<String, usize>,
    meetings: BTreeMap<Uuid, MeetingRef>,
    their_actions: BTreeMap<String, ActionThread>,
    my_actions: BTreeMap<String, ActionThread>,
    decisions: BTreeMap<String, (MeetingRef, Decision)>,
}

/// Joins calendar identities by address when present, otherwise by full
/// normalized name (`PeopleDirectory.Registry`).
#[derive(Default)]
struct Registry {
    entries: HashMap<String, Entry>,
    order: Vec<String>,
    key_by_name: HashMap<String, BTreeSet<String>>,
    redirects: HashMap<String, String>,
    members: HashMap<String, Vec<String>>,
    merge_target_names: HashMap<String, String>,
}

impl Registry {
    fn key_for_id(&self, id: &str) -> Option<String> {
        self.order
            .iter()
            .chain(self.redirects.keys())
            .find(|key| person_id(key) == id)
            .map(|key| self.canonical(key))
    }

    fn canonical(&self, key: &str) -> String {
        let mut current = key.to_string();
        let mut visited = HashSet::new();
        while let Some(next) = self.redirects.get(&current) {
            if !visited.insert(current.clone()) {
                break;
            }
            current = next.clone();
        }
        current
    }

    fn register(&mut self, email: Option<&str>, name: &str) -> String {
        let name_key = normalized(name);
        let key = if let Some(email) = email {
            let key = format!("email:{}", email.to_lowercase());
            let name_only = format!("name:{name_key}");
            let others = self
                .key_by_name
                .get(&name_key)
                .map(|keys| keys.iter().filter(|k| **k != name_only).count())
                .unwrap_or(0);
            if key != name_only && self.entries.contains_key(&name_only) && others == 0 {
                self.merge(&name_only, &key);
            }
            key
        } else if let Some(existing) = self
            .key_by_name
            .get(&name_key)
            .filter(|keys| keys.len() == 1)
        {
            existing.iter().next().cloned().unwrap_or_default()
        } else {
            format!("name:{name_key}")
        };
        self.add_name(name, &key);
        self.canonical(&key)
    }

    fn add_name(&mut self, name: &str, raw_key: &str) {
        let key = self.canonical(raw_key);
        if !self.entries.contains_key(&key) {
            self.entries.insert(key.clone(), Entry::default());
            self.order.push(key.clone());
        }
        let trimmed = name.trim();
        let display = if trimmed == trimmed.to_lowercase() {
            trimmed
                .split(' ')
                .map(capitalize)
                .collect::<Vec<_>>()
                .join(" ")
        } else {
            trimmed.to_string()
        };
        if let Some(entry) = self.entries.get_mut(&key) {
            *entry.name_counts.entry(display).or_default() += 1;
        }
        self.key_by_name
            .entry(normalized(name))
            .or_default()
            .insert(key);
    }

    fn names(&self, key: &str) -> Vec<String> {
        self.entries
            .get(&self.canonical(key))
            .map(|e| e.name_counts.keys().cloned().collect())
            .unwrap_or_default()
    }

    /// Exact full-name match first, then a unique first-name match.
    fn resolve(&self, name: &str, among: Option<&BTreeSet<String>>) -> Option<String> {
        let target = normalized(name);
        let candidates: Vec<String> = match among {
            Some(keys) => keys
                .iter()
                .map(|k| self.canonical(k))
                .collect::<BTreeSet<_>>()
                .into_iter()
                .collect(),
            None => self.order.clone(),
        };
        let exact: Vec<&String> = candidates
            .iter()
            .filter(|k| self.names(k).iter().any(|n| normalized(n) == target))
            .collect();
        if exact.len() == 1 {
            return Some(exact[0].clone());
        }
        if target.contains(' ') || target.chars().count() < 2 {
            return None;
        }
        let by_first: Vec<&String> = candidates
            .iter()
            .filter(|k| {
                self.names(k)
                    .iter()
                    .any(|n| normalized(n).split(' ').next() == Some(target.as_str()))
            })
            .collect();
        (by_first.len() == 1).then(|| by_first[0].clone())
    }

    fn entry(&mut self, key: &str) -> Option<&mut Entry> {
        let key = self.canonical(key);
        self.entries.get_mut(&key)
    }

    fn add_meeting(&mut self, meeting: &Meeting, key: &str) {
        if let Some(entry) = self.entry(key) {
            entry.meetings.insert(meeting.id, meeting_ref(meeting));
        }
    }

    fn add_chosen_names(&mut self, names: &BTreeMap<String, String>) {
        for (id, name) in names {
            if let Some(key) = self.key_for_id(id)
                && !normalized(name).is_empty()
            {
                self.add_name(name, &key);
            }
        }
    }

    fn apply_merges(&mut self, merges: &[PersonMerge]) {
        for merge in merges {
            let (Some(source), Some(target)) = (
                self.key_for_id(&merge.source_id),
                self.key_for_id(&merge.target_id),
            ) else {
                continue;
            };
            if source == target {
                continue;
            }
            if !self.merge_target_names.contains_key(&target)
                && let Some(entry) = self.entries.get(&target)
                && let Some(best) = ranked_names(entry).into_iter().next()
            {
                self.merge_target_names.insert(target.clone(), best);
            }
            self.merge(&source, &target);
        }
    }

    /// A first name alone joins the one person whose full name starts with it.
    fn merge_first_names_into_full_names(&mut self) {
        let mut full_by_first: HashMap<String, BTreeSet<String>> = HashMap::new();
        for key in &self.order {
            for name in self.names(key) {
                let words: Vec<String> = normalized(&name).split(' ').map(str::to_string).collect();
                if words.len() >= 2 {
                    full_by_first
                        .entry(words[0].clone())
                        .or_default()
                        .insert(key.clone());
                }
            }
        }
        for key in self.order.clone() {
            if !self.entries.contains_key(&key) {
                continue;
            }
            let keys: BTreeSet<String> = self.names(&key).iter().map(|n| normalized(n)).collect();
            let Some(only) = keys.iter().next().filter(|_| keys.len() == 1) else {
                continue;
            };
            if only.contains(' ') || only.chars().count() < 3 {
                continue;
            }
            let Some(targets) = full_by_first.get(only).filter(|t| t.len() == 1) else {
                continue;
            };
            let Some(target) = targets.iter().next().cloned() else {
                continue;
            };
            if target == key || (key.starts_with("email:") && target.starts_with("email:")) {
                continue;
            }
            self.merge(&key, &target);
        }
    }

    fn merge(&mut self, source: &str, target: &str) {
        let Some(moved) = self.entries.remove(source) else {
            return;
        };
        self.order.retain(|k| k != source);
        self.redirects
            .insert(source.to_string(), target.to_string());
        let mut source_members = self
            .members
            .remove(source)
            .unwrap_or_else(|| vec![source.to_string()]);
        self.members
            .entry(target.to_string())
            .or_insert_with(|| vec![target.to_string()])
            .append(&mut source_members);
        if !self.entries.contains_key(target) {
            self.entries.insert(target.to_string(), Entry::default());
            self.order.push(target.to_string());
        }
        for name in moved.name_counts.keys() {
            if let Some(keys) = self.key_by_name.get_mut(&normalized(name)) {
                keys.remove(source);
            }
            self.key_by_name
                .entry(normalized(name))
                .or_default()
                .insert(target.to_string());
        }
        if let Some(entry) = self.entries.get_mut(target) {
            for (name, count) in moved.name_counts {
                *entry.name_counts.entry(name).or_default() += count;
            }
            for (k, v) in moved.meetings {
                entry.meetings.entry(k).or_insert(v);
            }
            for (k, v) in moved.their_actions {
                entry.their_actions.entry(k).or_insert(v);
            }
            for (k, v) in moved.my_actions {
                entry.my_actions.entry(k).or_insert(v);
            }
            for (k, v) in moved.decisions {
                entry.decisions.entry(k).or_insert(v);
            }
        }
    }
}

/// The fullest name first, then the most frequent spelling.
fn ranked_names(entry: &Entry) -> Vec<String> {
    let mut names: Vec<(&String, &usize)> = entry.name_counts.iter().collect();
    names.sort_by(|a, b| {
        let (lw, rw) = (a.0.split(' ').count(), b.0.split(' ').count());
        rw.cmp(&lw).then(b.1.cmp(a.1)).then(a.0.cmp(b.0))
    });
    names.into_iter().map(|(n, _)| n.clone()).collect()
}

fn by_recency(threads: impl Iterator<Item = ActionThread>) -> Vec<ActionThread> {
    let mut threads: Vec<ActionThread> = threads.collect();
    threads.sort_by(|a, b| {
        b.latest()
            .meeting_started_at
            .cmp(&a.latest().meeting_started_at)
            .then_with(|| a.id.cmp(&b.id))
    });
    threads
}

/// Everything the directory is built from.
pub struct PeopleInput<'a> {
    pub meetings: &'a [Meeting],
    pub projections: &'a [crate::actions::OutcomeProjection],
    pub applied: &'a HashMap<Uuid, AppliedNames>,
    pub self_names: &'a [String],
    pub curation: &'a PeopleCuration,
    pub today: NaiveDate,
}

/// Builds every person profile (`PeopleDirectory.build`), most recently met first.
pub fn build_people(input: &PeopleInput) -> Vec<PersonProfile> {
    let mut people = Registry::default();
    let meetings: Vec<&Meeting> = input.meetings.iter().filter(|m| m.is_own_work()).collect();
    let is_self = SelfMatcher::new(input.self_names);
    let empty = AppliedNames::default();
    let mut participants: HashMap<Uuid, BTreeSet<String>> = HashMap::new();

    for meeting in &meetings {
        let applied = input.applied.get(&meeting.id).unwrap_or(&empty);
        let mut keys = BTreeSet::new();
        for identity in resolved_identities(meeting) {
            let applied_name = applied
                .by_calendar_identity
                .get(&identity.id)
                .map(|n| cleaned_name(n))
                .filter(|n| !is_placeholder(n));
            let Some(name) = applied_name
                .clone()
                .or(identity.name.clone())
                .or_else(|| name_from_address(&identity))
            else {
                continue;
            };
            if is_self.matches(&name) {
                continue;
            }
            let key = people.register(identity.email_address.as_deref(), &name);
            if let (Some(applied_name), Some(calendar_name)) = (&applied_name, &identity.name)
                && applied_name != calendar_name
            {
                people.add_name(calendar_name, &key);
            }
            keys.insert(key);
        }
        for name in applied.names.iter().map(|n| cleaned_name(n)) {
            if is_placeholder(&name) || is_self.matches(&name) {
                continue;
            }
            let key = people
                .resolve(&name, Some(&keys))
                .unwrap_or_else(|| people.register(None, &name));
            keys.insert(key);
        }
        for key in &keys {
            people.add_meeting(meeting, key);
        }
        participants.insert(meeting.id, keys);
    }
    people.merge_first_names_into_full_names();
    people.add_chosen_names(&input.curation.names);
    people.apply_merges(&input.curation.merges);

    let meetings_by_id: HashMap<Uuid, &Meeting> = meetings.iter().map(|m| (m.id, *m)).collect();
    let projections: Vec<&crate::actions::OutcomeProjection> = input
        .projections
        .iter()
        .filter(|p| meetings_by_id.contains_key(&p.meeting.id))
        .collect();
    let threads: Vec<ActionThread> = cluster_threads(
        projections
            .iter()
            .flat_map(|p| p.action_references())
            .collect(),
    )
    .into_iter()
    .filter(|t| t.status() != ActionStatus::Done)
    .collect();
    let roster = |people: &Registry, meeting_id: Uuid| -> BTreeSet<String> {
        participants
            .get(&meeting_id)
            .map(|keys| keys.iter().map(|k| people.canonical(k)).collect())
            .unwrap_or_default()
    };

    for thread in threads {
        let reference = thread.latest().clone();
        let roster_keys = roster(&people, reference.meeting_id);
        if thread.is_for_user() {
            let mut targets: BTreeSet<String> = roster_keys
                .iter()
                .filter(|key| people.names(key).iter().any(|n| mentions(&thread.text, n)))
                .cloned()
                .collect();
            if targets.is_empty() && (1..=SMALL_MEETING_SIZE).contains(&roster_keys.len()) {
                targets = roster_keys.clone();
            }
            for key in targets {
                if let Some(entry) = people.entry(&key) {
                    entry.my_actions.insert(thread.id.clone(), thread.clone());
                }
            }
        } else if let Some(owner) = thread.owner.as_deref().map(cleaned_name)
            && is_person_name(&owner)
            && !is_self.matches(&owner)
        {
            let key = people
                .resolve(&owner, Some(&roster_keys))
                .or_else(|| people.resolve(&owner, None))
                .unwrap_or_else(|| people.register(None, &owner));
            if let Some(meeting) = meetings_by_id.get(&reference.meeting_id) {
                people.add_meeting(meeting, &key);
            }
            if let Some(entry) = people.entry(&key) {
                entry
                    .their_actions
                    .insert(thread.id.clone(), thread.clone());
            }
        }
    }

    for projection in &projections {
        let roster_keys = roster(&people, projection.meeting.id);
        let applied = input.applied.get(&projection.meeting.id).unwrap_or(&empty);
        for decision in &projection.outcomes.decision_records {
            let id = format!(
                "{}:{}",
                crate::ids::uuid_upper(&projection.meeting.id),
                decision.id
            );
            let mut targets: BTreeSet<String> = if roster_keys.len() <= DECISION_MEETING_SIZE {
                roster_keys.clone()
            } else {
                BTreeSet::new()
            };
            if roster_keys.len() > DECISION_MEETING_SIZE {
                if let Some(attribution) = &decision.attribution
                    && attribution.identity != SpeakerIdentity::User
                    && let Some(name) = applied.name_for_speaker(&attribution.speaker_label)
                    && let Some(key) = people.resolve(name, Some(&roster_keys))
                {
                    targets.insert(key);
                }
                for key in &roster_keys {
                    if people
                        .names(key)
                        .iter()
                        .any(|n| is_named(n, &decision.text))
                    {
                        targets.insert(key.clone());
                    }
                }
            }
            for key in targets {
                if let Some(entry) = people.entry(&key) {
                    entry.decisions.insert(
                        id.clone(),
                        (meeting_ref(&projection.meeting), decision.clone()),
                    );
                }
            }
        }
    }
    people.apply_merges(&input.curation.merges);

    let roster_sizes: HashMap<Uuid, usize> = meetings
        .iter()
        .map(|m| (m.id, roster(&people, m.id).len()))
        .collect();
    let hidden: HashSet<&str> = input
        .curation
        .hidden
        .iter()
        .map(|h| h.id.as_str())
        .collect();
    let mut profiles: Vec<PersonProfile> = Vec::new();
    for key in &people.order {
        let Some(entry) = people.entries.get(key) else {
            continue;
        };
        if entry.meetings.is_empty() && entry.their_actions.is_empty() {
            continue;
        }
        let mut member_ids = vec![person_id(key)];
        member_ids.extend(
            people
                .members
                .get(key)
                .iter()
                .flat_map(|m| m.iter())
                .filter(|m| *m != key)
                .map(|m| person_id(m)),
        );
        if member_ids.iter().any(|id| hidden.contains(id.as_str())) {
            continue;
        }
        let mut names = ranked_names(entry);
        if let Some(preferred) = member_ids
            .iter()
            .find_map(|id| input.curation.names.get(id).cloned())
            .or_else(|| people.merge_target_names.get(key).cloned())
        {
            let preferred_key = normalized(&preferred);
            names.retain(|n| normalized(n) != preferred_key);
            names.insert(0, preferred);
        }
        let Some(name) = names.first().cloned() else {
            continue;
        };
        let mut meetings: Vec<MeetingRef> = entry
            .meetings
            .values()
            .map(|m| MeetingRef {
                participant_count: roster_sizes.get(&m.id).copied().unwrap_or(0),
                ..m.clone()
            })
            .collect();
        meetings.sort_by_key(|m| std::cmp::Reverse(m.started_at));
        let mut decisions: Vec<(MeetingRef, Decision)> =
            entry.decisions.values().cloned().collect();
        decisions.sort_by_key(|(m, _)| std::cmp::Reverse(m.started_at));
        decisions.truncate(MAXIMUM_DECISIONS);
        profiles.push(PersonProfile {
            id: person_id(key),
            name,
            other_names: names[1..].to_vec(),
            member_ids,
            meetings,
            their_actions: attention_sorted(
                by_recency(entry.their_actions.values().cloned()),
                input.today,
            ),
            my_actions: attention_sorted(
                by_recency(entry.my_actions.values().cloned()),
                input.today,
            ),
            decisions,
            recent_notes: Vec::new(),
            notes_meeting: None,
            projects: Vec::new(),
            project_links: Vec::new(),
        });
    }
    profiles.sort_by(|a, b| {
        b.last_met()
            .cmp(&a.last_met())
            .then_with(|| a.name.cmp(&b.name))
    });
    profiles
}

/// Recordings grouped into the meetings they belong to, newest first.
pub fn occasions(meetings: &[MeetingRef]) -> Vec<Vec<MeetingRef>> {
    let mut sorted = meetings.to_vec();
    sorted.sort_by_key(|m| std::cmp::Reverse(m.started_at));
    let mut groups: Vec<Vec<MeetingRef>> = Vec::new();
    for meeting in sorted {
        match groups
            .iter_mut()
            .find(|g| g.iter().any(|m| same_occasion(m, &meeting)))
        {
            Some(group) => group.push(meeting),
            None => groups.push(vec![meeting]),
        }
    }
    groups
}

/// Same local day and calendar event, or same title within 15 minutes.
pub fn same_occasion(left: &MeetingRef, right: &MeetingRef) -> bool {
    if crate::time::local_day(left.started_at) != crate::time::local_day(right.started_at) {
        return false;
    }
    if let (Some(a), Some(b)) = (&left.calendar_event_id, &right.calendar_event_id) {
        return a == b;
    }
    if normalized(&left.title) != normalized(&right.title) {
        return false;
    }
    let (earlier, later) = if left.started_at <= right.started_at {
        (left, right)
    } else {
        (right, left)
    };
    let earlier_end = earlier.ended_at.unwrap_or(earlier.started_at);
    later.started_at <= earlier_end + chrono::Duration::seconds(RECORDING_GAP_TOLERANCE_SECONDS)
}

/// The occasion's longest recording.
fn primary(occasion: &[MeetingRef]) -> &MeetingRef {
    let duration = |m: &MeetingRef| {
        (m.ended_at.unwrap_or(m.started_at) - m.started_at)
            .num_milliseconds()
            .max(0)
    };
    occasion
        .iter()
        .max_by(|a, b| {
            duration(a)
                .cmp(&duration(b))
                .then(a.started_at.cmp(&b.started_at))
        })
        .unwrap_or(&occasion[0])
}

// ------------------------------------------------------------------ notes

/// One summary bullet (`PersonNotes.SummaryLine`).
#[derive(Clone, Debug, PartialEq)]
pub struct SummaryLine {
    pub section: String,
    pub speaker: Option<String>,
    pub text: String,
    pub seek: Option<f64>,
}

static STAMP: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\[\d{1,2}(?::\d{2}){1,2}\]").expect("valid regex"));
static TRAILING_STAMPS: LazyLock<Regex> = LazyLock::new(|| {
    let stamp = r"\[\d{1,2}(?::\d{2}){1,2}\]";
    Regex::new(&format!(
        r"\s*(?:[—–-]\s*)?\(?\s*{stamp}(?:\s*[,–—-]?\s*{stamp})*\s*\)?\s*$"
    ))
    .expect("valid regex")
});
static INLINE_STAMPS: LazyLock<Regex> = LazyLock::new(|| {
    let stamp = r"\[\d{1,2}(?::\d{2}){1,2}\]";
    Regex::new(&format!(r"\s*\(?{stamp}(?:\s*[–—-]\s*{stamp})?\)?")).expect("valid regex")
});
static BOLD_SPEAKER: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\*\*[^*]{1,48}?:\*\*\s*").expect("valid regex"));
static BARE_SPEAKER: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[A-Za-z]+(?: \d+)?:\s+").expect("valid regex"));

const SKIPPED_SECTIONS: &[&str] = &[
    "action items",
    "actions",
    "next steps",
    "decisions",
    "follow ups",
    "follow up",
];
const OVERVIEW_SECTIONS: &[&str] = &["tl dr", "tldr", "summary", "overview", "key points"];

/// Summary bullets outside action/decision sections (`PersonNotes.lines`).
pub fn summary_lines(markdown: &str) -> Vec<SummaryLine> {
    let mut result = Vec::new();
    let mut section = String::new();
    for raw in markdown.lines() {
        let line = raw.trim();
        if let Some(heading) = line.strip_prefix("## ") {
            section = normalized(heading);
            continue;
        }
        if SKIPPED_SECTIONS.contains(&section.as_str()) {
            continue;
        }
        let Some(body) = line.strip_prefix("- ").or_else(|| line.strip_prefix("* ")) else {
            continue;
        };
        let mut body = body.trim().to_string();
        if body.starts_with('[') || body.is_empty() {
            continue;
        }
        let seek = STAMP
            .find(&body)
            .and_then(|m| crate::time::parse_stamp(&m.as_str()[1..m.as_str().len() - 1]));
        body = TRAILING_STAMPS.replace(&body, "").to_string();
        body = INLINE_STAMPS.replace_all(&body, "").to_string();
        let speaker = leading_speaker(&mut body);
        let text = shortened(body.replace("**", "").trim());
        if text.chars().count() < 12 || normalized(&text) == "none" {
            continue;
        }
        result.push(SummaryLine {
            section: section.clone(),
            speaker,
            text,
            seek,
        });
    }
    result
}

fn leading_speaker(body: &mut String) -> Option<String> {
    if let Some(m) = BOLD_SPEAKER.find(body) {
        let label = m.as_str().replace("**", "");
        let label = label.trim().trim_end_matches(':').trim().to_string();
        *body = body[m.end()..].to_string();
        return Some(label);
    }
    if let Some(m) = BARE_SPEAKER.find(body) {
        let label = m.as_str().trim().trim_end_matches(':').to_string();
        if is_placeholder(&label) || is_user_label(&label) {
            *body = body[m.end()..].to_string();
            return Some(label);
        }
    }
    None
}

fn is_user_label(label: &str) -> bool {
    matches!(normalized(label).as_str(), "you" | "me")
}

fn shortened(text: &str) -> String {
    if text.chars().count() <= MAXIMUM_NOTE_CHARACTERS {
        return text.to_string();
    }
    let cut: String = text.chars().take(MAXIMUM_NOTE_CHARACTERS).collect();
    let end = cut.rfind(' ').unwrap_or(cut.len());
    format!(
        "{}…",
        cut[..end].trim_end_matches(|c: char| c.is_ascii_punctuation() || c.is_whitespace())
    )
}

fn is_person(speaker: &str, names: &[String]) -> bool {
    let key = normalized(&cleaned_name(speaker));
    if key.is_empty() {
        return false;
    }
    names.iter().any(|name| {
        let candidate = normalized(name);
        candidate == key
            || (!key.contains(' ')
                && key.chars().count() >= 3
                && candidate.split(' ').next() == Some(key.as_str()))
    })
}

/// Whether a summary line was said by the person or names them.
pub(crate) fn line_is_about(
    line: &SummaryLine,
    person: &PersonProfile,
    applied: Option<&AppliedNames>,
) -> bool {
    let names: Vec<String> = std::iter::once(person.name.clone())
        .chain(person.other_names.iter().cloned())
        .collect();
    let speaker_name = line.speaker.as_ref().and_then(|label| {
        applied
            .and_then(|a| a.name_for_speaker(label).cloned())
            .or_else(|| (!is_placeholder(label) && !is_user_label(label)).then(|| label.clone()))
    });
    if speaker_name.as_ref().is_some_and(|s| is_person(s, &names)) {
        return true;
    }
    names.iter().any(|n| {
        let first = n.split(' ').next().unwrap_or(n);
        crate::ids::fold(&line.text).contains(&crate::ids::fold(first)) && is_named(n, &line.text)
    })
}

/// The newest meeting whose notes say something about the person
/// (`PersonNotes.recentNotes`): up to three lines, or a small meeting's
/// overview when no line names them.
pub fn recent_notes(
    person: &PersonProfile,
    lines: &HashMap<Uuid, Vec<SummaryLine>>,
    applied: &HashMap<Uuid, AppliedNames>,
) -> Option<(MeetingRef, Vec<String>)> {
    for occasion in occasions(&person.meetings)
        .iter()
        .take(MAXIMUM_NOTE_MEETINGS)
    {
        let main = primary(occasion).clone();
        let recordings = std::iter::once(&main).chain(occasion.iter().filter(|m| m.id != main.id));
        let mut points: Vec<String> = Vec::new();
        let mut overview: Vec<String> = Vec::new();
        let mut seen: HashSet<String> = HashSet::new();
        for recording in recordings {
            for line in lines.get(&recording.id).into_iter().flatten() {
                let key = normalized(&line.text);
                if line_is_about(line, person, applied.get(&recording.id)) {
                    if seen.insert(key) {
                        points.push(line.text.clone());
                    }
                } else if OVERVIEW_SECTIONS.contains(&line.section.as_str()) && !seen.contains(&key)
                {
                    overview.push(line.text.clone());
                }
            }
        }
        if points.is_empty() && (1..=SMALL_MEETING_SIZE).contains(&main.participant_count) {
            let mut unique = HashSet::new();
            points = overview
                .into_iter()
                .filter(|p| unique.insert(normalized(p)))
                .collect();
        }
        if !points.is_empty() {
            points.truncate(MAXIMUM_NOTE_POINTS);
            return Some((main, points));
        }
    }
    None
}

// ---------------------------------------------------------------- library

impl Library {
    /// The user's own names, excluded from people.
    pub fn self_names(&self) -> Vec<String> {
        let settings = crate::settings::Settings::load(&self.paths().settings_file());
        user_full_name(Some(&settings.cotyping_user_name))
            .into_iter()
            .collect()
    }

    pub fn people_curation(&self) -> Result<PeopleCuration> {
        Ok(
            crate::library::read_json(&self.paths().people_dir().join("curation.json"))?
                .unwrap_or_default(),
        )
    }

    /// Saves corrections; an empty curation deletes the file.
    pub fn save_people_curation(&self, curation: &PeopleCuration) -> Result<()> {
        let path = self.paths().people_dir().join("curation.json");
        if curation.names.is_empty() && curation.merges.is_empty() && curation.hidden.is_empty() {
            match std::fs::remove_file(&path) {
                Err(err) if err.kind() != std::io::ErrorKind::NotFound => return Err(err.into()),
                _ => return Ok(()),
            }
        }
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
            restrict(dir, 0o700);
        }
        write_json(&path, curation)?;
        restrict(&path, 0o600);
        Ok(())
    }

    /// Everyone the user meets, most recently met first, with recent notes
    /// and the projects named around them.
    pub fn people(&self) -> Result<Vec<PersonProfile>> {
        Ok(crate::projects::build_people_and_projects(self)?.0)
    }

    /// Speaker names applied per meeting.
    pub fn applied_names(&self, meetings: &[Meeting]) -> HashMap<Uuid, AppliedNames> {
        meetings
            .iter()
            .filter(|m| !m.is_merged_source())
            .filter_map(|m| {
                let transcript = self.transcript(m).ok().flatten()?;
                let names = AppliedNames::from_transcript(&transcript);
                (!names.names.is_empty()).then_some((m.id, names))
            })
            .collect()
    }
}

#[cfg_attr(not(unix), allow(unused_variables))]
fn restrict(path: &std::path::Path, mode: u32) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gecos_full_name() {
        let passwd =
            "root:x:0:0:root:/root:/bin/bash\nmaya:x:1000:1000:Maya Chen,,,:/home/maya:/bin/bash\n";
        assert_eq!(
            passwd_full_name(passwd, "maya").as_deref(),
            Some("Maya Chen")
        );
        assert_eq!(passwd_full_name(passwd, "nobody"), None);
        assert_eq!(user_full_name(Some(" Stevan ")).as_deref(), Some("Stevan"));
    }

    #[test]
    fn name_rules_match_swift() {
        assert!(is_placeholder("Them 4"));
        assert!(is_placeholder("Local speaker"));
        assert!(is_placeholder("the team"));
        assert!(!is_placeholder("Maya Chen"));
        assert_eq!(cleaned_name("Ana (host) · source 2"), "Ana");
        assert!(is_person_name("Maya Chen"));
        assert!(!is_person_name("Engineering team"));
        assert!(!is_person_name("Matt, John"));
        assert!(!is_person_name("Product/research"));
        assert!(!is_person_name("Ana and Marko"));
        assert!(mentions("Send Maya the deck", "Maya Chen"));
        assert!(!mentions("Send Mayan art", "Maya Chen"));
        assert!(is_named("Maya Chen", "We asked Maya to lead."));
        assert!(!is_named("May Lee", "May we start?"));
        assert!(is_named("Will Smith", "Ask Will Smith."));
    }

    #[test]
    fn summary_lines_strip_stamps_and_speakers() {
        let lines = summary_lines(
            "## TL;DR\n- **Maya Chen:** The client wants three vertical cuts. — [00:01:36]\n- None\n## Action items\n- [ ] Book it\n## Key points\n- Them 2: Framing stays wide for crops ([00:01:50]–[00:02:04])\n",
        );
        assert_eq!(lines.len(), 2, "{lines:?}");
        assert_eq!(lines[0].speaker.as_deref(), Some("Maya Chen"));
        assert_eq!(lines[0].text, "The client wants three vertical cuts.");
        assert_eq!(lines[0].seek, Some(96.0));
        assert_eq!(lines[1].speaker.as_deref(), Some("Them 2"));
        assert_eq!(lines[1].text, "Framing stays wide for crops");
    }

    #[test]
    fn self_matcher_excludes_the_user() {
        let matcher = SelfMatcher::new(&["Stevan".to_string()]);
        assert!(matcher.matches("Stevan Bogosavljevic"));
        assert!(matcher.matches("stevan"));
        assert!(!matcher.matches("Maya Chen"));
        let full = SelfMatcher::new(&["Maya Chen".to_string()]);
        assert!(full.matches("Maya"));
        assert!(!full.matches("Maya Lin"));
    }

    #[test]
    fn address_names() {
        let identity = |email: &str| CalendarParticipantIdentity {
            id: "x".into(),
            name: None,
            email_address: Some(email.into()),
        };
        assert_eq!(
            name_from_address(&identity("dragan@studio.example")).as_deref(),
            Some("Dragan")
        );
        assert_eq!(name_from_address(&identity("donaldkevlee@gmail.com")), None);
        assert_eq!(
            name_from_address(&identity("ana.petrovic@gmail.com")).as_deref(),
            Some("Ana Petrovic")
        );
        assert_eq!(name_from_address(&identity("info@studio.example")), None);
    }
}
