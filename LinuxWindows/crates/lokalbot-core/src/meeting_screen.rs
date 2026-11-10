//! What was on screen while a meeting recorded, aligned to its audio
//! (`MeetingScreenContext.swift`). Built only from retained screen rows
//! (titles, document names, URLs and times); pixels and captured text are not
//! read here. Captures expire with screen retention, so this can shrink.

use std::collections::{HashMap, HashSet};

use chrono::{DateTime, Duration, Utc};
use rusqlite::params;

use crate::calendar::is_meeting_url;
use crate::library::Library;
use crate::model::Meeting;
use crate::timeline::strip_browser_chrome;

/// A long call can touch dozens of windows; these are kept.
pub const MAXIMUM_MATERIALS: usize = 12;

const CALL_STATUS_MARKERS: [&str; 3] = [
    "camera recording",
    "microphone recording",
    "camera and microphone recording",
];
const BROWSER_APPS: [&str; 11] = [
    "safari",
    "google chrome",
    "chrome",
    "arc",
    "firefox",
    "microsoft edge",
    "brave browser",
    "opera",
    "vivaldi",
    "orion",
    "dia",
];
const LINUX_AND_WINDOWS_BROWSERS: [&str; 6] = [
    "google-chrome",
    "chromium",
    "chromium-browser",
    "microsoft-edge",
    "msedge",
    "brave",
];
/// Pages chosen by their query get no link: stored addresses drop it.
const QUERY_ROUTED_HOSTS: [&str; 6] = [
    "mail.google.com",
    "google.com",
    "youtube.com",
    "m.youtube.com",
    "bing.com",
    "duckduckgo.com",
];

fn is_browser(app: &str) -> bool {
    let app = app.to_lowercase();
    BROWSER_APPS.contains(&app.as_str()) || LINUX_AND_WINDOWS_BROWSERS.contains(&app.as_str())
}

/// One retained `screenshots` row.
#[derive(Clone, Debug, PartialEq)]
pub struct ScreenRow {
    pub id: i64,
    pub ts: DateTime<Utc>,
    pub path: String,
    pub app: String,
    pub window_title: String,
    pub source_url: String,
    pub document_name: String,
}

/// One stretch of the same app and window, as it appeared on screen.
#[derive(Clone, Debug, PartialEq)]
pub struct Moment {
    pub snapshot_id: i64,
    pub captured_at: DateTime<Utc>,
    /// Seconds from the start of the meeting's audio.
    pub offset: f64,
    /// When the next stretch began, or the end of the recording.
    pub end_offset: f64,
    pub app: String,
    pub title: String,
    /// The site named in a browser tab's title, else a web page's host.
    pub site: Option<String>,
    pub source_url: String,
    pub has_pixels: bool,
    /// The call itself (its app window or conference tab) was in front.
    pub is_call: bool,
}

/// A distinct document, page or window referenced during the call, in order
/// of first appearance.
#[derive(Clone, Debug, PartialEq)]
pub struct Material {
    pub id: String,
    pub title: String,
    pub app: String,
    pub site: Option<String>,
    pub first_offset: f64,
    pub first_snapshot_id: i64,
    /// Approximate time in front, from capture to the next change.
    pub seconds_on_screen: f64,
    /// A web address that reopens this page, when the stored one can.
    pub page_url: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct MeetingScreenContext {
    /// Every stretch in order, including the call's own window.
    pub moments: Vec<Moment>,
    pub materials: Vec<Material>,
}

impl MeetingScreenContext {
    pub fn is_empty(&self) -> bool {
        self.materials.is_empty()
    }

    /// The stretch in front at an audio position.
    pub fn moment(&self, offset: f64) -> Option<&Moment> {
        let first = self.moments.first()?;
        if offset < first.offset - 1.0 {
            return None;
        }
        let index = self
            .moments
            .partition_point(|moment| moment.offset <= offset)
            .saturating_sub(1);
        self.moments.get(index)
    }

    /// Window and document titles for use as secondary context in notes,
    /// never the captured text itself.
    pub fn material_titles(&self) -> Vec<String> {
        self.materials
            .iter()
            .map(|material| {
                format!(
                    "{} ({})",
                    material.title,
                    material.site.as_deref().unwrap_or(&material.app)
                )
            })
            .collect()
    }

    pub fn build(meeting: &Meeting, screenshots: &[ScreenRow]) -> Self {
        let start = meeting.started_at;
        let end = meeting
            .ended_at
            .unwrap_or_else(|| meeting.started_plus(meeting.recorded_duration.unwrap_or(0.0)));
        let playable = meeting
            .recorded_duration
            .unwrap_or_else(|| seconds_between(start, end))
            .max(0.0);
        let window_start = start - Duration::seconds(5);
        let window_end = end + Duration::seconds(5);
        let mut sorted: Vec<&ScreenRow> = screenshots.iter().collect();
        sorted.sort_by_key(|shot| (shot.ts, shot.id));
        let mut stretches: Vec<(&ScreenRow, f64, Page, bool)> = Vec::new();
        for shot in sorted {
            if shot.ts < window_start || shot.ts > window_end {
                continue;
            }
            let page = page_for(shot);
            if page.title.is_empty() {
                continue;
            }
            let is_call = is_call_window(shot, meeting);
            if stretches
                .last()
                .is_some_and(|(last, _, last_page, last_call)| {
                    last.app == shot.app && *last_page == page && *last_call == is_call
                })
            {
                continue;
            }
            let offset = seconds_between(start, shot.ts).max(0.0).min(playable);
            stretches.push((shot, offset, page, is_call));
        }

        let mut moments = Vec::with_capacity(stretches.len());
        for (index, (shot, offset, page, is_call)) in stretches.iter().enumerate() {
            let next = stretches.get(index + 1).map_or(playable, |s| s.1);
            moments.push(Moment {
                snapshot_id: shot.id,
                captured_at: shot.ts,
                offset: *offset,
                end_offset: next.max(*offset),
                app: shot.app.clone(),
                title: page.title.clone(),
                site: page.site.clone().or_else(|| web_host(&shot.source_url)),
                source_url: shot.source_url.clone(),
                has_pixels: !shot.path.is_empty(),
                is_call: *is_call,
            });
        }

        let mut materials: Vec<Material> = Vec::new();
        let mut index_by_key: HashMap<String, usize> = HashMap::new();
        for moment in moments.iter().filter(|m| !m.is_call && !is_blank_page(m)) {
            let key = format!(
                "{}|{}",
                moment.app.to_lowercase(),
                moment.title.to_lowercase()
            );
            let seconds = moment.end_offset - moment.offset;
            if let Some(index) = index_by_key.get(&key) {
                let existing = &mut materials[*index];
                existing.seconds_on_screen += seconds;
                if existing.page_url.is_none() {
                    existing.page_url = reopenable_url(&moment.source_url);
                }
                continue;
            }
            index_by_key.insert(key.clone(), materials.len());
            materials.push(Material {
                id: key,
                title: moment.title.clone(),
                app: moment.app.clone(),
                site: moment.site.clone(),
                first_offset: moment.offset,
                first_snapshot_id: moment.snapshot_id,
                seconds_on_screen: seconds,
                page_url: reopenable_url(&moment.source_url),
            });
        }
        if materials.len() > MAXIMUM_MATERIALS {
            let mut by_time: Vec<&Material> = materials.iter().collect();
            by_time.sort_by(|a, b| b.seconds_on_screen.total_cmp(&a.seconds_on_screen));
            let kept: HashSet<String> = by_time
                .into_iter()
                .take(MAXIMUM_MATERIALS)
                .map(|m| m.id.clone())
                .collect();
            materials.retain(|m| kept.contains(&m.id));
        }
        Self { moments, materials }
    }
}

fn seconds_between(from: DateTime<Utc>, to: DateTime<Utc>) -> f64 {
    (to - from).num_milliseconds() as f64 / 1000.0
}

#[derive(Clone, Debug, PartialEq)]
struct Page {
    title: String,
    site: Option<String>,
}

fn page_for(shot: &ScreenRow) -> Page {
    let browser = is_browser(&shot.app);
    // A browser's document name is the last piece of the page's URL, not
    // something the user would recognize.
    let document = shot.document_name.trim();
    if !browser && !document.is_empty() {
        return Page {
            title: document.to_string(),
            site: None,
        };
    }
    let title = strip_browser_chrome(&shot.window_title);
    let title = title.trim();
    if title.is_empty() {
        return Page {
            title: shot.app.clone(),
            site: None,
        };
    }
    if browser {
        splitting_site(title)
    } else {
        Page {
            title: title.to_string(),
            site: None,
        }
    }
}

/// "Weekly sync - you@example.com - Gmail" reads as the page "Weekly sync" on
/// "Gmail". Account addresses and unread counts are dropped so revisits of
/// one page group together.
fn splitting_site(title: &str) -> Page {
    let last = [" - ", " — ", " – ", " | "]
        .iter()
        .filter_map(|separator| title.rfind(separator).map(|at| (*separator, at)))
        .max_by_key(|(_, at)| *at);
    let mut page = title.to_string();
    let mut site = None;
    if let Some((separator, at)) = last {
        let candidate = title[at + separator.len()..].trim();
        let count = candidate.chars().count();
        if (1..=32).contains(&count)
            && candidate.split(' ').filter(|w| !w.is_empty()).count() <= 4
            && !candidate.contains('@')
        {
            site = Some(candidate.to_string());
            page = title[..at].to_string();
        }
        page = page
            .split(separator)
            .filter(|segment| !is_account_address(segment))
            .collect::<Vec<_>>()
            .join(separator);
    }
    let page = strip_unread_count(&page);
    if page.is_empty() {
        return Page {
            title: title.to_string(),
            site: None,
        };
    }
    Page { title: page, site }
}

/// `^\(\d+\)\s+|\s+\(\d+\)$`.
fn strip_unread_count(page: &str) -> String {
    let is_count = |text: &str| {
        text.len() > 2
            && text.starts_with('(')
            && text.ends_with(')')
            && text[1..text.len() - 1].chars().all(|c| c.is_ascii_digit())
    };
    let mut page = page.trim();
    if let Some((first, rest)) = page.split_once(char::is_whitespace)
        && is_count(first)
    {
        page = rest;
    }
    if let Some((rest, last)) = page.rsplit_once(char::is_whitespace)
        && is_count(last)
    {
        page = rest;
    }
    page.trim().to_string()
}

fn is_account_address(segment: &str) -> bool {
    let trimmed = segment.trim();
    trimmed.contains('@') && !trimmed.contains(' ') && trimmed.contains('.')
}

/// The host and the path of an http(s) address.
fn host_and_path(source_url: &str) -> Option<(String, String)> {
    let (scheme, rest) = source_url.split_once("://")?;
    if !scheme.eq_ignore_ascii_case("https") && !scheme.eq_ignore_ascii_case("http") {
        return None;
    }
    let rest = rest.split(['?', '#']).next().unwrap_or(rest);
    let (authority, path) = match rest.find('/') {
        Some(at) => rest.split_at(at),
        None => (rest, ""),
    };
    let authority = authority.rsplit('@').next().unwrap_or(authority);
    let host = authority.split(':').next().unwrap_or(authority);
    (!host.is_empty()).then(|| (host.to_string(), path.to_string()))
}

fn web_host(source_url: &str) -> Option<String> {
    let (host, _) = host_and_path(source_url)?;
    Some(host.strip_prefix("www.").unwrap_or(&host).to_string())
}

/// Stored addresses drop their query and fragment, so a page chosen by either
/// gets no link rather than one that opens the wrong page.
fn reopenable_url(source_url: &str) -> Option<String> {
    let host = web_host(source_url)?.to_lowercase();
    if QUERY_ROUTED_HOSTS.contains(&host.as_str()) {
        return None;
    }
    let (_, path) = host_and_path(source_url)?;
    let last = path
        .split('/')
        .rfind(|segment| !segment.is_empty())?
        .to_lowercase();
    if ["search", "results", "watch"].contains(&last.as_str()) {
        return None;
    }
    Some(source_url.to_string())
}

/// The call itself is not material the user referenced.
fn is_call_window(shot: &ScreenRow, meeting: &Meeting) -> bool {
    if !shot.source_url.is_empty() && is_meeting_url(&shot.source_url) {
        return true;
    }
    if is_browser(&shot.app) {
        // Captures can lack the tab's URL. A tab using the camera or
        // microphone during the meeting is the call, and so is a Meet tab.
        let lower = shot.window_title.to_lowercase();
        let segments: Vec<&str> = lower.split(" - ").collect();
        if segments.iter().any(|s| CALL_STATUS_MARKERS.contains(s)) {
            return true;
        }
        if segments.first() == Some(&"meet") || shot.window_title.starts_with("Meet – ") {
            return true;
        }
        if let Some(code) = meeting.meeting_url.as_deref().and_then(meeting_code)
            && shot.document_name.starts_with(&code)
        {
            return true;
        }
        return false;
    }
    let meeting_app = meeting.app_name.trim();
    if meeting_app.is_empty() || !shot.app.eq_ignore_ascii_case(meeting_app) {
        return false;
    }
    shot.source_url.is_empty() && shot.document_name.is_empty()
}

fn meeting_code(url: &str) -> Option<String> {
    let (_, path) = host_and_path(url)?;
    let code = path.split('/').rfind(|s| !s.is_empty())?;
    (code.chars().count() >= 6).then(|| code.to_string())
}

fn is_blank_page(moment: &Moment) -> bool {
    ["new tab", "start page", "favorites"].contains(&moment.title.to_lowercase().as_str())
        && is_browser(&moment.app)
}

impl Library {
    /// This meeting's rows and the unlinked ones around it
    /// (`ActivityStore.screenshots(forMeeting:from:to:)`).
    pub fn meeting_screenshots(
        &self,
        meeting: &Meeting,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
    ) -> anyhow::Result<Vec<ScreenRow>> {
        if to <= from {
            return Ok(Vec::new());
        }
        let id = crate::ids::uuid_upper(&meeting.id);
        self.with_db(|db| {
            let mut statement = db.prepare(
                "SELECT id, ts, path, app, window_title, source_url, document_name FROM screenshots \
                 WHERE ts >= ?2 AND ts <= ?3 AND (meeting_id = ?1 OR meeting_id = '') \
                 ORDER BY ts, id",
            )?;
            let rows = statement.query_map(
                params![
                    id,
                    from.timestamp_millis() as f64 / 1000.0,
                    to.timestamp_millis() as f64 / 1000.0
                ],
                |row| {
                    let ts: f64 = row.get(1)?;
                    Ok(ScreenRow {
                        id: row.get(0)?,
                        ts: DateTime::from_timestamp_millis((ts * 1000.0) as i64)
                            .unwrap_or_default(),
                        path: row.get(2)?,
                        app: row.get(3)?,
                        window_title: row.get(4)?,
                        source_url: row.get(5)?,
                        document_name: row.get(6)?,
                    })
                },
            )?;
            Ok(rows.filter_map(Result::ok).collect())
        })
    }

    /// The on-screen context of a meeting. An imported file was not played on
    /// this computer, so its time on the clock means nothing here.
    pub fn meeting_screen_context(&self, meeting: &Meeting) -> MeetingScreenContext {
        if meeting.is_imported() {
            return MeetingScreenContext::default();
        }
        let fallback = meeting.started_plus(meeting.recorded_duration.unwrap_or(60.0).max(60.0));
        let end = meeting
            .ended_at
            .filter(|end| *end > meeting.started_at)
            .unwrap_or(fallback);
        match self.meeting_screenshots(
            meeting,
            meeting.started_at - Duration::seconds(5),
            end + Duration::seconds(5),
        ) {
            Ok(rows) => MeetingScreenContext::build(meeting, &rows),
            Err(err) => {
                log::warn!("meeting screenshot query failed: {err:#}");
                MeetingScreenContext::default()
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shot(id: i64, seconds: i64, app: &str, title: &str, url: &str) -> ScreenRow {
        ScreenRow {
            id,
            ts: meeting().started_at + Duration::seconds(seconds),
            path: String::new(),
            app: app.into(),
            window_title: title.into(),
            source_url: url.into(),
            document_name: String::new(),
        }
    }

    fn meeting() -> Meeting {
        let mut meeting: Meeting = serde_json::from_value(serde_json::json!({
            "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
            "title": "Call",
            "appName": "Zoom",
            "startedAt": "2026-10-15T10:00:00Z",
            "relativePath": "meetings/x",
        }))
        .unwrap();
        meeting.recorded_duration = Some(600.0);
        meeting.ended_at = Some(meeting.started_at + Duration::seconds(600));
        meeting
    }

    /// A damaged `meta.json` can carry a length no calendar date can hold.
    #[test]
    fn an_impossible_recorded_length_does_not_panic() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(crate::paths::LibraryPaths::new(dir.path())).unwrap();
        for length in [1e13, -1e13, 1e300, -1e300, f64::NAN] {
            let mut meeting = meeting();
            meeting.ended_at = None;
            meeting.recorded_duration = Some(length);
            assert_eq!(meeting.started_plus(length), meeting.started_at);
            assert_eq!(
                crate::timeline::meeting_end(&meeting, meeting.started_at),
                meeting.started_at
            );
            let context = MeetingScreenContext::build(&meeting, &[shot(1, 0, "Zoom", "Zoom", "")]);
            assert!(context.materials.is_empty());
            assert_eq!(
                library.meeting_screen_context(&meeting),
                MeetingScreenContext::default()
            );
        }
        // An ordinary length still counts from the start.
        let meeting = meeting();
        assert_eq!(
            meeting.started_plus(600.0),
            meeting.started_at + Duration::seconds(600)
        );
    }

    #[test]
    fn material_is_what_was_shown_besides_the_call() {
        let rows = [
            shot(1, 0, "Zoom", "Zoom Meeting", ""),
            shot(
                2,
                60,
                "Google Chrome",
                "Q3 plan - you@example.com - Google Docs",
                "https://docs.google.com/document/d/abc",
            ),
            shot(
                3,
                120,
                "Google Chrome",
                "Q3 plan - you@example.com - Google Docs",
                "https://docs.google.com/document/d/abc",
            ),
            shot(4, 180, "Google Chrome", "Meet – abc-defg-hij", ""),
            shot(5, 240, "Zoom", "Zoom Meeting", ""),
            shot(
                6,
                300,
                "Google Chrome",
                "Q3 plan - you@example.com - Google Docs",
                "https://docs.google.com/document/d/abc",
            ),
            shot(7, 400, "Google Chrome", "New Tab", ""),
        ];
        let context = MeetingScreenContext::build(&meeting(), &rows);
        assert_eq!(context.materials.len(), 1, "{:?}", context.materials);
        let material = &context.materials[0];
        assert_eq!(material.title, "Q3 plan");
        assert_eq!(material.site.as_deref(), Some("Google Docs"));
        assert_eq!(material.first_offset, 60.0);
        // 60→180 and 300→400; revisits add up and the repeat row was one stretch.
        assert_eq!(material.seconds_on_screen, 220.0);
        assert_eq!(context.material_titles(), vec!["Q3 plan (Google Docs)"]);
        assert_eq!(context.moment(130.0).unwrap().snapshot_id, 2);
        assert!(context.moment(200.0).unwrap().is_call);
    }

    #[test]
    fn links_only_reopen_the_page_they_name() {
        assert!(reopenable_url("https://docs.google.com/document/d/abc").is_some());
        assert!(reopenable_url("https://mail.google.com/mail/u/0").is_none());
        assert!(reopenable_url("https://www.youtube.com/watch").is_none());
        assert!(reopenable_url("https://example.com/search").is_none());
        assert!(reopenable_url("file:///tmp/a.pdf").is_none());
    }

    #[test]
    fn a_long_call_keeps_the_windows_that_stayed_longest() {
        let mut rows = Vec::new();
        for i in 0..20 {
            rows.push(shot(i, i * 10, "Editor", &format!("file{i}.rs"), ""));
        }
        rows.push(shot(100, 200, "Editor", "long.rs", ""));
        let context = MeetingScreenContext::build(&meeting(), &rows);
        assert_eq!(context.materials.len(), MAXIMUM_MATERIALS);
        assert!(context.materials.iter().any(|m| m.title == "long.rs"));
        assert!(
            context
                .materials
                .windows(2)
                .all(|w| w[0].first_offset <= w[1].first_offset)
        );
    }

    #[test]
    fn splits_site_names_and_unread_counts() {
        let page = splitting_site("(3) Inbox - you@example.com - Gmail");
        assert_eq!(page.title, "Inbox");
        assert_eq!(page.site.as_deref(), Some("Gmail"));
        assert_eq!(splitting_site("Plain title").title, "Plain title");
    }
}
