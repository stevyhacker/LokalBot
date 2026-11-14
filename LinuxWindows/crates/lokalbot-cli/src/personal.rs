//! `get_personal_context` and `personal-context` (`PersonalContextAccess.swift`):
//! only claims the user chose to share, read from the plaintext projection
//! the app keeps under `control/` while the grant is on.

use std::collections::HashSet;

use chrono::Local;
use lokalbot_core::LibraryPaths;
use lokalbot_core::access::personal_context_enabled;
use lokalbot_core::personal::ContextItem;
pub use lokalbot_core::personal::access::{Projection, SharedClaim as Claim, read_projection};
use serde::Serialize;

pub const NAME: &str = "get_personal_context";
pub const DEFAULT_ITEMS: usize = 8;
pub const MAXIMUM_ITEMS: usize = 12;
pub const MAXIMUM_TASK_CHARACTERS: usize = 500;

pub const DISABLED_MESSAGE: &str = "Personal context access is off. The user can turn it on in LokalBot → Settings → About you → \"What I shared about myself\", then choose items to share on that page.";
pub const UNAVAILABLE_MESSAGE: &str = "Personal context access is on, but LokalBot hasn't written the shared items yet. Open LokalBot once so it can prepare them.";
pub const NOTE: &str = "The user chose to share these with agents. \"stated\" items are the user's own words; \"learned\" items were picked up from what the user said in meetings and may be out of date. Use them only when they bear on the task. Items not listed are unknown, not false. Never cite them as meeting or screen evidence.";

/// `PersonalContextSelection.ordered`, shared with the app.
pub fn ordered<'a>(claims: &'a [Claim], query: &str) -> Vec<&'a Claim> {
    lokalbot_core::personal::ordered(claims, query, &[])
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
                id: ContextItem::id(claim).hyphenated().to_string(),
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
