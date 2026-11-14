//! Settings → Personal Context (`PersonalContextSettings`): learned items waiting
//! for review, what LokalBot keeps about the person grouped by kind, the learning
//! switches, and whether agents can read the shared items. Every item can be
//! edited or forgotten here. Nothing reads the saved file until this page opens.

use std::collections::HashSet;

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::{Disableable as _, Sizable as _, WindowExt as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Entity, FontWeight, IntoElement, ParentElement as _,
    Render, SharedString, Styled as _, Window, div, px,
};
use lokalbot_core::Library;
use lokalbot_core::personal::controller::{LoadError, meta_source, saved_automatically};
use lokalbot_core::personal::{
    Claim, ClaimEdit, ClaimKind, EditError, MAX_CHARACTERS, Origin, Sharing, TypedSource,
};
use uuid::Uuid;

use super::{Section, SettingsPage};
use crate::i18n::h_flex;
use crate::state::AppData;
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico, settings_row};

/// Suggestions shown before "Show N more", so kept items stay in view.
const COLLAPSED_SUGGESTION_LIMIT: usize = 5;

/// What the page read, off the main thread.
#[derive(Default)]
struct Loaded {
    load_error: Option<LoadError>,
    suggestions: Vec<Claim>,
    kept: Vec<Claim>,
    access_enabled: bool,
    access_error: Option<String>,
}

#[derive(Default)]
pub(super) struct PersonalState {
    loaded_revision: Option<u64>,
    loaded: Option<Loaded>,
    error: Option<String>,
    show_all_suggestions: bool,
    confirming_dismiss_all: bool,
    confirming_forget_all: bool,
    /// The grant's marker, also read for Privacy & Data.
    pub(super) access_on: bool,
}

fn load(library: &Library) -> Loaded {
    let personal = library.personal();
    // A key that has only just become available opens what was unreadable.
    if personal.load_error().is_some() {
        personal.reload();
    }
    Loaded {
        load_error: personal.load_error(),
        suggestions: personal.suggestions(),
        kept: personal.kept(),
        access_enabled: lokalbot_core::access::personal_context_enabled(library.paths()),
        access_error: personal.access_error(),
    }
}

fn kind_icon(kind: ClaimKind) -> Ico {
    match kind {
        ClaimKind::Fact => Ico::User,
        ClaimKind::Preference => Ico::SlidersHorizontal,
        ClaimKind::Goal => Ico::Star,
        ClaimKind::Principle => Ico::Bookmark,
    }
}

/// `PersonalContextSettings.agentSummary`.
fn agent_summary(shared: usize, access_enabled: bool) -> String {
    if access_enabled {
        return match shared {
            0 => lokalbot_i18n::tr(
                "Personal context access is on, but nothing is shared yet. Choose Share with Agents on an item.",
            )
            .to_string(),
            1 => lokalbot_i18n::tr(
                "Agents can read 1 shared item, when it's relevant to their task.",
            )
            .to_string(),
            _ => lokalbot_i18n::format(
                "Agents can read {0} shared items, when they're relevant to their task.",
                &[("0", shared.to_string())],
            ),
        };
    }
    if shared == 1 {
        lokalbot_i18n::tr("1 item is marked for agents, but personal context access is off.")
            .to_string()
    } else {
        lokalbot_i18n::format(
            "{0} items are marked for agents, but personal context access is off.",
            &[("0", shared.to_string())],
        )
    }
}

/// "Preference · From Claude Code · Oct 22": the kind (in review only, where kept
/// items aren't grouped), where it came from, and the day.
fn meta_line(claim: &Claim, shows_kind: bool, meeting_title: Option<&str>) -> String {
    let mut parts: Vec<String> = Vec::new();
    if shows_kind {
        parts.push(claim.kind.display_name().to_string());
    }
    parts.push(meta_source(claim, meeting_title));
    if saved_automatically(claim) {
        parts.push(lokalbot_i18n::tr("Saved automatically").to_string());
    }
    let local = claim.created_at.with_timezone(&chrono::Local);
    let pattern = if local.date_naive().format("%Y").to_string()
        == chrono::Local::now().format("%Y").to_string()
    {
        "%b %-d"
    } else {
        "%b %-d, %Y"
    };
    parts.push(
        local
            .format_localized(
                lokalbot_i18n::date_pattern(pattern),
                lokalbot_i18n::date_locale(),
            )
            .to_string(),
    );
    parts.join(" · ")
}

fn quote_verb(claim: &Claim) -> &'static str {
    match &claim.origin {
        Origin::Typed {
            source: TypedSource::Dictation { .. },
            ..
        } => lokalbot_i18n::tr("You dictated"),
        Origin::Typed { .. } => lokalbot_i18n::tr("You typed"),
        _ => lokalbot_i18n::tr("You said"),
    }
}

impl SettingsPage {
    /// Items waiting for review and items kept, once read; for the Overview.
    pub(super) fn personal_counts(&self) -> (usize, usize) {
        self.personal.loaded.as_ref().map_or((0, 0), |loaded| {
            (loaded.suggestions.len(), loaded.kept.len())
        })
    }

    /// How many items are marked Share with Agents.
    pub(super) fn shared_personal_items(&self) -> usize {
        self.personal.loaded.as_ref().map_or(0, |loaded| {
            loaded
                .kept
                .iter()
                .chain(&loaded.suggestions)
                .filter(|claim| claim.sharing == Sharing::Agents)
                .count()
        })
    }

    pub(super) fn reload_personal(&mut self, cx: &mut Context<Self>) {
        let revision = self.data.read(cx).revision;
        if self.personal.loaded_revision == Some(revision) {
            return;
        }
        self.personal.loaded_revision = Some(revision);
        let library = self.data.read(cx).library.clone();
        cx.spawn(async move |this, cx| {
            let loaded = cx.background_spawn(async move { load(&library) }).await;
            let _ = this.update(cx, |this, cx| {
                this.personal.access_on = loaded.access_enabled;
                this.personal.loaded = Some(loaded);
                cx.notify();
            });
        })
        .detach();
    }

    /// Runs one edit off the main thread and reports it.
    fn personal_edit(
        &mut self,
        edit: impl FnOnce(&Library) -> Result<(), EditError> + Send + 'static,
        cx: &mut Context<Self>,
    ) {
        let library = self.data.read(cx).library.clone();
        let data = self.data.clone();
        cx.spawn(async move |this, cx| {
            let result = cx.background_spawn(async move { edit(&library) }).await;
            let _ = this.update(cx, |this, cx| {
                this.personal.error = result.err().map(|err| err.message());
                cx.notify();
            });
            data.update(cx, |data, cx| data.mark_library_changed(cx));
        })
        .detach();
    }

    fn meeting_title(&self, claim: &Claim, cx: &App) -> Option<String> {
        let Origin::Learned { meeting_id, .. } = &claim.origin else {
            return None;
        };
        self.data
            .read(cx)
            .meetings
            .iter()
            .find(|m| m.id == *meeting_id)
            .map(|m| m.title.clone())
    }

    fn claim_text(&self, claim: &Claim, meta: String, quote: bool, cx: &App) -> gpui_kit::Div {
        let lb = cx.lb();
        v_flex()
            .flex_1()
            .min_w_0()
            .gap(px(2.))
            .child(
                div()
                    .text_size(ty::BODY)
                    .text_color(lb.text)
                    .child(ui::text::paragraph(SharedString::from(claim.text.clone()))),
            )
            .child(settings_row::help(meta, cx))
            .when_some(claim.quote.clone().filter(|_| quote), |this, said| {
                this.child(
                    h_flex()
                        .gap(px(8.))
                        .pt(px(3.))
                        .items_start()
                        .child(div().w(px(2.)).h(px(16.)).flex_none().bg(lb.separator))
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text_secondary)
                                .child(ui::text::paragraph(SharedString::from(format!(
                                    "{}: “{said}”",
                                    quote_verb(claim)
                                )))),
                        ),
                )
            })
    }

    fn suggestion_row(&self, claim: &Claim, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let id = claim.id;
        let page = cx.entity();
        let meta = meta_line(claim, true, self.meeting_title(claim, cx).as_deref());
        let keep_page = page.clone();
        let dismiss_page = page.clone();
        let menu_claim = claim.clone();
        let data = self.data.clone();
        h_flex()
            .px(px(14.))
            .py(px(10.))
            .gap(px(10.))
            .items_start()
            .child(ui::icon(kind_icon(claim.kind), px(14.), lb.text_secondary))
            .child(self.claim_text(claim, meta, true, cx))
            .child(
                h_flex()
                    .gap(px(6.))
                    .flex_none()
                    .child(
                        Button::new(SharedString::from(format!("personal-keep-{id}")))
                            .outline()
                            .small()
                            .label(lokalbot_i18n::tr("Keep"))
                            .on_click(move |_, _, cx| {
                                keep_page.update(cx, |page, cx| {
                                    page.personal_edit(
                                        move |library| {
                                            library.personal().confirm(&HashSet::from([id]))
                                        },
                                        cx,
                                    )
                                })
                            }),
                    )
                    .child(
                        Button::new(SharedString::from(format!("personal-dismiss-{id}")))
                            .ghost()
                            .small()
                            .label(lokalbot_i18n::tr("Dismiss"))
                            .on_click(move |_, _, cx| {
                                dismiss_page.update(cx, |page, cx| {
                                    page.personal_edit(
                                        move |library| {
                                            library.personal().forget(&HashSet::from([id]))
                                        },
                                        cx,
                                    )
                                })
                            }),
                    )
                    .child(
                        Button::new(SharedString::from(format!("personal-more-{id}")))
                            .ghost()
                            .small()
                            .icon(Ico::Ellipsis)
                            .dropdown_menu(move |menu, _, _| {
                                let edit_claim = menu_claim.clone();
                                let edit_data = data.clone();
                                let mut menu = menu.item(
                                    PopupMenuItem::new(lokalbot_i18n::tr("Edit…")).on_click(
                                        move |_, window, cx| {
                                            ClaimEditor::open(
                                                edit_data.clone(),
                                                Some(edit_claim.clone()),
                                                window,
                                                cx,
                                            )
                                        },
                                    ),
                                );
                                if let Origin::Learned { meeting_id, .. } = &menu_claim.origin {
                                    let meeting = *meeting_id;
                                    let open_data = data.clone();
                                    menu = menu.item(
                                        PopupMenuItem::new(lokalbot_i18n::tr("Open Meeting"))
                                            .on_click(move |_, _, cx| {
                                                crate::ui::action_row::open_meeting(
                                                    &open_data, meeting, None, cx,
                                                );
                                            }),
                                    );
                                }
                                menu
                            }),
                    ),
            )
            .into_any_element()
    }

    fn kept_row(&self, claim: &Claim, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let id = claim.id;
        let page = cx.entity();
        let meta = meta_line(claim, false, self.meeting_title(claim, cx).as_deref());
        let menu_claim = claim.clone();
        let data = self.data.clone();
        let access_on = self.personal.access_on;
        h_flex()
            .px(px(14.))
            .py(px(10.))
            .gap(px(10.))
            .items_center()
            .child(self.claim_text(claim, meta, false, cx))
            .when(claim.always_use, |this| {
                this.child(ui::icon(Ico::Bookmark, px(12.), lb.text_secondary))
            })
            .when(claim.sharing == Sharing::Agents, |this| {
                this.child(
                    div()
                        .px(px(7.))
                        .py(px(1.))
                        .rounded_full()
                        .text_size(ty::CAPTION)
                        .font_weight(FontWeight::MEDIUM)
                        .bg(if access_on {
                            lb.accent_wash
                        } else {
                            lb.chip_fill
                        })
                        .text_color(if access_on {
                            lb.accent_text
                        } else {
                            lb.text_secondary
                        })
                        .child(lokalbot_i18n::tr("Shared")),
                )
            })
            .child(
                Button::new(SharedString::from(format!("personal-actions-{id}")))
                    .ghost()
                    .small()
                    .icon(Ico::Ellipsis)
                    .dropdown_menu(move |mut menu, _, _| {
                        let claim = menu_claim.clone();
                        let id = claim.id;
                        let edit = |edit_page: &Entity<SettingsPage>, change: ClaimEdit| {
                            let edit_page = edit_page.clone();
                            move |_: &gpui_kit::ClickEvent, _: &mut Window, cx: &mut App| {
                                let change = change.clone();
                                edit_page.update(cx, |page, cx| {
                                    page.personal_edit(
                                        move |library| {
                                            library.personal().update(id, change).map(|_| ())
                                        },
                                        cx,
                                    )
                                })
                            }
                        };
                        let edit_data = data.clone();
                        let edit_claim = claim.clone();
                        menu = menu.item(PopupMenuItem::new(lokalbot_i18n::tr("Edit…")).on_click(
                            move |_, window, cx| {
                                ClaimEditor::open(
                                    edit_data.clone(),
                                    Some(edit_claim.clone()),
                                    window,
                                    cx,
                                )
                            },
                        ));
                        menu = menu.item(
                            PopupMenuItem::new(if claim.always_use {
                                lokalbot_i18n::tr("Stop Always Using")
                            } else {
                                lokalbot_i18n::tr("Always Use")
                            })
                            .on_click(edit(
                                &page,
                                ClaimEdit {
                                    always_use: Some(!claim.always_use),
                                    ..Default::default()
                                },
                            )),
                        );
                        let shared = claim.sharing == Sharing::Agents;
                        menu = menu.item(
                            PopupMenuItem::new(if shared {
                                lokalbot_i18n::tr("Stop Sharing with Agents")
                            } else {
                                lokalbot_i18n::tr("Share with Agents")
                            })
                            .on_click(edit(
                                &page,
                                ClaimEdit {
                                    sharing: Some(if shared {
                                        Sharing::LokalBotOnly
                                    } else {
                                        Sharing::Agents
                                    }),
                                    ..Default::default()
                                },
                            )),
                        );
                        if claim.is_learned()
                            && claim.authority != lokalbot_core::personal::Authority::Stated
                            && claim.has_removable_source()
                        {
                            menu = menu.separator();
                            if let Origin::Learned { meeting_id, .. } = &claim.origin {
                                let meeting = *meeting_id;
                                let open_data = data.clone();
                                menu = menu.item(
                                    PopupMenuItem::new(lokalbot_i18n::tr("Open Meeting")).on_click(
                                        move |_, _, cx| {
                                            crate::ui::action_row::open_meeting(
                                                &open_data, meeting, None, cx,
                                            );
                                        },
                                    ),
                                );
                            }
                            let keep_page = page.clone();
                            menu = menu.item(PopupMenuItem::new(claim.keep_label()).on_click(
                                move |_, _, cx| {
                                    keep_page.update(cx, |page, cx| {
                                        page.personal_edit(
                                            move |library| {
                                                library.personal().keep_as_statement(id).map(|_| ())
                                            },
                                            cx,
                                        )
                                    })
                                },
                            ));
                        }
                        menu = menu.separator();
                        let forget_page = page.clone();
                        menu.item(PopupMenuItem::new(lokalbot_i18n::tr("Forget")).on_click(
                            move |_, _, cx| {
                                forget_page.update(cx, |page, cx| {
                                    page.personal_edit(
                                        move |library| {
                                            library.personal().forget(&HashSet::from([id]))
                                        },
                                        cx,
                                    )
                                })
                            },
                        ))
                    }),
            )
            .into_any_element()
    }

    pub(super) fn personal_context_sections(&mut self, cx: &mut Context<Self>) -> Vec<Section> {
        self.reload_personal(cx);
        let settings = self.data.read(cx).settings.clone();
        let lb = cx.lb().clone();
        let page = cx.entity();
        let loaded = self.personal.loaded.take().unwrap_or_default();
        let mut sections = Vec::new();

        let problem = loaded
            .load_error
            .map(|err| err.message().to_string())
            .or_else(|| self.personal.error.clone());
        if let Some(problem) = problem {
            sections.push(
                Section::new(None).row(
                    "settings.personalContext.problem",
                    settings_row::content_row(
                        "settings.personalContext.problem",
                        h_flex()
                            .gap(px(8.))
                            .items_start()
                            .child(ui::icon(Ico::TriangleAlert, px(14.), lb.attention_text))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.attention_text)
                                    .child(ui::text::paragraph(problem)),
                            ),
                        false,
                        cx,
                    ),
                ),
            );
        }

        if !loaded.suggestions.is_empty() {
            let count = loaded.suggestions.len();
            let ids: HashSet<Uuid> = loaded.suggestions.iter().map(|c| c.id).collect();
            let keep_ids = ids.clone();
            let keep_page = page.clone();
            let dismiss_page = page.clone();
            let header = settings_row::stacked_row(
                "settings.personalContext.suggestions",
                lokalbot_i18n::format("To review ({0})", &[("0", count.to_string())]),
                Some(
                    lokalbot_i18n::tr(
                        "Learned from your own words. LokalBot uses them only after you keep them.",
                    )
                    .into(),
                ),
                if self.personal.confirming_dismiss_all {
                    let confirm_page = page.clone();
                    let cancel_page = page.clone();
                    v_flex()
                        .gap(px(6.))
                        .child(settings_row::help(
                            lokalbot_i18n::tr("LokalBot won't suggest them again."),
                            cx,
                        ))
                        .child(
                            h_flex()
                                .gap(px(8.))
                                .child(
                                    Button::new("personal-dismiss-all-confirm")
                                        .danger()
                                        .small()
                                        .label(lokalbot_i18n::tr("Dismiss All"))
                                        .on_click(move |_, _, cx| {
                                            let ids = ids.clone();
                                            confirm_page.update(cx, |page, cx| {
                                                page.personal.confirming_dismiss_all = false;
                                                page.personal_edit(
                                                    move |library| library.personal().forget(&ids),
                                                    cx,
                                                )
                                            })
                                        }),
                                )
                                .child(
                                    Button::new("personal-dismiss-all-cancel")
                                        .outline()
                                        .small()
                                        .label(lokalbot_i18n::tr("Cancel"))
                                        .on_click(move |_, _, cx| {
                                            cancel_page.update(cx, |page, cx| {
                                                page.personal.confirming_dismiss_all = false;
                                                cx.notify();
                                            })
                                        }),
                                ),
                        )
                        .into_any_element()
                } else {
                    h_flex()
                        .gap(px(8.))
                        .child(
                            Button::new("personal-keep-all")
                                .outline()
                                .small()
                                .label(lokalbot_i18n::tr("Keep All"))
                                .on_click(move |_, _, cx| {
                                    let ids = keep_ids.clone();
                                    keep_page.update(cx, |page, cx| {
                                        page.personal_edit(
                                            move |library| library.personal().confirm(&ids),
                                            cx,
                                        )
                                    })
                                }),
                        )
                        .child(
                            Button::new("personal-dismiss-all")
                                .ghost()
                                .small()
                                .label(lokalbot_i18n::tr("Dismiss All"))
                                .on_click(move |_, _, cx| {
                                    dismiss_page.update(cx, |page, cx| {
                                        page.personal.confirming_dismiss_all = true;
                                        cx.notify();
                                    })
                                }),
                        )
                        .into_any_element()
                },
                false,
                cx,
            );
            let mut section =
                Section::new(None).row("settings.personalContext.suggestions", header);
            let show_all = self.personal.show_all_suggestions;
            let shown = if show_all {
                count
            } else {
                count.min(COLLAPSED_SUGGESTION_LIMIT)
            };
            for claim in &loaded.suggestions[..shown] {
                section = section.row(
                    "settings.personalContext.suggestion",
                    self.suggestion_row(claim, cx),
                );
            }
            if count > COLLAPSED_SUGGESTION_LIMIT {
                let more_page = page.clone();
                let label = if show_all {
                    lokalbot_i18n::tr("Show less").to_string()
                } else {
                    lokalbot_i18n::format(
                        "Show {0} more",
                        &[("0", (count - COLLAPSED_SUGGESTION_LIMIT).to_string())],
                    )
                };
                section = section.row(
                    "settings.personalContext.more",
                    h_flex()
                        .justify_center()
                        .py(px(8.))
                        .child(settings_row::link_button(
                            "personal-show-more",
                            label,
                            move |_, cx| {
                                more_page.update(cx, |page, cx| {
                                    page.personal.show_all_suggestions =
                                        !page.personal.show_all_suggestions;
                                    cx.notify();
                                })
                            },
                            cx,
                        )),
                );
            }
            sections.push(section);
        }

        // Kept, grouped by kind.
        let add_data = self.data.clone();
        let unavailable = loaded.load_error.is_some();
        let mut kept = Section::new(lokalbot_i18n::tr("Kept")).row(
            "settings.personalContext.add",
            settings_row::row(
                "settings.personalContext.add",
                match loaded.kept.len() {
                    0 => lokalbot_i18n::tr("Nothing yet").to_string(),
                    1 => lokalbot_i18n::tr("1 item").to_string(),
                    count => lokalbot_i18n::format("{0} items", &[("0", count.to_string())]),
                },
                loaded.kept.is_empty().then(|| {
                    lokalbot_i18n::tr(
                        "Try “Remember that Maya is my manager” or “Remember: answer in bullet points”.",
                    )
                    .into()
                }),
                Button::new("personal-add")
                    .outline()
                    .small()
                    .icon(Ico::Plus)
                    .label(lokalbot_i18n::tr("Add…"))
                    .disabled(unavailable)
                    .on_click(move |_, window, cx| {
                        ClaimEditor::open(add_data.clone(), None, window, cx)
                    }),
                false,
                cx,
            ),
        );
        for kind in ClaimKind::ALL {
            let group: Vec<&Claim> = loaded.kept.iter().filter(|c| c.kind == kind).collect();
            if group.is_empty() {
                continue;
            }
            kept = kept.row(
                "settings.personalContext.group",
                h_flex()
                    .px(px(14.))
                    .pt(px(10.))
                    .gap(px(6.))
                    .items_center()
                    .text_size(ty::CAPTION)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.text_secondary)
                    .child(ui::icon(kind_icon(kind), px(12.), lb.text_secondary))
                    .child(kind.group_title().to_uppercase()),
            );
            for claim in group {
                kept = kept.row("settings.personalContext.claim", self.kept_row(claim, cx));
            }
        }
        sections.push(kept);

        // Learning.
        let learning = settings.personal_learning_enabled && settings.ask_memory_enabled;
        let mut learn = Section::new(lokalbot_i18n::tr("Learning"))
            .row(
                "settings.askMemoryEnabled",
                self.toggle(
                    "settings.askMemoryEnabled",
                    lokalbot_i18n::tr("Remember what I tell Ask"),
                    Some(lokalbot_i18n::tr(
                        "Type “Remember …” in Ask or Quick Recall, or add items here. Ask gives the relevant ones to your Think model with each question.",
                    )),
                    settings.ask_memory_enabled,
                    |s, v| s.ask_memory_enabled = v,
                    cx,
                ),
            )
            .row(
                "settings.personalLearningEnabled",
                self.gated_toggle(
                    "settings.personalLearningEnabled",
                    lokalbot_i18n::tr("Learn about me from my meetings and work"),
                    lokalbot_i18n::tr(
                        "After the overnight review, LokalBot reads your own words from that day: what you said in meetings, and what you typed to coding agents or in Ask. Up to three new facts or goals from meetings are saved. Preferences, items from your typing, and goals or projects your work memory has kept for two weeks wait for your review below. It never learns your principles or values.",
                    ),
                    settings.personal_learning_enabled,
                    settings.ask_memory_enabled,
                    |s, v| s.personal_learning_enabled = v,
                    cx,
                ),
            )
            .row(
                "settings.personalLearningFromDictation",
                self.gated_toggle(
                    "settings.personalLearningFromDictation",
                    lokalbot_i18n::tr("Learn from my dictation"),
                    lokalbot_i18n::tr(
                        "Also reads what you dictate into other apps. LokalBot keeps the words you spoke, encrypted, until that night's learning reads them, and never more than two days. Only text pasted into a field it could identify is kept; excluded apps and websites, private windows, and password fields are skipped. Items from dictation always wait for your review. Turning this off deletes what is kept.",
                    ),
                    settings.personal_learning_from_dictation,
                    learning,
                    |s, v| s.personal_learning_from_dictation = v,
                    cx,
                ),
            );
        if learning && !settings.dreaming_enabled {
            learn = learn.row(
                "settings.personalContext.reviewOff",
                settings_row::content_row(
                    "settings.personalContext.reviewOff",
                    settings_row::help(
                        lokalbot_i18n::tr(
                            "Learning runs after the overnight review, which is off.",
                        ),
                        cx,
                    ),
                    false,
                    cx,
                ),
            );
        }
        sections.push(learn);

        // Agents.
        let shared = loaded
            .kept
            .iter()
            .chain(&loaded.suggestions)
            .filter(|c| c.sharing == Sharing::Agents)
            .count();
        let access_on = self.personal.access_on;
        let detail = (shared > 0 || access_on).then(|| agent_summary(shared, access_on));
        let detail = loaded.access_error.clone().or(detail);
        sections.push(Section::new(lokalbot_i18n::tr("External agents")).row(
            "settings.personalContextAccess",
            self.personal_access_row(detail, cx),
        ));

        // How it works, and forgetting everything.
        let mut details = Section::new(None).row(
            "settings.personalContext.details",
            self.details(
                "settings.personalContext.details",
                lokalbot_i18n::tr("How LokalBot uses this"),
                lokalbot_i18n::tr(
                    "Items stay on this computer, encrypted with the same key as your Ask history. Each question gets the items marked Always use, your principles and preferences, and the facts and goals that share words with it, up to about 2,000 characters. If your Think model is a remote server you approved, they are sent there with the question. External agents (MCP clients and the CLI) read only items you mark Share with Agents, and only while the box above is on. Agent Mode, Autocomplete, exports, and diagnostics never get them. Turning this off stops saving and using them in Ask; forget them here to delete them. Learned items go when you delete or correct the meeting they came from, unless you keep them. Questions limited to some sources or days don't get learned items. A forgotten learned item isn't learned again.",
                ),
                cx,
            ),
        );
        if !loaded.kept.is_empty() || !loaded.suggestions.is_empty() || unavailable {
            details = details.row(
                "settings.personalContext.forgetAll",
                self.forget_all_row(cx),
            );
        }
        sections.push(details);

        self.personal.loaded = Some(loaded);
        sections
    }

    /// The Personal context grant, separate from meeting and screen access. Agents
    /// also need each item marked Share with Agents.
    pub(super) fn personal_access_row(
        &self,
        detail: Option<String>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let access_on = self.personal.access_on;
        let access_data = self.data.clone();
        let access_page = cx.entity();
        settings_row::row(
            "settings.personalContextAccess",
            lokalbot_i18n::tr("What I shared about myself"),
            Some(
                detail
                    .unwrap_or_else(|| {
                        lokalbot_i18n::tr(
                            "MCP clients and the CLI can read items you mark Share with Agents while this is on. Off by default.",
                        )
                        .to_string()
                    })
                    .into(),
            ),
            settings_row::switch(
                "settings.personalContextAccess",
                access_on,
                move |on, _, cx| {
                    let library = access_data.read(cx).library.clone();
                    let data = access_data.clone();
                    let page = access_page.clone();
                    page.update(cx, |page, cx| {
                        page.personal.access_on = on;
                        cx.notify();
                    });
                    cx.spawn(async move |cx| {
                        let result = cx
                            .background_spawn(async move { library.personal().set_access(on) })
                            .await;
                        page.update(cx, |page, cx| {
                            page.personal.error = result.err();
                            cx.notify();
                        });
                        data.update(cx, |data, cx| data.mark_library_changed(cx));
                    })
                    .detach();
                },
            ),
            self.is_focused("settings.personalContextAccess"),
            cx,
        )
        .into_any_element()
    }

    /// A switch that is off and unavailable while what it depends on is off.
    #[allow(clippy::too_many_arguments)]
    fn gated_toggle(
        &self,
        id: &'static str,
        title: &'static str,
        help: &'static str,
        value: bool,
        enabled: bool,
        set: fn(&mut lokalbot_core::Settings, bool),
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let data = self.data.clone();
        settings_row::row(
            id,
            title,
            Some(help.into()),
            settings_row::switch(id, value && enabled, move |checked, _, cx| {
                data.update(cx, |data, cx| data.update_settings(|s| set(s, checked), cx))
            })
            .disabled(!enabled),
            self.is_focused(id),
            cx,
        )
        .into_any_element()
    }

    fn forget_all_row(&self, cx: &mut Context<Self>) -> AnyElement {
        let page = cx.entity();
        if !self.personal.confirming_forget_all {
            return settings_row::row(
                "settings.personalContext.forgetAll",
                lokalbot_i18n::tr("Everything LokalBot remembers about you"),
                None,
                Button::new("personal-forget-all")
                    .danger()
                    .small()
                    .label(lokalbot_i18n::tr("Forget everything…"))
                    .on_click(move |_, _, cx| {
                        page.update(cx, |page, cx| {
                            page.personal.confirming_forget_all = true;
                            cx.notify();
                        })
                    }),
                false,
                cx,
            )
            .into_any_element();
        }
        let confirm_page = page.clone();
        settings_row::stacked_row(
            "settings.personalContext.forgetAll",
            lokalbot_i18n::tr("Forget everything LokalBot remembers about you?"),
            Some(
                lokalbot_i18n::tr(
                    "Deletes every fact, preference, goal, and principle saved here. Your Ask history is kept.",
                )
                .into(),
            ),
            h_flex()
                .gap(px(8.))
                .child(
                    Button::new("personal-forget-all-confirm")
                        .danger()
                        .small()
                        .label(lokalbot_i18n::tr("Forget Everything"))
                        .on_click(move |_, _, cx| {
                            confirm_page.update(cx, |page, cx| {
                                page.personal.confirming_forget_all = false;
                                page.personal_edit(
                                    |library| {
                                        // Dictation not yet read goes too.
                                        if let Err(err) = library.dictation_log().delete_all() {
                                            log::warn!(
                                                "dictation learning log delete failed: {err:#}"
                                            );
                                        }
                                        library.personal().forget_all()
                                    },
                                    cx,
                                )
                            })
                        }),
                )
                .child(
                    Button::new("personal-forget-all-cancel")
                        .outline()
                        .small()
                        .label(lokalbot_i18n::tr("Cancel"))
                        .on_click(move |_, _, cx| {
                            page.update(cx, |page, cx| {
                                page.personal.confirming_forget_all = false;
                                cx.notify();
                            })
                        }),
                ),
            false,
            cx,
        )
        .into_any_element()
    }
}

/// Add or edit one claim (`PersonalClaimEditor`). The dialog stays open with the
/// reason when it can't be saved.
pub(crate) struct ClaimEditor {
    data: Entity<AppData>,
    claim: Option<Claim>,
    text: Entity<InputState>,
    kind: ClaimKind,
    shares: bool,
    error: Option<String>,
    busy: bool,
}

impl ClaimEditor {
    pub(crate) fn open(
        data: Entity<AppData>,
        claim: Option<Claim>,
        window: &mut Window,
        cx: &mut App,
    ) {
        let sheet = cx.new(|cx| {
            let kind = claim.as_ref().map(|c| c.kind).unwrap_or(ClaimKind::Fact);
            let value = claim.as_ref().map(|c| c.text.clone()).unwrap_or_default();
            let text = cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder(crate::i18n::placeholder(kind.placeholder(), window, cx))
                    .default_value(value)
            });
            cx.subscribe_in(&text, window, |_, _, event: &InputEvent, _, cx| {
                if let InputEvent::Change = event {
                    cx.notify();
                }
            })
            .detach();
            Self {
                data,
                shares: claim.as_ref().is_some_and(|c| c.sharing == Sharing::Agents),
                claim,
                text,
                kind,
                error: None,
                busy: false,
            }
        });
        window.open_dialog(cx, move |dialog, _, _| {
            dialog.w(px(460.)).close_button(false).child(sheet.clone())
        });
    }

    fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let text = self.text.read(cx).value().to_string();
        let library = self.data.read(cx).library.clone();
        let kind = self.kind;
        let sharing = if self.shares {
            Sharing::Agents
        } else {
            Sharing::LokalBotOnly
        };
        let claim = self.claim.as_ref().map(|c| c.id);
        let data = self.data.clone();
        self.busy = true;
        cx.notify();
        cx.spawn_in(window, async move |this, cx| {
            let result = cx
                .background_spawn(async move {
                    let personal = library.personal();
                    match claim {
                        Some(id) => personal
                            .update(
                                id,
                                ClaimEdit {
                                    text: Some(text),
                                    kind: Some(kind),
                                    sharing: Some(sharing),
                                    ..Default::default()
                                },
                            )
                            .map(|_| ()),
                        None => {
                            let saved = personal.remember(&text, Some(kind), Origin::Added {})?;
                            if saved.sharing != sharing {
                                personal.update(
                                    saved.id,
                                    ClaimEdit {
                                        sharing: Some(sharing),
                                        ..Default::default()
                                    },
                                )?;
                            }
                            Ok(())
                        }
                    }
                })
                .await;
            let _ = this.update_in(cx, |this, window, cx| {
                this.busy = false;
                match result {
                    Ok(()) => {
                        data.update(cx, |data, cx| data.mark_library_changed(cx));
                        window.close_dialog(cx);
                    }
                    Err(err) => this.error = Some(err.message()),
                }
                cx.notify();
            });
        })
        .detach();
    }
}

impl Render for ClaimEditor {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let typed = self.text.read(cx).value().to_string();
        let count = typed.chars().count();
        let kinds: Vec<&'static str> = ClaimKind::ALL.iter().map(|k| k.display_name()).collect();
        let selected = ClaimKind::ALL
            .iter()
            .position(|k| *k == self.kind)
            .unwrap_or(0);
        let page = cx.entity();
        let share_page = page.clone();
        v_flex()
            .gap(px(14.))
            .child(
                div()
                    .text_size(ty::QUESTION)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.text)
                    .child(if self.claim.is_some() {
                        lokalbot_i18n::tr("Edit")
                    } else {
                        lokalbot_i18n::tr("Add to Personal Context")
                    }),
            )
            .child(settings_row::segmented(
                "personal-editor-kind",
                &kinds,
                selected,
                move |index, _, cx| {
                    page.update(cx, |this, cx| {
                        this.kind = ClaimKind::ALL[index];
                        cx.notify();
                    })
                },
                cx,
            ))
            .child(Input::new(&self.text))
            .child(
                h_flex()
                    .gap(px(10.))
                    .items_center()
                    .child(settings_row::switch(
                        "personal-editor-share",
                        self.shares,
                        move |on, _, cx| {
                            share_page.update(cx, |this, cx| {
                                this.shares = on;
                                cx.notify();
                            })
                        },
                    ))
                    .child(settings_row::help(
                        lokalbot_i18n::tr("Share with Agents"),
                        cx,
                    )),
            )
            .child(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .child(
                        div()
                            .flex_1()
                            .text_size(ty::CAPTION)
                            .text_color(if count > MAX_CHARACTERS {
                                lb.attention_text
                            } else {
                                lb.text_secondary
                            })
                            .child(format!("{count}/{MAX_CHARACTERS}")),
                    )
                    .child(
                        Button::new("personal-editor-cancel")
                            .outline()
                            .label(lokalbot_i18n::tr("Cancel"))
                            .on_click(|_, window, cx| window.close_dialog(cx)),
                    )
                    .child(
                        Button::new("personal-editor-save")
                            .primary()
                            .label(lokalbot_i18n::tr("Save"))
                            .disabled(typed.trim().is_empty() || self.busy)
                            .on_click(cx.listener(|this, _, window, cx| this.save(window, cx))),
                    ),
            )
            .when_some(self.error.clone(), |this, error| {
                this.child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.attention_text)
                        .child(ui::text::paragraph(error)),
                )
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_agent_summary_says_what_is_actually_readable() {
        assert!(agent_summary(0, true).contains("nothing is shared yet"));
        assert!(agent_summary(1, true).contains("1 shared item"));
        assert!(agent_summary(3, true).contains("3 shared items"));
        assert!(agent_summary(1, false).contains("access is off"));
        assert!(agent_summary(2, false).contains("2 items"));
    }
}
