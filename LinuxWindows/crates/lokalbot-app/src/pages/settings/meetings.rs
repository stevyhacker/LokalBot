//! Meetings: detection, processing, summaries, speakers and note export.

use gpui_kit::component::Sizable as _;
use gpui_kit::component::button::Button;
use gpui_kit::{Context, SharedString};
use lokalbot_core::settings::{AutoRecordMode, NoteTemplate};

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
const DETECTED_APPS: &str = "Zoom, Microsoft Teams, Slack, Webex, and Google Meet in a browser";

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
