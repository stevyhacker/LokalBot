//! After the overnight review: one line for each recent finished week and month,
//! condensed from that period's daily reviews, so the agent briefing can show
//! older time at lower detail (`DreamRollupService`). A line records a stamp of
//! the reviews it came from; a deleted or regenerated review makes it stale, and
//! stale lines are removed here and never shown. At most a few model calls a
//! night, newest periods first.

use anyhow::Result;
use chrono::{DateTime, Duration, Utc};

use lokalbot_core::dream::day_from_key;
use lokalbot_core::dream::rollup::{self, DayReview, Kind, MAXIMUM_PER_NIGHT, Period, Rollup};
use lokalbot_core::{Library, time::local_day};

use crate::json::strip_reasoning;
use crate::prompts;
use crate::sanitize::sanitize;
use crate::think::{ChatRequest, ThinkClient};

const MAXIMUM_INPUT_CHARACTERS: usize = 12_000;
const MAXIMUM_LINE_CHARACTERS: usize = 280;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Outcome {
    pub written: Vec<String>,
    pub removed: Vec<String>,
}

pub fn prompt(period: &Period, reviews: &[&DayReview]) -> String {
    let per_review = (MAXIMUM_INPUT_CHARACTERS / reviews.len().max(1)).max(200);
    let count = if period.kind == Kind::Week { 6 } else { 3 };
    let days: Vec<String> = reviews
        .iter()
        .map(|review| {
            let label = day_from_key(&review.day)
                .map(|day| day.format("%a %b %-d").to_string())
                .unwrap_or_else(|| review.day.clone());
            let text = sanitize(
                &rollup::sentences(&review.narrative, count, per_review),
                Some(per_review),
            );
            format!("{label}: {text}")
        })
        .collect();
    let (span, name) = if period.kind == Kind::Week {
        (format!("week ({})", period.label), "week")
    } else {
        (format!("month ({})", period.label), "month")
    };
    format!(
        "Daily reviews for the {span}:\n\n{}\n\nWrite the one-line summary of this {name}.",
        days.join("\n\n")
    )
}

/// The first non-empty line, without a label or quotation marks.
pub fn line_from(output: &str) -> Option<String> {
    let visible = strip_reasoning(output);
    let first = visible.lines().map(str::trim).find(|l| !l.is_empty())?;
    let mut line = first;
    for prefix in ["Summary:", "Week:", "Month:"] {
        if let Some(rest) = line.strip_prefix(prefix) {
            line = rest.trim();
        }
    }
    let line = line.trim_matches(|c| matches!(c, '"' | '“' | '”' | '*' | '-' | ' '));
    let clean = sanitize(line, Some(MAXIMUM_LINE_CHARACTERS));
    (!clean.is_empty()).then_some(clean)
}

/// Removes stale lines and lines for periods the briefing no longer shows, then
/// writes up to `limit` due lines, unless lines were written within the minimum
/// interval. The engine is made only when something is due.
pub fn run(
    library: &Library,
    now: DateTime<Utc>,
    limit: usize,
    make_engine: &dyn Fn() -> Result<ThinkClient>,
) -> Result<Outcome> {
    let root = library.paths().root();
    let mut outcome = Outcome::default();
    let reviews = rollup::reviews(root);
    let today = local_day(now);
    let kept: Vec<String> = rollup::periods(today).into_iter().map(|p| p.key).collect();
    let mut current: Vec<Rollup> = Vec::new();
    for line in rollup::rollups(root) {
        if kept.contains(&line.key) && rollup::is_valid(&line, &reviews) {
            current.push(line);
        } else {
            let _ = std::fs::remove_file(rollup::rollup_path(root, &line.key));
            outcome.removed.push(line.key);
        }
    }
    let due: Vec<Period> = rollup::due(&reviews, &current, today)
        .into_iter()
        .take(limit)
        .collect();
    if due.is_empty() {
        return Ok(outcome);
    }
    if let Some(last) = rollup::last_generation(root)
        && now - last < Duration::seconds(rollup::MINIMUM_GENERATION_INTERVAL_SECONDS)
    {
        return Ok(outcome);
    }
    let think = make_engine()?;
    rollup::record_generation(root, now);
    for period in due {
        let inside = rollup::reviews_in(&period.first_day, &period.last_day, &reviews);
        let request = ChatRequest::new(prompts::DREAM_ROLLUP_SYSTEM, prompt(&period, &inside))
            .max_tokens(200)
            .reasoning_budget(0)
            .temperature(0.2);
        let output = think.complete(&request)?;
        let Some(line) = line_from(&output) else {
            continue;
        };
        rollup::write(
            &Rollup {
                kind: period.kind,
                key: period.key.clone(),
                first_day: period.first_day,
                last_day: period.last_day,
                line,
                stamp: rollup::stamp(&inside),
                generated_at: lokalbot_core::time::now_seconds(),
            },
            root,
        )?;
        outcome.written.push(period.key);
    }
    Ok(outcome)
}

/// The most new lines one night may write.
pub const fn nightly_limit(showable: bool) -> usize {
    if showable { MAXIMUM_PER_NIGHT } else { 0 }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_core::time::parse_iso;

    #[test]
    fn the_line_loses_labels_quotes_and_reasoning() {
        assert_eq!(
            line_from("<think>hm</think>\n\nSummary: \"Shipped the beta.\"\nExtra").as_deref(),
            Some("Shipped the beta.")
        );
        assert_eq!(line_from("  \n "), None);
    }

    #[test]
    fn the_prompt_names_the_period_and_its_days() {
        let period = rollup::week_containing(day_from_key("2026-10-07").unwrap());
        let review = DayReview {
            day: "2026-10-07".into(),
            generated_at: parse_iso("2026-10-08T04:00:00Z").unwrap(),
            narrative: "One. Two.".into(),
        };
        let text = prompt(&period, &[&review]);
        assert!(text.starts_with("Daily reviews for the week (Week of Oct 5):"));
        assert!(text.contains("Wed Oct 7: One. Two."));
        assert!(text.ends_with("Write the one-line summary of this week."));
    }

    #[test]
    fn stale_lines_go_and_nothing_is_written_without_permission_to_show_them() {
        let dir = tempfile::tempdir().unwrap();
        let library =
            lokalbot_core::Library::open(lokalbot_core::LibraryPaths::new(dir.path())).unwrap();
        let root = dir.path();
        let old = Rollup {
            kind: Kind::Week,
            key: "2026-W01".into(),
            first_day: "2026-01-01".into(),
            last_day: "2026-01-04".into(),
            line: "Old".into(),
            stamp: "stale".into(),
            generated_at: parse_iso("2026-01-05T04:00:00Z").unwrap(),
        };
        rollup::write(&old, root).unwrap();
        let outcome = run(
            &library,
            parse_iso("2026-10-20T04:00:00Z").unwrap(),
            nightly_limit(false),
            &|| panic!("no model call when nothing may be written"),
        )
        .unwrap();
        assert_eq!(outcome.removed, vec!["2026-W01".to_string()]);
        assert!(rollup::rollups(root).is_empty());
    }
}
