// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

//! "What am I writing in?" (`CotypingSurfaceContext`): the window title
//! carries the email subject, document name, chat channel or page title, the
//! strongest situational cue a small model gets. Left out for code editors
//! and terminals, where app metadata pulls the model toward code.
//!
//! macOS classifies by bundle identifier; here the desktop reports an
//! executable or desktop id ("firefox", "code.exe", "org.gnome.Evolution").

/// `CotypingSurfaceClass`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SurfaceClass {
    CodeEditor,
    Terminal,
    Email,
    Chat,
    Browser,
    Other,
}

impl SurfaceClass {
    /// `CotypingSurfaceClassifier.classify`, by the app's id and then its name.
    pub fn of(app_id: &str, app_name: &str) -> Self {
        let id = normalized_app_id(app_id);
        let name = app_name.trim().to_lowercase();
        for (class, names) in TABLE {
            if names
                .iter()
                .any(|n| *n == id || (!name.is_empty() && *n == name) || dotted_suffix(&id, n))
            {
                return *class;
            }
        }
        if id.starts_with("jetbrains-") || id.starts_with("com.jetbrains.") {
            return SurfaceClass::CodeEditor;
        }
        SurfaceClass::Other
    }
}

/// "Code.exe" → "code", "/usr/bin/firefox" → "firefox",
/// "org.mozilla.firefox.desktop" → "org.mozilla.firefox".
pub(crate) fn normalized_app_id(app_id: &str) -> String {
    let base = app_id
        .trim()
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or_default()
        .to_lowercase();
    let base = base.strip_suffix(".desktop").unwrap_or(&base);
    let base = base.strip_suffix(".exe").unwrap_or(base);
    base.to_string()
}

/// "org.mozilla.firefox" ends with the name "firefox" as its own segment.
fn dotted_suffix(id: &str, name: &str) -> bool {
    id.strip_suffix(name)
        .is_some_and(|rest| rest.ends_with('.') && !name.contains('.'))
}

const TABLE: &[(SurfaceClass, &[&str])] = &[
    (
        SurfaceClass::Terminal,
        &[
            "gnome-terminal",
            "gnome-terminal-server",
            "kgx",
            "org.gnome.console",
            "konsole",
            "xterm",
            "uxterm",
            "urxvt",
            "rxvt",
            "alacritty",
            "kitty",
            "wezterm",
            "wezterm-gui",
            "tilix",
            "terminator",
            "xfce4-terminal",
            "lxterminal",
            "mate-terminal",
            "qterminal",
            "foot",
            "footclient",
            "ghostty",
            "warp",
            "terminology",
            "guake",
            "yakuake",
            "tabby",
            "hyper",
            "contour",
            "blackbox",
            "ptyxis",
            "windowsterminal",
            "wt",
            "cmd",
            "powershell",
            "pwsh",
            "conhost",
            "openconsole",
            "mintty",
            "putty",
        ],
    ),
    (
        SurfaceClass::CodeEditor,
        &[
            "code",
            "code-oss",
            "code-insiders",
            "codium",
            "vscodium",
            "com.visualstudio.code",
            "cursor",
            "windsurf",
            "zed",
            "zeditor",
            "dev.zed.zed",
            "idea",
            "idea64",
            "pycharm",
            "pycharm64",
            "clion",
            "clion64",
            "webstorm",
            "webstorm64",
            "rider",
            "rider64",
            "goland",
            "goland64",
            "rustrover",
            "rustrover64",
            "phpstorm",
            "phpstorm64",
            "datagrip",
            "android-studio",
            "studio64",
            "sublime_text",
            "subl",
            "devenv",
            "neovide",
            "nvim-qt",
            "gvim",
            "emacs",
        ],
    ),
    (
        SurfaceClass::Email,
        &[
            "thunderbird",
            "betterbird",
            "evolution",
            "geary",
            "kmail",
            "kmail2",
            "mailspring",
            "outlook",
            "olk",
            "hxoutlook",
            "claws-mail",
            "sylpheed",
            "mailclient",
        ],
    ),
    (
        SurfaceClass::Chat,
        &[
            "slack",
            "discord",
            "teams",
            "ms-teams",
            "teams-for-linux",
            "telegram",
            "telegram-desktop",
            "org.telegram.desktop",
            "signal",
            "signal-desktop",
            "whatsapp",
            "whatsapp-for-linux",
            "element",
            "element-desktop",
            "im.riot.riot",
            "skype",
            "mattermost",
            "mattermost-desktop",
            "zulip",
            "wire",
            "viber",
        ],
    ),
    (
        SurfaceClass::Browser,
        &[
            "firefox",
            "firefox-esr",
            "librewolf",
            "waterfox",
            "floorp",
            "zen",
            "zen-browser",
            "chrome",
            "google-chrome",
            "google-chrome-stable",
            "chromium",
            "chromium-browser",
            "msedge",
            "microsoft-edge",
            "microsoft-edge-stable",
            "brave",
            "brave-browser",
            "opera",
            "vivaldi",
            "vivaldi-stable",
            "epiphany",
            "org.gnome.epiphany",
            "falkon",
            "konqueror",
            "qutebrowser",
            "thorium",
            "iexplore",
        ],
    ),
];

/// A sanitized surface description (`CotypingSurfaceContext`).
#[derive(Clone, Debug, PartialEq)]
pub struct Surface {
    pub class: SurfaceClass,
    pub app_name: String,
    pub window_title: Option<String>,
}

const MAX_TITLE_LENGTH: usize = 80;

/// Browser and app names Linux and Windows window titles end with
/// ("Inbox - Gmail - Mozilla Firefox"), besides the app's own name.
const TITLE_SUFFIXES: [&str; 12] = [
    "Mozilla Firefox",
    "Firefox",
    "Google Chrome",
    "Chromium",
    "Microsoft Edge",
    "Brave",
    "Vivaldi",
    "Opera",
    "LibreWolf",
    "Mozilla Thunderbird",
    "Thunderbird",
    "Visual Studio Code",
];

/// `CotypingSurfaceComposer.compose`: nil for code editors, terminals, and
/// generic apps with nothing useful to say.
pub fn compose(app_name: &str, app_id: &str, window_title: &str) -> Option<Surface> {
    let class = SurfaceClass::of(app_id, app_name);
    if matches!(class, SurfaceClass::CodeEditor | SurfaceClass::Terminal) {
        return None;
    }
    let app = collapse_whitespace(app_name);
    if app.is_empty() {
        return None;
    }
    let title = sanitized_title(window_title, &app).filter(|t| !is_generic_document_title(t));
    // A generic app with no title has nothing useful to add.
    if class == SurfaceClass::Other && title.is_none() {
        return None;
    }
    Some(Surface {
        class,
        app_name: app,
        window_title: title,
    })
}

/// Conditions on the writing topic. Descriptions of the interface ("text
/// being typed", "the window is titled") pull small models toward talking
/// about buttons and fields instead of continuing the passage.
pub fn preface_lines(surface: &Surface) -> Vec<String> {
    match (&surface.window_title, surface.class) {
        (_, SurfaceClass::CodeEditor | SurfaceClass::Terminal) => Vec::new(),
        (Some(title), SurfaceClass::Email) => vec![format!("Subject: {title}")],
        (Some(title), _) => vec![format!("Topic: {title}")],
        (None, _) => Vec::new(),
    }
}

/// Strips the app-name suffix titles carry ("Inbox - Gmail - Mozilla
/// Firefox", "Notes — Pages"), drops control characters and quotes, and caps
/// the length.
pub fn sanitized_title(raw: &str, app_name: &str) -> Option<String> {
    let mut title = non_empty_cleaned(raw)?;
    let mut suffixes: Vec<&str> = vec![app_name];
    suffixes.extend(TITLE_SUFFIXES);
    // "Notes - Visual Studio Code - Insiders" style titles end in two segments.
    for _ in 0..2 {
        let Some(cut) = suffixes.iter().find_map(|suffix| {
            [" - ", " — ", " – "]
                .iter()
                .find_map(|separator| suffix_start(&title, &format!("{separator}{suffix}")))
        }) else {
            break;
        };
        title.truncate(cut);
    }
    let title = title.trim();
    if title.is_empty() || title.eq_ignore_ascii_case(app_name) {
        return None;
    }
    Some(title.chars().take(MAX_TITLE_LENGTH).collect())
}

/// Where `tail` starts when `title` ends with it (case-insensitively) and
/// something comes before it.
fn suffix_start(title: &str, tail: &str) -> Option<usize> {
    let tail_chars = tail.chars().count();
    let title_chars = title.chars().count();
    if title_chars <= tail_chars {
        return None;
    }
    let (start, _) = title.char_indices().nth(title_chars - tail_chars)?;
    (title[start..].to_lowercase() == tail.to_lowercase()).then_some(start)
}

fn is_generic_document_title(title: &str) -> bool {
    let folded = title.trim().to_lowercase();
    folded == "untitled"
        || folded == "new document"
        || folded == "new tab"
        || folded.starts_with("untitled.")
        || folded.starts_with("untitled ")
}

fn non_empty_cleaned(text: &str) -> Option<String> {
    let cleaned: String = text
        .chars()
        .filter(|c| !super::text::is_control(*c) && *c != '"')
        .collect();
    let cleaned = collapse_whitespace(&cleaned);
    (!cleaned.is_empty()).then_some(cleaned)
}

fn collapse_whitespace(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_linux_and_windows_apps() {
        assert_eq!(
            SurfaceClass::of("gnome-terminal-server", "Terminal"),
            SurfaceClass::Terminal
        );
        assert_eq!(
            SurfaceClass::of("WindowsTerminal.exe", "Terminal"),
            SurfaceClass::Terminal
        );
        assert_eq!(
            SurfaceClass::of("code", "Visual Studio Code"),
            SurfaceClass::CodeEditor
        );
        assert_eq!(SurfaceClass::of("Code.exe", ""), SurfaceClass::CodeEditor);
        assert_eq!(
            SurfaceClass::of("jetbrains-idea", "IntelliJ IDEA"),
            SurfaceClass::CodeEditor
        );
        assert_eq!(
            SurfaceClass::of("org.mozilla.Thunderbird", "Thunderbird"),
            SurfaceClass::Email
        );
        assert_eq!(SurfaceClass::of("olk.exe", "Outlook"), SurfaceClass::Email);
        assert_eq!(
            SurfaceClass::of("com.slack.Slack", "Slack"),
            SurfaceClass::Chat
        );
        assert_eq!(
            SurfaceClass::of("firefox", "Firefox"),
            SurfaceClass::Browser
        );
        assert_eq!(
            SurfaceClass::of("/usr/lib/firefox/firefox", ""),
            SurfaceClass::Browser
        );
        assert_eq!(
            SurfaceClass::of("msedge.exe", "Microsoft Edge"),
            SurfaceClass::Browser
        );
        assert_eq!(
            SurfaceClass::of("org.gnome.TextEditor", "Text Editor"),
            SurfaceClass::Other
        );
        assert_eq!(
            SurfaceClass::of("lokalbot", "LokalBot"),
            SurfaceClass::Other
        );
    }

    #[test]
    fn code_editors_and_terminals_add_nothing() {
        assert_eq!(
            compose("Visual Studio Code", "code", "main.rs - lokalbot"),
            None
        );
        assert_eq!(compose("Terminal", "kgx", "~/src"), None);
        // A generic app without a title has nothing to say.
        assert_eq!(compose("Text Editor", "org.gnome.TextEditor", ""), None);
        assert_eq!(compose("Writer", "soffice", "Untitled 1"), None);
    }

    #[test]
    fn email_titles_become_the_subject_and_others_the_topic() {
        let mail = compose(
            "Thunderbird",
            "thunderbird",
            "Re: Q3 planning - Mozilla Thunderbird",
        )
        .unwrap();
        assert_eq!(preface_lines(&mail), ["Subject: Re: Q3 planning"]);
        let page = compose(
            "Firefox",
            "firefox",
            "Pricing draft - Google Docs — Mozilla Firefox",
        )
        .unwrap();
        assert_eq!(preface_lines(&page), ["Topic: Pricing draft - Google Docs"]);
        let chat = compose("Slack", "slack", "#launch (Channel) - Acme - Slack").unwrap();
        assert_eq!(preface_lines(&chat), ["Topic: #launch (Channel) - Acme"]);
    }

    #[test]
    fn titles_lose_app_suffixes_control_characters_and_quotes() {
        assert_eq!(
            sanitized_title("Inbox - Gmail - Mozilla Firefox", "Firefox").as_deref(),
            Some("Inbox - Gmail")
        );
        // Edge writes its name with a zero-width space, which is dropped first.
        assert_eq!(
            sanitized_title("Plan - Personal - Microsoft\u{200B} Edge", "Microsoft Edge")
                .as_deref(),
            Some("Plan - Personal")
        );
        assert_eq!(
            sanitized_title("\"Quoted\"\u{7} title", "App").as_deref(),
            Some("Quoted title")
        );
        assert_eq!(sanitized_title("Slack", "Slack"), None);
        assert_eq!(sanitized_title(&"x".repeat(120), "App").unwrap().len(), 80);
    }
}
