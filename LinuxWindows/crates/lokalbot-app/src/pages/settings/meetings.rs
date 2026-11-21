//! Meetings: detection, processing, summaries, speakers and note export.

#[cfg(windows)]
use crate::{
    i18n::h_flex,
    theme::{LbThemeExt as _, ty},
    ui::{Ico, icon, text::paragraph},
};
use gpui_kit::component::Sizable as _;
use gpui_kit::component::button::Button;
#[cfg(windows)]
use gpui_kit::component::button::ButtonVariants as _;
#[cfg(windows)]
use gpui_kit::component::{Icon, v_flex};
#[cfg(windows)]
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{Context, SharedString};
#[cfg(windows)]
use gpui_kit::{IntoElement, ParentElement as _, Styled as _, Window, div, px};
#[cfg(windows)]
use lokalbot_core::settings::{AdditionalCallApp, Settings};
use lokalbot_core::settings::{AutoRecordMode, NoteTemplate};
#[cfg(windows)]
use std::path::Path;

use super::{Section, SettingsPage};
use crate::state::SettingsCategory;
use crate::ui::settings_row;

/// `LanguageCode.summaryPresets` with their display names.
pub const SUMMARY_LANGUAGES: [(&str, &str); 24] = [
    ("en", "English"),
    ("zh", "Simplified Chinese (Mandarin)"),
    ("zh-Hant", "Traditional Chinese (Mandarin)"),
    ("yue", "Cantonese"),
    ("ja", "Japanese"),
    ("ko", "Korean"),
    ("es", "Spanish"),
    ("fr", "French"),
    ("de", "German"),
    ("pt", "Portuguese (Brazil)"),
    ("pt-PT", "Portuguese (Portugal)"),
    ("ru", "Russian"),
    ("ar", "Arabic"),
    ("hi", "Hindi"),
    ("it", "Italian"),
    ("nl", "Dutch"),
    ("tr", "Turkish"),
    ("pl", "Polish"),
    ("sv", "Swedish"),
    ("da", "Danish"),
    ("no", "Norwegian (Bokmål)"),
    ("nn", "Norwegian (Nynorsk)"),
    ("th", "Thai"),
    ("vi", "Vietnamese"),
];

pub fn summary_language_label(value: &str) -> String {
    if value == "match" || value.is_empty() {
        return lokalbot_i18n::tr("Match transcript (auto)").into();
    }
    if let Some(name) = value.strip_prefix("custom:") {
        return if name.is_empty() {
            lokalbot_i18n::tr("Custom").into()
        } else {
            name.to_string()
        };
    }
    SUMMARY_LANGUAGES
        .iter()
        .find(|(code, _)| *code == value)
        .map(|(_, name)| lokalbot_i18n::tr(name).to_string())
        .unwrap_or_else(|| value.to_string())
}

fn template_description(template: NoteTemplate) -> &'static str {
    match template {
        NoteTemplate::Meeting => {
            lokalbot_i18n::tr("TL;DR · Key points · Decisions · Action items · Open questions")
        }
        NoteTemplate::Lecture => lokalbot_i18n::tr(
            "TL;DR · Concepts · Definitions · Examples · Questions to review · Action items",
        ),
        NoteTemplate::StudyGuide => lokalbot_i18n::tr(
            "TL;DR · Key concepts · Flashcards · Practice questions · Action items",
        ),
        NoteTemplate::Podcast => {
            lokalbot_i18n::tr("TL;DR · Topics · Quotes · Insights · Action items")
        }
        NoteTemplate::Freeform => lokalbot_i18n::tr("Topical bullets · Action items"),
    }
}

/// Apps whose calls LokalBot notices on Linux and Windows.
#[cfg(not(windows))]
const DETECTED_APPS: &str = "Zoom, Microsoft Teams, Slack, Webex, and Google Meet in a browser";
#[cfg(windows)]
const DETECTED_APPS: &str =
    "Zoom, Microsoft Teams, Slack, Webex, Google Meet, Yandex Telemost, MTS Link, and eXpress";

#[cfg(windows)]
impl SettingsPage {
    fn call_app_editor(&self, settings: &Settings, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb();
        let mut list = v_flex().w_full().gap(px(6.)).child(
            h_flex()
                .w_full()
                .items_center()
                .gap(px(12.))
                .child(
                    settings_row::label(
                        lokalbot_i18n::tr("Additional call apps"),
                        Some(
                            lokalbot_i18n::tr("LokalBot detects calls in the apps you add here.")
                                .into(),
                        ),
                        cx,
                    )
                    .flex_1(),
                )
                .child(
                    Button::new("call-app-add")
                        .outline()
                        .small()
                        .icon(Icon::new(Ico::Plus))
                        .label(lokalbot_i18n::tr("Choose App…"))
                        .on_click(
                            cx.listener(|page, _, window, cx| page.choose_call_app(window, cx)),
                        ),
                ),
        );
        for call_app in &settings.additional_call_apps {
            let Some(key) = call_app.detector_key() else {
                continue;
            };
            let name = call_app.display_name().to_string();
            list = list.child(div().w_full().h(px(1.)).bg(lb.separator)).child(
                h_flex()
                    .w_full()
                    .items_center()
                    .gap(px(8.))
                    .child(icon(Ico::AppWindow, px(16.), lb.text_secondary))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(ty::BODY)
                            .child(paragraph(name)),
                    )
                    .child(
                        Button::new(SharedString::from(format!("call-app-remove-{key}")))
                            .ghost()
                            .small()
                            .icon(Icon::new(Ico::Trash))
                            .tooltip(lokalbot_i18n::tr("Remove from call detection"))
                            .on_click(cx.listener(move |page, _, _, cx| {
                                page.call_app_error = None;
                                page.update_settings(
                                    |settings| {
                                        settings.additional_call_apps.retain(|app| {
                                            app.detector_key().as_deref() != Some(key.as_str())
                                        });
                                    },
                                    cx,
                                );
                            })),
                    ),
            );
        }
        list = list.when_some(self.call_app_error, |list, error| {
            list.child(
                div()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.attention_text)
                    .child(paragraph(lokalbot_i18n::tr(error))),
            )
        });
        settings_row::content_row(
            "settings.additionalCallApps",
            list,
            self.is_focused("settings.additionalCallApps"),
            cx,
        )
    }

    fn choose_call_app(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.call_app_error = None;
        cx.notify();
        let receiver = cx.prompt_for_paths(gpui_kit::PathPromptOptions {
            files: true,
            directories: false,
            multiple: false,
            prompt: Some(lokalbot_i18n::tr("Choose a call app").into()),
        });
        let background = cx.background_executor().clone();
        cx.spawn_in(window, async move |this, cx| {
            let selection = match receiver.await {
                Ok(Ok(Some(paths))) => {
                    background
                        .spawn(async move {
                            let Some(path) = paths.first() else {
                                return Err("Choose an application file (.exe).");
                            };
                            call_app_from_file(path)
                        })
                        .await
                }
                Ok(Err(_)) => Err("Could not open the file picker."),
                _ => return,
            };
            let _ = this.update(cx, |page, cx| {
                page.call_app_error = selection
                    .and_then(|call_app| page.add_call_app(call_app, cx))
                    .err();
                cx.notify();
            });
        })
        .detach();
    }

    fn add_call_app(
        &self,
        call_app: AdditionalCallApp,
        cx: &mut Context<Self>,
    ) -> Result<(), &'static str> {
        let key = call_app
            .detector_key()
            .ok_or("Choose an application file (.exe).")?;
        if self
            .data
            .read(cx)
            .settings
            .additional_call_apps
            .iter()
            .any(|app| app.detector_key().as_deref() == Some(key.as_str()))
        {
            return Err("This app is already on the list.");
        }
        self.update_settings(|settings| settings.additional_call_apps.push(call_app), cx);
        Ok(())
    }
}

#[cfg(windows)]
fn call_app_from_file(path: &Path) -> Result<AdditionalCallApp, &'static str> {
    if !path
        .extension()
        .is_some_and(|ext| ext.eq_ignore_ascii_case("exe"))
        || !path.is_file()
    {
        return Err("Choose an application file (.exe).");
    }
    let identifier = path
        .file_name()
        .ok_or("Choose an application file (.exe).")?
        .to_string_lossy()
        .into_owned();
    if lokalbot_platform::meeting::has_built_in_call_detection(&identifier) {
        return Err("LokalBot already supports this app.");
    }
    let name = lokalbot_platform::activity::executable_display_name(path);
    Ok(AdditionalCallApp {
        identifier,
        name: Some(name),
    })
}

impl SettingsPage {
    pub(super) fn meetings_sections(&mut self, cx: &mut Context<Self>) -> Vec<Section> {
        let data_entity = self.data.clone();
        let (settings, microphones) = {
            let data = self.data.read(cx);
            (data.settings.clone(), data.audio_inputs.clone())
        };

        let debounce = settings.stop_debounce_seconds.round().clamp(5., 120.);
        let debounce_data = data_entity.clone();
        let mut microphone_options: Vec<(SharedString, SharedString)> =
            vec![("".into(), lokalbot_i18n::tr("System default").into())];
        microphone_options.extend(microphones.iter().map(|name| (name.clone(), name.clone())));
        if !settings.microphone_device.is_empty()
            && !microphones
                .iter()
                .any(|m| m.as_ref() == settings.microphone_device)
        {
            let name: SharedString = settings.microphone_device.clone().into();
            microphone_options.push((name.clone(), name));
        }
        let microphone_current = microphone_options
            .iter()
            .find(|(value, _)| value.as_ref() == settings.microphone_device)
            .map(|(_, label)| label.clone())
            .unwrap_or_else(|| lokalbot_i18n::tr("System default").into());
        let microphone_items: Vec<(SharedString, bool)> = microphone_options
            .iter()
            .map(|(value, label)| (label.clone(), value.as_ref() == settings.microphone_device))
            .collect();
        let microphone_values: Vec<String> = microphone_options
            .iter()
            .map(|(value, _)| value.to_string())
            .collect();
        let microphone_data = data_entity.clone();

        let meetings = Section::new(lokalbot_i18n::tr("Meetings"))
            .row(
                "settings.autoRecordMode",
                self.choice(
                    "settings.autoRecordMode",
                    lokalbot_i18n::tr("When a meeting is detected"),
                    Some(lokalbot_i18n::tr("Only record when everyone has been informed and any consent the meeting or location requires is in place.").into()),
                    AutoRecordMode::ALL.iter().map(|m| (*m, SharedString::from(lokalbot_i18n::tr(m.label())))).collect(),
                    settings.auto_record_mode,
                    |s, v| s.auto_record_mode = v,
                    cx,
                ),
            )
            .row(
                "settings.detectedApps",
                settings_row::row(
                    "settings.detectedApps",
                    lokalbot_i18n::tr("Detected apps"),
                    Some(lokalbot_i18n::tr(DETECTED_APPS).into()),
                    gpui_kit::div(),
                    false,
                    cx,
                ),
            )
            .row(
                "settings.stopDebounceSeconds",
                settings_row::row(
                    "settings.stopDebounceSeconds",
                    lokalbot_i18n::tr("Wait before stopping"),
                    None,
                    settings_row::stepper(
                        "settings-stop-debounce",
                        lokalbot_i18n::format("{debounce} s after audio stops", &[("debounce", format!("{}", debounce))]),
                        debounce > 5.,
                        debounce < 120.,
                        move |step, _, cx| {
                            let next = (debounce + f64::from(step) * 5.).clamp(5., 120.);
                            debounce_data.update(cx, |data, cx| data.update_settings(|s| s.stop_debounce_seconds = next, cx));
                        },
                        cx,
                    ),
                    self.is_focused("settings.stopDebounceSeconds"),
                    cx,
                ),
            )
            .row(
                "settings.recordSystemAudio",
                self.toggle(
                    "settings.recordSystemAudio",
                    lokalbot_i18n::tr("Record system audio"),
                    Some(lokalbot_i18n::tr("Records the other side of calls from the meeting app when this computer can separate its sound, otherwise everything it plays. Without it, only your microphone is recorded. Separating an app's sound needs Windows 10 build 20348 or later, or PulseAudio or PipeWire on Linux.")),
                    settings.record_system_audio,
                    |s, v| s.record_system_audio = v,
                    cx,
                ),
            )
            .row(
                "settings.microphoneDevice",
                settings_row::row(
                    "settings.microphoneDevice",
                    lokalbot_i18n::tr("Microphone"),
                    None,
                    settings_row::picker("settings-microphone", microphone_current, microphone_items, move |index, _, cx| {
                        if let Some(value) = microphone_values.get(index).cloned() {
                            microphone_data.update(cx, |data, cx| data.update_settings(|s| s.microphone_device = value, cx));
                        }
                    }),
                    self.is_focused("settings.microphoneDevice"),
                    cx,
                ),
            );

        #[cfg(windows)]
        let meetings = meetings
            .row(
                "settings.detectOtherBrowserCalls",
                self.toggle(
                    "settings.detectOtherBrowserCalls",
                    lokalbot_i18n::tr("Detect other browser calls"),
                    Some(lokalbot_i18n::tr("Uses browser microphone activity to detect calls on other sites. The browser's audio can include other tabs.")),
                    settings.detect_other_browser_calls,
                    |s, v| s.detect_other_browser_calls = v,
                    cx,
                ),
            )
            .row(
                "settings.additionalCallApps",
                self.call_app_editor(&settings, cx),
            );

        let models_data = data_entity.clone();
        let processing = Section::new(lokalbot_i18n::tr("Processing"))
            .row(
                "settings.autoTranscribe",
                self.toggle(
                    "settings.autoTranscribe",
                    lokalbot_i18n::tr("Transcribe automatically after each meeting"),
                    None,
                    settings.auto_transcribe,
                    |s, v| s.auto_transcribe = v,
                    cx,
                ),
            )
            .row(
                "settings.autoSummarize",
                self.toggle(
                    "settings.autoSummarize",
                    lokalbot_i18n::tr("Summarize automatically after transcription"),
                    None,
                    settings.auto_summarize,
                    |s, v| s.auto_summarize = v,
                    cx,
                ),
            )
            .row(
                "settings.processingModels",
                settings_row::row(
                    "settings.processingModels",
                    lokalbot_i18n::tr("Transcribe and Think models"),
                    None,
                    Button::new("settings-manage-models")
                        .outline()
                        .small()
                        .label(lokalbot_i18n::tr("Manage in Models…"))
                        .on_click(move |_, _, cx| {
                            models_data.update(cx, |data, cx| {
                                data.open_settings(SettingsCategory::Models, cx)
                            });
                        }),
                    false,
                    cx,
                ),
            );

        let mut languages: Vec<(&'static str, SharedString)> =
            vec![("match", lokalbot_i18n::tr("Match transcript (auto)").into())];
        languages.extend(
            SUMMARY_LANGUAGES
                .iter()
                .map(|(code, name)| (*code, SharedString::from(lokalbot_i18n::tr(name)))),
        );
        let current_language = languages
            .iter()
            .find(|(code, _)| *code == settings.summary_language)
            .map(|(code, _)| *code)
            .unwrap_or("match");
        let summarization = Section::new(lokalbot_i18n::tr("Summarization"))
            .row(
                "settings.noteTemplate",
                self.choice(
                    "settings.noteTemplate",
                    lokalbot_i18n::tr("Notes template"),
                    Some(template_description(settings.note_template).into()),
                    NoteTemplate::ALL
                        .iter()
                        .map(|t| (*t, SharedString::from(lokalbot_i18n::tr(t.label()))))
                        .collect(),
                    settings.note_template,
                    |s, v| s.note_template = v,
                    cx,
                ),
            )
            .row(
                "settings.summaryLanguage",
                self.choice(
                    "settings.summaryLanguage",
                    lokalbot_i18n::tr("Notes language"),
                    None,
                    languages,
                    current_language,
                    |s, v| s.summary_language = v.to_string(),
                    cx,
                ),
            )
            .row(
                "settings.meetingNotesUseCalendarContext",
                self.toggle(
                    "settings.meetingNotesUseCalendarContext",
                    lokalbot_i18n::tr("Give notes the calendar title and invited names"),
                    Some(lokalbot_i18n::tr("Helps spell names and relate the discussion to the meeting. Names only; email addresses are never included. The transcript stays the only evidence for decisions and actions.")),
                    settings.meeting_notes_use_calendar_context,
                    |s, v| s.meeting_notes_use_calendar_context = v,
                    cx,
                ),
            );

        let speakers = Section::new(lokalbot_i18n::tr("Speaker names"))
            .row(
                "settings.multiSpeakerDiarization",
                self.toggle(
                    "settings.multiSpeakerDiarization",
                    lokalbot_i18n::tr("Separate voices by speaker"),
                    None,
                    settings.multi_speaker_diarization,
                    |s, v| s.multi_speaker_diarization = v,
                    cx,
                ),
            )
            .row(
                "settings.microphoneIsUser",
                self.toggle(
                    "settings.microphoneIsUser",
                    lokalbot_i18n::tr("My microphone is me"),
                    Some(lokalbot_i18n::tr("Treats speech from this PC's microphone as yours, so your commitments lead each meeting's action items. Turn off when several people share this microphone, such as in a meeting room. Summarize a meeting again to update its action items.")),
                    settings.microphone_is_user,
                    |s, v| s.microphone_is_user = v,
                    cx,
                ),
            )
            .row(
                "settings.rememberSpeakers",
                settings_row::row(
                    "settings.rememberSpeakers",
                    lokalbot_i18n::tr("Remembered people"),
                    Some(
                        if settings.multi_speaker_diarization {
                            lokalbot_i18n::tr("When you name a speaker, LokalBot remembers their voice in an encrypted profile on this computer and suggests their name in later meetings. You apply each suggestion, and suggestions never train profiles.")
                        } else {
                            lokalbot_i18n::tr("Turn on “Separate voices by speaker” to collect the voice samples remembering needs.")
                        }
                        .into(),
                    ),
                    Button::new("settings-remembered-people")
                        .outline()
                        .small()
                        .label(lokalbot_i18n::tr("Manage remembered people…"))
                        .on_click({
                            let data = data_entity.clone();
                            move |_, window, cx| {
                                super::remembered_people::RememberedPeople::open(
                                    data.clone(),
                                    window,
                                    cx,
                                );
                            }
                        }),
                    self.is_focused("settings.rememberSpeakers"),
                    cx,
                ),
            );

        let echo = Section::new(lokalbot_i18n::tr("Speakers and echo")).row(
            "settings.echoCancellation",
            self.toggle(
                "settings.echoCancellation",
                lokalbot_i18n::tr("Remove the other side from your microphone track"),
                Some(lokalbot_i18n::tr("Use on speakers, where the other side reaches your microphone and would be transcribed twice. Also cleans meetings already recorded.")),
                settings.echo_cancellation,
                |s, v| s.echo_cancellation = v,
                cx,
            ),
        );

        let mut on_screen = Section::new(lokalbot_i18n::tr("Screen context in meetings")).row(
            "settings.meetingNotesUseScreenTitles",
            self.toggle(
                "settings.meetingNotesUseScreenTitles",
                lokalbot_i18n::tr("Give notes the titles of documents on screen"),
                Some(lokalbot_i18n::tr("Adds titles of documents and pages captured during the call, never their captured text. Requires screen context in Screen & Activity.")),
                settings.meeting_notes_use_screen_titles,
                |s, v| s.meeting_notes_use_screen_titles = v,
                cx,
            ),
        );
        if settings.screen_context_capture_mode == lokalbot_core::ScreenContextMode::TextAndVisual {
            on_screen = on_screen.row(
                "settings.meetingVisualContextEnabled",
                self.toggle(
                    "settings.meetingVisualContextEnabled",
                    lokalbot_i18n::tr("Capture low-frequency visual context during meetings"),
                    Some(lokalbot_i18n::tr("Off by default. Captures the window in front at most once a minute on meaningful changes and links each frame to the meeting.")),
                    settings.meeting_visual_context_enabled,
                    |s, v| s.meeting_visual_context_enabled = v,
                    cx,
                ),
            );
        }
        if settings.screen_context_capture_mode != lokalbot_core::ScreenContextMode::ActivityOnly {
            on_screen = on_screen.row(
                "settings.suggestActionCompletion",
                self.toggle(
                    "settings.suggestActionCompletion",
                    lokalbot_i18n::tr("Suggest actions that look done"),
                    Some(lokalbot_i18n::tr("When later captured text shows an action's words with a completion such as “message sent” or “merged”, the action offers Mark Done. Nothing changes until you confirm.")),
                    settings.suggest_action_completion,
                    |s, v| s.suggest_action_completion = v,
                    cx,
                ),
            );
        }

        let calendar = self.calendar_section(cx);
        let note_export = self.meeting_note_export_section(cx);
        vec![
            meetings,
            calendar,
            processing,
            summarization,
            speakers,
            note_export,
            echo,
            on_screen,
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn language_labels() {
        assert_eq!(summary_language_label("match"), "Match transcript (auto)");
        assert_eq!(summary_language_label("pt-PT"), "Portuguese (Portugal)");
        assert_eq!(summary_language_label("custom:Klingon"), "Klingon");
    }
}
