//! Private calendar links: an iCalendar feed (Google's "secret address in
//! iCal format", Outlook's published calendar, iCloud's `webcal://` link) or
//! a CalDAV collection. Credentials can ride in the link
//! (`https://user:app-password@host/…`); the whole link is a secret, so only
//! [`redacted`] ever reaches a log or the screen.

use std::io::Read as _;
use std::time::Duration;

use anyhow::{Context as _, Result, bail};
use chrono::{DateTime, Utc};
use lokalbot_core::calendar::{CalendarEvent, provider};

use super::ics::{self, ParseOptions};

/// Feeds larger than this are refused (a full Google history is a few MB).
const MAX_BYTES: u64 = 64 * 1024 * 1024;
const TIMEOUT: Duration = Duration::from_secs(45);

/// `scheme://host/…`: what may be shown or logged of a calendar link.
pub fn redacted(link: &str) -> String {
    let Ok(normalized) = normalize(link) else {
        return "a calendar link".to_string();
    };
    let scheme = normalized
        .split_once("://")
        .map_or("https", |(scheme, _)| scheme);
    match lokalbot_core::calendar::url_host(&normalized) {
        Some(host) => format!("{scheme}://{host}/…"),
        None => "a calendar link".to_string(),
    }
}

/// `webcal(s)://` becomes `https://`; anything but `http(s)` is refused.
pub fn normalize(link: &str) -> Result<String> {
    let trimmed = link.trim();
    let lower = trimmed.to_ascii_lowercase();
    for prefix in ["webcals://", "webcal://"] {
        if lower.starts_with(prefix) {
            return Ok(format!("https://{}", &trimmed[prefix.len()..]));
        }
    }
    if lower.starts_with("https://") || lower.starts_with("http://") {
        return Ok(trimmed.to_string());
    }
    bail!("calendar links start with https:// or webcal://")
}

/// Events from one link overlapping `[from, to)`. A link that answers with
/// iCalendar is a feed; otherwise it is asked as a CalDAV collection.
pub fn fetch(link: &str, options: &ParseOptions) -> Result<Vec<CalendarEvent>> {
    let url = normalize(link)?;
    let (url, authorization) = split_credentials(&url);
    let agent = agent();
    let mut request = agent.get(&url).header("Accept", "text/calendar, */*;q=0.5");
    if let Some(authorization) = &authorization {
        request = request.header("Authorization", authorization);
    }
    let response = request
        .call()
        .map_err(|err| anyhow::anyhow!("{} did not answer ({})", redacted(&url), describe(&err)))?;
    let status = response.status().as_u16();
    if status == 401 || status == 403 {
        bail!("{} refused the link (HTTP {status})", redacted(&url));
    }
    let body = if (200..300).contains(&status) {
        read_body(response)?
    } else {
        String::new()
    };
    if looks_like_icalendar(&body) {
        return ics::parse_events(
            &body,
            &ParseOptions {
                provider: provider::ICS.into(),
                ..options.clone()
            },
        );
    }
    caldav_query(&agent, &url, authorization.as_deref(), options)
        .with_context(|| format!("{} is not a calendar feed", redacted(&url)))
}

/// CalDAV `calendar-query` for events overlapping the window (RFC 4791 §7.8).
/// The server returns whole series; they are expanded here like a feed.
fn caldav_query(
    agent: &ureq::Agent,
    url: &str,
    authorization: Option<&str>,
    options: &ParseOptions,
) -> Result<Vec<CalendarEvent>> {
    let body = format!(
        r#"<?xml version="1.0" encoding="utf-8"?>
<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop><c:calendar-data/></d:prop>
  <c:filter>
    <c:comp-filter name="VCALENDAR">
      <c:comp-filter name="VEVENT">
        <c:time-range start="{}" end="{}"/>
      </c:comp-filter>
    </c:comp-filter>
  </c:filter>
</c:calendar-query>"#,
        caldav_time(options.from),
        caldav_time(options.to)
    );
    let mut request = ureq::http::Request::builder()
        .method("REPORT")
        .uri(url)
        .header("Depth", "1")
        .header("Content-Type", "application/xml; charset=utf-8");
    if let Some(authorization) = authorization {
        request = request.header("Authorization", authorization);
    }
    let request = request
        .body(body)
        .map_err(|_| anyhow::anyhow!("the link is not a valid address"))?;
    let response = agent
        .run(request)
        .map_err(|err| anyhow::anyhow!("the CalDAV request failed ({})", describe(&err)))?;
    let status = response.status().as_u16();
    if status != 207 {
        bail!("the server answered HTTP {status}");
    }
    let xml = read_body(response)?;
    let documents = calendar_data(&xml)?;
    let caldav = ParseOptions {
        provider: provider::CALDAV.into(),
        ..options.clone()
    };
    let mut events = Vec::new();
    for document in documents {
        match ics::parse_events(&document, &caldav) {
            Ok(found) => events.extend(found),
            Err(err) => log::debug!("skipping an unreadable CalDAV object: {err:#}"),
        }
    }
    events.sort_by_key(|a| a.start);
    events.dedup_by(|a, b| a.external_id == b.external_id);
    Ok(events)
}

/// Every `calendar-data` text in a multistatus reply.
pub(crate) fn calendar_data(xml: &str) -> Result<Vec<String>> {
    let document = roxmltree::Document::parse(xml).context("the CalDAV reply is not XML")?;
    Ok(document
        .descendants()
        .filter(|node| {
            node.is_element()
                && node.tag_name().name() == "calendar-data"
                && node.tag_name().namespace() == Some("urn:ietf:params:xml:ns:caldav")
        })
        .filter_map(|node| node.text().map(str::to_string))
        .filter(|text| !text.trim().is_empty())
        .collect())
}

/// A transport failure in words that never repeat the link: some `ureq`
/// errors carry the whole URL, and a calendar link is a secret.
fn describe(err: &ureq::Error) -> String {
    match err {
        ureq::Error::StatusCode(code) => format!("HTTP {code}"),
        ureq::Error::Timeout(_) => "timed out".into(),
        ureq::Error::HostNotFound => "host not found".into(),
        ureq::Error::ConnectionFailed => "connection failed".into(),
        ureq::Error::TooManyRedirects | ureq::Error::RedirectFailed => "redirect failed".into(),
        ureq::Error::BadUri(_) => "the link is not a valid address".into(),
        ureq::Error::Io(io) => format!("network error: {:?}", io.kind()),
        ureq::Error::Tls(_) => "secure connection failed".into(),
        _ => "the request failed".into(),
    }
}

fn caldav_time(value: DateTime<Utc>) -> String {
    value.format("%Y%m%dT%H%M%SZ").to_string()
}

fn looks_like_icalendar(body: &str) -> bool {
    body.trim_start_matches('\u{feff}')
        .trim_start()
        .get(..15)
        .is_some_and(|start| start.eq_ignore_ascii_case("BEGIN:VCALENDAR"))
}

fn agent() -> ureq::Agent {
    let config = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .allow_non_standard_methods(true)
        .max_redirects(5)
        .user_agent(concat!("LokalBot/", env!("CARGO_PKG_VERSION")))
        .timeout_connect(Some(Duration::from_secs(15)))
        .timeout_global(Some(TIMEOUT))
        .build();
    ureq::Agent::new_with_config(config)
}

fn read_body(response: ureq::http::Response<ureq::Body>) -> Result<String> {
    let mut bytes = Vec::new();
    response
        .into_body()
        .into_reader()
        .take(MAX_BYTES + 1)
        .read_to_end(&mut bytes)
        .context("reading the calendar")?;
    if bytes.len() as u64 > MAX_BYTES {
        bail!("the calendar is larger than {} MB", MAX_BYTES / 1024 / 1024);
    }
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

/// Moves `user:password@` out of the link into a Basic `Authorization` value.
fn split_credentials(url: &str) -> (String, Option<String>) {
    let Some((scheme, rest)) = url.split_once("://") else {
        return (url.to_string(), None);
    };
    let authority_end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let (authority, path) = rest.split_at(authority_end);
    let Some((userinfo, host)) = authority.rsplit_once('@') else {
        return (url.to_string(), None);
    };
    let decoded = percent_decode(userinfo);
    let token = base64_encode(decoded.as_bytes());
    (
        format!("{scheme}://{host}{path}"),
        Some(format!("Basic {token}")),
    )
}

fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && let Ok(byte) = u8::from_str_radix(&text[i + 1..i + 3], 16)
        {
            out.push(byte);
            i += 3;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn base64_encode(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (chunk[0] as u32) << 16
            | (chunk.get(1).copied().unwrap_or(0) as u32) << 8
            | chunk.get(2).copied().unwrap_or(0) as u32;
        for (i, shift) in [18, 12, 6, 0].into_iter().enumerate() {
            if i <= chunk.len() {
                out.push(TABLE[(n >> shift & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Asks a real CalDAV server: `LOKALBOT_CALDAV_TEST_URL=https://user:pass@host/cal/`
    /// with a "Weekly review" event today.
    #[test]
    #[ignore = "needs a CalDAV server"]
    fn live_caldav_report() {
        let Ok(link) = std::env::var("LOKALBOT_CALDAV_TEST_URL") else {
            return;
        };
        let now = Utc::now();
        let options = ParseOptions {
            provider: String::new(),
            from: now - chrono::Duration::days(1),
            to: now + chrono::Duration::days(1),
            my_addresses: vec!["you@example.com".into()],
            calendar_title: None,
            default_zone: None,
        };
        let (url, authorization) = split_credentials(&normalize(&link).unwrap());
        let events = caldav_query(&agent(), &url, authorization.as_deref(), &options).unwrap();
        eprintln!("{events:#?}");
        assert!(
            events
                .iter()
                .any(|e| e.title == "Weekly review" && e.provider == "caldav")
        );
        // The same link also works through `fetch`, as a feed or as CalDAV.
        assert!(
            fetch(&link, &options)
                .unwrap()
                .iter()
                .any(|e| e.title == "Weekly review")
        );
    }

    #[test]
    fn links_are_normalized_and_redacted_to_their_host() {
        assert_eq!(
            normalize("webcal://p01-caldav.icloud.com/published/2/abc").unwrap(),
            "https://p01-caldav.icloud.com/published/2/abc"
        );
        assert!(normalize("ftp://example.com/cal.ics").is_err());
        assert_eq!(
            redacted(
                "https://calendar.google.com/calendar/ical/me%40gmail.com/private-0123/basic.ics"
            ),
            "https://calendar.google.com/…"
        );
        assert_eq!(
            redacted("https://ana:secret@dav.example.com:8443/cal/"),
            "https://dav.example.com/…"
        );
        assert_eq!(redacted("not a link"), "a calendar link");
    }

    #[test]
    fn failures_never_repeat_the_link() {
        let options = ParseOptions {
            provider: String::new(),
            from: Utc::now(),
            to: Utc::now(),
            my_addresses: Vec::new(),
            calendar_title: None,
            default_zone: None,
        };
        let secret = "https://ana:hunter2@127.0.0.1:9/private-0123abc/basic.ics";
        let error = format!("{:#}", fetch(secret, &options).unwrap_err());
        assert!(!error.contains("private-0123abc"), "{error}");
        assert!(!error.contains("hunter2"), "{error}");
        assert!(error.starts_with("https://127.0.0.1/…"), "{error}");
        let error = format!(
            "{:#}",
            fetch("https://exa mple.com/secret-path", &options).unwrap_err()
        );
        assert!(!error.contains("secret-path"), "{error}");
    }

    #[test]
    fn credentials_move_into_a_basic_header() {
        let (url, auth) =
            split_credentials("https://ana%40example.com:pa%3Ass@dav.example.com/cal/x?y=1");
        assert_eq!(url, "https://dav.example.com/cal/x?y=1");
        assert_eq!(auth.as_deref(), Some("Basic YW5hQGV4YW1wbGUuY29tOnBhOnNz"));
        let (url, auth) = split_credentials("https://example.com/a@b");
        assert_eq!(url, "https://example.com/a@b");
        assert!(auth.is_none());
        assert_eq!(base64_encode(b"ab"), "YWI=");
        assert_eq!(base64_encode(b"a"), "YQ==");
    }

    #[test]
    fn reads_calendar_data_from_a_multistatus_reply() {
        let xml = r#"<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav">
  <d:response><d:href>/cal/a.ics</d:href><d:propstat><d:prop>
    <cal:calendar-data>BEGIN:VCALENDAR
VERSION:2.0
END:VCALENDAR
</cal:calendar-data></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
  <d:response><d:href>/cal/b.ics</d:href><d:propstat><d:prop>
    <cal:calendar-data><![CDATA[BEGIN:VCALENDAR
END:VCALENDAR]]></cal:calendar-data></d:prop></d:propstat></d:response>
</d:multistatus>"#;
        let documents = calendar_data(xml).unwrap();
        assert_eq!(documents.len(), 2);
        assert!(documents[0].starts_with("BEGIN:VCALENDAR"));
        assert!(looks_like_icalendar("\u{feff}BEGIN:VCALENDAR\r\n"));
        assert!(!looks_like_icalendar("<html>"));
    }
}
