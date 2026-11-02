//! Editable exclusion lists (`ExclusionRulesEditor.swift`): apps or sites that
//! LokalBot never captures or suggests in. Stored comma-separated in settings.

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AppContext as _, Context, Entity, EventEmitter, FontWeight, InteractiveElement as _,
    IntoElement, ParentElement as _, Render, SharedString, StatefulInteractiveElement as _,
    Styled as _, Subscription, Window, div, px,
};

use super::{Ico, icon};
use crate::theme::{LbThemeExt as _, ty};

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum RuleKind {
    Applications,
    /// Capture rules: a URL with a path excludes that URL prefix.
    Domains,
    /// Writing rules: a pasted URL applies to its whole domain.
    WritingDomains,
    /// Folders are stored with commas between them, like the other two, so a
    /// path can't hold one (`ExclusionRulesEditor.folders`).
    Folders,
}

pub enum RuleListEvent {
    /// The new comma-separated value.
    Changed(String),
}

pub struct RuleList {
    title: SharedString,
    kind: RuleKind,
    rules: Vec<String>,
    selected: Option<usize>,
    adding: bool,
    input: Entity<InputState>,
    error: Option<SharedString>,
    _subscription: Subscription,
}

impl EventEmitter<RuleListEvent> for RuleList {}

impl RuleList {
    pub fn new(
        title: &str,
        kind: RuleKind,
        value: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let placeholder = match kind {
            RuleKind::Applications => "Application name",
            RuleKind::Domains | RuleKind::WritingDomains => {
                "example.com or https://example.com/private"
            }
            RuleKind::Folders => "~/Code/client-project",
        };
        let input = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::i18n::placeholder(
                placeholder,
                window,
                cx,
            ))
        });
        let subscription = cx.subscribe_in(
            &input,
            window,
            |this, _, event: &InputEvent, window, cx| match event {
                InputEvent::PressEnter { .. } => this.add(window, cx),
                InputEvent::Change if this.error.take().is_some() => cx.notify(),
                _ => {}
            },
        );
        Self {
            title: title.to_string().into(),
            kind,
            rules: lokalbot_core::settings::split_list(value),
            selected: None,
            adding: false,
            input,
            error: None,
            _subscription: subscription,
        }
    }

    /// Follows a change made elsewhere.
    pub fn set_value(&mut self, value: &str, cx: &mut Context<Self>) {
        let rules = lokalbot_core::settings::split_list(value);
        if rules != self.rules {
            self.rules = rules;
            self.selected = None;
            cx.notify();
        }
    }

    fn commit(&mut self, cx: &mut Context<Self>) {
        cx.emit(RuleListEvent::Changed(self.rules.join(", ")));
        cx.notify();
    }

    fn add(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let candidate = self.input.read(cx).value().trim().to_string();
        if let Some(problem) = validate(&candidate, self.kind, &self.rules) {
            self.error = Some(problem.into());
            cx.notify();
            return;
        }
        self.rules.push(candidate);
        self.adding = false;
        self.error = None;
        self.input
            .update(cx, |input, cx| input.set_value("", window, cx));
        self.commit(cx);
    }

    /// "Choose App…" and "Choose Folder…": the file picker's choice goes
    /// through the same checks as typing it, and any failure is shown.
    fn choose(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let folders = self.kind == RuleKind::Folders;
        let receiver = cx.prompt_for_paths(gpui_kit::PathPromptOptions {
            files: !folders,
            directories: folders,
            multiple: false,
            prompt: Some(
                if folders {
                    lokalbot_i18n::tr("Choose a folder to exclude")
                } else {
                    lokalbot_i18n::tr("Choose an application to exclude")
                }
                .into(),
            ),
        });
        cx.spawn_in(window, async move |this, cx| {
            let chosen = receiver.await;
            let _ = this.update_in(cx, |this, window, cx| {
                match chosen {
                    Ok(Ok(Some(paths))) => {
                        let Some(path) = paths.first() else { return };
                        let rule = if folders {
                            folder_rule(path)
                        } else {
                            application_rule(path)
                        };
                        this.input
                            .update(cx, |input, cx| input.set_value(rule, window, cx));
                        this.add(window, cx);
                    }
                    Ok(Ok(None)) => {}
                    Ok(Err(err)) => {
                        this.error = Some(
                            lokalbot_i18n::format(
                                "The file picker could not open: {err}. Add the rule with +.",
                                &[("err", format!("{err:#}"))],
                            )
                            .into(),
                        );
                        cx.notify();
                    }
                    Err(_) => {}
                };
            });
        })
        .detach();
    }

    fn remove_selected(&mut self, cx: &mut Context<Self>) {
        if let Some(index) = self.selected.take()
            && index < self.rules.len()
        {
            self.rules.remove(index);
            self.commit(cx);
        }
    }
}

/// Why a rule cannot be added, if it cannot.
pub fn validate(candidate: &str, kind: RuleKind, existing: &[String]) -> Option<&'static str> {
    if candidate.is_empty() || candidate.contains(',') {
        return Some(lokalbot_i18n::tr("Add one rule at a time."));
    }
    if matches!(kind, RuleKind::Domains | RuleKind::WritingDomains) && !is_domain_rule(candidate) {
        return Some(lokalbot_i18n::tr(
            "Enter a domain or an HTTP(S) URL prefix. Existing rules remain unchanged.",
        ));
    }
    if kind == RuleKind::Folders && !is_folder_rule(candidate) {
        return Some(if cfg!(windows) {
            lokalbot_i18n::tr(
                "Enter a folder path such as C:\\Code\\client or ~\\client. Existing rules remain unchanged.",
            )
        } else {
            lokalbot_i18n::tr(
                "Enter a folder path starting with / or ~. Existing rules remain unchanged.",
            )
        });
    }
    if existing
        .iter()
        .any(|rule| rule.eq_ignore_ascii_case(candidate))
    {
        return Some(lokalbot_i18n::tr("This rule is already excluded."));
    }
    None
}

/// Rules saved before these checks, or typed into a settings file, stay until
/// removed, and say so (`ExclusionRulesEditor.isValid`).
fn is_valid_rule(rule: &str, kind: RuleKind) -> bool {
    match kind {
        RuleKind::Applications => true,
        RuleKind::Folders => is_folder_rule(rule),
        RuleKind::Domains | RuleKind::WritingDomains => is_domain_rule(rule),
    }
}

/// `~/…` for a folder under the home folder, as the Mac abbreviates it.
fn folder_rule(path: &std::path::Path) -> String {
    let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .map(std::path::PathBuf::from);
    abbreviated(path, home.as_deref())
}

fn abbreviated(path: &std::path::Path, home: Option<&std::path::Path>) -> String {
    match home.and_then(|home| path.strip_prefix(home).ok()) {
        Some(rest) if rest.as_os_str().is_empty() => "~".to_string(),
        Some(rest) => std::path::Path::new("~").join(rest).display().to_string(),
        None => path.display().to_string(),
    }
}

/// What an excluded app is matched by. A window's name changes with the
/// language, so a launcher's window class or command wins over it, and a
/// Windows program is known by its file name.
fn application_rule(path: &std::path::Path) -> String {
    let stem = path
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default();
    let extension = path
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    match extension.as_str() {
        "desktop" => std::fs::read_to_string(path)
            .ok()
            .and_then(|text| desktop_entry_rule(&text))
            .unwrap_or(stem),
        "exe" => format!("{}.exe", stem.to_lowercase()),
        _ => stem,
    }
}

/// `StartupWMClass`, else the program `Exec` runs.
fn desktop_entry_rule(text: &str) -> Option<String> {
    let mut in_entry = false;
    let mut class = None;
    let mut exec = None;
    for line in text.lines().map(str::trim) {
        if line.starts_with('[') {
            in_entry = line == "[Desktop Entry]";
            continue;
        }
        if !in_entry {
            continue;
        }
        if let Some(value) = line.strip_prefix("StartupWMClass=") {
            class = Some(value.trim().to_string());
        } else if let Some(value) = line.strip_prefix("Exec=") {
            exec = value
                .split_whitespace()
                .find(|word| *word != "env" && !word.contains('='))
                .and_then(|program| program.rsplit('/').next())
                .map(str::to_string);
        }
    }
    class.or(exec).filter(|rule| !rule.is_empty())
}

fn is_folder_rule(candidate: &str) -> bool {
    let bytes = candidate.as_bytes();
    candidate.starts_with('/')
        || candidate.starts_with('~')
        || candidate.starts_with("\\\\")
        || (bytes.len() >= 3
            && bytes[0].is_ascii_alphabetic()
            && bytes[1] == b':'
            && matches!(bytes[2], b'/' | b'\\'))
}

fn is_domain_rule(candidate: &str) -> bool {
    if candidate.contains(char::is_whitespace) {
        return false;
    }
    let with_scheme = if candidate.contains("://") {
        candidate.to_string()
    } else {
        format!("https://{candidate}")
    };
    let Some((scheme, rest)) = with_scheme.split_once("://") else {
        return false;
    };
    let host = rest.split(['/', '?', '#']).next().unwrap_or_default();
    matches!(scheme.to_ascii_lowercase().as_str(), "http" | "https")
        && host.contains('.')
        && !host.starts_with('.')
}

impl Render for RuleList {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let (glyph, kind_label) = match self.kind {
            RuleKind::Applications => (Ico::LayoutGrid, lokalbot_i18n::tr("App")),
            RuleKind::Domains | RuleKind::WritingDomains => {
                (Ico::Globe, lokalbot_i18n::tr("Domain / URL"))
            }
            RuleKind::Folders => (Ico::Folder, lokalbot_i18n::tr("Folder")),
        };
        let rows: Vec<_> = self
            .rules
            .iter()
            .enumerate()
            .map(|(index, rule)| {
                let selected = self.selected == Some(index);
                let valid = is_valid_rule(rule, self.kind);
                h_flex()
                    .id(("rule", index))
                    .gap(px(8.))
                    .items_center()
                    .px(px(10.))
                    .py(px(5.))
                    .cursor_pointer()
                    .when(selected, |this| this.bg(lb.accent_wash))
                    .when(!selected, |this| this.hover(|s| s.bg(lb.hover)))
                    .child(icon(glyph, px(14.), lb.text_secondary))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_size(ty::BODY)
                            .text_color(lb.text)
                            .child(rule.clone()),
                    )
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(kind_label),
                    )
                    .when(!valid, |this| {
                        this.child(
                            div()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.attention_text)
                                .child(lokalbot_i18n::tr("Legacy rule · review")),
                        )
                    })
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.selected = if this.selected == Some(index) {
                            None
                        } else {
                            Some(index)
                        };
                        cx.notify();
                    }))
            })
            .collect();
        let empty = rows.is_empty();
        v_flex()
            .w_full()
            .gap(px(8.))
            .child(div().text_size(ty::SECONDARY).font_weight(FontWeight::SEMIBOLD).text_color(lb.text).child(crate::ui::text::paragraph(lokalbot_i18n::tr(&self.title).to_string())))
            .child(
                v_flex()
                    .w_full()
                    .rounded(px(8.))
                    .border_1()
                    .border_color(lb.separator)
                    .bg(lb.elevated)
                    .overflow_hidden()
                    .py(px(2.))
                    .children(rows)
                    .when(empty, |this| {
                        this.child(div().px(px(10.)).py(px(6.)).text_size(ty::SECONDARY).text_color(lb.text_secondary).child(crate::ui::text::paragraph(lokalbot_i18n::tr("No exclusions"))))
                    }),
            )
            .child(
                h_flex()
                    .gap(px(6.))
                    .child(
                        Button::new("rule-add")
                            .outline()
                            .xsmall()
                            .icon(Icon::new(Ico::Plus))
                            .tooltip(lokalbot_i18n::tr("Add Exclusion…"))
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.adding = true;
                                this.error = None;
                                this.input.update(cx, |input, cx| input.focus(window, cx));
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new("rule-remove")
                            .outline()
                            .xsmall()
                            .icon(Icon::new(Ico::Minus))
                            .tooltip(lokalbot_i18n::tr("Remove Selected Exclusion"))
                            .disabled(self.selected.is_none())
                            .on_click(cx.listener(|this, _, _, cx| this.remove_selected(cx))),
                    )
                    .child(div().flex_1())
                    .when(
                        matches!(self.kind, RuleKind::Applications | RuleKind::Folders),
                        |this| {
                            this.child(
                                Button::new("rule-choose")
                                    .outline()
                                    .xsmall()
                                    .label(if self.kind == RuleKind::Folders {
                                        lokalbot_i18n::tr("Choose Folder…")
                                    } else {
                                        lokalbot_i18n::tr("Choose App…")
                                    })
                                    .on_click(
                                        cx.listener(|this, _, window, cx| this.choose(window, cx)),
                                    ),
                            )
                        },
                    ),
            )
            .when(self.adding, |this| {
                this.child(
                    h_flex()
                        .gap(px(6.))
                        .items_center()
                        .child(div().flex_1().min_w_0().child(Input::new(&self.input).small()))
                        .child(Button::new("rule-cancel").outline().small().label(lokalbot_i18n::tr("Cancel")).on_click(cx.listener(
                            |this, _, window, cx| {
                                this.adding = false;
                                this.error = None;
                                this.input.update(cx, |input, cx| input.set_value("", window, cx));
                                cx.notify();
                            },
                        )))
                        .child(
                            Button::new("rule-confirm")
                                .primary()
                                .small()
                                .label(lokalbot_i18n::tr("Add"))
                                .on_click(cx.listener(|this, _, window, cx| this.add(window, cx))),
                        ),
                )
            })
            .when_some(self.error.clone(), |this, error| {
                this.child(div().text_size(ty::SECONDARY).text_color(lb.attention_text).child(error))
            })
            .when(self.kind == RuleKind::WritingDomains, |this| {
                this.child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Matches this domain and its subdomains. A pasted URL applies to its whole domain."))),
                )
            })
            .when(self.kind == RuleKind::Domains, |this| {
                this.child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr("A domain excludes its subdomains too. A URL with a path excludes that URL prefix. Existing rules are kept until you remove them."))),
                )
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_rules() {
        let existing = vec!["1Password".to_string()];
        assert_eq!(
            validate("1password", RuleKind::Applications, &existing),
            Some("This rule is already excluded.")
        );
        assert_eq!(
            validate("a, b", RuleKind::Applications, &existing),
            Some("Add one rule at a time.")
        );
        assert!(validate("bank.example.com", RuleKind::Domains, &[]).is_none());
        assert!(validate("https://mail.example.com/private", RuleKind::Domains, &[]).is_none());
        assert!(validate("localhost", RuleKind::Domains, &[]).is_some());
        assert!(validate("ftp://x.y", RuleKind::Domains, &[]).is_some());
        assert!(validate("~/work", RuleKind::Folders, &[]).is_none());
        assert!(validate("/opt/secret", RuleKind::Folders, &[]).is_none());
        assert!(validate(r"C:\Work", RuleKind::Folders, &[]).is_none());
        assert!(validate(r"\\server\share", RuleKind::Folders, &[]).is_none());
        assert!(validate("relative/path", RuleKind::Folders, &[]).is_some());
        assert!(validate("/a,b", RuleKind::Folders, &[]).is_some());
    }

    #[test]
    fn older_rules_are_flagged_not_dropped() {
        assert!(is_valid_rule("anything", RuleKind::Applications));
        assert!(is_valid_rule("~/work", RuleKind::Folders));
        assert!(!is_valid_rule("relative/path", RuleKind::Folders));
        assert!(is_valid_rule("example.com", RuleKind::Domains));
        assert!(!is_valid_rule("not a domain", RuleKind::Domains));
        assert!(!is_valid_rule("localhost", RuleKind::WritingDomains));
    }

    #[test]
    fn folders_abbreviate_home() {
        use std::path::Path;
        let home = Path::new("/home/ana");
        let rule = |p: &Path| abbreviated(p, Some(home));
        // Each platform's own separator: a rule reads like the paths around it.
        let inside = Path::new("~").join("Code").join("x");
        assert_eq!(
            rule(&home.join("Code").join("x")),
            inside.display().to_string()
        );
        assert_eq!(rule(home), "~");
        assert_eq!(rule(Path::new("/opt/secret")), "/opt/secret");
    }

    #[test]
    fn launchers_name_their_window_class_or_program() {
        let entry = "[Desktop Entry]\nName=Rechner\nExec=env GDK_BACKEND=x11 /usr/bin/gnome-calculator %U\nStartupWMClass=gnome-calculator-win\n[Desktop Action New]\nExec=other\n";
        assert_eq!(
            desktop_entry_rule(entry).as_deref(),
            Some("gnome-calculator-win")
        );
        let plain = "[Desktop Entry]\nName=Slack\nExec=/usr/bin/slack --gpu %U\n";
        assert_eq!(desktop_entry_rule(plain).as_deref(), Some("slack"));
        assert_eq!(desktop_entry_rule("[Other]\nExec=x\n"), None);
        assert_eq!(
            application_rule(std::path::Path::new("C:/Apps/Thing.EXE")),
            "thing.exe"
        );
        assert_eq!(
            application_rule(std::path::Path::new("/opt/Tool.AppImage")),
            "Tool"
        );
    }
}
