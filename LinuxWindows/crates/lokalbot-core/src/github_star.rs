//! The one-time request on Today to star LokalBot's repository
//! (`GitHubStarPrompt.swift`). Everything here stays on this computer:
//! LokalBot keeps only whether a meeting summary has finished, which calendar
//! days it was used, and whether the request was answered. It sends nothing
//! and never learns whether anyone starred.

use std::path::Path;

/// Distinct days of use that make the request eligible without a summary.
pub const ACTIVE_DAYS_BEFORE_ASKING: usize = 7;

/// Written at the root of every demo library, including the screenshot ones.
pub const DEMO_LIBRARY_MARKER: &str = ".lokalbot-demo-library";

/// After the first completed meeting summary or `ACTIVE_DAYS_BEFORE_ASKING`
/// distinct days of use, whichever comes first, until it is answered.
pub fn should_show(
    dismissed: bool,
    summary_completed: bool,
    active_days: &[String],
    seeded_demo_library: bool,
) -> bool {
    !seeded_demo_library
        && !dismissed
        && (summary_completed || active_days.len() >= ACTIVE_DAYS_BEFORE_ASKING)
}

/// Whether `day_key` still needs counting; each day counts once, and only
/// until there are enough to ask.
pub fn should_record_day(day_key: &str, active_days: &[String]) -> bool {
    !active_days.iter().any(|day| day == day_key) && active_days.len() < ACTIVE_DAYS_BEFORE_ASKING
}

pub fn is_seeded_demo_library(root: &Path) -> bool {
    root.join(DEMO_LIBRARY_MARKER).exists()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn days(n: usize) -> Vec<String> {
        (0..n).map(|i| format!("2026-10-{:02}", i + 1)).collect()
    }

    #[test]
    fn asks_after_a_summary_or_seven_days() {
        assert!(!should_show(false, false, &days(6), false));
        assert!(should_show(false, false, &days(7), false));
        assert!(should_show(false, true, &[], false));
    }

    #[test]
    fn either_answer_retires_it_and_demo_libraries_never_ask() {
        assert!(!should_show(true, true, &days(7), false));
        assert!(!should_show(false, true, &days(7), true));
    }

    #[test]
    fn days_count_once_and_stop_at_the_limit() {
        assert!(should_record_day("2026-10-20", &days(3)));
        assert!(!should_record_day("2026-10-02", &days(3)));
        assert!(!should_record_day("2026-10-20", &days(7)));
    }

    #[test]
    fn the_marker_identifies_a_demo_library() {
        let dir = tempfile::tempdir().unwrap();
        assert!(!is_seeded_demo_library(dir.path()));
        std::fs::write(dir.path().join(DEMO_LIBRARY_MARKER), "").unwrap();
        assert!(is_seeded_demo_library(dir.path()));
    }
}
