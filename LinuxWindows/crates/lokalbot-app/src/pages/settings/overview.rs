//! Settings → Overview (`SettingsOverview.swift`), where Settings opens: every
//! feature LokalBot has, whether it is on, and one click to turn it on or open its
//! page. Features that capture or share data open their page instead of turning
//! on here, so their explanation and consent stay where they are.
//!
//! A category in [`super::CATEGORIES`] that no feature below covers gets a card of
//! its own, so a new page shows up here without changing this file.

use gpui_kit::component::Sizable as _;
use gpui_kit::component::button::{Button, ButtonVariant, ButtonVariants as _};
use gpui_kit::component::{Icon, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, Context, FontWeight, Hsla, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, div, px,
};
use lokalbot_core::settings::CotypingAcceptKey;
use lokalbot_core::{ScreenContextMode, Settings};
use lokalbot_platform::autocomplete::Support;

use super::{CATEGORIES, SettingsPage, catalog, category_icon, category_subtitle};
use crate::control::permissions;
use crate::i18n::h_flex;
use crate::state::SettingsCategory;
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico};

/// `AgentReadAccess.Kind`: meetings, screen memory, personal context, files.
const AGENT_READ_KINDS: usize = 4;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Group {
    Memory,
    Assistant,
    Writing,
    Connections,
}

impl Group {
    fn title(self) -> &'static str {
        match self {
            Self::Memory => lokalbot_i18n::tr("Memory"),
            Self::Assistant => lokalbot_i18n::tr("Assistant"),
            Self::Writing => lokalbot_i18n::tr("Writing"),
            Self::Connections => lokalbot_i18n::tr("Connections"),
        }
    }
}

#[derive(Clone)]
enum Status {
    On(String),
    Off(String),
    Attention(String),
}

#[derive(Clone)]
enum Action {
    Open(&'static str),
    TurnOn(fn(&mut Settings)),
}

#[derive(Clone)]
struct Feature {
    id: &'static str,
    group: Group,
    title: &'static str,
    icon: Ico,
    status: Status,
    detail: String,
    page: SettingsCategory,
    focus: Option<&'static str>,
    action: Option<(&'static str, Action)>,
}

fn tr(key: &str) -> String {
    lokalbot_i18n::tr(key).to_string()
}

fn on_off(on: bool) -> Status {
    if on {
        Status::On(tr("On"))
    } else {
        Status::Off(tr("Off"))
    }
}

/// Sharing turns on on its page, beside its explanation; here only its state
/// (`companionStatus`).
fn companion_status(enabled: bool, companion: &lokalbot_engine::CompanionSnapshot) -> Status {
    use lokalbot_engine::CompanionStatus;
    if !enabled {
        return Status::Off(tr("Off"));
    }
    match companion.status {
        CompanionStatus::Failed(_) => Status::Attention(tr("Not available")),
        CompanionStatus::Listening { .. } => Status::On(lokalbot_i18n::format(
            "{0} paired",
            &[("0", companion.devices.len().to_string())],
        )),
        CompanionStatus::Off | CompanionStatus::Starting => Status::On(tr("Starting…")),
    }
}

/// The label of the key that accepts a suggestion.
fn accept_key_label(settings: &Settings) -> String {
    match settings.cotyping_accept_key {
        CotypingAcceptKey::Tab => tr("Tab"),
        CotypingAcceptKey::RightArrow => tr("Right Arrow"),
    }
}

impl SettingsPage {
    fn features(&self, settings: &Settings, cx: &Context<Self>) -> Vec<Feature> {
        let data = self.data.read(cx);
        let mode = settings.screen_context_capture_mode;
        let captures_text = mode != ScreenContextMode::ActivityOnly;
        let routines_on = settings.memory_routines_enabled
            || settings.daily_memory_export_enabled
            || settings.meeting_note_export_enabled;
        let files_shared = self
            .files_access
            .unwrap_or_else(|| lokalbot_core::files::access::is_enabled(data.library.paths()));
        let shared = usize::from(self.meetings_access == Some(true))
            + usize::from(self.screen_access.flatten().is_some())
            + usize::from(self.personal.access_on)
            + usize::from(files_shared);
        let (learned, kept) = self.personal_counts();
        let installed = self.cli_installed == Some(true);
        let autocomplete_status = if !settings.cotyping_enabled {
            Status::Off(tr("Off"))
        } else if matches!(
            lokalbot_platform::autocomplete::support(),
            Support::Unavailable(_)
        ) {
            Status::Attention(tr("Not available"))
        } else {
            Status::On(tr("On"))
        };
        let screen_status = if !settings.tracking_enabled {
            Status::Off(tr("Off"))
        } else if !captures_text {
            Status::Off(tr("Apps only"))
        } else if mode == ScreenContextMode::TextAndVisual
            && data.screen.capture_limitation.is_some()
        {
            Status::Attention(tr("Not available"))
        } else {
            Status::On(tr(mode.label()))
        };
        vec![
            Feature {
                id: "meetings",
                group: Group::Memory,
                title: "Meetings",
                icon: category_icon(SettingsCategory::Meetings),
                status: Status::On(tr("On")),
                detail: tr(settings.auto_record_mode.label()),
                page: SettingsCategory::Meetings,
                focus: None,
                action: None,
            },
            Feature {
                id: "screen",
                group: Group::Memory,
                title: "Screen & Activity",
                icon: category_icon(SettingsCategory::DayMemory),
                status: screen_status,
                detail: tr(if captures_text {
                    "Ask can find what you read on screen."
                } else {
                    "Capture the text on screen, so Ask can find what you read."
                }),
                page: SettingsCategory::DayMemory,
                focus: Some("settings.screenContextCaptureMode"),
                action: (!captures_text)
                    .then_some(("Choose…", Action::Open("settings.screenContextCaptureMode"))),
            },
            Feature {
                id: "files",
                group: Group::Memory,
                title: "Files",
                icon: category_icon(SettingsCategory::Files),
                status: if settings.file_search_enabled {
                    Status::On(lokalbot_i18n::format(
                        "{0} folders",
                        &[("0", settings.file_search_folders.len().to_string())],
                    ))
                } else {
                    Status::Off(tr("Off"))
                },
                detail: tr("Find documents, PDFs, and pictures by what’s in them."),
                page: SettingsCategory::Files,
                focus: Some("settings.fileSearchEnabled"),
                action: (!settings.file_search_enabled)
                    .then_some(("Set Up…", Action::Open("settings.fileSearchEnabled"))),
            },
            Feature {
                id: "askAnywhere",
                group: Group::Assistant,
                title: "Ask anywhere",
                icon: Ico::TextSearch,
                status: on_off(settings.quick_recall_enabled),
                detail: lokalbot_i18n::format(
                    "Press {0} in any app to search your memory or ask a question.",
                    &[("0", settings.quick_recall_shortcut.clone())],
                ),
                page: SettingsCategory::General,
                focus: Some("settings.quickRecallEnabled"),
                action: (!settings.quick_recall_enabled)
                    .then_some(("Turn On", Action::TurnOn(|s| s.quick_recall_enabled = true))),
            },
            Feature {
                id: "selectionActions",
                group: Group::Assistant,
                title: "Selection actions",
                icon: Ico::TextCursor,
                status: on_off(settings.selection_actions_enabled),
                detail: lokalbot_i18n::format(
                    "Select text in any app and press {0} to rewrite, translate, or summarize it.",
                    &[("0", settings.selection_actions_shortcut.clone())],
                ),
                page: SettingsCategory::General,
                focus: Some("settings.selectionActionsEnabled"),
                action: (!settings.selection_actions_enabled).then_some((
                    "Turn On",
                    Action::TurnOn(|s| s.selection_actions_enabled = true),
                )),
            },
            Feature {
                id: "personalContext",
                group: Group::Assistant,
                title: "Personal Context",
                icon: category_icon(SettingsCategory::PersonalContext),
                status: if learned > 0 {
                    Status::Attention(lokalbot_i18n::format(
                        "{0} to review",
                        &[("0", learned.to_string())],
                    ))
                } else {
                    Status::On(lokalbot_i18n::format(
                        "{0} items",
                        &[("0", (learned + kept).to_string())],
                    ))
                },
                detail: tr("What you told LokalBot about yourself, and what it learns."),
                page: SettingsCategory::PersonalContext,
                focus: None,
                action: None,
            },
            Feature {
                id: "overnight",
                group: Group::Assistant,
                title: "Overnight review",
                icon: Ico::Moon,
                status: on_off(settings.dreaming_enabled),
                detail: tr("A morning retrospective of yesterday, on Today."),
                page: SettingsCategory::DayMemory,
                focus: Some("settings.dreamingEnabled"),
                action: (!settings.dreaming_enabled)
                    .then_some(("Turn On", Action::TurnOn(|s| s.dreaming_enabled = true))),
            },
            Feature {
                id: "routines",
                group: Group::Assistant,
                title: "Routines and exports",
                icon: Ico::Download,
                status: on_off(routines_on),
                detail: tr(
                    "Stand-up notes, a weekly log, and notes for Obsidian, written to a folder you choose.",
                ),
                page: SettingsCategory::DayMemory,
                focus: Some("settings.memoryRoutinesEnabled"),
                action: (!routines_on)
                    .then_some(("Set Up…", Action::Open("settings.memoryRoutinesEnabled"))),
            },
            Feature {
                id: "autocomplete",
                group: Group::Writing,
                title: "Autocomplete",
                icon: category_icon(SettingsCategory::Writing),
                status: autocomplete_status,
                detail: tr("Suggestions as you type in other apps, on this PC."),
                page: SettingsCategory::Writing,
                focus: Some("settings.autocompletePreview"),
                action: (!settings.cotyping_enabled).then_some((
                    "Try autocomplete",
                    Action::Open("settings.autocompletePreview"),
                )),
            },
            Feature {
                id: "dictation",
                group: Group::Writing,
                title: "Dictation",
                icon: category_icon(SettingsCategory::Dictation),
                status: on_off(settings.dictation_enabled),
                detail: lokalbot_i18n::format(
                    "Press {0}, speak, and the text lands where you type.",
                    &[("0", settings.dictation_shortcut.clone())],
                ),
                page: SettingsCategory::Dictation,
                focus: Some("settings.dictationEnabled"),
                action: (!settings.dictation_enabled)
                    .then_some(("Turn On", Action::TurnOn(|s| s.dictation_enabled = true))),
            },
            Feature {
                id: "models",
                group: Group::Connections,
                title: "Models",
                icon: category_icon(SettingsCategory::Models),
                status: if data.models.transcription_ready && data.models.think_ready {
                    Status::On(data.inference_label.to_string())
                } else {
                    Status::Attention(tr("Needs Attention"))
                },
                detail: tr("Choose the models behind Transcribe, Think, and Autocomplete."),
                page: SettingsCategory::Models,
                focus: None,
                action: None,
            },
            Feature {
                id: "agents",
                group: Group::Connections,
                title: "External Agents",
                icon: Ico::Terminal,
                status: if shared > 0 {
                    Status::On(lokalbot_i18n::format(
                        "{0} of {1} kinds",
                        &[
                            ("0", shared.to_string()),
                            ("1", AGENT_READ_KINDS.to_string()),
                        ],
                    ))
                } else {
                    Status::Off(tr("Off"))
                },
                detail: tr("Claude, Codex, Cursor, and other agents can read what you allow."),
                page: SettingsCategory::Privacy,
                focus: Some("settings.agentAccess"),
                action: None,
            },
            Feature {
                id: "agentCLI",
                group: Group::Connections,
                title: "Agent CLI",
                icon: Ico::Terminal,
                status: if installed {
                    Status::On(tr("Installed"))
                } else {
                    Status::Off(tr("Not installed"))
                },
                detail: tr("lokalbot-cli and its skill, for coding agents in a terminal."),
                page: SettingsCategory::Advanced,
                focus: Some("settings.agentCLI"),
                action: (!installed).then_some(("Install…", Action::Open("settings.agentCLI"))),
            },
            Feature {
                id: "devices",
                group: Group::Connections,
                title: "Phones & tablets",
                icon: category_icon(SettingsCategory::Devices),
                status: companion_status(settings.companion_sharing_enabled, &data.companion),
                detail: tr("Read your work memory on your own iPhone, iPad, or Android device."),
                page: SettingsCategory::Devices,
                focus: Some("settings.companionSharingEnabled"),
                action: (!settings.companion_sharing_enabled)
                    .then_some(("Set Up…", Action::Open("settings.companionSharingEnabled"))),
            },
        ]
    }

    /// A category no feature card covers. General, Privacy and Advanced stay in
    /// the sidebar, as on the Mac; anything else gets a card here.
    fn category_cards(features: &[Feature]) -> Vec<Feature> {
        CATEGORIES
            .iter()
            .copied()
            .filter(|category| {
                !matches!(
                    category,
                    SettingsCategory::Overview
                        | SettingsCategory::General
                        | SettingsCategory::Privacy
                        | SettingsCategory::Advanced
                ) && !features.iter().any(|feature| feature.page == *category)
            })
            .map(|category| Feature {
                id: catalog::category_key(category),
                group: Group::Memory,
                title: catalog::category_key(category),
                icon: category_icon(category),
                status: Status::On(tr("Settings")),
                detail: category_subtitle(category).to_string(),
                page: category,
                focus: None,
                action: None,
            })
            .collect()
    }

    fn open_feature(
        &mut self,
        page: SettingsCategory,
        focus: Option<&'static str>,
        window: &mut gpui_kit::Window,
        cx: &mut Context<Self>,
    ) {
        match focus {
            Some(id) if catalog::ENTRIES.iter().any(|entry| entry.id == id) => {
                self.reveal(id, window, cx)
            }
            _ => self.select_category(page, window, cx),
        }
    }

    fn render_badge(status: &Status, cx: &Context<Self>) -> impl IntoElement + use<> {
        let lb = cx.lb();
        let (text, color): (String, Hsla) = match status {
            Status::On(text) => (text.clone(), lb.accent_text),
            Status::Off(text) => (text.clone(), lb.text_secondary),
            Status::Attention(text) => (text.clone(), lb.attention_text),
        };
        div()
            .px(px(7.))
            .py(px(2.))
            .rounded_full()
            .bg(color.opacity(0.12))
            .text_size(ty::CAPTION)
            .font_weight(FontWeight::SEMIBOLD)
            .text_color(color)
            .max_w(px(130.))
            .truncate()
            .child(text)
    }

    /// The title opens the feature's page; the bottom row shows its status and
    /// either the one action that turns it on or a link to its settings.
    fn render_card(&self, feature: Feature, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let (page, focus) = (feature.page, feature.focus);
        let id = feature.id;
        let data = self.data.clone();
        let action: AnyElement = match feature.action.clone() {
            Some((title, Action::TurnOn(turn_on))) => {
                Button::new(SharedString::from(format!("overview-{id}-action")))
                    .small()
                    .with_variant(ButtonVariant::Primary)
                    .label(lokalbot_i18n::tr(title))
                    .on_click(move |_, _, cx| {
                        data.update(cx, |data, cx| data.update_settings(turn_on, cx));
                    })
                    .into_any_element()
            }
            Some((title, Action::Open(target))) => {
                Button::new(SharedString::from(format!("overview-{id}-action")))
                    .small()
                    .with_variant(ButtonVariant::Primary)
                    .label(lokalbot_i18n::tr(title))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.open_feature(page, Some(target), window, cx)
                    }))
                    .into_any_element()
            }
            None => Button::new(SharedString::from(format!("overview-{id}-settings")))
                .ghost()
                .small()
                .label(lokalbot_i18n::tr("Settings"))
                .icon(Icon::new(Ico::ChevronRight))
                .on_click(cx.listener(move |this, _, window, cx| {
                    this.open_feature(page, focus, window, cx)
                }))
                .into_any_element(),
        };
        v_flex()
            .id(SharedString::from(format!("overview-{id}")))
            .w(px(214.))
            .gap(px(8.))
            .p(px(12.))
            .rounded(metric::GROUP_RADIUS)
            .bg(lb.group_fill)
            .border_1()
            .border_color(lb.group_stroke)
            .child(
                h_flex()
                    .id(SharedString::from(format!("overview-{id}-open")))
                    .gap(px(9.))
                    .items_center()
                    .cursor_pointer()
                    .child(ui::icon_tile(feature.icon, lb.accent_text, px(28.)))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_size(ty::BODY)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.text)
                            .child(lokalbot_i18n::tr(feature.title)),
                    )
                    .child(ui::icon(Ico::ChevronRight, px(12.), lb.text_secondary))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.open_feature(page, focus, window, cx)
                    })),
            )
            .child(
                div()
                    .min_h(px(34.))
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(ui::text::paragraph(feature.detail)),
            )
            .child(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .child(Self::render_badge(&feature.status, cx))
                    .child(div().flex_1())
                    .child(action),
            )
            .into_any_element()
    }

    fn render_attention(&self, settings: &Settings, cx: &mut Context<Self>) -> Option<AnyElement> {
        let lb = cx.lb().clone();
        let _ = settings;
        let (learned, _) = self.personal_counts();
        let mut items: Vec<AnyElement> = permissions::needs(self.data.read(cx), cx)
            .into_iter()
            .filter(|need| !need.granted && !need.needed_by.is_empty())
            .map(|need| {
                let name = need.name;
                let data = self.data.clone();
                let text = lokalbot_i18n::format(
                    "{0}: {1}",
                    &[("0", need.title.clone()), ("1", need.detail.clone())],
                );
                ui::status_surface(lb.attention, cx)
                    .px(px(12.))
                    .py(px(10.))
                    .child(
                        h_flex()
                            .gap(px(10.))
                            .items_center()
                            .child(ui::icon(Ico::TriangleAlert, px(14.), lb.attention_text))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.text)
                                    .child(ui::text::paragraph(text)),
                            )
                            .child(
                                Button::new(SharedString::from(format!(
                                    "overview-attention-{name}"
                                )))
                                .small()
                                .outline()
                                .label(lokalbot_i18n::tr("Grant…"))
                                .on_click(move |_, _, cx| permissions::request(name, &data, cx)),
                            ),
                    )
                    .into_any_element()
            })
            .collect();
        if learned > 0 {
            items.push(
                ui::status_surface(lb.attention, cx)
                    .px(px(12.))
                    .py(px(10.))
                    .child(
                        h_flex()
                            .gap(px(10.))
                            .items_center()
                            .child(ui::icon(Ico::TriangleAlert, px(14.), lb.attention_text))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.text)
                                    .child(ui::text::paragraph(lokalbot_i18n::format(
                                        "{0} things LokalBot learned about you are waiting for review.",
                                        &[("0", learned.to_string())],
                                    ))),
                            )
                            .child(
                                Button::new("overview-attention-learned")
                                    .small()
                                    .outline()
                                    .label(lokalbot_i18n::tr("Review…"))
                                    .on_click(cx.listener(|this, _, window, cx| {
                                        this.select_category(
                                            SettingsCategory::PersonalContext,
                                            window,
                                            cx,
                                        )
                                    })),
                            ),
                    )
                    .into_any_element(),
            );
        }
        if items.is_empty() {
            return None;
        }
        Some(
            v_flex()
                .w_full()
                .gap(px(8.))
                .child(group_title(lokalbot_i18n::tr("Needs Attention"), cx))
                .children(items)
                .into_any_element(),
        )
    }

    fn render_shortcuts(&self, settings: &Settings, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let rows = [
            (
                "Ask anywhere",
                settings.quick_recall_shortcut.clone(),
                settings.quick_recall_enabled,
                Some(SettingsCategory::General),
            ),
            (
                "Selection actions",
                settings.selection_actions_shortcut.clone(),
                settings.selection_actions_enabled,
                Some(SettingsCategory::General),
            ),
            (
                "Dictation",
                settings.dictation_shortcut.clone(),
                settings.dictation_enabled,
                Some(SettingsCategory::Dictation),
            ),
            (
                "Accept a suggestion",
                accept_key_label(settings),
                settings.cotyping_enabled,
                Some(SettingsCategory::Writing),
            ),
            // Ctrl+K opens Quick Recall inside LokalBot (the palette is retired).
            ("Quick Recall in LokalBot", "Ctrl+K".to_string(), true, None),
        ];
        let count = rows.len();
        let elements: Vec<AnyElement> =
            rows.into_iter()
                .enumerate()
                .map(|(index, (title, keys, on, page))| {
                    let row = h_flex()
                        .id(("overview-shortcut", index))
                        .gap(px(10.))
                        .items_center()
                        .py(px(8.))
                        .child(
                            div()
                                .flex_1()
                                .text_size(ty::BODY)
                                .text_color(if on { lb.text } else { lb.text_secondary })
                                .child(lokalbot_i18n::tr(title)),
                        )
                        .when(!on, |this| {
                            this.child(
                                div()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.text_secondary)
                                    .child(lokalbot_i18n::tr("Off")),
                            )
                        })
                        .child(
                            div()
                                .px(px(7.))
                                .py(px(2.))
                                .rounded(px(5.))
                                .bg(lb.group_fill)
                                .border_1()
                                .border_color(lb.group_stroke)
                                .text_size(ty::SECONDARY)
                                .when(!on, |this| this.opacity(0.55))
                                .child(keys),
                        )
                        .when_some(page, |this, page| {
                            this.cursor_pointer().on_click(cx.listener(
                                move |this, _, window, cx| this.select_category(page, window, cx),
                            ))
                        });
                    v_flex()
                        .child(row)
                        .when(index + 1 < count, |this| {
                            this.child(div().h(px(1.)).bg(lb.separator))
                        })
                        .into_any_element()
                })
                .collect();
        v_flex()
            .w_full()
            .gap(px(8.))
            .child(group_title(lokalbot_i18n::tr("Keyboard shortcuts"), cx))
            .child(
                v_flex()
                    .px(px(12.))
                    .py(px(4.))
                    .rounded(metric::GROUP_RADIUS)
                    .bg(lb.group_fill)
                    .border_1()
                    .border_color(lb.group_stroke)
                    .children(elements),
            )
            .into_any_element()
    }

    pub(super) fn render_overview(&mut self, cx: &mut Context<Self>) -> AnyElement {
        self.reload_personal(cx);
        let settings = self.data.read(cx).settings.clone();
        let features = self.features(&settings, cx);
        let extra = Self::category_cards(&features);
        let mut children: Vec<AnyElement> = Vec::new();
        children.extend(self.render_attention(&settings, cx));
        for group in [
            Group::Memory,
            Group::Assistant,
            Group::Writing,
            Group::Connections,
        ] {
            let cards: Vec<AnyElement> = features
                .iter()
                .filter(|feature| feature.group == group)
                .cloned()
                .map(|feature| self.render_card(feature, cx))
                .collect();
            children.push(
                v_flex()
                    .w_full()
                    .gap(px(8.))
                    .child(group_title(group.title(), cx))
                    .child(
                        h_flex()
                            .flex_wrap()
                            .gap(px(10.))
                            .items_start()
                            .children(cards),
                    )
                    .into_any_element(),
            );
        }
        if !extra.is_empty() {
            let cards: Vec<AnyElement> = extra
                .into_iter()
                .map(|feature| self.render_card(feature, cx))
                .collect();
            children.push(
                v_flex()
                    .w_full()
                    .gap(px(8.))
                    .child(group_title(lokalbot_i18n::tr("More"), cx))
                    .child(
                        h_flex()
                            .flex_wrap()
                            .gap(px(10.))
                            .items_start()
                            .children(cards),
                    )
                    .into_any_element(),
            );
        }
        children.push(self.render_shortcuts(&settings, cx));
        v_flex()
            .id("settings-overview")
            .size_full()
            .items_center()
            .overflow_y_scroll()
            .pt(px(4.))
            .pb(metric::DETAIL_PADDING)
            .child(
                v_flex()
                    .w_full()
                    .max_w(metric::READING_MAX_WIDTH + px(56.))
                    .px(metric::DETAIL_PADDING)
                    .gap(metric::SECTION_SPACING)
                    .children(children),
            )
            .into_any_element()
    }
}

fn group_title(title: &'static str, cx: &Context<SettingsPage>) -> impl IntoElement + use<> {
    let lb = cx.lb();
    div()
        .px(px(4.))
        .text_size(ty::SECTION)
        .font_weight(FontWeight::BOLD)
        .text_color(lb.text)
        .child(title)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_phones_card_follows_the_listener_and_the_pairings() {
        use lokalbot_engine::{CompanionSnapshot, CompanionStatus};
        let text = |status: Status| match status {
            Status::On(text) => format!("on: {text}"),
            Status::Off(text) => format!("off: {text}"),
            Status::Attention(text) => format!("attention: {text}"),
        };
        let snapshot = |status| CompanionSnapshot {
            status,
            ..Default::default()
        };
        assert_eq!(
            text(companion_status(false, &snapshot(CompanionStatus::Off))),
            "off: Off"
        );
        assert_eq!(
            text(companion_status(true, &snapshot(CompanionStatus::Starting))),
            "on: Starting…"
        );
        assert_eq!(
            text(companion_status(
                true,
                &snapshot(CompanionStatus::Listening { port: 4000 })
            )),
            "on: 0 paired"
        );
        assert_eq!(
            text(companion_status(
                true,
                &snapshot(CompanionStatus::Failed("no network".into()))
            )),
            "attention: Not available"
        );
    }

    #[test]
    fn a_category_without_a_feature_card_gets_one_of_its_own() {
        let feature = |page| Feature {
            id: "x",
            group: Group::Memory,
            title: "x",
            icon: Ico::Search,
            status: Status::Off(String::new()),
            detail: String::new(),
            page,
            focus: None,
            action: None,
        };
        // With no feature cards, every category outside the sidebar-only three
        // shows up; a card for a page takes that page out.
        let all = SettingsPage::category_cards(&[]);
        let pages: Vec<SettingsCategory> = all.iter().map(|f| f.page).collect();
        assert!(pages.contains(&SettingsCategory::Meetings));
        assert!(!pages.contains(&SettingsCategory::Overview));
        assert!(!pages.contains(&SettingsCategory::General));
        assert!(!pages.contains(&SettingsCategory::Privacy));
        assert!(!pages.contains(&SettingsCategory::Advanced));
        let fewer = SettingsPage::category_cards(&[feature(SettingsCategory::Meetings)]);
        assert!(!fewer.iter().any(|f| f.page == SettingsCategory::Meetings));
        assert_eq!(fewer.len(), all.len() - 1);
    }
}
