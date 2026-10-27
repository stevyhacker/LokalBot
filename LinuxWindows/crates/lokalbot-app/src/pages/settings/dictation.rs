//! Dictation: the shortcut, how it triggers, Transcribe or Compose, where the
//! text goes, a place to try it, and the recent dictations to copy again
//! (`DictationSettingsControls.swift`, `DictationView.swift`,
//! `RecentDictationsViews.swift`). The start sound and kept audio files are
//! not implemented on Linux and Windows, so their rows are not shown.

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{Context, FontWeight, ParentElement as _, SharedString, Styled as _, div, px};
use lokalbot_core::Settings;
use lokalbot_core::settings::{DictationIntent, DictationOutputMode, DictationTriggerMode};
use lokalbot_engine::{Command, DictationCommand};

use super::{Section, SettingsPage};
use crate::state::AppEvent;
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{Ico, settings_row};

const INTENTS: [DictationIntent; 2] = [DictationIntent::Transcribe, DictationIntent::Compose];

fn intent_label(intent: DictationIntent) -> &'static str {
    match intent {
        DictationIntent::Transcribe => lokalbot_i18n::tr("Transcribe"),
        DictationIntent::Compose => lokalbot_i18n::tr("Compose"),
    }
}

fn intent_detail(intent: DictationIntent) -> &'static str {
    match intent {
        DictationIntent::Transcribe => {
            lokalbot_i18n::tr("Keeps the recognized speech. No rewriting.")
        }
        DictationIntent::Compose => lokalbot_i18n::tr(
            "Your Think model tidies what you say. Start with “reply…”, “write…” or “draft…” to have it write the text for you.",
        ),
    }
}

/// "Name, Style" or "Not set" (`DictationView.writingProfileSummary`).
pub fn writing_profile_summary(settings: &Settings) -> &'static str {
    match (
        settings.cotyping_user_name.trim().is_empty(),
        settings.cotyping_style_note.trim().is_empty(),
    ) {
        (false, false) => lokalbot_i18n::tr("Name, Style"),
        (false, true) => lokalbot_i18n::tr("Name"),
        (true, false) => lokalbot_i18n::tr("Style"),
        (true, true) => lokalbot_i18n::tr("Not set"),
    }
}

impl SettingsPage {
    pub(super) fn dictation_sections(&mut self, cx: &mut Context<Self>) -> Vec<Section> {
        let (settings, microphones, last, recent) = {
            let data = self.data.read(cx);
            (
                data.settings.clone(),
                data.audio_inputs.clone(),
                data.last_dictation.clone(),
                data.recent_dictations.clone(),
            )
        };
        let lb = cx.lb().clone();

        let mut options: Vec<(SharedString, SharedString)> =
            vec![("".into(), lokalbot_i18n::tr("System default").into())];
        options.extend(microphones.iter().map(|m| (m.clone(), m.clone())));
        if !settings.dictation_microphone_id.is_empty()
            && !options
                .iter()
                .any(|(value, _)| value.as_ref() == settings.dictation_microphone_id)
        {
            let id: SharedString = settings.dictation_microphone_id.clone().into();
            options.push((id.clone(), id));
        }
        let current = options
            .iter()
            .find(|(value, _)| value.as_ref() == settings.dictation_microphone_id)
            .map(|(_, label)| label.clone())
            .unwrap_or_else(|| lokalbot_i18n::tr("System default").into());
        let items: Vec<(SharedString, bool)> = options
            .iter()
            .map(|(value, label)| {
                (
                    label.clone(),
                    value.as_ref() == settings.dictation_microphone_id,
                )
            })
            .collect();
        let values: Vec<String> = options.iter().map(|(value, _)| value.to_string()).collect();
        let microphone_data = self.data.clone();
        let intent_data = self.data.clone();
        let intent_index = INTENTS
            .iter()
            .position(|i| *i == settings.dictation_intent)
            .unwrap_or(0);

        let dictation = Section::new(lokalbot_i18n::tr("Dictation"))
            .row(
                "settings.dictationEnabled",
                self.toggle(
                    "settings.dictationEnabled",
                    lokalbot_i18n::tr("Enable dictation shortcut"),
                    None,
                    settings.dictation_enabled,
                    |s, v| s.dictation_enabled = v,
                    cx,
                ),
            )
            .row(
                "settings.dictationShortcut",
                settings_row::row(
                    "settings.dictationShortcut",
                    lokalbot_i18n::tr("Shortcut"),
                    None,
                    self.dictation_shortcut.clone(),
                    self.is_focused("settings.dictationShortcut"),
                    cx,
                ),
            )
            .row(
                "settings.dictationTriggerMode",
                self.choice(
                    "settings.dictationTriggerMode",
                    lokalbot_i18n::tr("Trigger"),
                    None,
                    DictationTriggerMode::ALL
                        .iter()
                        .map(|m| (*m, SharedString::from(lokalbot_i18n::tr(m.label()))))
                        .collect(),
                    settings.dictation_trigger_mode,
                    |s, v| s.dictation_trigger_mode = v,
                    cx,
                ),
            )
            .row(
                "settings.dictationIntent",
                settings_row::row(
                    "settings.dictationIntent",
                    lokalbot_i18n::tr("Intent"),
                    Some(intent_detail(settings.dictation_intent).into()),
                    settings_row::segmented(
                        "settings-dictation-intent",
                        &INTENTS.map(intent_label),
                        intent_index,
                        move |index, _, cx| {
                            let intent = INTENTS[index];
                            intent_data.update(cx, |data, cx| {
                                data.update_settings(|s| s.dictation_intent = intent, cx)
                            });
                        },
                        cx,
                    ),
                    self.is_focused("settings.dictationIntent"),
                    cx,
                ),
            );
        let dictation = if settings.dictation_intent == DictationIntent::Compose {
            let compose_help = if crate::pages::ask::composer_inference(cx).remote {
                lokalbot_i18n::tr(
                    "Compose uses your name and writing style. What you dictate is sent to your remote Think model for the final wording.",
                )
            } else {
                lokalbot_i18n::tr(
                    "Compose uses your name and writing style, with your Think model on this PC.",
                )
            };
            dictation.row(
                "settings.dictationWritingProfile",
                settings_row::row(
                    "settings.dictationWritingProfile",
                    lokalbot_i18n::tr("Writing profile"),
                    Some(compose_help.into()),
                    h_flex()
                        .gap(px(8.))
                        .items_center()
                        .child(settings_row::value(writing_profile_summary(&settings), cx))
                        .child(
                            Button::new("settings-dictation-profile")
                                .outline()
                                .small()
                                .label(lokalbot_i18n::tr("Edit…"))
                                .on_click(cx.listener(|this, _, window, cx| {
                                    this.reveal("settings.cotypingUserName", window, cx)
                                })),
                        ),
                    self.is_focused("settings.dictationWritingProfile"),
                    cx,
                ),
            )
        } else {
            dictation
        };
        let dictation = dictation
            .row(
                "settings.dictationOutputMode",
                self.choice(
                    "settings.dictationOutputMode",
                    lokalbot_i18n::tr("After a shortcut recording"),
                    None,
                    DictationOutputMode::ALL.iter().map(|m| (*m, SharedString::from(lokalbot_i18n::tr(m.label())))).collect(),
                    settings.dictation_output_mode,
                    |s, v| s.dictation_output_mode = v,
                    cx,
                ),
            )
            .row(
                "settings.dictationMicrophoneID",
                settings_row::row(
                    "settings.dictationMicrophoneID",
                    lokalbot_i18n::tr("Microphone"),
                    Some(lokalbot_i18n::tr("With a Bluetooth headset, choose the built-in microphone to keep the headset's audio quality while you dictate.").into()),
                    settings_row::picker("settings-dictation-microphone", current, items, move |index, _, cx| {
                        if let Some(value) = values.get(index).cloned() {
                            microphone_data.update(cx, |data, cx| data.update_settings(|s| s.dictation_microphone_id = value, cx));
                        }
                    }),
                    self.is_focused("settings.dictationMicrophoneID"),
                    cx,
                ),
            )
            .row(
                "settings.dictationShowOverlay",
                self.toggle(
                    "settings.dictationShowOverlay",
                    lokalbot_i18n::tr("Show floating dictation status"),
                    None,
                    settings.dictation_show_overlay,
                    |s, v| s.dictation_show_overlay = v,
                    cx,
                ),
            );

        let status: SharedString = if settings.dictation_enabled {
            lokalbot_i18n::format(
                match settings.dictation_trigger_mode {
                    DictationTriggerMode::PushToTalk => "Ready — hold {shortcut} to dictate.",
                    DictationTriggerMode::Toggle => "Ready — press {shortcut} to dictate.",
                    DictationTriggerMode::TapOrHold => "Ready — tap or hold {shortcut} to dictate.",
                },
                &[("shortcut", settings.dictation_shortcut.clone())],
            )
            .into()
        } else {
            lokalbot_i18n::tr(
                "The dictation shortcut is off. Try it here, or turn on the shortcut above.",
            )
            .into()
        };
        let data = self.data.clone();
        let try_it = v_flex()
            .w_full()
            .gap(px(10.))
            .child(
                h_flex()
                    .gap(px(10.))
                    .items_center()
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(ty::BODY)
                            .text_color(lb.text)
                            .child(status),
                    )
                    .child(
                        Button::new("settings-try-dictation")
                            .outline()
                            .small()
                            .icon(Icon::new(Ico::Mic))
                            .label(lokalbot_i18n::tr("Try here"))
                            .on_click(move |_, _, cx| {
                                data.update(cx, |data, cx| {
                                    data.request(AppEvent::ToggleDictation, cx)
                                })
                            }),
                    ),
            )
            .when_some(last, |this, text| {
                this.child(
                    v_flex()
                        .gap(px(4.))
                        .p(px(10.))
                        .rounded(px(8.))
                        .bg(lb.chip_fill)
                        .child(
                            div()
                                .text_size(ty::CAPTION)
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(lb.text_secondary)
                                .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                    "Last result",
                                ))),
                        )
                        .child(div().text_size(ty::BODY).text_color(lb.text).child(text)),
                )
            });
        let try_section = Section::new(lokalbot_i18n::tr("Try dictation")).row(
            "settings.dictationTry",
            settings_row::content_row("settings.dictationTry", try_it, false, cx),
        );

        if recent.is_empty() {
            return vec![dictation, try_section];
        }
        // Earlier results with Copy, so one left on the clipboard can be
        // copied again after something else replaced it.
        let now = chrono::Local::now();
        let list = v_flex()
            .w_full()
            .gap(px(12.))
            .children(recent.iter().map(|entry| {
                let caption = [
                    Some(crate::pages::ask::row_timestamp(entry.date, now)),
                    entry.app_name.clone(),
                    Some(lokalbot_i18n::tr(entry.outcome.label()).to_string()),
                ]
                .into_iter()
                .flatten()
                .collect::<Vec<_>>()
                .join(" · ");
                let id = entry.id;
                h_flex()
                    .w_full()
                    .gap(px(10.))
                    .items_start()
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .gap(px(2.))
                            .child(
                                div()
                                    .text_size(ty::BODY)
                                    .text_color(lb.text)
                                    .line_clamp(3)
                                    .child(entry.text.clone()),
                            )
                            .child(
                                div()
                                    .text_size(ty::CAPTION)
                                    .text_color(lb.text_secondary)
                                    .child(caption),
                            ),
                    )
                    .child(
                        Button::new(SharedString::from(format!("settings-dictation-copy-{id}")))
                            .outline()
                            .small()
                            .icon(Icon::new(Ico::Copy))
                            .label(lokalbot_i18n::tr("Copy"))
                            .on_click(move |_, _, cx| {
                                crate::bridge::send(
                                    Command::Dictation(DictationCommand::CopyRecent(Some(id))),
                                    cx,
                                )
                            }),
                    )
            }))
            .child(
                h_flex()
                    .w_full()
                    .gap(px(10.))
                    .items_center()
                    .child(div().flex_1().min_w_0().child(settings_row::help(
                        lokalbot_i18n::tr(
                            "Saved encrypted on this computer for 7 days, so you can copy a dictation again after the clipboard changes or the computer restarts. Text dictated into a password manager is never kept.",
                        ),
                        cx,
                    )))
                    .child(
                        Button::new("settings-dictation-clear-recent")
                            .ghost()
                            .small()
                            .label(lokalbot_i18n::tr("Clear"))
                            .on_click(|_, _, cx| {
                                crate::bridge::send(
                                    Command::Dictation(DictationCommand::ClearRecent),
                                    cx,
                                )
                            }),
                    ),
            );
        let recent_section = Section::new(lokalbot_i18n::tr("Recent dictations")).row(
            "settings.dictationRecent",
            settings_row::content_row("settings.dictationRecent", list, false, cx),
        );
        vec![dictation, try_section, recent_section]
    }
}
