#[cfg(target_os = "linux")]
mod eds;
pub mod feed;
pub mod ics;

use lokalbot_core::calendar::CalendarEvent;

pub use feed::{LinkRefused, normalize as normalize_link, redacted as redacted_link};
pub use ics::ParseOptions;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CalendarSources {
    pub links: Vec<String>,
    pub evolution: bool,
}

impl CalendarSources {
    pub fn is_empty(&self) -> bool {
        self.links.is_empty() && !self.evolution_available()
    }

    fn evolution_available(&self) -> bool {
        self.evolution && cfg!(target_os = "linux")
    }
}

#[derive(Clone, Debug, Default)]
pub struct FetchReport {
    pub events: Vec<CalendarEvent>,
    pub sources_read: usize,
    pub problems: Vec<String>,
}

pub fn fetch(sources: &CalendarSources, options: &ParseOptions) -> FetchReport {
    let mut report = FetchReport::default();
    for link in &sources.links {
        match feed::fetch(link, options) {
            Ok(events) => {
                report.sources_read += 1;
                report.events.extend(events);
            }
            Err(err) => {
                let problem = format!("{}: {err:#}", feed::redacted(link));
                log::warn!("calendar: {problem}");
                report.problems.push(problem);
            }
        }
    }
    #[cfg(target_os = "linux")]
    if sources.evolution {
        match eds::fetch(options) {
            Ok(Some(events)) => {
                report.sources_read += 1;
                report.events.extend(events);
            }
            Ok(None) => log::debug!("calendar: Evolution Data Server is not installed"),
            Err(err) => {
                let problem = format!("Evolution Data Server: {err:#}");
                log::warn!("calendar: {problem}");
                report.problems.push(problem);
            }
        }
    }
    report
        .events
        .sort_by(|a, b| a.start.cmp(&b.start).then(a.end.cmp(&b.end)));
    let mut seen = std::collections::HashSet::new();
    report
        .events
        .retain(|event| seen.insert(event.external_id.clone()));
    report
}
