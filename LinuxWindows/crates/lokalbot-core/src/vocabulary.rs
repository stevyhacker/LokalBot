//! Names and terms LokalBot already knows, offered to speech models that take a
//! vocabulary prompt (`TranscriptionVocabulary.swift`). Every source is local
//! and already part of the library: calendar attendee display names (never
//! addresses or names derived from addresses), speaker names the user applied
//! in related meetings, pinned overnight-review projects, tracked project names
//! and distinctive meeting-title terms. Speaker evidence, suggestions and voice
//! profile links are not read.

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::LazyLock;

use anyhow::Result;
use chrono::{DateTime, Utc};
use regex::Regex;
use serde::{Deserialize, Serialize};
use unicode_normalization::UnicodeNormalization as _;
use unicode_normalization::char::is_combining_mark;

use crate::library::{Library, read_json, write_json};
use crate::model::{CalendarParticipantIdentity, Meeting};
use crate::paths::LibraryPaths;
use crate::settings::Settings;
use crate::time::iso_seconds;

pub const FILE_NAME: &str = "transcription-vocabulary.json";
pub const MAXIMUM_TERMS: usize = 40;
pub const MAXIMUM_CHARACTERS: usize = 480;
pub const MAXIMUM_RELATED_MEETINGS: usize = 8;
/// How far back dictation looks for names (`recentSources`).
pub const RECENT_DAYS: i64 = 45;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Sources {
    pub attendee_names: Vec<String>,
    pub applied_speaker_names: Vec<String>,
    pub project_names: Vec<String>,
    pub title_terms: Vec<String>,
}

/// Per-meeting record, so a crash resume uses the same prompt even if the
/// library changed in between.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Record {
    #[serde(default = "first_version")]
    pub version: u32,
    pub terms: Vec<String>,
    #[serde(with = "iso_seconds")]
    pub created_at: DateTime<Utc>,
}

fn first_version() -> u32 {
    1
}

/// Priority order: attendees, names the user applied before, projects, then
/// title terms. Deduplicated ignoring case and accents, and bounded so the
/// prompt never crowds out the audio context.
pub fn terms(sources: &Sources) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut result: Vec<String> = Vec::new();
    let mut characters = 0;
    let ordered = sources
        .attendee_names
        .iter()
        .chain(&sources.applied_speaker_names)
        .chain(&sources.project_names)
        .chain(&sources.title_terms);
    for raw in ordered {
        let term = cleaned_term(raw);
        let count = term.chars().count();
        if !(2..=60).contains(&count) || is_placeholder_name(&term) {
            continue;
        }
        if !seen.insert(folded(&term)) {
            continue;
        }
        if result.len() >= MAXIMUM_TERMS || characters + count + 2 > MAXIMUM_CHARACTERS {
            break;
        }
        characters += count + 2;
        result.push(term);
    }
    result
}

/// The user's own vocabulary stays first and verbatim; known terms follow.
pub fn prompt(manual: &str, terms: &[String]) -> String {
    let manual = manual.trim();
    if terms.is_empty() {
        return manual.to_string();
    }
    let known = format!("{}.", terms.join(", "));
    if manual.is_empty() {
        known
    } else {
        format!("{manual}\n{known}")
    }
}

/// What is known for one meeting: its attendees, names applied in up to eight
/// earlier related meetings (the same series, or a shared attendee), projects
/// and its title's distinctive words.
pub fn sources(meeting: &Meeting, meetings: &[Meeting], library: &Library) -> Sources {
    let attendees = attendee_names(meeting);
    let attendee_keys: HashSet<String> = attendees.iter().map(|n| normalized_key(n)).collect();
    let title = meeting.calendar_title.as_deref().unwrap_or(&meeting.title);
    let series = normalized_key(title);
    let mut related: Vec<&Meeting> = meetings
        .iter()
        .filter(|candidate| {
            if candidate.id == meeting.id
                || candidate.started_at >= meeting.started_at
                || !candidate.is_own_work()
            {
                return false;
            }
            let same_series = !series.is_empty()
                && normalized_key(
                    candidate
                        .calendar_title
                        .as_deref()
                        .unwrap_or(&candidate.title),
                ) == series
                && !is_generic_title(&series);
            same_series
                || attendee_names(candidate)
                    .iter()
                    .any(|name| attendee_keys.contains(&normalized_key(name)))
        })
        .collect();
    related.sort_by_key(|candidate| std::cmp::Reverse(candidate.started_at));
    related.truncate(MAXIMUM_RELATED_MEETINGS);
    let mut applied_speaker_names = Vec::new();
    for candidate in related {
        let Ok(Some(transcript)) = library.transcript(candidate) else {
            continue;
        };
        let mut names: Vec<String> = transcript.speaker_aliases.values().cloned().collect();
        names.sort();
        applied_speaker_names.extend(names);
    }
    let mut project_names = endorsed_project_names(library.paths());
    // Names the person tracks in Projects are confirmed spellings too.
    if let Ok(curation) = library.project_curation() {
        for project in curation.tracked {
            project_names.push(project.name);
            project_names.extend(project.other_names);
        }
    }
    Sources {
        attendee_names: attendees,
        applied_speaker_names,
        project_names,
        title_terms: title_terms(title),
    }
}

/// Recent attendee names and projects for dictation, which has no meeting of
/// its own. The most frequently met people come first.
pub fn recent_sources(meetings: &[Meeting], paths: &LibraryPaths, now: DateTime<Utc>) -> Sources {
    let cutoff = now - chrono::Duration::days(RECENT_DAYS);
    let mut counts: HashMap<String, (String, u32, DateTime<Utc>)> = HashMap::new();
    for meeting in meetings
        .iter()
        .filter(|m| m.started_at >= cutoff && m.is_own_work())
    {
        for name in attendee_names(meeting) {
            let entry = counts.entry(normalized_key(&name)).or_insert((
                name.clone(),
                0,
                meeting.started_at,
            ));
            entry.0 = name;
            entry.1 += 1;
            entry.2 = entry.2.max(meeting.started_at);
        }
    }
    let mut people: Vec<_> = counts.into_values().collect();
    people.sort_by(|a, b| b.1.cmp(&a.1).then(b.2.cmp(&a.2)));
    Sources {
        attendee_names: people.into_iter().map(|(name, ..)| name).collect(),
        project_names: endorsed_project_names(paths),
        ..Default::default()
    }
}

/// Only projects the person pinned in `memory/memory.json`. Unpinned ones are
/// model labels, often built from earlier mishearings; as vocabulary they
/// biased the next transcript toward the same errors.
fn endorsed_project_names(paths: &LibraryPaths) -> Vec<String> {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Memory {
        version: u32,
        #[serde(default)]
        active_projects: Vec<Project>,
    }
    #[derive(Deserialize)]
    struct Project {
        name: String,
        #[serde(default)]
        pinned: bool,
    }
    let root = paths.root();
    // A retraction in progress (`DreamStore.evidenceIsAvailable`) fails closed.
    if root.join(".dream-revocation-pending.json").exists() {
        return Vec::new();
    }
    let memory: Option<Memory> = read_json(&root.join("memory").join("memory.json"))
        .ok()
        .flatten();
    memory
        .filter(|memory| (1..=2).contains(&memory.version))
        .map(|memory| {
            memory
                .active_projects
                .into_iter()
                .filter(|project| project.pinned)
                .map(|project| project.name)
                .collect()
        })
        .unwrap_or_default()
}

pub fn load(folder: &Path) -> Option<Record> {
    read_json(&folder.join(FILE_NAME)).ok().flatten()
}

pub fn save(record: &Record, folder: &Path) -> Result<()> {
    write_json(&folder.join(FILE_NAME), record)
}

/// The prompt a finished meeting was transcribed with, for cleanup that runs
/// after transcription: the manual vocabulary plus the saved terms.
pub fn saved_prompt(manual: &str, folder: &Path) -> String {
    let terms = load(folder).map(|record| record.terms).unwrap_or_default();
    prompt(manual, &terms)
}

/// The manual vocabulary plus names LokalBot already knows, for speech models
/// that read a prompt (`ProcessingPipeline.transcriptionPrompt`). A resume
/// reuses the terms saved with the meeting.
pub fn transcription_prompt(
    meeting: &Meeting,
    library: &Library,
    settings: &Settings,
    accepts_prompt: bool,
    reuse_saved: bool,
) -> String {
    // The sample transcribes the same way in every library, so names from the
    // user's own meetings never steer it.
    if !settings.auto_transcription_vocabulary || meeting.is_sample() || !accepts_prompt {
        return settings.transcription_prompt.clone();
    }
    let folder = library.meeting_dir(meeting);
    if reuse_saved && let Some(saved) = load(&folder) {
        return prompt(&settings.transcription_prompt, &saved.terms);
    }
    let meetings = library.list_all_meetings().unwrap_or_default();
    let terms = terms(&sources(meeting, &meetings, library));
    let record = Record {
        version: 1,
        terms: terms.clone(),
        created_at: Utc::now(),
    };
    if let Err(error) = save(&record, &folder) {
        log::warn!("transcription vocabulary not saved: {error:#}");
    }
    prompt(&settings.transcription_prompt, &terms)
}

const GENERIC_TITLE_WORDS: &[&str] = &[
    "all",
    "and",
    "call",
    "catch",
    "check",
    "daily",
    "demo",
    "for",
    "hands",
    "in",
    "kickoff",
    "meeting",
    "monthly",
    "office",
    "hours",
    "on",
    "one",
    "planning",
    "quarterly",
    "retro",
    "review",
    "standup",
    "stand",
    "up",
    "sync",
    "team",
    "the",
    "to",
    "weekly",
    "with",
    "workshop",
    "interview",
    "onboarding",
    "update",
];

/// Department and format words name a series ("Product standup", so they still
/// relate its meetings) but are ordinary words a speech model spells on its
/// own; as vocabulary, "Product" came back in prompt-echo rows.
const COMMON_TITLE_WORDS: &[&str] = &[
    "product",
    "design",
    "engineering",
    "eng",
    "dev",
    "tech",
    "marketing",
    "sales",
    "research",
    "support",
    "operations",
    "ops",
    "finance",
    "legal",
    "hr",
    "people",
    "leadership",
    "management",
    "growth",
    "data",
    "platform",
    "mobile",
    "web",
    "backend",
    "frontend",
    "infra",
    "infrastructure",
    "security",
    "analytics",
    "content",
    "community",
    "customer",
    "client",
    "partner",
    "vendor",
    "status",
    "project",
    "sprint",
    "roadmap",
    "strategy",
    "discussion",
    "session",
    "brainstorm",
    "brainstorming",
    "lunch",
    "coffee",
    "chat",
    "intro",
    "introduction",
    "prep",
    "debrief",
    "backlog",
    "grooming",
    "refinement",
    "triage",
    "handoff",
    "huddle",
    "offsite",
    "training",
    "feedback",
    "budget",
    "hiring",
    "recruiting",
    "release",
    "launch",
    "general",
    "internal",
    "external",
    "optional",
    "agenda",
    "notes",
    "followup",
    "follow",
    "biweekly",
    "fortnightly",
    "morning",
    "afternoon",
    "evening",
    "today",
    "tomorrow",
];

/// Capitalized or mixed-case words and acronyms from a title ("Acme", "iOS",
/// "SDK") are likely names worth spelling; generic words are not.
pub fn title_terms(title: &str) -> Vec<String> {
    title
        .split(|c: char| !c.is_alphanumeric() && c != '-' && c != '\'')
        .filter(|word| !word.is_empty())
        .filter(|word| {
            let lowered = word.to_lowercase();
            if word.chars().count() < 2
                || GENERIC_TITLE_WORDS.contains(&lowered.as_str())
                || COMMON_TITLE_WORDS.contains(&lowered.as_str())
                || !word.chars().any(char::is_alphabetic)
            {
                return false;
            }
            word.chars().any(char::is_uppercase)
        })
        .map(str::to_string)
        .collect()
}

fn is_generic_title(normalized_title: &str) -> bool {
    normalized_title
        .split(' ')
        .all(|word| GENERIC_TITLE_WORDS.contains(&word))
}

/// `Meeting.resolvedCalendarParticipantIdentities`: structured identities when
/// there are any, else the legacy name list. Only display names.
fn attendee_names(meeting: &Meeting) -> Vec<String> {
    let structured = CalendarParticipantIdentity::normalized(
        meeting
            .calendar_participant_identities
            .as_deref()
            .unwrap_or_default(),
    );
    let identities = if structured.is_empty() {
        CalendarParticipantIdentity::from_legacy_names(
            meeting
                .participant_name_hints
                .as_deref()
                .unwrap_or_default(),
        )
    } else {
        structured
    };
    identities
        .into_iter()
        .filter_map(|identity| identity.name)
        .collect()
}

/// Placeholder labels ("Them 6", "Speaker unclear", "Local speaker") and
/// collective words carry no spelling value; fed to a recognizer, a label came
/// back as transcript rows on silent spans.
fn is_placeholder_name(name: &str) -> bool {
    static SPEAKER: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"(?i)^(?:Them(?: \d+)?|Speaker(?: \d+| unclear)?|Local speaker)$")
            .expect("valid regex")
    });
    SPEAKER.is_match(name) || crate::people::is_placeholder(name)
}

/// Merges suffix applied names with "· source 2", which names a recording
/// rather than a person; whitespace and edge punctuation go too.
fn cleaned_term(raw: &str) -> String {
    static EDGES: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"^[\s\p{P}]+|[\s\p{P}]+$").expect("valid regex"));
    let cleaned = crate::people::cleaned_name(raw);
    let collapsed = cleaned.split_whitespace().collect::<Vec<_>>().join(" ");
    EDGES.replace_all(&collapsed, "").into_owned()
}

/// Case- and accent-insensitive form (`folding(.caseInsensitive, .diacriticInsensitive)`).
fn folded(value: &str) -> String {
    value
        .nfd()
        .filter(|c| !is_combining_mark(*c))
        .flat_map(char::to_lowercase)
        .collect()
}

fn normalized_key(value: &str) -> String {
    folded(value)
        .split(|c: char| !c.is_alphanumeric())
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|v| v.to_string()).collect()
    }

    #[test]
    fn terms_keep_the_order_and_drop_what_has_no_spelling_value() {
        let sources = Sources {
            attendee_names: strings(&["Ana Marić", "Them 6", "Speaker unclear", "x"]),
            applied_speaker_names: strings(&["ana maric", "Bob · source 2", "Local speaker"]),
            project_names: strings(&["Atlas", "Team"]),
            title_terms: strings(&["SDK", "\"Acme\","]),
        };
        assert_eq!(
            terms(&sources),
            strings(&["Ana Marić", "Bob", "Atlas", "SDK", "Acme"])
        );
    }

    #[test]
    fn terms_stop_at_either_limit() {
        let many: Vec<String> = (0..60).map(|i| format!("Name{i:02}")).collect();
        let sources = Sources {
            attendee_names: many,
            ..Default::default()
        };
        assert_eq!(terms(&sources).len(), MAXIMUM_TERMS);

        let long: Vec<String> = (0..20)
            .map(|i| format!("{i:02}{}", "n".repeat(58)))
            .collect();
        let sources = Sources {
            attendee_names: long,
            ..Default::default()
        };
        // 60 characters plus the separator's 2, up to 480.
        assert_eq!(terms(&sources).len(), 7);
    }

    #[test]
    fn prompt_puts_the_manual_vocabulary_first() {
        let known = strings(&["Ana", "Atlas"]);
        assert_eq!(prompt("  Kubernetes \n", &known), "Kubernetes\nAna, Atlas.");
        assert_eq!(prompt("", &known), "Ana, Atlas.");
        assert_eq!(prompt(" Kubernetes ", &[]), "Kubernetes");
        assert_eq!(prompt("  ", &[]), "");
    }

    #[test]
    fn title_terms_pick_names_and_acronyms() {
        assert_eq!(
            title_terms("Acme iOS SDK Weekly Sync with the Product team"),
            strings(&["Acme", "iOS", "SDK"])
        );
        assert_eq!(title_terms("q3 budget 2026 Q4"), strings(&["Q4"]));
        assert_eq!(title_terms("Standup"), Vec::<String>::new());
    }

    #[test]
    fn a_mac_record_reads_back() {
        let dir = tempfile::tempdir().unwrap();
        // As `JSONEncoder` writes it: pretty-printed, sorted keys, ISO 8601.
        std::fs::write(
            dir.path().join(FILE_NAME),
            "{\n  \"createdAt\" : \"2026-10-03T08:15:00Z\",\n  \"terms\" : [\n    \"Ana\"\n  ],\n  \"version\" : 1\n}",
        )
        .unwrap();
        let record = load(dir.path()).unwrap();
        assert_eq!(record.terms, strings(&["Ana"]));
        assert_eq!(saved_prompt("Kubernetes", dir.path()), "Kubernetes\nAna.");

        save(&record, dir.path()).unwrap();
        let saved: serde_json::Value =
            serde_json::from_slice(&std::fs::read(dir.path().join(FILE_NAME)).unwrap()).unwrap();
        assert_eq!(saved["createdAt"], "2026-10-03T08:15:00Z");
        assert_eq!(saved["version"], 1);
    }

    fn meeting(title: &str, day: u32, names: &[&str]) -> Meeting {
        let started = chrono::TimeZone::with_ymd_and_hms(&Utc, 2026, 10, day, 9, 0, 0).unwrap();
        let mut meeting = Meeting::new(title, "App", started, &format!("m{day}"));
        meeting.participant_name_hints = Some(strings(names));
        meeting
    }

    fn library() -> (tempfile::TempDir, Library) {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(LibraryPaths::new(dir.path())).unwrap();
        (dir, library)
    }

    #[test]
    fn dictation_prefers_the_people_met_most() {
        let (_dir, library) = library();
        let now = chrono::TimeZone::with_ymd_and_hms(&Utc, 2026, 10, 30, 0, 0, 0).unwrap();
        let meetings = vec![
            meeting("A", 1, &["Bo Lind"]),
            meeting("B", 2, &["Ana Marić", "Bo Lind"]),
            meeting("C", 3, &["Ana Maric"]),
            meeting("D", 4, &["Ana Maric", "Cy Young"]),
        ];
        let sources = recent_sources(&meetings, library.paths(), now);
        assert_eq!(sources.attendee_names[0], "Ana Maric");
        assert_eq!(sources.attendee_names[1], "Bo Lind");
        assert_eq!(sources.attendee_names[2], "Cy Young");

        let later = now + chrono::Duration::days(60);
        assert!(
            recent_sources(&meetings, library.paths(), later)
                .attendee_names
                .is_empty()
        );
    }

    #[test]
    fn only_pinned_projects_are_endorsed() {
        let (dir, library) = library();
        std::fs::create_dir_all(dir.path().join("memory")).unwrap();
        std::fs::write(
            dir.path().join("memory/memory.json"),
            r#"{"version":2,"activeProjects":[{"name":"Pinned","status":"","lastActiveDay":"2026-10-01","pinned":true},{"name":"Ave vault","status":"","lastActiveDay":"2026-10-01"}]}"#,
        )
        .unwrap();
        assert_eq!(
            endorsed_project_names(library.paths()),
            strings(&["Pinned"])
        );
        std::fs::write(dir.path().join(".dream-revocation-pending.json"), "[]").unwrap();
        assert!(endorsed_project_names(library.paths()).is_empty());
    }

    #[test]
    fn a_resume_reuses_the_saved_terms_and_the_sample_stays_neutral() {
        let (_dir, library) = library();
        let mut settings = Settings {
            transcription_prompt: "Kubernetes".into(),
            ..Default::default()
        };
        let mut target = meeting("Acme review", 10, &["Ana Marić"]);
        library.save_meeting(&target).unwrap();
        assert_eq!(
            transcription_prompt(&target, &library, &settings, true, false),
            "Kubernetes\nAna Marić, Acme."
        );
        let folder = library.meeting_dir(&target);
        let saved = load(&folder).unwrap();
        assert_eq!(saved.terms, strings(&["Ana Marić", "Acme"]));

        // A resume ignores what changed since; a fresh run sees it.
        target.participant_name_hints = Some(strings(&["Bo Lind"]));
        assert_eq!(
            transcription_prompt(&target, &library, &settings, true, true),
            "Kubernetes\nAna Marić, Acme."
        );
        assert_eq!(
            transcription_prompt(&target, &library, &settings, true, false),
            "Kubernetes\nBo Lind, Acme."
        );

        // A model that takes no prompt, the setting off, or the sample.
        assert_eq!(
            transcription_prompt(&target, &library, &settings, false, false),
            "Kubernetes"
        );
        settings.auto_transcription_vocabulary = false;
        assert_eq!(
            transcription_prompt(&target, &library, &settings, true, false),
            "Kubernetes"
        );
        settings.auto_transcription_vocabulary = true;
        target.sample_id = Some("sample".into());
        assert_eq!(
            transcription_prompt(&target, &library, &settings, true, false),
            "Kubernetes"
        );
    }

    #[test]
    fn related_meetings_lend_their_applied_names() {
        let (_dir, library) = library();
        let earlier = meeting("Acme review", 1, &["Ana Marić"]);
        let unrelated = meeting("Other", 2, &["Zed Roe"]);
        library.save_meeting(&earlier).unwrap();
        library.save_meeting(&unrelated).unwrap();
        for (source, alias) in [(&earlier, "Bo Lind"), (&unrelated, "Not Related")] {
            let mut transcript = crate::model::Transcript::default();
            transcript
                .speaker_aliases
                .insert("them".into(), alias.to_string());
            library.save_transcript(source, &transcript).unwrap();
        }
        let current = meeting("Acme review", 5, &["Ana Maric"]);
        let meetings = vec![earlier, unrelated, current.clone()];
        let sources = sources(&current, &meetings, &library);
        assert_eq!(sources.applied_speaker_names, strings(&["Bo Lind"]));
        assert_eq!(sources.title_terms, strings(&["Acme"]));
    }
}
