//! Dictation: the shortcut, how it triggers, Transcribe or Compose, where the
//! text goes, a place to try it, and the recent dictations to copy again
//! (`DictationSettingsControls.swift`, `DictationView.swift`,
//! `RecentDictationsViews.swift`).

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, Context, FontWeight, IntoElement as _, ParentElement as _, SharedString,
    Styled as _, div, px,
};
use lokalbot_core::Settings;
use lokalbot_core::settings::{DictationIntent, DictationOutputMode, DictationTriggerMode};
use lokalbot_engine::{Command, DictationCommand};

use super::{Section, SettingsPage};
use crate::state::{AppEvent, DictationHud};
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
pub fn writing_profile_summary(settings: &Settings) -> String {
    let parts: Vec<&str> = [
        ("Name", &settings.cotyping_user_name),
        ("Style", &settings.cotyping_style_note),
        ("Languages", &settings.cotyping_languages),
        ("Terminology", &settings.cotyping_extended_context),
    ]
    .into_iter()
    .filter(|(_, value)| !value.trim().is_empty())
    .map(|(label, _)| lokalbot_i18n::tr(label))
    .collect();
    if parts.is_empty() {
        lokalbot_i18n::tr("Not set").to_string()
    } else {
        parts.join(", ")
    }
}

/// The dictation in progress keeps the settings it started with, so its grants
/// do not change under it.
fn is_working(state: &DictationHud) -> bool {
    !matches!(
        state,
        DictationHud::Idle
            | DictationHud::Notice(_)
            | DictationHud::Undelivered { .. }
            | DictationHud::Failed(_)
    )
}

impl SettingsPage {
    /// A grant row, locked while a dictation is under way.
    #[allow(clippy::too_many_arguments)]
    fn grant(
        &self,
        id: &'static str,
        title: &'static str,
        help: Option<&'static str>,
        value: bool,
        locked: bool,
        set: fn(&mut Settings, bool),
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let data = self.data.clone();
        settings_row::row(
            id,
            lokalbot_i18n::tr(title).to_string(),
            help.map(|help| lokalbot_i18n::tr(help).to_string().into()),
            settings_row::switch(id, value, move |checked, _, cx| {
                data.update(cx, |data, cx| data.update_settings(|s| set(s, checked), cx))
            })
            .disabled(locked),
            self.is_focused(id),
            cx,
        )
        .into_any_element()
    }

    /// What dictation runs on (`modelSection`), and any reason it can't reach
    /// other apps on this desktop. The models themselves are chosen under Models.
    fn dictation_model_section(
        &self,
        settings: &lokalbot_core::Settings,
        cx: &mut Context<Self>,
    ) -> Section {
        let transcribe = lokalbot_speech::models::find(&settings.transcription_model).map_or_else(
            || settings.transcription_model.clone(),
            |m| m.display_name.to_string(),
        );
        let language = lokalbot_speech::language::language_name(&settings.transcription_language);
        let mut section = Section::new(lokalbot_i18n::tr("Model"))
            .row(
                "settings.dictationTranscribeModel",
                settings_row::row(
                    "settings.dictationTranscribeModel",
                    lokalbot_i18n::tr("Transcribe model"),
                    None,
                    settings_row::value(transcribe, cx),
                    self.is_focused("settings.dictationTranscribeModel"),
                    cx,
                ),
            )
            .row(
                "settings.dictationLanguage",
                settings_row::row(
                    "settings.dictationLanguage",
                    lokalbot_i18n::tr("Language"),
                    None,
                    settings_row::value(lokalbot_i18n::tr(language).to_string(), cx),
                    false,
                    cx,
                ),
            );
        if settings.dictation_intent != DictationIntent::Compose {
            section = section.row(
                "settings.dictationModelTrust",
                settings_row::content_row(
                    "settings.dictationModelTrust",
                    settings_row::help(
                        lokalbot_i18n::tr(
                            "Speech recognition runs on this computer. No screen context or rewrite model is used.",
                        ),
                        cx,
                    ),
                    false,
                    cx,
                ),
            );
        }
        if let Some(limitation) = lokalbot_platform::insert::insertion_limitation() {
            section = section.row(
                "settings.dictationInsertion",
                settings_row::content_row(
                    "settings.dictationInsertion",
                    settings_row::help(lokalbot_i18n::tr(&limitation).to_string(), cx),
                    false,
                    cx,
                ),
            );
        }
        section
    }

    pub(super) fn dictation_sections(&mut self, cx: &mut Context<Self>) -> Vec<Section> {
        let (settings, microphones, last, details, recent, hud, installed) = {
            let data = self.data.read(cx);
            (
                data.settings.clone(),
                data.audio_inputs.clone(),
                data.last_dictation.clone(),
                data.last_dictation_details.clone(),
                data.recent_dictations.clone(),
                data.dictation.clone(),
                data.models.installed.clone(),
            )
        };
        let working = is_working(&hud);
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
            let composition = lokalbot_ai::dictation::composition_settings(&settings);
            let (_, hosts) = crate::state::inference_presentation(&composition);
            let compose_help: SharedString = if hosts.is_empty() {
                lokalbot_i18n::tr(
                    "Speech uses the meeting transcription model; final wording uses your local composition model and writing profile. Everything stays on this PC.",
                )
                .to_string()
                .into()
            } else {
                lokalbot_i18n::format(
                    "Final wording uses your approved remote Think model ({0}). What you dictate, and any enabled screen context or saved facts it uses, is sent to that server.",
                    &[(
                        "0",
                        hosts
                            .iter()
                            .map(|host| host.to_string())
                            .collect::<Vec<_>>()
                            .join(", "),
                    )],
                )
                .into()
            };
            // Built-in models that are ready, plus a stored choice.
            let chosen = settings.dictation_composition_built_in_model_id.clone();
            let mut models: Vec<(String, SharedString)> = vec![(
                String::new(),
                lokalbot_i18n::tr("Same as Think").to_string().into(),
            )];
            models.extend(
                lokalbot_ai::catalog::think_entries()
                    .filter(|entry| entry.id == chosen || installed.iter().any(|id| id == entry.id))
                    .map(|entry| (entry.id.to_string(), entry.display_name.into())),
            );
            let current_model = models
                .iter()
                .find(|(id, _)| *id == chosen)
                .map_or_else(|| models[0].1.clone(), |(_, name)| name.clone());
            let model_items: Vec<(SharedString, bool)> = models
                .iter()
                .map(|(id, name)| (name.clone(), *id == chosen))
                .collect();
            let model_ids: Vec<String> = models.iter().map(|(id, _)| id.clone()).collect();
            let model_data = self.data.clone();
            let sources_help = settings_row::content_row(
                "settings.dictationComposeSources",
                settings_row::help(
                    lokalbot_i18n::tr(
                        "The sources below are read only when you start with a writing request, such as “reply…”, “write…” or “draft…”. Other dictation is only cleaned up.",
                    )
                    .to_string(),
                    cx,
                ),
                false,
                cx,
            );
            let screen_grant = self.grant(
                "settings.dictationUseScreenContext",
                "Use the focused window as context",
                Some(
                    "Reads the focused window's text through accessibility, or from a screenshot with on-device text recognition when it shares too little and that is installed. The image and text are not saved.",
                ),
                settings.dictation_use_screen_context,
                working,
                |s, v| s.dictation_use_screen_context = v,
                cx,
            );
            let visible_grant = self.grant(
                "settings.dictationUseVisibleContext",
                "Use visible text above the field",
                Some(
                    "Reads nearby messages and labels through accessibility. No screenshot is needed, and the excerpts are not saved.",
                ),
                settings.dictation_use_visible_context,
                working,
                |s, v| s.dictation_use_visible_context = v,
                cx,
            );
            let meeting_grant = self.grant(
                "settings.dictationUseMeetingMemory",
                "Use meeting and work memory",
                None,
                settings.dictation_use_meeting_memory,
                working,
                |s, v| s.dictation_use_meeting_memory = v,
                cx,
            );
            let screen_memory_grant = self.grant(
                "settings.dictationUseScreenMemory",
                "Use screen-derived work memory",
                Some(
                    "Adds relevant saved facts when you ask Compose to draft or reply. Reads what is already saved; it does not start an overnight review.",
                ),
                settings.dictation_use_screen_memory,
                working,
                |s, v| s.dictation_use_screen_memory = v,
                cx,
            );
            dictation
                .row("settings.dictationComposeSources", sources_help)
                .row("settings.dictationUseScreenContext", screen_grant)
                .row("settings.dictationUseVisibleContext", visible_grant)
                .row("settings.dictationUseMeetingMemory", meeting_grant)
                .row("settings.dictationUseScreenMemory", screen_memory_grant)
                .row(
                    "settings.dictationCompositionBuiltInModelID",
                    settings_row::row(
                        "settings.dictationCompositionBuiltInModelID",
                        lokalbot_i18n::tr("Compose model"),
                        Some(
                            lokalbot_i18n::tr(
                                "A built-in model just for Compose. Same as Think follows your Think model and connection.",
                            )
                            .to_string()
                            .into(),
                        ),
                        settings_row::picker(
                            "settings-dictation-compose-model",
                            current_model,
                            model_items,
                            move |index, _, cx| {
                                if let Some(id) = model_ids.get(index).cloned() {
                                    model_data.update(cx, |data, cx| {
                                        data.update_settings(
                                            |s| s.dictation_composition_built_in_model_id = id,
                                            cx,
                                        )
                                    });
                                }
                            },
                        ),
                        self.is_focused("settings.dictationCompositionBuiltInModelID"),
                        cx,
                    ),
                )
                .row(
                "settings.dictationWritingProfile",
                settings_row::row(
                    "settings.dictationWritingProfile",
                    lokalbot_i18n::tr("Writing profile"),
                    Some(compose_help),
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
            )
            .row(
                "settings.dictationPlaysStartSound",
                self.toggle(
                    "settings.dictationPlaysStartSound",
                    lokalbot_i18n::tr("Play a sound when the microphone is ready"),
                    None,
                    settings.dictation_plays_start_sound,
                    |s, v| s.dictation_plays_start_sound = v,
                    cx,
                ),
            )
            .row(
                "settings.dictationLivePreview",
                self.toggle(
                    "settings.dictationLivePreview",
                    lokalbot_i18n::tr("Show live transcript"),
                    None,
                    settings.dictation_live_preview,
                    |s, v| s.dictation_live_preview = v,
                    cx,
                ),
            )
            .row(
                "settings.dictationRetainAudio",
                self.toggle(
                    "settings.dictationRetainAudio",
                    lokalbot_i18n::tr("Keep dictation audio files"),
                    Some(lokalbot_i18n::tr(
                        "Saved as WAV files in the dictations folder of your library. Off, the audio stays in memory and is never written to disk.",
                    )),
                    settings.dictation_retain_audio,
                    |s, v| s.dictation_retain_audio = v,
                    cx,
                ),
            );

        let status: SharedString = if self.data.read(cx).dictation_shortcut_inactive {
            lokalbot_i18n::tr("Shortcut inactive.").into()
        } else if settings.dictation_enabled {
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
                            .label(lokalbot_i18n::tr(match hud {
                                DictationHud::Starting
                                | DictationHud::Transcribing
                                | DictationHud::Preparing(_)
                                | DictationHud::PreparationFailed(_)
                                | DictationHud::Composing => "Cancel",
                                DictationHud::Listening { .. } => "Stop & finish",
                                _ => "Try here",
                            }))
                            .on_click(move |_, _, cx| {
                                data.update(cx, |data, cx| {
                                    data.request(AppEvent::ToggleDictation, cx)
                                })
                            }),
                    ),
            )
            .child(settings_row::help(
                lokalbot_i18n::tr(
                    "Trying here shows the result below. It never inserts into another app or changes your clipboard; the shortcut uses the output setting above.",
                )
                .to_string(),
                cx,
            ))
            .when_some(last, |this, text| {
                let details = details.clone().unwrap_or_default();
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
                        .child(div().text_size(ty::BODY).text_color(lb.text).child(text))
                        .when_some(details.spoken, |this, spoken| {
                            this.child(
                                div()
                                    .text_size(ty::CAPTION)
                                    .text_color(lb.text_secondary)
                                    .child(lokalbot_i18n::format(
                                        "Spoken request: {0}",
                                        &[("0", spoken.to_string())],
                                    )),
                            )
                        })
                        .when_some(details.context, |this, context| {
                            this.child(
                                div()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.text_secondary)
                                    .child(context),
                            )
                        })
                        .when_some(details.engine, |this, engine| {
                            this.child(
                                div()
                                    .text_size(ty::CAPTION)
                                    .text_color(lb.text_secondary)
                                    .child(engine),
                            )
                        }),
                )
            });
        let try_section = Section::new(lokalbot_i18n::tr("Try dictation")).row(
            "settings.dictationTry",
            settings_row::content_row("settings.dictationTry", try_it, false, cx),
        );
        let model_section = self.dictation_model_section(&settings, cx);

        if recent.is_empty() {
            return vec![dictation, try_section, model_section];
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
        vec![dictation, try_section, model_section, recent_section]
    }
}
