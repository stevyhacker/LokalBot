//! Writing: autocomplete, its practice editor, the writing profile and
//! exclusions (`AutocompleteExperienceView.swift`, `SettingsView.cotypingSection`).
//! The writing profile is also what Compose dictation writes as.
//!
//! The practice editor goes through the same engine path as a field in
//! another app: its text is sent as a field context, the suggestion is drawn
//! after its caret, Tab takes the next word or phrase and Esc dismisses.

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Escape as InputEscape, IndentInline, Input, Textarea};
use gpui_kit::component::slider::Slider;
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Context, FontWeight, InteractiveElement as _, IntoElement, ParentElement as _,
    SharedString, Styled as _, Window, canvas, div, px,
};
use lokalbot_core::settings::AcceptGranularity;
use lokalbot_platform::autocomplete::Support;
use lokalbot_platform::autocomplete::session::replaced_bytes;

use super::{Section, SettingsPage, models};
use crate::state::{AppEvent, SettingsCategory};
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico, settings_row};

/// What the practice editor starts with (`AutocompleteExperienceView.openingText`).
pub const PRACTICE_OPENING: &str = "Hi Sarah, thanks for the update. I wanted to follow";

pub fn granularity_label(granularity: AcceptGranularity) -> &'static str {
    match granularity {
        AcceptGranularity::Word => lokalbot_i18n::tr("One word"),
        AcceptGranularity::Phrase => lokalbot_i18n::tr("One phrase"),
    }
}

impl SettingsPage {
    /// Sends the practice editor's text around its caret to the engine when
    /// it changed.
    pub(super) fn practice_sync(&mut self, cx: &mut Context<Self>) {
        let (before, after) = {
            let state = self.practice.read(cx);
            let value = state.value();
            let cursor = state.cursor().min(value.len());
            let before = value.get(..cursor).unwrap_or(value.as_ref()).to_string();
            let after = value.get(cursor..).unwrap_or_default().to_string();
            (before, after)
        };
        if self.practice_text == (before.clone(), after.clone()) {
            return;
        }
        self.practice_text = (before.clone(), after.clone());
        if let Some(autocomplete) = crate::autocomplete::global(cx) {
            autocomplete.update(cx, |autocomplete, cx| {
                autocomplete.practice_changed(before, after, cx)
            });
        }
    }

    /// One Tab, or "Insert suggestion" with `whole`. True when it took the key.
    fn practice_accept(
        &mut self,
        whole: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(autocomplete) = crate::autocomplete::global(cx) else {
            return false;
        };
        let Some(edit) = autocomplete.update(cx, |autocomplete, cx| {
            autocomplete.practice_accept(whole, cx)
        }) else {
            return false;
        };
        self.practice.update(cx, |state, cx| {
            if edit.backward == 0 && edit.forward == 0 {
                state.insert(edit.text, window, cx);
                return;
            }
            // Replace the `:shortcode` an emoji stands for, or the rest of
            // the word the caret is inside of.
            let value = state.value();
            let cursor = state.cursor().min(value.len());
            let (before, after) = value.split_at(cursor);
            let (back, forward) = replaced_bytes(before, after, edit.backward, edit.forward);
            state.set_selected_range(cursor - back..cursor + forward, cx);
            state.replace(edit.text, window, cx);
        });
        self.practice_sync(cx);
        true
    }

    fn practice_dismiss(&mut self, cx: &mut Context<Self>) -> bool {
        crate::autocomplete::global(cx).is_some_and(|autocomplete| {
            autocomplete.update(cx, |autocomplete, cx| autocomplete.practice_dismiss(cx))
        })
    }

    pub(super) fn writing_sections(&mut self, cx: &mut Context<Self>) -> Vec<Section> {
        let (settings, model_ready, downloads, installed) = {
            let data = self.data.read(cx);
            (
                data.settings.clone(),
                data.models.autocomplete_ready,
                data.downloads.clone(),
                data.models.installed.clone(),
            )
        };
        let (support, limitation, ghost) = match crate::autocomplete::global(cx) {
            Some(autocomplete) => {
                let autocomplete = autocomplete.read(cx);
                (
                    autocomplete.support().clone(),
                    autocomplete.limitation(),
                    autocomplete.practice.ghost(&settings),
                )
            }
            None => (Support::Available, None, None),
        };
        let lb = cx.lb().clone();
        let data = self.data.clone();
        let model_name = models::model_name(&settings.cotyping_built_in_model_id);
        let needs = models::autocomplete_needs(&settings);
        let missing: Vec<String> = needs
            .iter()
            .filter(|id| !installed.contains(id))
            .cloned()
            .collect();
        let downloading = needs
            .iter()
            .find_map(|id| downloads.get(id))
            .map(|d| d.fraction());
        let other_apps = support == Support::Available;

        // Summary: what autocomplete is doing, its readiness and the switch.
        let summary_detail = if settings.cotyping_enabled && other_apps {
            lokalbot_i18n::format(
                "{model_name} · suggestions appear as you type in other apps.",
                &[("model_name", model_name.to_string())],
            )
        } else if settings.cotyping_enabled {
            lokalbot_i18n::format(
                "{model_name} · suggestions appear in the practice editor below.",
                &[("model_name", model_name.to_string())],
            )
        } else if model_ready {
            lokalbot_i18n::tr("The model is ready. Turn on autocomplete to start.").into()
        } else {
            lokalbot_i18n::tr("Download the Autocomplete model to try it.").into()
        };
        let readiness: AnyElement = match (model_ready, downloading) {
            (true, _) => status_pill(lokalbot_i18n::tr("Model ready"), true, cx).into_any_element(),
            (false, Some(fraction)) => status_pill_text(
                lokalbot_i18n::format(
                    "Downloading · {0}%",
                    &[("0", format!("{}", (fraction * 100.).round()))],
                ),
                false,
                cx,
            )
            .into_any_element(),
            (false, None) => {
                let size = models::size_label(
                    missing
                        .iter()
                        .map(|id| models::model_bytes(id, &settings))
                        .sum(),
                );
                let download_data = data.clone();
                let ids = missing.clone();
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .child(status_pill(lokalbot_i18n::tr("Model needed"), false, cx))
                    .child(
                        Button::new("settings-cotyping-download")
                            .outline()
                            .small()
                            .icon(Icon::new(Ico::CircleArrowDown))
                            .label(lokalbot_i18n::format(
                                "Download · {size}",
                                &[("size", size.to_string())],
                            ))
                            .on_click(move |_, _, cx| {
                                download_data.update(cx, |data, cx| {
                                    for id in &ids {
                                        data.request(AppEvent::DownloadModel(id.clone()), cx);
                                    }
                                })
                            }),
                    )
                    .into_any_element()
            }
        };
        let enable_data = data.clone();
        let summary = h_flex()
            .w_full()
            .gap(px(12.))
            .items_start()
            .child(ui::icon_tile(
                Ico::TextCursorInput,
                if settings.cotyping_enabled {
                    lb.accent_text
                } else {
                    lb.text_tertiary
                },
                px(40.),
            ))
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .gap(px(4.))
                    .child(
                        div()
                            .text_size(ty::BODY)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.text)
                            .child(if settings.cotyping_enabled {
                                lokalbot_i18n::tr("Autocomplete on")
                            } else {
                                lokalbot_i18n::tr("Autocomplete off")
                            }),
                    )
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(summary_detail),
                    )
                    .child(h_flex().pt(px(2.)).child(readiness)),
            )
            .child(settings_row::switch(
                "settings.cotypingEnabled",
                settings.cotyping_enabled,
                move |on, _, cx| {
                    enable_data.update(cx, |data, cx| {
                        data.update_settings(|s| s.cotyping_enabled = on, cx)
                    })
                },
            ));
        let mut home = Section::new(None).row(
            "settings.cotypingEnabled",
            settings_row::content_row(
                "settings.cotypingEnabled",
                summary,
                self.is_focused("settings.cotypingEnabled"),
                cx,
            ),
        );
        // Where autocomplete cannot follow the user into other apps, say so.
        if let Support::Unavailable(reason) = &support {
            home = home.row(
                "settings.autocompleteSupport",
                settings_row::content_row(
                    "settings.autocompleteSupport",
                    notice(Ico::TriangleAlert, reason.clone(), lb.attention_text, cx),
                    false,
                    cx,
                ),
            );
        } else if let Some(limitation) = limitation
            && settings.cotyping_enabled
        {
            home = home.row(
                "settings.autocompleteLimitation",
                settings_row::content_row(
                    "settings.autocompleteLimitation",
                    notice(Ico::Info, limitation, lb.text_secondary, cx),
                    false,
                    cx,
                ),
            );
        }

        // The practice editor, through the same engine path as other apps.
        let conversation =
            v_flex()
                .gap(px(6.))
                .child(
                    div()
                        .text_size(ty::SECONDARY)
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(lb.text_secondary)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                            "Sample conversation",
                        ))),
                )
                .children(crate::autocomplete::PRACTICE_CONVERSATION.iter().map(
                    |(sender, text)| {
                        h_flex()
                            .gap(px(6.))
                            .px(px(10.))
                            .py(px(6.))
                            .rounded(px(8.))
                            .bg(lb.text.opacity(0.05))
                            .text_size(ty::SECONDARY)
                            .child(
                                div()
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(lb.text)
                                    .child(*sender),
                            )
                            .child(div().text_color(lb.text).child(*text))
                    },
                ));
        let hint = lokalbot_i18n::tr(
            if settings.cotyping_accept_granularity == AcceptGranularity::Word {
                "Tab accepts the next word · Esc dismisses"
            } else {
                "Tab accepts the next phrase · Esc dismisses"
            },
        );
        let editor = div()
            .relative()
            .w_full()
            .capture_action(cx.listener(|this, _: &IndentInline, window, cx| {
                let taken = this.practice_accept(false, window, cx);
                log::debug!("autocomplete: practice Tab, accepted: {taken}");
                if taken {
                    cx.stop_propagation();
                }
            }))
            .capture_action(cx.listener(|this, _: &InputEscape, _, cx| {
                let taken = this.practice_dismiss(cx);
                log::debug!("autocomplete: practice Esc, dismissed: {taken}");
                if taken {
                    cx.stop_propagation();
                }
            }))
            .child(Textarea::new(&self.practice).h(px(96.)).text_size(ty::BODY))
            .child({
                // Where the editor is on screen, for placing the ghost in it.
                let origin = self.practice_origin.clone();
                canvas(
                    move |bounds, _, _| origin.set(Some(bounds.origin)),
                    |_, _, _, _| {},
                )
                .absolute()
                .top_0()
                .left_0()
                .size_full()
            })
            .when_some(self.practice_ghost(ghost.clone(), cx), |this, ghost| {
                this.child(ghost)
            });
        let has_ghost = ghost.is_some();
        let practice = v_flex()
            .w_full()
            .gap(px(10.))
            .child(conversation)
            .child(editor)
            .child(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(hint),
                    )
                    .child(
                        Button::new("settings-insert-suggestion")
                            .primary()
                            .small()
                            .label(lokalbot_i18n::tr("Insert suggestion"))
                            .disabled(!has_ghost)
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.practice_accept(true, window, cx);
                            })),
                    ),
            )
            .child(settings_row::help(
                if !settings.cotyping_enabled {
                    lokalbot_i18n::tr("Turn on autocomplete to see suggestions while you type.")
                } else if !model_ready {
                    lokalbot_i18n::tr("Suggestions appear here as grey text once the Autocomplete model is downloaded.")
                } else {
                    lokalbot_i18n::tr("Type in the reply, or put the cursor at the end of the text. Suggestions come from the Autocomplete model on this PC.")
                },
                cx,
            ));
        let try_it = Section::new(lokalbot_i18n::tr("Try the real autocomplete")).row(
            "settings.autocompletePreview",
            settings_row::content_row(
                "settings.autocompletePreview",
                practice,
                self.is_focused("settings.autocompletePreview"),
                cx,
            ),
        );

        let words = settings.cotyping_max_words.clamp(2, 50);
        let words_data = data.clone();
        let change_data = data.clone();
        let autocomplete = Section::new(lokalbot_i18n::tr("Autocomplete"))
            .row(
                "settings.cotypingModel",
                settings_row::row(
                    "settings.cotypingModel",
                    lokalbot_i18n::tr("Autocomplete model"),
                    None,
                    h_flex()
                        .gap(px(10.))
                        .items_center()
                        .child(
                            div()
                                .text_size(ty::BODY)
                                .text_color(lb.text_secondary)
                                .child(model_name.clone()),
                        )
                        .child(
                            Button::new("settings-cotyping-model")
                                .outline()
                                .small()
                                .label(lokalbot_i18n::tr("Change…"))
                                .on_click(move |_, _, cx| {
                                    change_data.update(cx, |data, cx| {
                                        data.open_settings(SettingsCategory::Models, cx)
                                    });
                                }),
                        ),
                    false,
                    cx,
                ),
            )
            .row(
                "settings.cotypingMaxWords",
                settings_row::row(
                    "settings.cotypingMaxWords",
                    lokalbot_i18n::format(
                        "Suggestion length: up to {words} words",
                        &[("words", format!("{}", words))],
                    ),
                    None,
                    settings_row::stepper(
                        "settings-cotyping-words",
                        "",
                        words > 2,
                        words < 50,
                        move |step, _, cx| {
                            let next = (words as i32 + step).clamp(2, 50) as u32;
                            words_data.update(cx, |data, cx| {
                                data.update_settings(|s| s.cotyping_max_words = next, cx)
                            });
                        },
                        cx,
                    ),
                    self.is_focused("settings.cotypingMaxWords"),
                    cx,
                ),
            )
            .row(
                "settings.cotypingMultiLine",
                self.toggle(
                    "settings.cotypingMultiLine",
                    lokalbot_i18n::tr("Allow multi-line suggestions"),
                    None,
                    settings.cotyping_multi_line,
                    |s, v| s.cotyping_multi_line = v,
                    cx,
                ),
            )
            .row(
                "settings.cotypingDebounceMs",
                settings_row::row(
                    "settings.cotypingDebounceMs",
                    lokalbot_i18n::tr("Pause before suggesting"),
                    None,
                    h_flex()
                        .gap(px(10.))
                        .items_center()
                        .child(div().w(px(220.)).child(Slider::new(&self.debounce_slider)))
                        .child(
                            div()
                                .min_w(px(56.))
                                .text_size(ty::BODY)
                                .text_color(lb.text_secondary)
                                .flex()
                                .justify_end()
                                .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                                    "{0} ms",
                                    &[("0", format!("{}", settings.cotyping_debounce_ms))],
                                ))),
                        ),
                    self.is_focused("settings.cotypingDebounceMs"),
                    cx,
                ),
            )
            .row(
                "settings.cotypingAcceptGranularity",
                self.choice(
                    "settings.cotypingAcceptGranularity",
                    lokalbot_i18n::tr("Each accept takes"),
                    None,
                    vec![
                        (
                            AcceptGranularity::Word,
                            granularity_label(AcceptGranularity::Word).into(),
                        ),
                        (
                            AcceptGranularity::Phrase,
                            granularity_label(AcceptGranularity::Phrase).into(),
                        ),
                    ],
                    settings.cotyping_accept_granularity,
                    |s, v| s.cotyping_accept_granularity = v,
                    cx,
                ),
            );

        let context = Section::new(lokalbot_i18n::tr("Context"))
            .row(
                "settings.cotypingUseVisibleContext",
                self.toggle(
                    "settings.cotypingUseVisibleContext",
                    lokalbot_i18n::tr("Use visible text above the field"),
                    Some(
                        lokalbot_i18n::tr("Use nearby messages and labels to suggest relevant replies. Processed on this PC, never saved; capture exclusions apply and private browser windows are skipped."),
                    ),
                    settings.cotyping_use_visible_context,
                    |s, v| s.cotyping_use_visible_context = v,
                    cx,
                ),
            )
            .row(
                "settings.cotypingUseMeetingMemory",
                self.toggle(
                    "settings.cotypingUseMeetingMemory",
                    lokalbot_i18n::tr("Use meeting and work memory"),
                    Some(
                        lokalbot_i18n::tr("Use up to two relevant facts from recent meeting notes, decisions, and work memory to help with names and details. Processed on this PC."),
                    ),
                    settings.cotyping_use_meeting_memory,
                    |s, v| s.cotyping_use_meeting_memory = v,
                    cx,
                ),
            );

        let profile = Section::new(lokalbot_i18n::tr("Writing profile"))
            .row(
                "settings.cotypingUserName",
                settings_row::row(
                    "settings.cotypingUserName",
                    lokalbot_i18n::tr("Your name"),
                    Some(lokalbot_i18n::tr("Also keeps you out of People.").into()),
                    div()
                        .w(px(280.))
                        .child(Input::new(&self.cotyping_name).small()),
                    self.is_focused("settings.cotypingUserName"),
                    cx,
                ),
            )
            .row(
                "settings.cotypingStyleNote",
                settings_row::row(
                    "settings.cotypingStyleNote",
                    lokalbot_i18n::tr("Writing style"),
                    None,
                    div()
                        .w(px(280.))
                        .child(Input::new(&self.cotyping_style).small()),
                    self.is_focused("settings.cotypingStyleNote"),
                    cx,
                ),
            )
            .row(
                "settings.writingProfileHelp",
                settings_row::content_row(
                    "settings.writingProfileHelp",
                    settings_row::help(
                        lokalbot_i18n::tr("Autocomplete and Compose dictation write as you, in this style. Both are optional and stay on this PC unless your Think model runs on a server."),
                        cx,
                    ),
                    false,
                    cx,
                ),
            );

        let exclusions = Section::new(lokalbot_i18n::tr("Exclusions"))
            .row(
                "settings.cotypingExcludedApps",
                settings_row::content_row(
                    "settings.cotypingExcludedApps",
                    self.cotyping_excluded_apps.clone(),
                    self.is_focused("settings.cotypingExcludedApps"),
                    cx,
                ),
            )
            .row(
                "settings.cotypingExcludedDomains",
                settings_row::content_row(
                    "settings.cotypingExcludedDomains",
                    self.cotyping_excluded_sites.clone(),
                    self.is_focused("settings.cotypingExcludedDomains"),
                    cx,
                ),
            )
            .row(
                "settings.cotypingExclusionsHelp",
                settings_row::content_row(
                    "settings.cotypingExclusionsHelp",
                    settings_row::help(
                        lokalbot_i18n::tr("Password managers, password fields and terminals are always skipped. Autocomplete never reads an excluded app or site."),
                        cx,
                    ),
                    false,
                    cx,
                ),
            );

        vec![home, try_it, autocomplete, context, profile, exclusions]
    }

    /// The practice suggestion after the editor's caret: inline at the end
    /// of a line, else under the caret's line, as in other apps. Placed in
    /// the editor from the caret it drew last, so scrolling clips it.
    fn practice_ghost(&self, ghost: Option<(String, usize)>, cx: &App) -> Option<AnyElement> {
        let (text, emphasis) = ghost?;
        let (caret, line_height) = self.practice.read(cx).cursor_layout()?;
        let origin = self.practice_origin.get()?;
        let (x, y) = (caret.origin.x - origin.x, caret.origin.y - origin.y);
        let lb = cx.lb();
        let display =
            lokalbot_platform::autocomplete::geometry::display_text(&text).replace('\n', " ");
        let split = display
            .char_indices()
            .nth(emphasis)
            .map_or(display.len(), |(index, _)| index);
        let (strong, rest) = display.split_at(split);
        let visible = |text: &str| SharedString::from(text.replace(' ', "\u{a0}"));
        let at_line_end = self.practice_text.1.is_empty() || self.practice_text.1.starts_with('\n');
        let spans = h_flex()
            .h(line_height)
            .items_center()
            .whitespace_nowrap()
            .font_family(crate::theme::FONT_FAMILY)
            .text_size(ty::BODY)
            .child(div().text_color(lb.text_secondary).child(visible(strong)))
            .child(div().text_color(lb.text_tertiary).child(visible(rest)));
        let ghost = if at_line_end {
            div()
                .absolute()
                .left(x + caret.size.width)
                .top(y)
                .child(spans)
        } else {
            div()
                .absolute()
                .left(x)
                .top(y + caret.size.height + px(2.))
                .px(px(8.))
                .py(px(2.))
                .rounded(px(7.))
                .bg(lb.elevated)
                .border_1()
                .border_color(lb.separator)
                .shadow_sm()
                .child(spans)
        };
        Some(ghost.into_any_element())
    }
}

/// A warning or note under the summary.
fn notice(
    icon: Ico,
    text: impl Into<SharedString>,
    color: gpui_kit::Hsla,
    _cx: &App,
) -> gpui_kit::Div {
    h_flex()
        .w_full()
        .gap(px(8.))
        .items_start()
        .child(div().pt(px(1.)).child(ui::icon(icon, px(14.), color)))
        .child(
            div()
                .flex_1()
                .min_w_0()
                .text_size(ty::SECONDARY)
                .text_color(color)
                .child(text.into()),
        )
}

/// "Model ready" in green or "Model needed" in amber (`MemoryHealthStatus`).
pub fn status_pill(label: &'static str, good: bool, cx: &App) -> gpui_kit::Div {
    status_pill_text(label, good, cx)
}

fn status_pill_text(label: impl Into<SharedString>, good: bool, cx: &App) -> gpui_kit::Div {
    let lb = cx.lb();
    let tint = if good {
        lb.success_text
    } else {
        lb.attention_text
    };
    h_flex()
        .gap(px(5.))
        .items_center()
        .px(px(8.))
        .py(px(2.))
        .rounded_full()
        .bg(tint.opacity(0.10))
        .text_size(ty::CAPTION)
        .font_weight(FontWeight::MEDIUM)
        .text_color(tint)
        .child(ui::status_dot(tint, px(6.)))
        .child(label.into())
}
