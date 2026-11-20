use crate::privacy::{is_browser, is_excluded_app, is_excluded_url, sanitized_url};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Observation {
    pub app_name: String,
    pub app_id: String,
    pub window_title: Option<String>,
    pub source_url: Option<String>,
    pub focused_secure_field: Option<bool>,
    pub has_web_content: bool,
    pub contains_secure_field: bool,
    pub framed_urls: Vec<String>,
    pub has_unattributed_web_content: bool,
}

const SENSITIVE_MARKERS: [&str; 13] = [
    "secure",
    "password",
    "passcode",
    "passphrase",
    "cvv",
    "cvc",
    "security code",
    "verification code",
    "one-time code",
    "one time code",
    "social security",
    "card number",
    "credit card",
];

pub(crate) fn names_a_secret(label: &str) -> bool {
    let label = label.to_lowercase();
    SENSITIVE_MARKERS
        .iter()
        .any(|marker| label.contains(marker))
}

pub fn focus_permits_capture(
    focused_secure_field: Option<bool>,
    contains_secure_field: bool,
) -> bool {
    match focused_secure_field {
        Some(false) => true,
        Some(true) => false,
        None => !contains_secure_field,
    }
}

pub fn permits_content(
    observation: &Observation,
    excluded_apps: &[String],
    excluded_domains: &[String],
    allows_unknown_focus: bool,
) -> bool {
    if is_excluded_app(&observation.app_name, &observation.app_id, excluded_apps)
        || observation.window_title.is_none()
    {
        return false;
    }
    let focus_allows = if allows_unknown_focus {
        focus_permits_capture(
            observation.focused_secure_field,
            observation.contains_secure_field,
        )
    } else {
        observation.focused_secure_field == Some(false)
    };
    if !focus_allows {
        return false;
    }
    if is_excluded_url(observation.source_url.as_deref(), excluded_domains)
        || observation
            .framed_urls
            .iter()
            .any(|url| is_excluded_url(Some(url), excluded_domains))
    {
        return false;
    }
    let has_domain_rules = excluded_domains.iter().any(|rule| !rule.trim().is_empty());
    if has_domain_rules
        && (observation.has_web_content || is_browser(&observation.app_name, &observation.app_id))
        && (sanitized_url(observation.source_url.as_deref()).is_none()
            || observation.has_unattributed_web_content)
    {
        return false;
    }
    true
}

pub fn settled_focus(before: Option<bool>, after: Option<bool>) -> (bool, Option<bool>) {
    if before == after {
        return (true, before);
    }
    if before.is_none() && after == Some(false) {
        return (true, Some(false));
    }
    (false, before)
}

pub fn has_rich_accessible_text(text: &str) -> bool {
    text.chars().filter(|c| !c.is_whitespace()).count() >= 80
}

pub fn sanitized_document_name(raw: Option<&str>) -> Option<String> {
    let raw = raw?.trim();
    if raw.is_empty() {
        return None;
    }
    if let Ok(url) = url::Url::parse(raw) {
        if url.scheme() == "file" {
            let name = url
                .to_file_path()
                .ok()
                .and_then(|path| path.file_name().map(|n| n.to_string_lossy().into_owned()))
                .or_else(|| url.path_segments()?.next_back().map(str::to_string))?;
            return (!name.is_empty()).then(|| name.chars().take(300).collect());
        }
        if url.host_str().is_some() {
            return None;
        }
    }
    let name = raw.rsplit(['/', '\\']).next().unwrap_or(raw);
    (!name.is_empty()).then(|| name.chars().take(300).collect())
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PageAddress {
    pub source_url: Option<String>,
    pub framed_urls: Vec<String>,
    pub has_unattributed_web_content: bool,
}

pub fn page_address(document: Option<&str>, web_area_urls: &[Option<String>]) -> PageAddress {
    let mut page: Option<String> = document
        .filter(|d| sanitized_url(Some(d)).is_some())
        .map(str::to_string);
    let mut framed: Vec<String> = Vec::new();
    let mut unattributed = false;
    for (index, raw) in web_area_urls.iter().enumerate() {
        let Some(raw) = raw.as_deref().filter(|raw| !raw.is_empty()) else {
            unattributed = true;
            continue;
        };
        let scheme = raw
            .split_once(':')
            .map(|(scheme, _)| scheme.to_ascii_lowercase())
            .unwrap_or_default();
        if scheme == "about" || scheme == "data" {
            continue;
        }
        let address = if scheme == "blob" { &raw[5..] } else { raw };
        let Some(sanitized) = sanitized_url(Some(address)) else {
            unattributed = true;
            continue;
        };
        if page.is_none() && index == 0 {
            page = Some(raw.to_string());
            continue;
        }
        if Some(&sanitized) != sanitized_url(page.as_deref()).as_ref()
            && !framed.contains(&sanitized)
        {
            framed.push(sanitized);
        }
    }
    PageAddress {
        source_url: page,
        framed_urls: framed,
        has_unattributed_web_content: unattributed,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rules(list: &str) -> Vec<String> {
        lokalbot_core::settings::split_list(list)
    }

    fn observation() -> Observation {
        Observation {
            app_name: "Text Editor".into(),
            app_id: "org.gnome.texteditor".into(),
            window_title: Some("notes.txt".into()),
            focused_secure_field: Some(false),
            ..Default::default()
        }
    }

    #[test]
    fn focus_rules_match_the_mac() {
        assert!(focus_permits_capture(Some(false), true));
        assert!(!focus_permits_capture(Some(true), false));
        assert!(focus_permits_capture(None, false));
        assert!(!focus_permits_capture(None, true));
        assert_eq!(settled_focus(None, Some(false)), (true, Some(false)));
        assert_eq!(settled_focus(Some(false), Some(true)), (false, Some(false)));
        assert_eq!(settled_focus(None, Some(true)), (false, None));
        assert_eq!(settled_focus(Some(true), Some(true)), (true, Some(true)));
    }

    #[test]
    fn excluded_apps_secure_fields_and_missing_titles_are_refused() {
        let ok = observation();
        assert!(permits_content(&ok, &[], &[], true));
        assert!(!permits_content(&ok, &rules("text edit"), &[], true));
        let keepass = Observation {
            app_name: "KeePassXC".into(),
            app_id: "keepassxc".into(),
            ..observation()
        };
        assert!(
            !permits_content(&keepass, &[], &[], true),
            "password managers always"
        );
        let secure = Observation {
            focused_secure_field: Some(true),
            ..observation()
        };
        assert!(!permits_content(&secure, &[], &[], true));
        let unknown_with_password = Observation {
            focused_secure_field: None,
            contains_secure_field: true,
            ..observation()
        };
        assert!(!permits_content(&unknown_with_password, &[], &[], true));
        let unknown = Observation {
            focused_secure_field: None,
            ..observation()
        };
        assert!(permits_content(&unknown, &[], &[], true));
        assert!(!permits_content(&unknown, &[], &[], false));
        let untitled = Observation {
            window_title: None,
            ..observation()
        };
        assert!(!permits_content(&untitled, &[], &[], true));
    }

    #[test]
    fn site_rules_cover_frames_and_unreadable_addresses() {
        let domains = rules("bank.example");
        let browser = Observation {
            app_name: "Firefox".into(),
            app_id: "firefox".into(),
            source_url: Some("https://docs.example/plan".into()),
            has_web_content: true,
            ..observation()
        };
        assert!(permits_content(&browser, &[], &domains, true));
        let on_bank = Observation {
            source_url: Some("https://login.bank.example/".into()),
            ..browser.clone()
        };
        assert!(!permits_content(&on_bank, &[], &domains, true));
        let framing_bank = Observation {
            framed_urls: vec!["https://pay.bank.example/widget".into()],
            ..browser.clone()
        };
        assert!(!permits_content(&framing_bank, &[], &domains, true));
        let unknown_address = Observation {
            source_url: None,
            ..browser.clone()
        };
        assert!(!permits_content(&unknown_address, &[], &domains, true));
        assert!(
            permits_content(&unknown_address, &[], &[], true),
            "without site rules an unknown address is fine"
        );
        let unattributed = Observation {
            has_unattributed_web_content: true,
            ..browser
        };
        assert!(!permits_content(&unattributed, &[], &domains, true));
        assert!(permits_content(&observation(), &[], &domains, true));
    }

    #[test]
    fn secret_labels_are_recognized() {
        assert!(names_a_secret("Password"));
        assert!(names_a_secret("Card Number"));
        assert!(names_a_secret("Enter the one-time code"));
        assert!(!names_a_secret("Search"));
    }

    #[test]
    fn rich_text_needs_eighty_visible_characters() {
        assert!(!has_rich_accessible_text(&"a ".repeat(79)));
        assert!(has_rich_accessible_text(&"a\n".repeat(80)));
    }

    #[test]
    fn document_names_drop_folders_and_web_addresses() {
        #[cfg(unix)]
        assert_eq!(
            sanitized_document_name(Some("file:///home/me/Plans/Q4%20plan.odt")).as_deref(),
            Some("Q4 plan.odt")
        );
        assert_eq!(
            sanitized_document_name(Some("/home/me/notes.txt")).as_deref(),
            Some("notes.txt")
        );
        assert_eq!(
            sanitized_document_name(Some(r"C:\Users\me\report.docx")).as_deref(),
            Some("report.docx")
        );
        assert_eq!(
            sanitized_document_name(Some("https://mail.example/#inbox")),
            None
        );
        assert_eq!(sanitized_document_name(Some("  ")), None);
    }

    #[test]
    fn page_addresses_follow_chrome_frames() {
        let urls = |list: &[Option<&str>]| -> Vec<Option<String>> {
            list.iter().map(|u| u.map(str::to_string)).collect()
        };
        let address = page_address(
            None,
            &urls(&[
                Some("https://docs.example/a?x=1"),
                Some("about:blank"),
                Some("https://ads.example/frame"),
                Some("https://docs.example/a"),
            ]),
        );
        assert_eq!(
            address.source_url.as_deref(),
            Some("https://docs.example/a?x=1")
        );
        assert_eq!(address.framed_urls, ["https://ads.example/frame"]);
        assert!(!address.has_unattributed_web_content);
        let unreadable = page_address(None, &urls(&[None, Some("blob:https://x.example/1")]));
        assert_eq!(unreadable.source_url, None);
        assert!(unreadable.has_unattributed_web_content);
        assert_eq!(unreadable.framed_urls, ["https://x.example/1"]);
        let documented = page_address(
            Some("https://site.example/"),
            &urls(&[Some("https://site.example/")]),
        );
        assert_eq!(
            documented.source_url.as_deref(),
            Some("https://site.example/")
        );
        assert!(documented.framed_urls.is_empty());
    }
}
