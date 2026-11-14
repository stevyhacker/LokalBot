//! Setup, step 1 (`OnboardingChooseStep.swift`): what LokalBot does, that it
//! stays on this computer, and the choices, each with its one real option.

use crate::i18n::h_flex;
use gpui_kit::component::button::Button;
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::switch::Switch;
use gpui_kit::component::{Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    Context, Div, FontWeight, IntoElement, ParentElement as _, SharedString, Styled as _, div, img,
    px,
};
use lokalbot_core::ScreenContextMode;
use lokalbot_core::settings::AutoRecordMode;

use super::{DETECTED_CALL_MODES, Onboarding, card, note, quiet, row};
use crate::state::PrivacyLine;
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico};

/// The option's name in setup's "When a call starts" menu.
fn meeting_mode_title(mode: AutoRecordMode) -> &'static str {
    match mode {
        AutoRecordMode::Automatic => lokalbot_i18n::tr("Record automatically"),
        AutoRecordMode::Ask => lokalbot_i18n::tr("Ask me first"),
        AutoRecordMode::Manual => lokalbot_i18n::tr("Never auto-record"),
    }
}

/// What the chosen option means: the menu's tooltip.
fn meeting_mode_detail(mode: AutoRecordMode) -> &'static str {
    match mode {
        AutoRecordMode::Automatic => lokalbot_i18n::tr("Starts as soon as a call begins"),
        AutoRecordMode::Ask => lokalbot_i18n::tr("A notification lets you start it"),
        AutoRecordMode::Manual => lokalbot_i18n::tr("Records only when you press Record."),
    }
}

/// The option's name in setup's "Keeps" menu.
fn context_mode_title(mode: ScreenContextMode) -> &'static str {
    match mode {
        ScreenContextMode::ActivityOnly => lokalbot_i18n::tr("App names only"),
        ScreenContextMode::Text => lokalbot_i18n::tr("Text on screen"),
        ScreenContextMode::TextAndVisual => lokalbot_i18n::tr("Text and screenshots"),
    }
}

/// What is kept, on its own line under the menu.
fn context_mode_detail(mode: ScreenContextMode) -> &'static str {
    match mode {
        ScreenContextMode::ActivityOnly => lokalbot_i18n::tr("The app and the window title"),
        ScreenContextMode::Text => lokalbot_i18n::tr("Readable text, no screenshots"),
        ScreenContextMode::TextAndVisual => {
            lokalbot_i18n::tr("Screenshots are encrypted on this PC")
        }
    }
}

/// The retention sentence under the choices, for every workday choice. The
/// port's wording, because it differs from the Mac: private windows' text
/// and images are never captured here.
fn retention_note(mode: ScreenContextMode, retention_days: u32) -> String {
    let retention = match retention_days {
        1 => lokalbot_i18n::tr("1 day").to_string(),
        days => lokalbot_i18n::format("{days} days", &[("days", days.to_string())]),
    };
    if mode == ScreenContextMode::ActivityOnly {
        lokalbot_i18n::format(
            "Day Memory notes the app in front and its window title, never what you type or what is on screen. Window titles are cleared after {retention}; you can change this in Settings → Privacy & Data.",
            &[("retention", retention)],
        )
    } else {
        lokalbot_i18n::format(
            "Text and images build on app activity. Images are encrypted on disk; captured text remains searchable under your retention policy ({retention}), and passwords, excluded apps and private windows are never captured.",
            &[("retention", retention)],
        )
    }
}

impl Onboarding {
    pub(super) fn render_choose(&self, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let draft = self.draft;
        let (everything_local, retention_days) = {
            let data = self.data.read(cx);
            (
                data.privacy == PrivacyLine::Local,
                data.settings.retention_days,
            )
        };
        let page = cx.entity();

        let welcome = v_flex()
            .w_full()
            .items_center()
            .gap(px(5.))
            .child(img("brand/lokalbot.svg").size(px(52.)))
            .child(
                div()
                    .text_center()
                    .text_size(px(23.))
                    .font_weight(FontWeight::BOLD)
                    .text_color(lb.text)
                    .child(ui::text::paragraph(lokalbot_i18n::tr("Welcome to LokalBot"))),
            )
            .child(
                div()
                    .max_w(px(480.))
                    .text_center()
                    .text_size(px(13.5))
                    .line_height(px(19.))
                    .text_color(lb.text_secondary)
                    .child(ui::text::paragraph(lokalbot_i18n::tr(
                        "LokalBot takes notes in your meetings and remembers what you worked on, so you can search it or ask about it later.",
                    ))),
            )
            .child(
                // A server set up before setup was reopened is named for what it is.
                h_flex()
                    .pt(px(2.))
                    .gap(px(6.))
                    .items_center()
                    .justify_center()
                    .child(ui::icon(Ico::Lock, px(13.), lb.accent_text))
                    .child(
                        div()
                            .text_size(px(13.))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(lb.accent_text)
                            .child(ui::text::paragraph(lokalbot_i18n::tr(if everything_local {
                                "Everything is processed and stored on this PC. No account needed."
                            } else {
                                "Local models process on this PC. Each remote server requires its own approval before context can leave the PC."
                            }))),
                    ),
            );

        let meeting_page = page.clone();
        let meeting_switch_page = page.clone();
        let meeting_option = if draft.records_detected_calls() {
            let mode = draft.meeting_mode;
            option(
                lokalbot_i18n::tr("When a call starts"),
                Button::new("onboarding-meeting-mode")
                    .outline()
                    .small()
                    .label(meeting_mode_title(mode))
                    .dropdown_caret(true)
                    .tooltip(meeting_mode_detail(mode))
                    .dropdown_menu(move |mut menu, _, _| {
                        for choice in DETECTED_CALL_MODES {
                            let page = meeting_page.clone();
                            menu = menu.item(
                                PopupMenuItem::new(meeting_mode_title(choice))
                                    .checked(choice == mode)
                                    .on_click(move |_, _, cx| {
                                        page.update(cx, |this, cx| {
                                            this.set_draft(|d| d.set_meeting_mode(choice), cx)
                                        })
                                    }),
                            );
                        }
                        menu
                    })
                    .into_any_element(),
                None,
                cx,
            )
        } else {
            div().pt(px(6.)).child(quiet(
                lokalbot_i18n::tr("Records only when you press Record."),
                cx,
            ))
        };
        let meeting_notes = row(
            Ico::Mic,
            true,
            v_flex()
                .gap(px(2.))
                .child(row_name(lokalbot_i18n::tr("Meeting notes"), cx))
                .child(quiet(
                    lokalbot_i18n::tr(
                        "Notes and action items from your Zoom, Teams, Meet and Webex calls.",
                    ),
                    cx,
                ))
                .child(meeting_option),
            Some(
                Switch::new("onboarding-meeting-notes")
                    .checked(draft.records_detected_calls())
                    .on_click(move |on, _, cx| {
                        let on = *on;
                        meeting_switch_page.update(cx, |this, cx| {
                            this.set_draft(|d| d.set_records_detected_calls(on), cx)
                        })
                    })
                    .into_any_element(),
            ),
            cx,
        );

        let context_page = page.clone();
        let memory_page = page.clone();
        let workday_option = draft.day_memory.then(|| {
            let mode = draft.context_mode;
            option(
                lokalbot_i18n::tr("Keeps"),
                Button::new("onboarding-context-mode")
                    .outline()
                    .small()
                    .label(context_mode_title(mode))
                    .dropdown_caret(true)
                    .dropdown_menu(move |mut menu, _, _| {
                        for choice in ScreenContextMode::ALL {
                            let page = context_page.clone();
                            menu = menu.item(
                                PopupMenuItem::new(context_mode_title(choice))
                                    .checked(choice == mode)
                                    .on_click(move |_, _, cx| {
                                        page.update(cx, |this, cx| {
                                            this.set_draft(|d| d.context_mode = choice, cx)
                                        })
                                    }),
                            );
                        }
                        menu
                    })
                    .into_any_element(),
                Some(context_mode_detail(mode)),
                cx,
            )
        });
        let workday = row(
            Ico::AppWindow,
            true,
            v_flex()
                .gap(px(2.))
                .child(row_name(lokalbot_i18n::tr("Your workday"), cx))
                .child(quiet(
                    lokalbot_i18n::tr(
                        "The apps you use and the text on screen, for search and a daily summary.",
                    ),
                    cx,
                ))
                .children(workday_option),
            Some(
                Switch::new("onboarding-day-memory")
                    .checked(draft.day_memory)
                    .on_click(move |on, _, cx| {
                        let on = *on;
                        memory_page.update(cx, |this, cx| this.set_draft(|d| d.day_memory = on, cx))
                    })
                    .into_any_element(),
            ),
            cx,
        );

        let agents_page = page.clone();
        let coding_agents = row(
            Ico::SquareTerminal,
            false,
            v_flex()
                .gap(px(2.))
                .child(row_name(lokalbot_i18n::tr("Coding agent sessions"), cx))
                .child(quiet(
                    lokalbot_i18n::tr(
                        "Read your Claude Code and Codex sessions so LokalBot remembers what your agents did. Files stay on this computer.",
                    ),
                    cx,
                )),
            Some(
                Switch::new("onboarding-coding-agents")
                    .checked(draft.coding_agent_sessions)
                    .on_click(move |on, _, cx| {
                        let on = *on;
                        agents_page.update(cx, |this, cx| {
                            this.set_draft(|d| d.coding_agent_sessions = on, cx)
                        })
                    })
                    .into_any_element(),
            ),
            cx,
        );

        v_flex()
            .w_full()
            .gap(px(16.))
            .child(welcome)
            .child(
                v_flex()
                    .w_full()
                    .gap(px(10.))
                    .child(
                        div()
                            .px(px(2.))
                            .text_size(ty::SECTION)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.text)
                            .child(ui::text::paragraph(lokalbot_i18n::tr(
                                "What should LokalBot remember?",
                            ))),
                    )
                    .child(
                        card(cx)
                            .child(meeting_notes)
                            .child(ui::divider(cx))
                            .child(workday)
                            .child(ui::divider(cx))
                            .child(coding_agents),
                    ),
            )
            // Shown for every workday choice: it is what the person agrees to
            // before picking more.
            .when(draft.day_memory, |this| {
                this.child(note(
                    Ico::Lock,
                    retention_note(draft.context_mode, retention_days),
                    cx,
                ))
            })
    }
}

/// A row's bold name.
fn row_name(title: &'static str, cx: &gpui_kit::App) -> Div {
    div()
        .text_size(ty::BODY)
        .font_weight(FontWeight::SEMIBOLD)
        .text_color(cx.lb().text)
        .child(ui::text::paragraph(title))
}

/// The one option a choice has, on its own line under the description, with
/// what the chosen option keeps under it when that matters.
fn option(
    label: &'static str,
    control: gpui_kit::AnyElement,
    meaning: Option<&'static str>,
    cx: &gpui_kit::App,
) -> Div {
    let lb = cx.lb();
    v_flex()
        .pt(px(6.))
        .gap(px(4.))
        .child(
            h_flex()
                .gap(px(8.))
                .items_center()
                .child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(SharedString::from(label)),
                )
                .child(control),
        )
        .when_some(meaning, |this, meaning| this.child(quiet(meaning, cx)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_workday_choice_states_its_retention() {
        for mode in ScreenContextMode::ALL {
            let text = retention_note(mode, 14);
            assert!(text.contains("14"), "{mode:?}: {text}");
        }
        assert!(retention_note(ScreenContextMode::Text, 1).contains("1 day"));
    }

    #[test]
    fn setup_offers_only_the_two_detected_call_modes() {
        assert!(!DETECTED_CALL_MODES.contains(&AutoRecordMode::Manual));
        for mode in AutoRecordMode::ALL {
            assert!(!meeting_mode_title(mode).is_empty());
            assert!(!meeting_mode_detail(mode).is_empty());
        }
    }
}
