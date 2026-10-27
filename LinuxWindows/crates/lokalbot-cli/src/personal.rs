//! `get_personal_context` and `personal-context` (`PersonalContextAccess.swift`):
//! only claims the user chose to share, read from the plaintext projection
//! the app keeps under `control/` while the grant is on.

use std::collections::HashSet;

use chrono::{DateTime, Local, Utc};
use lokalbot_core::LibraryPaths;
use lokalbot_core::access::{PERSONAL_PROJECTION, personal_context_enabled};
use serde::{Deserialize, Serialize};

pub const NAME: &str = "get_personal_context";
pub const DEFAULT_ITEMS: usize = 8;
pub const MAXIMUM_ITEMS: usize = 12;
pub const MAXIMUM_TASK_CHARACTERS: usize = 500;

// The Windows and Linux app has no Personal Context page or personal-context
// setting: the marker and the shared items arrive only with a library that
// came from a Mac.
pub const DISABLED_MESSAGE: &str = "Personal context access is off. The Windows and Linux app has no Personal Context page: the user writes and shares these items in the Mac app, so here they can be read only from a library that came from a Mac.";
pub const UNAVAILABLE_MESSAGE: &str = "Personal context access is on, but this library holds no shared items. Only the Mac app writes them; opening LokalBot on the Mac this library came from prepares them.";
pub const NOTE: &str = "The user chose to share these with agents. \"stated\" items are the user's own words; \"learned\" items were picked up from what the user said in meetings and may be out of date. Use them only when they bear on the task. Items not listed are unknown, not false. Never cite them as meeting or screen evidence.";

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Claim {
    pub id: uuid::Uuid,
    pub kind: String,
    pub text: String,
    #[serde(default)]
    pub always_use: bool,
    pub source: String,
    #[serde(with = "lokalbot_core::time::iso_seconds")]
    pub created_at: DateTime<Utc>,
    #[serde(with = "lokalbot_core::time::iso_seconds")]
    pub updated_at: DateTime<Utc>,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Projection {
    #[serde(default = "one")]
    pub version: u32,
    pub claims: Vec<Claim>,
}

fn one() -> u32 {
    1
}

/// The shared claims, or `None` when the grant is off or nothing readable was written.
pub fn read_projection(paths: &LibraryPaths) -> Option<Projection> {
    if !personal_context_enabled(paths) {
        return None;
    }
    let bytes = std::fs::read(paths.control_dir().join(PERSONAL_PROJECTION)).ok()?;
    serde_json::from_slice::<Projection>(&bytes)
        .ok()
        .filter(|p| p.version <= 1)
}

const STOPWORDS: &[&str] = &[
    "the", "and", "for", "are", "but", "not", "you", "your", "with", "that", "this", "have", "has",
    "had", "was", "were", "will", "would", "should", "could", "what", "when", "where", "which",
    "who", "whom", "why", "how", "about", "from", "into", "than", "then", "them", "they", "their",
    "there", "these", "those", "our", "out", "can", "did", "does", "doing", "just", "like", "more",
    "most", "some", "such", "only", "also", "very", "too", "any", "all", "its", "it's", "i'm",
    "myself", "mine", "me", "my", "his", "her", "him", "she", "one", "get", "got", "let", "make",
    "made", "want", "need", "tell", "know", "think", "remember", "please", "always", "never",
];

fn content_words(text: &str) -> HashSet<String> {
    lokalbot_core::ids::fold(text)
        .split(|c: char| !c.is_alphanumeric() && c != '\'')
        .map(|w| w.trim_matches('\''))
        .filter(|w| w.chars().count() >= 3 && !STOPWORDS.contains(w))
        .map(str::to_string)
        .collect()
}

/// Always-use items, then principles and preferences, then facts and goals
/// sharing words with the query, then the rest; newest first within each.
pub fn ordered<'a>(claims: &'a [Claim], query: &str) -> Vec<&'a Claim> {
    let query_words = content_words(query);
    let mut newest: Vec<&Claim> = claims.iter().collect();
    newest.sort_by(|a, b| {
        b.updated_at
            .cmp(&a.updated_at)
            .then_with(|| a.id.to_string().cmp(&b.id.to_string()))
    });
    let mut placed: HashSet<uuid::Uuid> = HashSet::new();
    let mut out: Vec<&Claim> = Vec::new();
    let mut place = |claim: &'a Claim, out: &mut Vec<&'a Claim>| {
        if placed.insert(claim.id) {
            out.push(claim);
        }
    };
    for claim in newest.iter().filter(|c| c.always_use) {
        place(claim, &mut out);
    }
    for claim in newest
        .iter()
        .filter(|c| c.kind == "principle" || c.kind == "preference")
    {
        place(claim, &mut out);
    }
    let mut matches: Vec<(&Claim, usize)> = newest
        .iter()
        .filter(|c| !out.iter().any(|o| o.id == c.id))
        .map(|c| {
            (
                *c,
                content_words(&c.text).intersection(&query_words).count(),
            )
        })
        .filter(|(_, score)| *score > 0)
        .collect();
    matches.sort_by_key(|m| std::cmp::Reverse(m.1));
    for (claim, _) in matches {
        place(claim, &mut out);
    }
    for claim in newest {
        place(claim, &mut out);
    }
    out
}

#[derive(Serialize)]
pub struct ReportItem {
    pub id: String,
    pub kind: String,
    pub text: String,
    pub authority: String,
    pub as_of: String,
    pub source: String,
    pub always_use: bool,
}

#[derive(Serialize)]
pub struct Report {
    pub task: String,
    pub items: Vec<ReportItem>,
    pub shared_count: usize,
    pub note: String,
}

pub enum Failure {
    Disabled,
    Unavailable,
    Invalid(String),
}

impl Failure {
    pub fn message(&self) -> String {
        match self {
            Failure::Disabled => DISABLED_MESSAGE.into(),
            Failure::Unavailable => UNAVAILABLE_MESSAGE.into(),
            Failure::Invalid(message) => message.clone(),
        }
    }
}

pub fn report(
    paths: &LibraryPaths,
    task: &str,
    kinds: Option<&[String]>,
    max_items: Option<i64>,
) -> Result<Report, Failure> {
    let task = task.trim();
    if task.is_empty() || task.chars().count() > MAXIMUM_TASK_CHARACTERS {
        return Err(Failure::Invalid(format!(
            "\"task\" must be a non-empty string of at most {MAXIMUM_TASK_CHARACTERS} characters."
        )));
    }
    let limit = max_items.unwrap_or(DEFAULT_ITEMS as i64);
    if !(1..=MAXIMUM_ITEMS as i64).contains(&limit) {
        return Err(Failure::Invalid(format!(
            "\"max_items\" must be an integer between 1 and {MAXIMUM_ITEMS}."
        )));
    }
    let mut wanted: Option<HashSet<String>> = None;
    if let Some(kinds) = kinds {
        let mut parsed = HashSet::new();
        for raw in kinds {
            let kind = raw.to_lowercase();
            if !["fact", "preference", "goal", "principle"].contains(&kind.as_str()) {
                return Err(Failure::Invalid(
                    "\"kinds\" may contain only fact, preference, goal, and principle.".into(),
                ));
            }
            parsed.insert(kind);
        }
        wanted = (!parsed.is_empty()).then_some(parsed);
    }
    if !personal_context_enabled(paths) {
        return Err(Failure::Disabled);
    }
    let Some(projection) = read_projection(paths) else {
        return Err(Failure::Unavailable);
    };
    let eligible: Vec<Claim> = projection
        .claims
        .iter()
        .filter(|c| wanted.as_ref().is_none_or(|w| w.contains(&c.kind)))
        .cloned()
        .collect();
    let items = ordered(&eligible, task)
        .into_iter()
        .take(limit as usize)
        .map(|claim| {
            let (source, authority) = match claim.source.as_str() {
                "asked_to_remember" => ("The user asked LokalBot to remember this", "stated"),
                "added_in_settings" => ("The user added this in LokalBot", "stated"),
                "learned_from_meeting" => (
                    "LokalBot learned this from something the user said in a meeting; it may be out of date",
                    "learned",
                ),
                "learned_from_typing" => {
                    ("LokalBot learned this from something the user typed; the user confirmed it", "learned")
                }
                "learned_from_dictation" => {
                    ("LokalBot learned this from something the user dictated; the user confirmed it", "learned")
                }
                _ => ("LokalBot saw this in the user's work for weeks; the user confirmed it", "learned"),
            };
            ReportItem {
                id: claim.id.hyphenated().to_string(),
                kind: claim.kind.clone(),
                text: claim.text.clone(),
                authority: authority.into(),
                as_of: claim.updated_at.with_timezone(&Local).format("%Y-%m-%d").to_string(),
                source: source.into(),
                always_use: claim.always_use,
            }
        })
        .collect();
    Ok(Report {
        task: task.to_string(),
        items,
        shared_count: projection.claims.len(),
        note: NOTE.into(),
    })
}
