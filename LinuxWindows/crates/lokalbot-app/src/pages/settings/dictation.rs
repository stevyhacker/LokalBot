//! Settings › Dictation (`DictationView.swift`, `RecentDictationsViews.swift`):
//! under the shared header, the shortcut, what it writes and who writes it,
//! what shows while dictating, and a row that opens the recent dictations.
//! Trying it out is the header's "Try it…" sheet (`try_sheet`).

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

use super::model_overview::{Place, place};
use super::status::Role;
use super::subpage::Subpage;
use super::{Section, SettingsPage};
use crate::pages::people::model::{directional, fill};
use crate::state::{AppEvent, DictationHud, SettingsCategory};
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
        DictationIntent::Transcribe => lokalbot_i18n::tr(
            "Types what you say. Nothing is rewritten, and nothing on screen is read.",
        ),
        DictationIntent::Compose => lokalbot_i18n::tr(
            "Say “reply…”, “write…” or “draft…” and it writes the text for you. Anything else is typed as you said it, cleaned up.",
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

/// Where the dictated words become the text that is pasted
/// (`DictationWriterPresentation`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Writer {
    pub text: String,
    /// What is dictated leaves this computer to be written.
    pub online: bool,
}

pub fn writer(settings: &Settings) -> Writer {
    if settings.dictation_intent != DictationIntent::Compose {
        let name = super::model_options::transcription_name(settings);
        return match place(Role::Transcribe, settings) {
            Place::ThisPc => Writer {
                text: fill(
                    lokalbot_i18n::tr("The Transcribe model, %@, on this PC"),
                    &[&name],
                ),
                online: false,
            },
            Place::Online(host) => Writer {
                text: fill(
                    lokalbot_i18n::tr(
                        "The Transcribe model, online at %@. What you say is sent there.",
                    ),
                    &[&host],
                ),
                online: true,
            },
            Place::NotSetUp => Writer {
                text: lokalbot_i18n::tr("The Transcribe model isn’t set up yet.").to_string(),
                online: false,
            },
        };
    }
    // A model of its own for Compose is always one on this computer.
    let effective = lokalbot_ai::dictation::composition_settings(settings);
    let uses_think = effective == *settings;
    let name = super::models::think_name(&effective);
    match place(Role::Think, &effective) {
        Place::ThisPc => Writer {
            text: if uses_think {
                fill(
                    lokalbot_i18n::tr("The Think model, %@, on this PC"),
                    &[&name],
                )
            } else {
                fill(lokalbot_i18n::tr("%@, on this PC"), &[&name])
            },
            online: false,
        },
        Place::Online(host) => Writer {
            text: fill(
                lokalbot_i18n::tr("The Think model, online at %@. What you dictate is sent there."),
                &[&host],
            ),
            online: true,
        },
        Place::NotSetUp => Writer {
            text: lokalbot_i18n::tr("The Think model isn’t set up yet.").to_string(),
            online: false,
        },
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

    /// Settings › Dictation under its header, or the page one of its rows
    /// opened (`DictationSettingsSections`).
    pub(super) fn dictation_sections(&mut self, cx: &mut Context<Self>) -> Vec<Section> {
        match self.open_subpage(SettingsCategory::Dictation) {
            Some(Subpage::DictationProfile) => vec![
                self.writing_profile_fields(Section::new(None), cx).row(
                    "settings.dictationProfileHelp",
                    settings_row::content_row(
                        "settings.dictationProfileHelp",
                        settings_row::help(
                            lokalbot_i18n::tr("Compose uses it for tone, your name and terminology. Autocomplete uses the same profile."),
                            cx,
                        ),
                        false,
                        cx,
                    ),
                ),
            ],
            Some(Subpage::DictationRecent) => vec![self.recent_dictations_section(cx)],
            _ => self.dictation_main_sections(cx),
        }
    }

    fn dictation_main_sections(&mut self, cx: &mut Context<Self>) -> Vec<Section> {
        let (settings, microphones, recent, hud, installed) = {
            let data = self.data.read(cx);
            (
                data.settings.clone(),
                data.audio_inputs.clone(),
                data.recent_dictations.len(),
                data.dictation.clone(),
                data.models.installed.clone(),
            )
        };
        let working = is_working(&hud);
        let lb = cx.lb().clone();

        // Shortcut.
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
        let mut shortcut = Section::new(lokalbot_i18n::tr("Shortcut"))
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
                    lokalbot_i18n::tr("Start and stop"),
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
                "settings.dictationOutputMode",
                self.choice(
                    "settings.dictationOutputMode",
                    lokalbot_i18n::tr("When you finish"),
                    None,
                    DictationOutputMode::ALL
                        .iter()
                        .map(|m| (*m, SharedString::from(lokalbot_i18n::tr(m.label()))))
                        .collect(),
                    settings.dictation_output_mode,
                    |s, v| s.dictation_output_mode = v,
                    cx,
                ),
            );
        // What this desktop lets pasting do (port-only).
        if let Some(limitation) = lokalbot_platform::insert::insertion_limitation() {
            shortcut = shortcut.row(
                "settings.dictationInsertion",
                settings_row::content_row(
                    "settings.dictationInsertion",
                    settings_row::help(lokalbot_i18n::tr(&limitation).to_string(), cx),
                    false,
                    cx,
                ),
            );
        }
        let shortcut = shortcut.row(
            "settings.dictationMicrophoneID",
            settings_row::row(
                "settings.dictationMicrophoneID",
                lokalbot_i18n::tr("Microphone"),
                Some(lokalbot_i18n::tr("With a Bluetooth headset, choose the built-in microphone to keep the headset's audio quality while you dictate.").into()),
                settings_row::picker(
                    "settings-dictation-microphone",
                    current,
                    items,
                    move |index, _, cx| {
                        if let Some(value) = values.get(index).cloned() {
                            microphone_data.update(cx, |data, cx| {
                                data.update_settings(|s| s.dictation_microphone_id = value, cx)
                            });
                        }
                    },
                ),
                self.is_focused("settings.dictationMicrophoneID"),
                cx,
            ),
        );

        // What it writes.
        let intent_data = self.data.clone();
        let intent_index = INTENTS
            .iter()
            .position(|i| *i == settings.dictation_intent)
            .unwrap_or(0);
        let mut writes = Section::new(lokalbot_i18n::tr("What it writes")).row(
            "settings.dictationIntent",
            settings_row::row(
                "settings.dictationIntent",
                lokalbot_i18n::tr("Mode"),
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
        let compose = settings.dictation_intent == DictationIntent::Compose;
        if compose {
            let page = cx.entity();
            writes = writes
                .row(
                    "settings.dictationComposeSources",
                    settings_row::content_row(
                        "settings.dictationComposeSources",
                        settings_row::help(
                            lokalbot_i18n::tr("Compose may read, only for that request:"),
                            cx,
                        ),
                        false,
                        cx,
                    ),
                )
                .row(
                    "settings.dictationUseScreenContext",
                    self.grant(
                        "settings.dictationUseScreenContext",
                        "The focused window",
                        Some(
                            "Reads the focused window's text through accessibility, or from a screenshot with on-device text recognition when it shares too little and that is installed. The image and text are not saved.",
                        ),
                        settings.dictation_use_screen_context,
                        working,
                        |s, v| s.dictation_use_screen_context = v,
                        cx,
                    ),
                )
                .row(
                    "settings.dictationUseVisibleContext",
                    self.grant(
                        "settings.dictationUseVisibleContext",
                        "Text above where you type",
                        Some(
                            "Reads nearby messages and labels through accessibility. No screenshot is needed, and the excerpts are not saved.",
                        ),
                        settings.dictation_use_visible_context,
                        working,
                        |s, v| s.dictation_use_visible_context = v,
                        cx,
                    ),
                )
                .row(
                    "settings.dictationUseMeetingMemory",
                    self.grant(
                        "settings.dictationUseMeetingMemory",
                        "Facts from your meetings",
                        Some(
                            "Adds relevant saved facts when you ask Compose to draft or reply. Reads what is already saved; it does not start an overnight review.",
                        ),
                        settings.dictation_use_meeting_memory,
                        working,
                        |s, v| s.dictation_use_meeting_memory = v,
                        cx,
                    ),
                )
                .row(
                    "settings.dictationUseScreenMemory",
                    self.grant(
                        "settings.dictationUseScreenMemory",
                        "Facts from your screen history",
                        Some(
                            "Adds relevant saved facts when you ask Compose to draft or reply. Reads what is already saved; it does not start an overnight review.",
                        ),
                        settings.dictation_use_screen_memory,
                        working,
                        |s, v| s.dictation_use_screen_memory = v,
                        cx,
                    ),
                )
                .row(
                    "settings.dictationWritingProfile",
                    super::model_overview::drill_row(
                        "settings-dictation-profile",
                        lokalbot_i18n::tr("Writing profile"),
                        Some(lokalbot_i18n::tr("Shared with Autocomplete")),
                        Some(writing_profile_summary(&settings)),
                        move |_, cx| {
                            page.update(cx, |page, cx| {
                                page.show_subpage(Subpage::DictationProfile, cx)
                            })
                        },
                        cx,
                    ),
                );
        }
        // Who writes the text: the Compose model (a built-in one, or Think),
        // or the Transcribe model, which is changed under Models.
        let writer = writer(&settings);
        let control: AnyElement = if compose {
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
            )
            .into_any_element()
        } else {
            Button::new("settings-dictation-writer-change")
                .outline()
                .small()
                .label(lokalbot_i18n::tr("Change…"))
                .on_click(cx.listener(|this, _, window, cx| {
                    this.reveal("settings.transcriptionModel", window, cx)
                }))
                .into_any_element()
        };
        let writer_color = if writer.online {
            lb.attention_text
        } else {
            lb.text_secondary
        };
        let writer_id = if compose {
            "settings.dictationCompositionBuiltInModelID"
        } else {
            "settings.dictationTranscribeModel"
        };
        writes = writes.row(
            writer_id,
            settings_row::content_row(
                writer_id,
                h_flex()
                    .w_full()
                    .gap(px(16.))
                    .items_center()
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .gap(px(3.))
                            .child(
                                div()
                                    .text_size(ty::BODY)
                                    .text_color(lb.text)
                                    .child(lokalbot_i18n::tr("Who writes the text")),
                            )
                            .child(
                                div()
                                    .text_size(ty::SECONDARY)
                                    .line_height(px(18.))
                                    .text_color(writer_color)
                                    .child(crate::ui::text::paragraph(directional(writer.text))),
                            ),
                    )
                    .child(div().flex_none().child(control)),
                self.is_focused(writer_id),
                cx,
            ),
        );
        if compose && writer.online {
            // What else travels with the dictated words, said in full.
            let composition = lokalbot_ai::dictation::composition_settings(&settings);
            let (_, hosts) = crate::state::inference_presentation(&composition);
            writes = writes.row(
                "settings.dictationRemoteNotice",
                settings_row::content_row(
                    "settings.dictationRemoteNotice",
                    settings_row::help(
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
                        ),
                        cx,
                    ),
                    false,
                    cx,
                ),
            );
        }

        // While dictating.
        let while_dictating = Section::new(lokalbot_i18n::tr("While dictating"))
            .row(
                "settings.dictationShowOverlay",
                self.toggle(
                    "settings.dictationShowOverlay",
                    lokalbot_i18n::tr("Show a small status window"),
                    None,
                    settings.dictation_show_overlay,
                    |s, v| s.dictation_show_overlay = v,
                    cx,
                ),
            )
            .row(
                "settings.dictationLivePreview",
                self.toggle(
                    "settings.dictationLivePreview",
                    lokalbot_i18n::tr("Show the words as you speak"),
                    None,
                    settings.dictation_live_preview,
                    |s, v| s.dictation_live_preview = v,
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
                "settings.dictationRetainAudio",
                self.toggle(
                    "settings.dictationRetainAudio",
                    lokalbot_i18n::tr("Keep the audio files"),
                    Some(lokalbot_i18n::tr(
                        "Saved as WAV files in the dictations folder of your library. Off, the audio stays in memory and is never written to disk.",
                    )),
                    settings.dictation_retain_audio,
                    |s, v| s.dictation_retain_audio = v,
                    cx,
                ),
            );

        // More.
        let page = cx.entity();
        let more = Section::new(lokalbot_i18n::tr("More")).row(
            "settings.dictationRecent",
            super::model_overview::drill_row(
                "settings-dictation-recent",
                lokalbot_i18n::tr("Recent dictations"),
                Some(lokalbot_i18n::tr("The last 10, kept encrypted for 7 days")),
                Some(if recent == 0 {
                    lokalbot_i18n::tr("None yet").to_string()
                } else {
                    lokalbot_i18n::number(recent)
                }),
                move |_, cx| {
                    page.update(cx, |page, cx| {
                        page.show_subpage(Subpage::DictationRecent, cx)
                    })
                },
                cx,
            ),
        );
        vec![shortcut, writes, while_dictating, more]
    }

    /// Recent dictations: earlier results with Copy, so one left on the
    /// clipboard can be copied again after something else replaced it.
    fn recent_dictations_section(&mut self, cx: &mut Context<Self>) -> Section {
        let lb = cx.lb().clone();
        let recent = self.data.read(cx).recent_dictations.clone();
        let id = "settings.dictationRecent";
        if recent.is_empty() {
            return Section::new(None).row(
                id,
                settings_row::content_row(
                    id,
                    settings_row::help(
                        lokalbot_i18n::tr("Nothing dictated in the last 7 days."),
                        cx,
                    ),
                    false,
                    cx,
                ),
            );
        }
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
        Section::new(None).row(id, settings_row::content_row(id, list, false, cx))
    }

    /// "Try it…" (`DictationTrySheet`, `DictationView`): what still stands in
    /// the way, then the button that starts and stops a recording, where it
    /// stands, and the last result. Nothing is pasted into another app and
    /// the clipboard is left alone.
    pub(super) fn dictation_try(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let (settings, last, details, hud, inactive) = {
            let data = self.data.read(cx);
            (
                data.settings.clone(),
                data.last_dictation.clone(),
                data.last_dictation_details.clone(),
                data.dictation.clone(),
                data.dictation_shortcut_inactive,
            )
        };
        let lb = cx.lb().clone();
        let blockers = self.status(cx).dictation_try_blockers();
        let open = super::header::opener(&cx.entity());
        let status: SharedString = if inactive {
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
        let mut body = v_flex().w_full().gap(px(12.));
        for line in blockers {
            body = body.child(super::header::status_line(
                SettingsCategory::Dictation,
                line,
                &self.data,
                open.clone(),
                cx,
            ));
        }
        let result: AnyElement = match last {
            Some(text) => {
                let details = details.unwrap_or_default();
                v_flex()
                    .gap(px(4.))
                    .child(
                        div()
                            .text_size(ty::CAPTION)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.text_secondary)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Last result"))),
                    )
                    .child(
                        v_flex()
                            .gap(px(6.))
                            .p(px(12.))
                            .min_h(px(64.))
                            .rounded(px(8.))
                            .bg(lb.chip_fill)
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
                    .into_any_element()
            }
            None => div()
                .p(px(12.))
                .min_h(px(64.))
                .rounded(px(8.))
                .bg(lb.chip_fill)
                .text_size(ty::BODY)
                .text_color(lb.text_secondary)
                .child(lokalbot_i18n::tr("Your words appear here."))
                .into_any_element(),
        };
        body.child(
            h_flex()
                .gap(px(12.))
                .items_center()
                .child(crate::ui::icon_tile(Ico::Mic, lb.accent_text, px(36.)))
                .child(
                    v_flex()
                        .flex_1()
                        .min_w_0()
                        .gap(px(2.))
                        .child(
                            div()
                                .text_size(ty::BODY)
                                .text_color(lb.text)
                                .child(crate::ui::text::paragraph(status)),
                        )
                        .child(settings_row::help(
                            fill(
                                lokalbot_i18n::tr("Mode: %@"),
                                &[intent_label(settings.dictation_intent)],
                            ),
                            cx,
                        )),
                )
                .child(
                    Button::new("settings-try-dictation")
                        .primary()
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
                            data.update(cx, |data, cx| data.request(AppEvent::ToggleDictation, cx))
                        }),
                ),
        )
        .child(result)
        .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn who_writes_the_text_says_where_it_runs() {
        let mut settings = Settings {
            dictation_intent: DictationIntent::Transcribe,
            ..Settings::default()
        };
        let local = writer(&settings);
        assert!(!local.online);
        assert!(
            local.text.starts_with("The Transcribe model, "),
            "{}",
            local.text
        );
        assert!(local.text.ends_with(", on this PC"), "{}", local.text);

        settings.dictation_intent = DictationIntent::Compose;
        let think = writer(&settings);
        assert!(
            think.text.starts_with("The Think model, "),
            "{}",
            think.text
        );
        assert!(!think.online);

        // A Think server that is approved receives what is dictated.
        settings.summarizer_backend = lokalbot_core::settings::SummarizerBackend::OpenAICompatible;
        settings.openai_base_url = "https://ai.example.com/v1".into();
        let blocked = writer(&settings);
        assert_eq!(blocked.text, "The Think model isn’t set up yet.");
        assert!(!blocked.online);
        settings
            .approved_remote_inference_origins
            .push("https://ai.example.com".into());
        let online = writer(&settings);
        assert!(online.online);
        assert_eq!(
            online.text,
            "The Think model, online at ai.example.com. What you dictate is sent there."
        );
    }

    #[test]
    fn the_profile_summary_names_what_is_set() {
        let mut settings = Settings::default();
        assert_eq!(writing_profile_summary(&settings), "Not set");
        settings.cotyping_user_name = "Ana".into();
        settings.cotyping_extended_context = "LokalBot".into();
        assert_eq!(writing_profile_summary(&settings), "Name, Terminology");
    }
}
