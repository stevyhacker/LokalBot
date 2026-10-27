//! Conferencing links in free text (`ConferenceURLDetector.swift`): they mark
//! an event as an online meeting and let a browser call count as calendar
//! backed when its window title says nothing.

use std::sync::LazyLock;

use regex::Regex;

/// Known conferencing hosts. Subdomains match too.
pub const CONFERENCE_HOSTS: [&str; 18] = [
    "meet.google.com",
    "zoom.us",
    "zoom.com",
    "teams.microsoft.com",
    "teams.live.com",
    "webex.com",
    "whereby.com",
    "meet.jit.si",
    "jit.si",
    "bluejeans.com",
    "gotomeeting.com",
    "chime.aws",
    "around.co",
    "meeting.tencent.com",
    "voovmeeting.com",
    "vc.feishu.cn",
    "vc.larksuite.com",
    "meeting.dingtalk.com",
];

/// `http(s)` links, stopping at whitespace, angle brackets, quotes and CJK
/// punctuation (invitations write "会议：https://…" without a space).
static SCHEME_LINK: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"(?i)https?://[^\s<>"'`\x{3000}-\x{303F}\x{FF00}-\x{FFEF}]+"#)
        .expect("valid regex")
});

/// A bare `host/path` link without a scheme ("zoom.us/j/123").
static BARE_LINK: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"(?i)(?:^|[^\w@./:-])((?:[a-z0-9-]+\.)+[a-z]{2,}/[^\s<>"'`\x{3000}-\x{303F}\x{FF00}-\x{FFEF}]*)"#)
        .expect("valid regex")
});

/// The first conferencing link in `text`, or `None`.
pub fn first_meeting_url(text: Option<&str>) -> Option<String> {
    let text = text.filter(|t| !t.is_empty())?;
    let mut found: Vec<(usize, String)> = SCHEME_LINK
        .find_iter(text)
        .map(|m| (m.start(), trim_trailing(m.as_str()).to_string()))
        .collect();
    found.extend(BARE_LINK.captures_iter(text).filter_map(|c| {
        let m = c.get(1)?;
        Some((m.start(), format!("https://{}", trim_trailing(m.as_str()))))
    }));
    found.sort_by_key(|(at, _)| *at);
    found
        .into_iter()
        .map(|(_, url)| url)
        .find(|url| is_meeting_url(url))
}

/// Whether `url` is an `http(s)` link whose host is (a subdomain of) a known
/// conferencing host.
pub fn is_meeting_url(url: &str) -> bool {
    let lower = url.trim().to_ascii_lowercase();
    if !(lower.starts_with("https://") || lower.starts_with("http://")) {
        return false;
    }
    let Some(host) = url_host(url) else {
        return false;
    };
    CONFERENCE_HOSTS
        .iter()
        .any(|known| host == *known || host.ends_with(&format!(".{known}")))
}

/// The lowercased host of a URL (`scheme://user@host:port/path`), if any.
pub fn url_host(url: &str) -> Option<String> {
    let trimmed = url.trim();
    let rest = trimmed.split_once("://").map_or(trimmed, |(_, rest)| rest);
    let authority = rest.split(['/', '?', '#']).next()?;
    let host_port = authority.rsplit('@').next()?;
    let host = if let Some(bracketed) = host_port.strip_prefix('[') {
        bracketed.split(']').next()?
    } else {
        host_port.split(':').next()?
    };
    let host = host.trim_end_matches('.').to_ascii_lowercase();
    (!host.is_empty()).then_some(host)
}

/// Sentence punctuation after a link is not part of it.
fn trim_trailing(link: &str) -> &str {
    link.trim_end_matches(['.', ',', ';', ':', '!', '?', ')', ']', '}', '>', '*'])
}
