// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 18 October 2026.
// See THIRD_PARTY_NOTICES.md.

//! What autocomplete may read and where it may suggest, kept pure so it is
//! testable without a desktop: the app read policy, secure and search field
//! detection, the bounded text windows around the caret, site exclusions,
//! focus smoothing and the field identity that suggestions are anchored to
//! (`CotypingAXPolicies.swift`, `CotypingAvailability.swift`,
//! `CotypingBrowserDomain.swift`, `CotypingFieldIdentity.swift`,
//! `CotypingFocusPollBackoff.swift`, `CotypingFocusCapabilityFlickerGate.swift`).

use std::time::{Duration, Instant};

use unicode_segmentation::UnicodeSegmentation as _;

use super::geometry::Rect;
use super::{Capability, FieldSnapshot, FocusSnapshot};

/// Text before the caret, in UTF-16 units, as on macOS
/// (`CotypingAcceptanceContentBounds.maximumPrecedingUTF16Length`).
pub const MAX_BEFORE_UTF16: usize = 4_096;
/// Text after the caret, in UTF-16 units.
pub const MAX_AFTER_UTF16: usize = 1_024;

/// How long a field stays quiet after Escape (`CotypingEscapeBehavior.pauseSeconds`).
pub const ESCAPE_PAUSE: Duration = Duration::from_secs(10);

pub mod reasons {
    //! Why a field gets no suggestion, as macOS words it in its status line.
    pub const SECURE: &str = "Secure field — never read.";
    pub const SELECTION: &str = "Text selected.";
    pub const NOT_EDITABLE: &str = "Not an editable text field.";
    pub const SEARCH: &str = "Search field.";
    pub const NO_CARET: &str = "No caret in this field.";
    pub const TERMINAL: &str = "Not available in terminal apps.";
    pub const FILE_DIALOG: &str = "Open or save dialog.";
    pub const NO_FIELD: &str = "No focused text field.";
    pub const EXCLUDED_APP: &str = "Disabled in this app.";
    pub const EXCLUDED_SITE: &str = "Disabled on this site.";
    pub const UNVERIFIABLE_SITE: &str = "Cannot verify this browser site — autocomplete paused.";
}

/// Who may be read at all. App exclusions authorize the read itself, before
/// any field text exists (`CotypingAppReadPolicy`): an excluded app's fields
/// are never read, not read and then dropped.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ReadPolicy {
    /// Autocomplete is on. Off means nothing is read.
    pub enabled: bool,
    /// "Never suggest in these apps" (`cotyping_excluded_apps`).
    pub excluded_apps: Vec<String>,
    /// "Never suggest on these sites" (`cotyping_excluded_domains`).
    pub excluded_domains: Vec<String>,
    /// Day memory's "Never capture these apps", which also keeps the text
    /// around a field out of a suggestion (`CotypingVisibleContext.Policy`).
    pub capture_excluded_apps: Vec<String>,
    /// Day memory's "Never capture these sites".
    pub capture_excluded_domains: Vec<String>,
    /// Read the text shown above the field, such as the conversation being
    /// answered. Never on the Tab path.
    pub visible_text: bool,
}

impl ReadPolicy {
    /// Whether `app_name`/`app_id` may be read. Unknown owners fail closed.
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

    /// Whether the text around the field may join a suggestion: the field's
    /// own rules plus day memory's capture exclusions, with private windows
    /// and browsers whose page cannot be read left out
    /// (`CotypingVisibleContext.Policy.permits`).
    pub fn allows_visible_text(&self, field: &FieldSnapshot) -> bool {
        if !self.visible_text || !self.allows_app(&field.app_name, &field.app_id) {
            return false;
        }
        if crate::privacy::is_private_window(&field.window_title) {
            return false;
        }
        if crate::privacy::is_excluded_app(
            &field.app_name,
            &field.app_id,
            &self.capture_excluded_apps,
        ) {
            return false;
        }
        let browser = crate::privacy::is_browser(&field.app_name, &field.app_id);
        if browser && crate::privacy::sanitized_url(field.url.as_deref()).is_none() {
            return false;
        }
        !crate::privacy::is_excluded_url(field.url.as_deref(), &self.capture_excluded_domains)
            && !is_host_disabled(
                field.url.as_deref().and_then(host_from_url).as_deref(),
                &self.excluded_domains,
            )
    }
}

/// Case-insensitive substring of the app name or id
/// (`CotypingAvailability.isExcluded`).
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

/// Terminal emulators: their history and completions fight ghost text
/// (`CotypingSurfaceClassifier` `.terminal`).
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

/// Conservative secure-field check over every label a toolkit exposes. A
/// false positive only hides autocomplete; a false negative could show a
/// secret as ghost text (`CotypingSecureFieldDetector`).
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

/// Search boxes stay quiet: a query is not prose to continue, and Tab there
/// belongs to the results (`CotypingSearchFieldDetector`). `roles` are the
/// toolkit's role names, ARIA roles and input types.
pub fn is_search_field<'a>(roles: impl IntoIterator<Item = &'a str>) -> bool {
    roles.into_iter().any(|role| {
        let role = role.trim().to_lowercase();
        role == "searchbox" || role == "search box" || role == "search" || role == "search field"
    })
}

/// The bounded text before the caret. `read_truncated` says the reader
/// already left out text before what it returned. A clipped window drops its
/// outermost grapheme, which the cut may have split
/// (`CotypingAcceptanceContentBounds.context`).
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

/// The bounded text after the caret, the mirror of [`bounded_before`].
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

/// Whether the caret is at the end of its line: nothing follows it, or what
/// follows starts with a line break (`CotypingRenderModePolicy.isCaretAtEndOfLine`).
pub fn caret_at_end_of_line(after: &str) -> bool {
    after.chars().next().is_none_or(|c| c == '\n' || c == '\r')
}

/// Lowercased host of a page address without a leading `www.`; `None` for
/// addresses without a network host (`CotypingBrowserDomain.host`).
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

/// Whether a host is covered by a site rule: the same host or a subdomain of
/// it. Rules may be pasted as full URLs (`CotypingBrowserDomain.isHostDisabled`).
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

/// Why `focus` gets no suggestion, or `None` when it may
/// (`CotypingAvailability.disabledReason`).
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
    let host = field.url.as_deref().and_then(host_from_url);
    if is_host_disabled(host.as_deref(), &policy.excluded_domains) {
        return Some(reasons::EXCLUDED_SITE);
    }
    // A site rule is a privacy boundary: a browser whose page cannot be read
    // is paused, never treated as allowed.
    let has_site_rules = policy.excluded_domains.iter().any(|d| !d.trim().is_empty());
    if has_site_rules
        && crate::privacy::is_browser(&field.app_name, &field.app_id)
        && host.is_none()
    {
        return Some(reasons::UNVERIFIABLE_SITE);
    }
    None
}

/// Identity of "the same field" across snapshots: the toolkit's own element
/// identity, else the field frame, else the window title. Content is left
/// out so typing through a suggestion keeps it (`CotypingFieldIdentity`).
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

/// Cotabby's idle backoff for the poll fallback: full speed after activity,
/// slower after repeated captures that changed nothing
/// (`CotypingFocusPollBackoff`).
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

/// Smooths one `supported → selected → supported` blip on the same element:
/// some apps briefly report a selection while redrawing the caret, which
/// would tear the ghost down and rebuild it. Secure fields are never
/// smoothed (`CotypingFocusCapabilityFlickerGate`).
#[derive(Clone, Debug, Default)]
pub struct FlickerGate {
    last_supported: Option<String>,
    blocked_reads: u32,
}

impl FlickerGate {
    pub const REQUIRED_BLOCKED_READS: u32 = 2;

    /// True to deliver `focus`, false to keep the previous one for now.
    pub fn apply(&mut self, focus: &FocusSnapshot) -> bool {
        match &focus.capability {
            Capability::Supported => {
                self.last_supported = focus
                    .field
                    .as_ref()
                    .map(|f| f.focus_key.clone())
                    .or_else(|| focus.focus_key.clone());
                self.blocked_reads = 0;
                true
            }
            Capability::Blocked(reason) => {
                let same = *reason == reasons::SELECTION
                    && self.last_supported.is_some()
                    && focus.focus_key.is_some()
                    && self.last_supported == focus.focus_key;
                if !same {
                    self.last_supported = None;
                    self.blocked_reads = 0;
                    return true;
                }
                self.blocked_reads += 1;
                if self.blocked_reads >= Self::REQUIRED_BLOCKED_READS {
                    self.last_supported = None;
                    self.blocked_reads = 0;
                    return true;
                }
                false
            }
            Capability::Unsupported(_) => {
                self.last_supported = None;
                self.blocked_reads = 0;
                true
            }
        }
    }
}

/// Picks the caret from what a field reports for the empty range at the
/// caret and for the character before it: that character's trailing edge
/// when it is one glyph inside the field, else the empty range. Several apps
/// report the empty range a line off or with no size, while the character
/// before the caret is where it is drawn (`CotypingCaretGeometry.caret`).
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
        let x = if right_to_left {
            character.x
        } else {
            character.right()
        };
        return Some(Rect::new(x, character.y, 0.0, character.height));
    }
    empty_range
}

/// Whether a rect reported for the collapsed selection is a caret rather
/// than a whole line or field (`CotypingCaretGeometry.isCollapsedCaret`).
pub fn is_collapsed_caret(rect: &Rect) -> bool {
    rect.is_finite() && rect.height > 0.0 && rect.width <= (rect.height / 4.0).max(2.0)
}

/// Escape keeps one field quiet for a while; it never follows the user to
/// another field (`CotypingCoordinator.isPausedByEscape`).
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

/// Right-to-left when the last strong character is Hebrew or Arabic
/// (`CotypingTextDirectionDetector`), for choosing the caret's edge. The
/// engine's `lokalbot_ai::autocomplete::is_right_to_left` does the same for
/// placing the ghost; this crate does not depend on that one.
pub fn is_right_to_left(text: &str) -> bool {
    text.chars()
        .rev()
        .find(|c| c.is_alphabetic())
        .is_some_and(|c| matches!(c as u32, 0x0590..=0x08FF | 0xFB1D..=0xFDFF | 0xFE70..=0xFEFF))
}

#[cfg(test)]
mod tests {
    use super::*;

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
        // Built in even when the user cleared the list.
        let cleared = ReadPolicy {
            enabled: true,
            ..Default::default()
        };
        assert!(!cleared.allows_app("Proton Pass", "proton pass.exe"));
        assert!(!cleared.allows_app("Windows Security", "CredentialUIBroker.exe"));
        assert!(!cleared.allows_app("LokalBot", "lokalbot"));
        assert!(!cleared.allows_app("Terminal", "gnome-terminal-server"));
        assert!(!cleared.allows_app("Windows Terminal", "WindowsTerminal.exe"));
        // Substring of the name or the id, case-insensitive, as on macOS.
        let custom = ReadPolicy {
            enabled: true,
            excluded_apps: rules("slack, code.exe"),
            ..Default::default()
        };
        assert!(!custom.allows_app("Slack", "slack"));
        assert!(!custom.allows_app("Visual Studio Code", "Code.exe"));
        assert!(custom.allows_app("Notepad", "notepad.exe"));
        // Off, or an unknown owner, reads nothing.
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
    fn context_windows_are_bounded_like_macos() {
        let (before, truncated) = bounded_before("Hello there", false);
        assert_eq!((before.as_str(), truncated), ("Hello there", false));
        // Too long: the last 4096 units, minus the outer grapheme.
        let long = format!("{}{}", "a".repeat(10), "b".repeat(MAX_BEFORE_UTF16));
        let (before, truncated) = bounded_before(&long, false);
        assert!(truncated);
        assert_eq!(before.len(), MAX_BEFORE_UTF16 - 1);
        assert!(before.chars().all(|c| c == 'b'));
        // A reader that clipped already: the first grapheme may be split.
        let (before, truncated) = bounded_before("e\u{301}tude", true);
        assert_eq!((before.as_str(), truncated), ("tude", true));
        // UTF-16 counting: astral characters take two units.
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
        // A site rule pauses a browser whose page it cannot read.
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
        // Native apps have no page to authorize.
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
        // Private windows and browsers without a readable page abstain.
        chat.window_title = "New Tab - Private Browsing".into();
        assert!(!policy.allows_visible_text(&chat));
        let mut browser = field("Firefox", "firefox");
        assert!(!policy.allows_visible_text(&browser));
        browser.url = Some("https://chat.example.com/room".into());
        assert!(policy.allows_visible_text(&browser));
        // Day memory's capture exclusions apply too.
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
        // Without a toolkit identity the frame stands in.
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
        // The second blocked read in a row goes through.
        assert!(gate.apply(&blip));
        assert!(gate.apply(&supported));
        // Secure fields are never smoothed.
        let mut secure = blip.clone();
        secure.capability = Capability::Blocked(reasons::SECURE);
        assert!(gate.apply(&secure));
        // Another element is never smoothed.
        assert!(gate.apply(&supported));
        let mut other = blip.clone();
        other.focus_key = Some("other".into());
        assert!(gate.apply(&other));
    }

    #[test]
    fn caret_prefers_the_character_before_it() {
        let field = Some(Rect::new(0.0, 0.0, 400.0, 40.0));
        // The previous character's trailing edge wins over a misplaced range.
        let caret = choose_caret(
            Some(Rect::new(100.0, -20.0, 0.0, 18.0)),
            Some(Rect::new(90.0, 10.0, 8.0, 18.0)),
            field,
            false,
        );
        assert_eq!(caret, Some(Rect::new(98.0, 10.0, 0.0, 18.0)));
        // Right to left: the leading edge.
        let caret = choose_caret(None, Some(Rect::new(90.0, 10.0, 8.0, 18.0)), field, true);
        assert_eq!(caret, Some(Rect::new(90.0, 10.0, 0.0, 18.0)));
        // A whole line is not one glyph; a character outside the field with no
        // range to confirm it is not trusted.
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
        assert!(is_collapsed_caret(&Rect::new(5.0, 5.0, 1.0, 16.0)));
        assert!(!is_collapsed_caret(&Rect::new(5.0, 5.0, 788.0, 23.0)));
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
}
