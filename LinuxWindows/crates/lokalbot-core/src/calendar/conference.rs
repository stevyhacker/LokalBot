use std::sync::LazyLock;

use regex::Regex;

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

const TELEMOST: &str = "telemost.yandex.ru";
const MTS_LINK: &str = "my.mts-link.ru";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MeetingService {
    GoogleMeet,
    Telemost,
    MtsLink,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MeetingRoom {
    pub service: MeetingService,
    pub url: String,
}

pub fn meeting_room(raw: &str) -> Option<MeetingRoom> {
    let rest = raw
        .get(..8)
        .filter(|scheme| scheme.eq_ignore_ascii_case("https://"))
        .map(|_| &raw[8..])?;
    let authority_end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let (authority, tail) = rest.split_at(authority_end);
    let host = authority.strip_suffix(":443").unwrap_or(authority);
    let path = tail.split(['?', '#']).next().unwrap_or("");
    let (service, url) = if host.eq_ignore_ascii_case("meet.google.com") {
        let code = path
            .strip_prefix("/meet/")
            .or_else(|| path.strip_prefix('/'))?;
        let parts: Vec<&str> = code.split('-').collect();
        if parts.len() != 3
            || ![3, 4, 3].iter().zip(&parts).all(|(length, part)| {
                part.len() == *length && part.bytes().all(|b| b.is_ascii_lowercase())
            })
        {
            return None;
        }
        (
            MeetingService::GoogleMeet,
            format!("https://meet.google.com/{code}"),
        )
    } else if host.eq_ignore_ascii_case(TELEMOST) {
        let code = path.strip_prefix("/j/")?;
        let code = code.strip_suffix('/').unwrap_or(code);
        if !numeric_room_component(code) {
            return None;
        }
        (
            MeetingService::Telemost,
            format!("https://{TELEMOST}/j/{code}"),
        )
    } else if host.eq_ignore_ascii_case(MTS_LINK) {
        let path = path
            .strip_prefix("/j/")
            .or_else(|| path.strip_prefix('/'))?;
        let path = path.strip_suffix('/').unwrap_or(path);
        let mut segments = path.split('/');
        let account = segments
            .next()
            .filter(|value| numeric_room_component(value))?;
        let event = segments
            .next()
            .filter(|value| numeric_room_component(value))?;
        match segments.next() {
            None => {}
            Some("stream-new")
                if segments.next().is_some_and(numeric_room_component)
                    && segments.next().is_none() => {}
            _ => return None,
        }
        (
            MeetingService::MtsLink,
            format!("https://{MTS_LINK}/j/{account}/{event}"),
        )
    } else {
        return None;
    };
    Some(MeetingRoom { service, url })
}

fn numeric_room_component(value: &str) -> bool {
    !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit())
}

static SCHEME_LINK: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"(?i)https?://[^\s<>"'`\x{3000}-\x{303F}\x{FF00}-\x{FFEF}]+"#)
        .expect("valid regex")
});

static BARE_LINK: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"(?i)(?:^|[^\w@./:-])((?:[a-z0-9-]+\.)+[a-z]{2,}/[^\s<>"'`\x{3000}-\x{303F}\x{FF00}-\x{FFEF}]*)"#)
        .expect("valid regex")
});

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

pub fn is_meeting_url(url: &str) -> bool {
    let lower = url.trim().to_ascii_lowercase();
    if !(lower.starts_with("https://") || lower.starts_with("http://")) {
        return false;
    }
    let Some(host) = url_host(url) else {
        return false;
    };
    if matches!(host.as_str(), TELEMOST | MTS_LINK) {
        return meeting_room(url.trim()).is_some();
    }
    CONFERENCE_HOSTS
        .iter()
        .any(|known| host == *known || host.ends_with(&format!(".{known}")))
}

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

fn trim_trailing(link: &str) -> &str {
    link.trim_end_matches(['.', ',', ';', ':', '!', '?', ')', ']', '}', '>', '*'])
}
