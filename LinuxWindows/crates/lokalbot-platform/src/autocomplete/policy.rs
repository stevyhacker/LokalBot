// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 18 October 2026.
// See THIRD_PARTY_NOTICES.md.

use std::time::{Duration, Instant};

use unicode_segmentation::UnicodeSegmentation as _;

use super::geometry::Rect;
use super::{Capability, FieldSnapshot, FocusSnapshot};

pub const MAX_BEFORE_UTF16: usize = 4_096;
pub const MAX_AFTER_UTF16: usize = 1_024;

pub const ESCAPE_PAUSE: Duration = Duration::from_secs(10);

pub mod reasons {
    pub const SECURE: &str = "Secure field — never read.";
    pub const SELECTION: &str = "Text selected.";
    pub const NOT_EDITABLE: &str = "Not an editable text field.";
    pub const SEARCH: &str = "Search field.";
    pub const CODE_FIELD: &str = "Verification code field.";
    pub const NO_CARET: &str = "No caret in this field.";
    pub const TERMINAL: &str = "Not available in terminal apps.";
    pub const INTEGRATED_TERMINAL: &str = "Not available in the integrated terminal.";
    pub const FILE_DIALOG: &str = "Open or save dialog.";
    pub const NO_FIELD: &str = "No focused text field.";
    pub const EXCLUDED_APP: &str = "Disabled in this app.";
    pub const EXCLUDED_SITE: &str = "Disabled on this site.";
    pub const UNVERIFIABLE_SITE: &str = "Cannot verify this browser site — autocomplete paused.";
    pub const NOT_PROSE: &str = "A field for numbers, dates or addresses.";
    pub const NO_SURROUNDING_TEXT: &str = "This app does not share the text around the caret.";
    pub const UNKNOWN_APP: &str = "Cannot tell which app this field belongs to.";
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ReadPolicy {
    pub enabled: bool,
    pub excluded_apps: Vec<String>,
    pub excluded_domains: Vec<String>,
    pub capture_excluded_apps: Vec<String>,
    pub capture_excluded_domains: Vec<String>,
    pub visible_text: bool,
    pub window_text: bool,
    pub match_host_style: bool,
    pub suggest_in_integrated_terminals: bool,
}

impl ReadPolicy {
    pub fn from_settings(settings: &lokalbot_core::Settings, enabled: bool) -> Self {
        Self {
            enabled,
            excluded_apps: settings.cotyping_excluded_app_list(),
            excluded_domains: settings.cotyping_excluded_domain_list(),
            capture_excluded_apps: settings.excluded_app_list(),
            capture_excluded_domains: settings.excluded_domain_list(),
            visible_text: settings.cotyping_use_visible_context,
            window_text: settings.cotyping_use_window_text,
            match_host_style: settings.cotyping_match_host_style,
            suggest_in_integrated_terminals: settings.cotyping_suggest_in_integrated_terminals,
        }
    }

    pub fn allows_app(&self, app_name: &str, app_id: &str) -> bool {
        if !self.enabled || (app_name.trim().is_empty() && app_id.trim().is_empty()) {
            return false;
        }
        if app_id.eq_ignore_ascii_case(crate::privacy::SELF_APP_ID) {
            return false;
        }
        if crate::privacy::is_password_manager(app_name, app_id) {
            return false;
        }
        if is_terminal_app(app_name, app_id) {
            return false;
        }
        !is_excluded(app_name, app_id, &self.excluded_apps)
    }

    pub fn allows_visible_text(&self, field: &FieldSnapshot) -> bool {
        self.visible_text
            && !field.is_integrated_terminal
            && self.allows_surroundings(
                &field.app_name,
                &field.app_id,
                &field.window_title,
                field.url.as_deref(),
            )
    }

    pub fn allows_window_text(
        &self,
        app_name: &str,
        app_id: &str,
        window_title: &str,
        url: Option<&str>,
        is_integrated_terminal: bool,
    ) -> bool {
        self.window_text
            && !is_integrated_terminal
            && self.allows_surroundings(app_name, app_id, window_title, url)
    }

    fn allows_surroundings(
        &self,
        app_name: &str,
        app_id: &str,
        window_title: &str,
        url: Option<&str>,
    ) -> bool {
        if !self.allows_app(app_name, app_id) {
            return false;
        }
        if crate::privacy::is_private_window(window_title) {
            return false;
        }
        if crate::privacy::is_excluded_app(app_name, app_id, &self.capture_excluded_apps) {
            return false;
        }
        let browser = crate::privacy::is_browser(app_name, app_id);
        if browser && crate::privacy::sanitized_url(url).is_none() {
            return false;
        }
        !crate::privacy::is_excluded_url(url, &self.capture_excluded_domains)
            && !is_host_disabled(
                url.and_then(host_from_url).as_deref(),
                &self.excluded_domains,
            )
    }
}

pub fn is_excluded(app_name: &str, app_id: &str, rules: &[String]) -> bool {
    let haystacks = [app_name.to_lowercase(), app_id.to_lowercase()];
    rules
        .iter()
        .map(|rule| rule.trim().to_lowercase())
        .filter(|rule| !rule.is_empty())
        .any(|rule| {
            haystacks
                .iter()
                .any(|hay| !hay.is_empty() && hay.contains(&rule))
        })
}

pub fn is_integrated_terminal(dom_classes: &str) -> bool {
    dom_classes
        .split_whitespace()
        .any(|class| class.to_lowercase().starts_with("xterm"))
}

pub fn is_terminal_app(app_name: &str, app_id: &str) -> bool {
    let id = app_id.to_lowercase();
    let name = app_name.trim().to_lowercase();
    crate::insert::TERMINALS
        .iter()
        .any(|terminal| *terminal == id || *terminal == name)
        || matches!(
            name.as_str(),
            "terminal" | "console" | "windows terminal" | "command prompt" | "windows powershell"
        )
}

pub fn is_secure_field<'a>(labels: impl IntoIterator<Item = &'a str>) -> bool {
    const MARKERS: [&str; 13] = [
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
    labels.into_iter().any(|label| {
        let label = label.to_lowercase();
        MARKERS.iter().any(|marker| label.contains(marker))
    })
}

pub fn is_code_field<'a>(labels: impl IntoIterator<Item = &'a str>) -> bool {
    const CODE_WORDS: [&str; 3] = ["code", "kod", "код"];
    const SECRET_WORDS: [&str; 10] = [
        "otp",
        "totp",
        "2fa",
        "mfa",
        "pin",
        "passcode",
        "onetimecode",
        "otpcode",
        "smscode",
        "verificationcode",
    ];
    const CODE_CONTEXT_WORDS: [&str; 37] = [
        "verification",
        "verify",
        "confirmation",
        "confirm",
        "authentication",
        "authenticator",
        "auth",
        "login",
        "signin",
        "sms",
        "sent",
        "texted",
        "digit",
        "digits",
        "enter",
        "access",
        "backup",
        "recovery",
        "verifikacioni",
        "verifikacijski",
        "verifikaciju",
        "potvrdu",
        "potvrdni",
        "sigurnosni",
        "jednokratni",
        "unesite",
        "poslat",
        "poslan",
        "верификациони",
        "верификацију",
        "потврду",
        "потврдни",
        "сигурносни",
        "једнократни",
        "унесите",
        "послат",
        "смс",
    ];
    const PHRASES: [&str; 13] = [
        "one time code",
        "one time password",
        "one time passcode",
        "one time pin",
        "two factor",
        "2 factor",
        "two step",
        "2 step",
        "multi factor",
        "sign in code",
        "log in code",
        "jednokratna lozinka",
        "једнократна лозинка",
    ];
    labels.into_iter().any(|label| {
        let words = label_words(label);
        let has = |set: &[&str]| words.iter().any(|word| set.contains(&word.as_str()));
        if words.is_empty() {
            return false;
        }
        if words.len() == 1 && CODE_WORDS.contains(&words[0].as_str()) {
            return true;
        }
        if has(&SECRET_WORDS) || (has(&CODE_WORDS) && has(&CODE_CONTEXT_WORDS)) {
            return true;
        }
        let joined = format!(" {} ", words.join(" "));
        PHRASES
            .iter()
            .any(|phrase| joined.contains(&format!(" {phrase} ")))
    })
}

pub fn label_words(label: &str) -> Vec<String> {
    let characters: Vec<char> = label.chars().collect();
    let mut words = Vec::new();
    let mut current = String::new();
    for (index, &c) in characters.iter().enumerate() {
        if !c.is_alphanumeric() {
            if !current.is_empty() {
                words.push(current.to_lowercase());
                current.clear();
            }
            continue;
        }
        if c.is_uppercase()
            && let Some(previous) = current.chars().last()
        {
            let next_is_lowercase = characters.get(index + 1).is_some_and(|n| n.is_lowercase());
            if previous.is_lowercase() || (previous.is_uppercase() && next_is_lowercase) {
                words.push(current.to_lowercase());
                current.clear();
            }
        }
        current.push(c);
    }
    if !current.is_empty() {
        words.push(current.to_lowercase());
    }
    words
}

pub fn is_search_field<'a>(roles: impl IntoIterator<Item = &'a str>) -> bool {
    roles.into_iter().any(|role| {
        let role = role.trim().to_lowercase();
        role == "searchbox" || role == "search box" || role == "search" || role == "search field"
    })
}

pub fn is_non_text_glyph(c: char) -> bool {
    matches!(
        u32::from(c),
        0xFFFC | 0xFFFD | 0xE000..=0xF8FF | 0xF0000..=0xFFFFD | 0x100000..=0x10FFFD
    )
}

pub fn strip_non_text_glyphs(text: &str) -> (String, Option<u32>) {
    let mut first_removed = None;
    let mut removed_after_space = false;
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        let c = if c == '\u{00A0}' { ' ' } else { c };
        if is_non_text_glyph(c) {
            if first_removed.is_none() {
                first_removed = Some(u32::from(c));
            }
            removed_after_space = out.ends_with(' ');
        } else if c == ' ' && removed_after_space {
            removed_after_space = false;
        } else {
            removed_after_space = false;
            out.push(c);
        }
    }
    (out, first_removed)
}

pub fn is_inaccessible_editor_placeholder(name: &str, class_name: &str) -> bool {
    let lower_name = name.to_lowercase();
    if lower_name.contains("editor is not accessible at this time") {
        return true;
    }
    let lower_class = class_name.to_lowercase();
    (lower_class.contains("native-edit-context") || lower_class.contains("inputarea"))
        && lower_name.contains("enable screen reader optimized mode")
}

pub fn bounded_before(text: &str, read_truncated: bool) -> (String, bool) {
    let mut start = 0;
    let mut units = 0;
    for (index, c) in text.char_indices().rev() {
        if units + c.len_utf16() > MAX_BEFORE_UTF16 {
            start = index + c.len_utf8();
            break;
        }
        units += c.len_utf16();
    }
    let truncated = read_truncated || start > 0;
    let window = &text[start..];
    if !truncated {
        return (window.to_string(), false);
    }
    let rest = window
        .grapheme_indices(true)
        .nth(1)
        .map_or("", |(index, _)| &window[index..]);
    (rest.to_string(), true)
}

pub fn bounded_after(text: &str, read_truncated: bool) -> String {
    let mut end = text.len();
    let mut units = 0;
    for (index, c) in text.char_indices() {
        if units + c.len_utf16() > MAX_AFTER_UTF16 {
            end = index;
            break;
        }
        units += c.len_utf16();
    }
    let truncated = read_truncated || end < text.len();
    let window = &text[..end];
    if !truncated {
        return window.to_string();
    }
    let keep = window
        .grapheme_indices(true)
        .next_back()
        .map_or(0, |(index, _)| index);
    window[..keep].to_string()
}

pub fn caret_at_end_of_line(after: &str) -> bool {
    after
        .split(['\n', '\r'])
        .next()
        .unwrap_or("")
        .trim_end_matches([' ', '\t'])
        .is_empty()
}

pub fn luminance_probe_xs(caret: Rect, field: Option<Rect>, offsets: &[f32]) -> Vec<i32> {
    const LEFT_INSET: f32 = 4.0;
    const RIGHT_SCROLLBAR_INSET: f32 = 18.0;
    if let Some(frame) = field.filter(|f| f.is_finite() && f.width >= 64.0) {
        let min_x = frame.x + LEFT_INSET;
        let max_x = frame.right() - RIGHT_SCROLLBAR_INSET;
        if max_x <= min_x {
            return Vec::new();
        }
        let valid: Vec<i32> = offsets
            .iter()
            .map(|dx| caret.right() + dx)
            .filter(|x| *x >= min_x && *x <= max_x)
            .map(|x| x as i32)
            .collect();
        if valid.len() < offsets.len().min(2) {
            return Vec::new();
        }
        return valid;
    }
    offsets
        .iter()
        .map(|dx| (caret.right() + dx) as i32)
        .collect()
}

pub fn host_from_url(url: &str) -> Option<String> {
    let parsed = url::Url::parse(url.trim()).ok()?;
    let host = parsed.host_str()?.to_lowercase();
    if host.is_empty() {
        return None;
    }
    Some(strip_www(&host).to_string())
}

fn strip_www(host: &str) -> &str {
    match host.strip_prefix("www.") {
        Some(rest) if !rest.is_empty() => rest,
        _ => host,
    }
}

pub fn is_host_disabled(host: Option<&str>, rules: &[String]) -> bool {
    let Some(host) = host.filter(|h| !h.is_empty()) else {
        return false;
    };
    rules.iter().any(|entry| {
        let entry = entry.trim();
        if entry.is_empty() {
            return false;
        }
        let domain =
            host_from_url(entry).unwrap_or_else(|| strip_www(&entry.to_lowercase()).to_string());
        host == domain || host.ends_with(&format!(".{domain}"))
    })
}

pub fn disabled_reason(policy: &ReadPolicy, focus: &FocusSnapshot) -> Option<&'static str> {
    if !policy.enabled {
        return Some("Autocomplete is off.");
    }
    if is_terminal_app(&focus.app_name, &focus.app_id) {
        return Some(reasons::TERMINAL);
    }
    if !policy.allows_app(&focus.app_name, &focus.app_id) {
        return Some(reasons::EXCLUDED_APP);
    }
    match &focus.capability {
        Capability::Supported => {}
        Capability::Blocked(reason) | Capability::Unsupported(reason) => return Some(reason),
    }
    let field = focus.field.as_ref()?;
    if field.is_integrated_terminal && !policy.suggest_in_integrated_terminals {
        return Some(reasons::INTEGRATED_TERMINAL);
    }
    let host = field.url.as_deref().and_then(host_from_url);
    if is_host_disabled(host.as_deref(), &policy.excluded_domains) {
        return Some(reasons::EXCLUDED_SITE);
    }
    let has_site_rules = policy.excluded_domains.iter().any(|d| !d.trim().is_empty());
    if has_site_rules
        && crate::privacy::is_browser(&field.app_name, &field.app_id)
        && host.is_none()
    {
        return Some(reasons::UNVERIFIABLE_SITE);
    }
    None
}

pub fn field_identity(field: &FieldSnapshot) -> String {
    let part = if !field.focus_key.is_empty() {
        format!("focus:{}", field.focus_key)
    } else if let Some(frame) = field.field_frame {
        format!(
            "frame:{},{},{},{}",
            frame.x.round() as i64,
            frame.y.round() as i64,
            frame.width.round() as i64,
            frame.height.round() as i64
        )
    } else {
        field.window_title.clone()
    };
    [
        field.pid.to_string(),
        field.app_id.clone(),
        field.app_name.clone(),
        part,
    ]
    .join("\u{1f}")
}

pub fn background_cache_key(field: &FieldSnapshot, dark_theme: bool) -> String {
    let frame = field.field_frame.map_or_else(String::new, |f| {
        format!(
            "{},{},{},{}",
            (f.x / 16.0).round() as i64,
            (f.y / 16.0).round() as i64,
            (f.width / 16.0).round() as i64,
            (f.height / 16.0).round() as i64
        )
    });
    let host = field
        .url
        .as_deref()
        .and_then(host_from_url)
        .unwrap_or_default();
    let theme = if dark_theme { "dark" } else { "light" };
    [
        field.pid.to_string(),
        field.app_id.clone(),
        field.focus_key.clone(),
        host,
        field.window_title.clone(),
        frame,
        theme.to_string(),
    ]
    .join("\u{1f}")
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PollBackoff {
    idle_captures: u32,
}

impl PollBackoff {
    pub const IDLE_CAP: u32 = 60;

    pub fn stride(&self) -> u32 {
        match self.idle_captures {
            0..5 => 1,
            5..12 => 3,
            12..30 => 6,
            _ => 10,
        }
    }

    pub fn record(&mut self, changed: bool) {
        self.idle_captures = if changed {
            0
        } else {
            (self.idle_captures + 1).min(Self::IDLE_CAP)
        };
    }

    pub fn reset(&mut self) {
        self.idle_captures = 0;
    }
}

#[derive(Clone, Debug, Default)]
pub struct FlickerGate {
    last_supported_key: Option<String>,
    last_supported_app: Option<String>,
    blocked_reads: u32,
}

impl FlickerGate {
    pub const REQUIRED_BLOCKED_READS: u32 = 2;

    pub fn apply(&mut self, focus: &FocusSnapshot) -> bool {
        match &focus.capability {
            Capability::Supported => {
                self.last_supported_key = focus
                    .field
                    .as_ref()
                    .map(|f| f.focus_key.clone())
                    .or_else(|| focus.focus_key.clone());
                self.last_supported_app = (!focus.app_id.is_empty()).then(|| focus.app_id.clone());
                self.blocked_reads = 0;
                true
            }
            Capability::Blocked(reason) => {
                let same = *reason == reasons::SELECTION
                    && self.last_supported_key.is_some()
                    && focus.focus_key.is_some()
                    && self.last_supported_key == focus.focus_key;
                self.absorb_blip(same)
            }
            Capability::Unsupported(reason) => {
                let transient = *reason == reasons::NO_CARET || *reason == reasons::NOT_EDITABLE;
                let same = transient
                    && self.last_supported_app.is_some()
                    && !focus.app_id.is_empty()
                    && self.last_supported_app.as_deref() == Some(focus.app_id.as_str())
                    && focus
                        .focus_key
                        .as_ref()
                        .is_none_or(|key| self.last_supported_key.as_ref() == Some(key));
                self.absorb_blip(same)
            }
        }
    }

    fn absorb_blip(&mut self, same: bool) -> bool {
        if !same {
            self.last_supported_key = None;
            self.last_supported_app = None;
            self.blocked_reads = 0;
            return true;
        }
        self.blocked_reads += 1;
        if self.blocked_reads >= Self::REQUIRED_BLOCKED_READS {
            self.last_supported_key = None;
            self.last_supported_app = None;
            self.blocked_reads = 0;
            return true;
        }
        false
    }
}

pub fn choose_caret(
    empty_range: Option<Rect>,
    previous_character: Option<Rect>,
    field: Option<Rect>,
    right_to_left: bool,
) -> Option<Rect> {
    const CONTAINMENT_TOLERANCE: f32 = 4.0;
    let empty_range = empty_range.filter(|r| r.is_finite() && r.height > 0.0);
    if let Some(character) = previous_character
        && character.is_finite()
        && character.width > 0.0
        && character.height > 0.0
        && character.width <= character.height * 3.0
        && (empty_range.is_some()
            || field.is_some_and(|f| {
                f.inset(-CONTAINMENT_TOLERANCE, -CONTAINMENT_TOLERANCE)
                    .contains_rect(&character)
            }))
    {
        if let Some(empty) = empty_range {
            let empty_in_field = field.is_none_or(|f| {
                f.inset(-CONTAINMENT_TOLERANCE, -CONTAINMENT_TOLERANCE)
                    .contains_rect(&empty)
            });
            let wrapped_next_line = empty_in_field
                && is_collapsed_caret(&empty)
                && empty.y >= character.bottom() - 2.0
                && (!right_to_left && empty.x < character.x
                    || right_to_left && empty.x > character.right());
            if wrapped_next_line {
                return Some(Rect::new(empty.x, empty.y, 0.0, empty.height));
            }
        }
        let x = if right_to_left {
            character.x
        } else {
            character.right()
        };
        return Some(Rect::new(x, character.y, 0.0, character.height));
    }
    empty_range.filter(is_collapsed_caret).map(|empty| {
        Rect::new(
            if right_to_left {
                empty.right()
            } else {
                empty.x
            },
            empty.y,
            0.0,
            empty.height,
        )
    })
}

pub fn is_collapsed_caret(rect: &Rect) -> bool {
    rect.is_finite() && rect.height > 0.0 && rect.width <= (rect.height / 4.0).max(2.0)
}

pub fn is_stuck_at_origin_caret(first_char: Rect, previous_char: Rect, before: &str) -> bool {
    if !first_char.is_finite() || !previous_char.is_finite() {
        return false;
    }
    let has_newline = before.contains('\n');
    let visible_chars = before.chars().filter(|c| !c.is_control()).count();
    if !has_newline && visible_chars < 3 {
        return false;
    }
    (previous_char.x - first_char.x).abs() < 1.0 && (previous_char.y - first_char.y).abs() < 1.0
}

pub fn translate_for_leading_button(
    previous_char: Rect,
    first_char: Rect,
    field: Rect,
    button_right: f32,
) -> Rect {
    const BUTTON_GAP: f32 = 4.0;
    if !previous_char.is_finite()
        || !first_char.is_finite()
        || !field.is_finite()
        || button_right <= field.x
        || first_char.x >= button_right - 1.0
    {
        return previous_char;
    }
    let origin = first_char.x.max(field.x);
    let shift = (button_right - origin + BUTTON_GAP).max(0.0);
    let max_x = (field.right() - previous_char.width).max(previous_char.x);
    Rect::new(
        (previous_char.x + shift).min(max_x),
        previous_char.y,
        previous_char.width,
        previous_char.height,
    )
}

pub fn is_plausible_system_caret(caret: Rect, field: Option<Rect>) -> bool {
    const MIN_HEIGHT: f32 = 8.0;
    const TOLERANCE: f32 = 4.0;
    caret.is_finite()
        && caret.height >= MIN_HEIGHT
        && field.is_none_or(|f| f.inset(-TOLERANCE, -TOLERANCE).contains_rect(&caret))
}

#[derive(Clone, Debug, Default)]
pub struct EscapePause {
    paused: Option<(String, Instant)>,
}

impl EscapePause {
    pub fn pause(&mut self, field_identity: String, now: Instant) {
        self.paused = Some((field_identity, now + ESCAPE_PAUSE));
    }

    pub fn is_paused(&mut self, field_identity: &str, now: Instant) -> bool {
        let Some((identity, until)) = &self.paused else {
            return false;
        };
        if now >= *until {
            self.paused = None;
            return false;
        }
        identity == field_identity
    }

    pub fn clear(&mut self) {
        self.paused = None;
    }
}

pub fn is_right_to_left(text: &str) -> bool {
    text.chars()
        .rev()
        .find(|c| c.is_alphabetic())
        .is_some_and(|c| matches!(c as u32, 0x0590..=0x08FF | 0xFB1D..=0xFDFF | 0xFE70..=0xFEFF))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_integrated_terminal_is_a_class_starting_with_xterm() {
        assert!(is_integrated_terminal("xterm-helper-textarea"));
        assert!(is_integrated_terminal("monaco XTerm-screen"));
        assert!(!is_integrated_terminal("editor my-xterm"));
        assert!(!is_integrated_terminal(""));
    }

    #[test]
    fn window_text_has_its_own_grant_and_the_same_exclusions() {
        let policy = ReadPolicy {
            enabled: true,
            window_text: true,
            capture_excluded_apps: vec!["Signal".into()],
            capture_excluded_domains: vec!["bank.example".into()],
            excluded_domains: vec!["private.example".into()],
            ..ReadPolicy::default()
        };
        let allows = |name: &str, id: &str, title: &str, url: Option<&str>| {
            policy.allows_window_text(name, id, title, url, false)
        };
        assert!(allows("Text Editor", "org.gnome.TextEditor", "Notes", None));
        assert!(!allows("Signal", "signal", "Chat", None));
        assert!(!allows(
            "Text Editor",
            "x",
            "Inbox - Private Browsing",
            None
        ));
        assert!(!allows("Firefox", "firefox", "Inbox", None));
        assert!(allows(
            "Firefox",
            "firefox",
            "Inbox",
            Some("https://mail.example/")
        ));
        assert!(!allows(
            "Firefox",
            "firefox",
            "x",
            Some("https://bank.example/a")
        ));
        assert!(!allows(
            "Firefox",
            "firefox",
            "x",
            Some("https://private.example/a")
        ));
        assert!(!policy.allows_window_text("Text Editor", "x", "Notes", None, true));
        let off = ReadPolicy {
            window_text: false,
            ..policy.clone()
        };
        assert!(!off.allows_window_text("Text Editor", "x", "Notes", None, false));
    }

    #[test]
    fn an_integrated_terminal_gets_a_reason_unless_allowed() {
        let mut policy = ReadPolicy {
            enabled: true,
            ..ReadPolicy::default()
        };
        let focus = FocusSnapshot {
            app_name: "Code".into(),
            app_id: "code".into(),
            capability: Capability::Supported,
            field: Some(FieldSnapshot {
                is_integrated_terminal: true,
                app_name: "Code".into(),
                app_id: "code".into(),
                ..FieldSnapshot::default()
            }),
            focus_key: None,
        };
        assert_eq!(
            disabled_reason(&policy, &focus),
            Some(reasons::INTEGRATED_TERMINAL)
        );
        policy.suggest_in_integrated_terminals = true;
        assert_eq!(disabled_reason(&policy, &focus), None);
    }

    fn rules(list: &str) -> Vec<String> {
        lokalbot_core::settings::split_list(list)
    }

    fn policy() -> ReadPolicy {
        ReadPolicy {
            enabled: true,
            excluded_apps: rules("1Password, Bitwarden, KeePassXC, KeePass"),
            ..Default::default()
        }
    }

    pub(crate) fn field(app: &str, id: &str) -> FieldSnapshot {
        FieldSnapshot {
            focus_key: "1:/a/b".into(),
            app_name: app.into(),
            app_id: id.into(),
            pid: 42,
            window_title: "Draft".into(),
            before: "Hello".into(),
            ..Default::default()
        }
    }

    fn focus_of(field: FieldSnapshot) -> FocusSnapshot {
        FocusSnapshot {
            app_name: field.app_name.clone(),
            app_id: field.app_id.clone(),
            capability: Capability::Supported,
            focus_key: Some(field.focus_key.clone()),
            field: Some(field),
        }
    }

    #[test]
    fn excluded_apps_password_managers_terminals_and_self_are_never_read() {
        let policy = policy();
        assert!(policy.allows_app("Text Editor", "org.gnome.TextEditor"));
        assert!(!policy.allows_app("KeePassXC", "keepassxc"));
        let cleared = ReadPolicy {
            enabled: true,
            ..Default::default()
        };
        assert!(!cleared.allows_app("Proton Pass", "proton pass.exe"));
        assert!(!cleared.allows_app("Windows Security", "CredentialUIBroker.exe"));
        assert!(!cleared.allows_app("LokalBot", "lokalbot"));
        assert!(!cleared.allows_app("Terminal", "gnome-terminal-server"));
        assert!(!cleared.allows_app("Windows Terminal", "WindowsTerminal.exe"));
        let custom = ReadPolicy {
            enabled: true,
            excluded_apps: rules("slack, code.exe"),
            ..Default::default()
        };
        assert!(!custom.allows_app("Slack", "slack"));
        assert!(!custom.allows_app("Visual Studio Code", "Code.exe"));
        assert!(custom.allows_app("Notepad", "notepad.exe"));
        assert!(!ReadPolicy::default().allows_app("Notepad", "notepad.exe"));
        assert!(!cleared.allows_app("", ""));
    }

    #[test]
    fn secure_and_search_fields() {
        assert!(is_secure_field(["password text"]));
        assert!(is_secure_field(["entry", "Card number"]));
        assert!(is_secure_field(["", "Enter the verification code"]));
        assert!(!is_secure_field(["text", "Message #general"]));
        assert!(is_search_field(["entry", "searchbox"]));
        assert!(is_search_field(["search box"]));
        assert!(!is_search_field(["entry", "textbox"]));
    }

    #[test]
    fn code_fields_are_named_by_label_placeholder_or_id() {
        for label in [
            "Code",
            "Enter code",
            "Enter the 6-digit code",
            "Code sent by SMS",
            "SMS code",
            "Login code",
            "Two-factor authentication",
            "2-Step Verification",
            "One-time password",
            "OTP",
            "Authenticator app code",
            "PIN",
            "Backup code",
            "otpInput",
            "SMSCode",
            "verification-code",
            "mfa_code",
            "one-time-code",
            "Unesite kod",
            "Verifikacioni kod",
            "Kod za potvrdu",
            "Jednokratna lozinka",
            "Унесите код",
            "Код за потврду",
        ] {
            assert!(is_code_field(["", label]), "{label}");
        }
        for label in [
            "Message #general",
            "Reply to Claude…",
            "Pinned notes",
            "Opinion",
            "Spinner",
            "Write a code review comment",
            "Source Control Input",
            "iMessage",
            "Text Message • SMS",
            "Subject",
            "Add a comment",
            "Shipping address",
            "",
        ] {
            assert!(!is_code_field([label]), "{label}");
        }
        assert_eq!(label_words("SMSCode"), ["sms", "code"]);
        assert_eq!(label_words("otpInput-2"), ["otp", "input", "2"]);
        assert_eq!(label_words("2FA"), ["2fa"]);
        assert_eq!(label_words("Унесите код"), ["унесите", "код"]);
    }

    #[test]
    fn context_windows_are_bounded_like_macos() {
        let (before, truncated) = bounded_before("Hello there", false);
        assert_eq!((before.as_str(), truncated), ("Hello there", false));
        let long = format!("{}{}", "a".repeat(10), "b".repeat(MAX_BEFORE_UTF16));
        let (before, truncated) = bounded_before(&long, false);
        assert!(truncated);
        assert_eq!(before.len(), MAX_BEFORE_UTF16 - 1);
        assert!(before.chars().all(|c| c == 'b'));
        let (before, truncated) = bounded_before("e\u{301}tude", true);
        assert_eq!((before.as_str(), truncated), ("tude", true));
        let emoji = "😀".repeat(MAX_BEFORE_UTF16 / 2 + 3);
        let (before, _) = bounded_before(&emoji, false);
        assert!(before.encode_utf16().count() <= MAX_BEFORE_UTF16);
        assert_eq!(bounded_after("tail text", false), "tail text");
        let after = bounded_after(&"x".repeat(MAX_AFTER_UTF16 + 5), false);
        assert_eq!(after.len(), MAX_AFTER_UTF16 - 1);
        assert_eq!(bounded_after("ab", true), "a");
    }

    #[test]
    fn caret_end_of_line() {
        assert!(caret_at_end_of_line(""));
        assert!(caret_at_end_of_line("   "));
        assert!(caret_at_end_of_line(" \t \nnext line"));
        assert!(caret_at_end_of_line("\nnext line"));
        assert!(!caret_at_end_of_line(" world"));
    }

    #[test]
    fn site_rules() {
        assert_eq!(
            host_from_url("https://www.Bank.com/login").as_deref(),
            Some("bank.com")
        );
        assert_eq!(host_from_url("about:blank"), None);
        assert_eq!(host_from_url("file:///tmp/x"), None);
        let list = rules("bank.com, https://mail.example.org/inbox");
        assert!(is_host_disabled(Some("bank.com"), &list));
        assert!(is_host_disabled(Some("online.bank.com"), &list));
        assert!(!is_host_disabled(Some("notbank.com"), &list));
        assert!(is_host_disabled(Some("mail.example.org"), &list));
        assert!(!is_host_disabled(None, &list));
    }

    #[test]
    fn availability_follows_macos() {
        let mut policy = policy();
        let mut browsing = field("Firefox", "firefox");
        browsing.url = Some("https://docs.example.com/page".into());
        assert_eq!(disabled_reason(&policy, &focus_of(browsing.clone())), None);
        policy.excluded_domains = rules("bank.com");
        browsing.url = None;
        assert_eq!(
            disabled_reason(&policy, &focus_of(browsing.clone())),
            Some(reasons::UNVERIFIABLE_SITE)
        );
        browsing.url = Some("https://www.bank.com/".into());
        assert_eq!(
            disabled_reason(&policy, &focus_of(browsing)),
            Some(reasons::EXCLUDED_SITE)
        );
        assert_eq!(
            disabled_reason(&policy, &focus_of(field("Text Editor", "gedit"))),
            None
        );
        assert_eq!(
            disabled_reason(&policy, &focus_of(field("Konsole", "konsole"))),
            Some(reasons::TERMINAL)
        );
        let mut secure = focus_of(field("Text Editor", "gedit"));
        secure.capability = Capability::Blocked(reasons::SECURE);
        secure.field = None;
        assert_eq!(disabled_reason(&policy, &secure), Some(reasons::SECURE));
        policy.enabled = false;
        assert!(disabled_reason(&policy, &focus_of(field("Text Editor", "gedit"))).is_some());
    }

    #[test]
    fn visible_text_needs_its_own_grant_and_a_readable_page() {
        let mut policy = policy();
        let mut chat = field("Element", "element");
        chat.window_title = "General".into();
        assert!(!policy.allows_visible_text(&chat));
        policy.visible_text = true;
        assert!(policy.allows_visible_text(&chat));
        chat.window_title = "New Tab - Private Browsing".into();
        assert!(!policy.allows_visible_text(&chat));
        let mut browser = field("Firefox", "firefox");
        assert!(!policy.allows_visible_text(&browser));
        browser.url = Some("https://chat.example.com/room".into());
        assert!(policy.allows_visible_text(&browser));
        policy.capture_excluded_domains = rules("example.com");
        assert!(!policy.allows_visible_text(&browser));
        policy.capture_excluded_apps = rules("Element");
        assert!(!policy.allows_visible_text(&chat));
    }

    #[test]
    fn identity_ignores_content() {
        let mut a = field("Text Editor", "gedit");
        let id = field_identity(&a);
        a.before.push_str(" world");
        a.after = "x".into();
        assert_eq!(field_identity(&a), id);
        a.focus_key = ":1.5/org/a11y/atspi/accessible/9".into();
        assert_ne!(field_identity(&a), id);
        let mut b = field("App", "app");
        b.focus_key.clear();
        b.field_frame = Some(Rect::new(10.2, 20.0, 300.0, 40.0));
        let mut c = b.clone();
        c.field_frame = Some(Rect::new(10.0, 20.0, 300.0, 40.0));
        assert_eq!(field_identity(&b), field_identity(&c));
        c.field_frame = Some(Rect::new(10.0, 90.0, 300.0, 40.0));
        assert_ne!(field_identity(&b), field_identity(&c));
    }

    #[test]
    fn poll_backoff_strides() {
        let mut backoff = PollBackoff::default();
        assert_eq!(backoff.stride(), 1);
        for _ in 0..5 {
            backoff.record(false);
        }
        assert_eq!(backoff.stride(), 3);
        for _ in 0..7 {
            backoff.record(false);
        }
        assert_eq!(backoff.stride(), 6);
        for _ in 0..100 {
            backoff.record(false);
        }
        assert_eq!(backoff.stride(), 10);
        backoff.record(true);
        assert_eq!(backoff.stride(), 1);
    }

    #[test]
    fn flicker_gate_smooths_one_selection_blip_only() {
        let mut gate = FlickerGate::default();
        let supported = focus_of(field("Text Editor", "gedit"));
        assert!(gate.apply(&supported));
        let mut blip = supported.clone();
        blip.capability = Capability::Blocked(reasons::SELECTION);
        blip.field = None;
        assert!(!gate.apply(&blip));
        assert!(gate.apply(&blip));
        assert!(gate.apply(&supported));
        let mut secure = blip.clone();
        secure.capability = Capability::Blocked(reasons::SECURE);
        assert!(gate.apply(&secure));
        assert!(gate.apply(&supported));
        let mut other = blip.clone();
        other.focus_key = Some("other".into());
        assert!(gate.apply(&other));

        assert!(gate.apply(&supported));
        let mut no_caret = FocusSnapshot::unsupported("Text Editor", "gedit", reasons::NO_CARET);
        assert!(!gate.apply(&no_caret));
        assert!(gate.apply(&no_caret));
        assert!(gate.apply(&supported));
        no_caret.app_id = "terminal".into();
        assert!(gate.apply(&no_caret));
        assert!(gate.apply(&supported));
        let terminal = FocusSnapshot::unsupported("Text Editor", "gedit", reasons::TERMINAL);
        assert!(gate.apply(&terminal));
    }

    #[test]
    fn caret_prefers_the_character_before_it() {
        let field = Some(Rect::new(0.0, 0.0, 400.0, 40.0));
        let caret = choose_caret(
            Some(Rect::new(100.0, -20.0, 0.0, 18.0)),
            Some(Rect::new(90.0, 10.0, 8.0, 18.0)),
            field,
            false,
        );
        assert_eq!(caret, Some(Rect::new(98.0, 10.0, 0.0, 18.0)));
        let caret = choose_caret(None, Some(Rect::new(90.0, 10.0, 8.0, 18.0)), field, true);
        assert_eq!(caret, Some(Rect::new(90.0, 10.0, 0.0, 18.0)));
        assert_eq!(
            choose_caret(None, Some(Rect::new(0.0, 10.0, 300.0, 18.0)), field, false),
            None
        );
        assert_eq!(
            choose_caret(None, Some(Rect::new(900.0, 10.0, 8.0, 18.0)), field, false),
            None
        );
        let range = Rect::new(50.0, 10.0, 0.0, 18.0);
        assert_eq!(choose_caret(Some(range), None, field, false), Some(range));
        assert_eq!(
            choose_caret(Some(Rect::new(5.0, 5.0, 788.0, 23.0)), None, field, false),
            None
        );
        assert!(is_collapsed_caret(&Rect::new(5.0, 5.0, 1.0, 16.0)));
        assert!(!is_collapsed_caret(&Rect::new(5.0, 5.0, 788.0, 23.0)));

        let multiline = Some(Rect::new(0.0, 0.0, 400.0, 200.0));
        let soft_wrapped = choose_caret(
            Some(Rect::new(12.0, 51.0, 2.0, 27.0)),
            Some(Rect::new(380.0, 0.0, 12.0, 51.0)),
            multiline,
            false,
        );
        assert_eq!(soft_wrapped, Some(Rect::new(12.0, 51.0, 0.0, 27.0)));
    }

    #[test]
    fn non_text_glyphs_and_inaccessible_placeholders_are_filtered() {
        let (clean, first) = strip_non_text_glyphs("\u{FFFC}hello \u{EAB6}world 👍");
        assert_eq!(clean, "hello world 👍");
        assert_eq!(first, Some(0xFFFC));
        assert_eq!(
            strip_non_text_glyphs("Hey \u{FFFC} "),
            ("Hey ".into(), Some(0xFFFC))
        );
        assert_eq!(
            strip_non_text_glyphs("plain text"),
            ("plain text".into(), None)
        );
        assert_eq!(
            strip_non_text_glyphs("Hello\u{00A0}world\u{00A0}"),
            ("Hello world ".into(), None)
        );
        let notepad_frame = Some(Rect::new(4170.0, 500.0, 824.0, 900.0));
        assert!(
            luminance_probe_xs(
                Rect::new(4979.0, 881.0, 0.0, 27.0),
                notepad_frame,
                &[4.0, 10.0, 16.0]
            )
            .is_empty()
        );
        assert_eq!(
            luminance_probe_xs(
                Rect::new(4186.0, 908.0, 0.0, 27.0),
                notepad_frame,
                &[4.0, 10.0, 16.0]
            ),
            vec![4190, 4196, 4202]
        );
        assert!(is_inaccessible_editor_placeholder(
            "The editor is not accessible at this time. To enable screen reader optimized mode, use Shift+Alt+F1",
            "native-edit-context"
        ));
        assert!(!is_inaccessible_editor_placeholder(
            "Search settings",
            "inputarea"
        ));
    }

    #[test]
    fn background_cache_separates_pages_and_frames() {
        let mut a = field("Firefox", "firefox.exe");
        a.url = Some("https://developer.mozilla.org/en-US/".into());
        a.field_frame = Some(Rect::new(100.0, 200.0, 300.0, 40.0));
        let mut b = a.clone();
        b.url = Some("https://github.com/".into());
        assert_ne!(
            background_cache_key(&a, true),
            background_cache_key(&b, true)
        );
        assert_ne!(
            background_cache_key(&a, true),
            background_cache_key(&a, false)
        );
        let mut nudged = a.clone();
        nudged.field_frame = Some(Rect::new(101.0, 201.0, 300.0, 40.0));
        assert_eq!(
            background_cache_key(&a, true),
            background_cache_key(&nudged, true)
        );
    }

    #[test]
    fn escape_pause_holds_one_field_for_ten_seconds() {
        let mut pause = EscapePause::default();
        let now = Instant::now();
        pause.pause("field-a".into(), now);
        assert!(pause.is_paused("field-a", now + Duration::from_secs(9)));
        assert!(!pause.is_paused("field-b", now + Duration::from_secs(1)));
        assert!(!pause.is_paused("field-a", now + Duration::from_secs(11)));
        assert!(!pause.is_paused("field-a", now));
    }

    #[test]
    fn right_to_left_follows_the_last_letter() {
        assert!(is_right_to_left("שלום"));
        assert!(!is_right_to_left("hello"));
        assert!(!is_right_to_left("שלום hello"));
    }

    #[test]
    fn stuck_origin_caret_and_leading_button_offsets_are_detected() {
        let origin = Rect::new(552.0, 109.0, 8.0, 18.0);
        assert!(is_stuck_at_origin_caret(origin, origin, "SELECT * FROM "));
        assert!(is_stuck_at_origin_caret(origin, origin, "a\nb"));
        assert!(!is_stuck_at_origin_caret(origin, origin, "ab"));
        assert!(!is_stuck_at_origin_caret(
            origin,
            Rect::new(620.0, 109.0, 8.0, 18.0),
            "SELECT * FROM "
        ));

        let field_rect = Rect::new(7.0, 120.0, 3753.0, 27.0);
        let first = Rect::new(7.0, 120.0, 7.0, 24.0);
        let prev = Rect::new(549.0, 120.0, 7.0, 24.0);
        let shifted = translate_for_leading_button(prev, first, field_rect, 32.0);
        assert_eq!(shifted.x, 578.0);

        let already_offset = Rect::new(36.0, 120.0, 7.0, 24.0);
        assert_eq!(
            translate_for_leading_button(prev, already_offset, field_rect, 32.0),
            prev
        );
    }
}
