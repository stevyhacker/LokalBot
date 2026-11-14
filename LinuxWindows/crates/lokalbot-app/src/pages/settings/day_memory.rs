//! Screen & activity (activity tracking and screen context) and Daily
//! review (the day digest, with the overnight review, routines and the
//! daily note from their own files).

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::Textarea;
use gpui_kit::component::slider::Slider;
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Context, Entity, IntoElement as _, ParentElement as _, SharedString,
    Styled as _, div, px,
};
use lokalbot_ai::ocr::{self, OcrBackend, OcrStatus};
use lokalbot_core::ScreenContextMode;

use super::{Section, SettingsPage};
use crate::state::{AppData, AppEvent};
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico, settings_row};

/// The first characters of the digest instructions that are used.
pub const DIGEST_PROMPT_LIMIT: usize = 500;

/// `ScreenContextCaptureMode.detail`, for this platform's accessibility and OCR.
pub fn mode_detail(mode: ScreenContextMode) -> &'static str {
    match mode {
        ScreenContextMode::ActivityOnly => {
            lokalbot_i18n::tr("Records the active app and window title only.")
        }
        ScreenContextMode::Text => lokalbot_i18n::tr(
            "Reads visible interface text through accessibility, with on-device OCR when it shows little; no screenshots are stored.",
        ),
        ScreenContextMode::TextAndVisual => lokalbot_i18n::tr(
            "Pairs visible text with an encrypted screenshot, using on-device OCR only when needed.",
        ),
    }
}

pub(super) fn hour_label(hour: u32) -> String {
    chrono::NaiveDate::from_ymd_opt(2000, 1, 1)
        .unwrap()
        .and_hms_opt(hour % 24, 0, 0)
        .unwrap()
        .and_utc()
        .format_localized(
            lokalbot_i18n::date_pattern("%-I %p"),
            lokalbot_i18n::date_locale(),
        )
        .to_string()
}

impl SettingsPage {
    pub(super) fn day_memory_sections(&mut self, cx: &mut Context<Self>) -> Vec<Section> {
        let settings = self.data.read(cx).settings.clone();
        let data = self.data.clone();

        let captures_text = settings.tracking_enabled
            && settings.screen_context_capture_mode != ScreenContextMode::ActivityOnly;
        let tracking_data = data.clone();
        let mode_data = data.clone();
        let mode_items: Vec<(SharedString, bool)> = ScreenContextMode::ALL
            .iter()
            .map(|m| {
                (
                    SharedString::from(lokalbot_i18n::tr(m.label())),
                    *m == settings.screen_context_capture_mode,
                )
            })
            .collect();
        let mut memory = Section::new(lokalbot_i18n::tr("Activity"))
            .row(
                "settings.trackingEnabled",
                settings_row::row(
                    "settings.trackingEnabled",
                    lokalbot_i18n::tr("Track app & window activity"),
                    Some(lokalbot_i18n::tr("Records which app and window you're using for the Timeline and day digest.").into()),
                    settings_row::switch("settings.trackingEnabled", settings.tracking_enabled, move |on, _, cx| {
                        tracking_data.update(cx, |data, cx| {
                            data.update_settings(
                                |s| {
                                    s.tracking_enabled = on;
                                    if !on {
                                        s.screen_context_capture_mode = ScreenContextMode::ActivityOnly;
                                    }
                                },
                                cx,
                            )
                        })
                    }),
                    self.is_focused("settings.trackingEnabled"),
                    cx,
                ),
            )
            .row(
                "settings.screenContextCaptureMode",
                settings_row::row(
                    "settings.screenContextCaptureMode",
                    lokalbot_i18n::tr("Screen context"),
                    Some(mode_detail(settings.screen_context_capture_mode).into()),
                    settings_row::picker(
                        "settings-screen-context",
                        lokalbot_i18n::tr(settings.screen_context_capture_mode.label()),
                        mode_items,
                        move |index, _, cx| {
                            let mode = ScreenContextMode::ALL[index];
                            mode_data.update(cx, |data, cx| {
                                data.update_settings(
                                    |s| {
                                        s.screen_context_capture_mode = mode;
                                        if mode != ScreenContextMode::ActivityOnly {
                                            s.tracking_enabled = true;
                                        }
                                    },
                                    cx,
                                )
                            })
                        },
                    ),
                    self.is_focused("settings.screenContextCaptureMode"),
                    cx,
                ),
            );
        if captures_text {
            let minutes = settings
                .screenshot_interval_minutes
                .round()
                .clamp(1.0, 15.0) as u32;
            // The download recognition needs is offered right under the choice.
            memory = memory
                .row(
                    "settings.screenTextRecognition",
                    self.screen_text_model_row(cx),
                )
                .row(
                    "settings.screenContextStatus",
                    settings_row::content_row(
                        "settings.screenContextStatus",
                        self.screen_status(cx),
                        false,
                        cx,
                    ),
                )
                .row(
                    "settings.screenshotIntervalMinutes",
                    settings_row::stacked_row(
                        "settings.screenshotIntervalMinutes",
                        lokalbot_i18n::format("Idle fallback: at least every {minutes} min", &[("minutes", format!("{}", minutes))]),
                        None,
                        Slider::new(&self.interval_slider).w_full(),
                        self.is_focused("settings.screenshotIntervalMinutes"),
                        cx,
                    ),
                )
                .row(
                    "settings.captureDetails",
                    settings_row::content_row(
                        "settings.captureDetails",
                        self.details(
                            "settings.captureDetails",
                            lokalbot_i18n::tr("How screen context is captured"),
                            lokalbot_i18n::tr("Captures context after app or window changes, a pause in typing or pointer input, a clipboard change, or the idle fallback, without storing keys, pointer positions, or clipboard contents. Accessible text is preferred; on-device OCR fills gaps. Private windows, excluded apps and sites, password fields, and detected credentials are never captured, and nothing is captured while day memory is paused or the screen is locked. Images are encrypted with a key kept in this PC's credential store; extracted text follows the same retention. Saved moments keep their encrypted frame and text until you unsave or delete them. Excluded apps log as “Private”."),
                            cx,
                        ),
                        false,
                        cx,
                    ),
                );
        } else {
            memory = memory
                .row(
                    "settings.activityDetails",
                    settings_row::content_row(
                        "settings.activityDetails",
                        self.details(
                            "settings.activityDetails",
                            lokalbot_i18n::tr("What is recorded"),
                            lokalbot_i18n::tr("Every few seconds LokalBot notes the app in front and its window title, and how long you stay. With screen context off it never records what you type, the clipboard, or what is on screen. Excluded apps and sites are logged as “Private” with the time only, password managers are always excluded, and passwords or keys in window titles are redacted. Window titles are cleared after the retention period set below."),
                            cx,
                        ),
                        false,
                        cx,
                    ),
                );
        }

        vec![memory]
    }

    /// Daily review (`SettingsTab.daily`): the day digest, the overnight
    /// review, routines and the daily note, which Day Memory held before.
    pub(super) fn daily_review_sections(&mut self, cx: &mut Context<Self>) -> Vec<Section> {
        let settings = self.data.read(cx).settings.clone();
        let data = self.data.clone();
        let lb = cx.lb().clone();
        let hour = settings.day_digest_hour.min(23);
        let hour_data = data.clone();
        let used = settings.day_digest_custom_prompt.trim().chars().count();
        let counter = if used > DIGEST_PROMPT_LIMIT {
            Some((
                lokalbot_i18n::format(
                    "{used} of {DIGEST_PROMPT_LIMIT} characters. Only the first {DIGEST_PROMPT_LIMIT} are used; shorten the rest.",
                    &[
                        ("used", format!("{}", used)),
                        ("DIGEST_PROMPT_LIMIT", format!("{}", DIGEST_PROMPT_LIMIT)),
                    ],
                ),
                lb.attention_text,
            ))
        } else if used > 0 {
            Some((
                lokalbot_i18n::format(
                    "{used} of {DIGEST_PROMPT_LIMIT} characters",
                    &[
                        ("used", format!("{}", used)),
                        ("DIGEST_PROMPT_LIMIT", format!("{}", DIGEST_PROMPT_LIMIT)),
                    ],
                ),
                lb.text_secondary,
            ))
        } else {
            None
        };
        let mut digest = Section::new(lokalbot_i18n::tr("Day digest")).row(
            "settings.dayDigestAutoEnabled",
            self.toggle(
                "settings.dayDigestAutoEnabled",
                lokalbot_i18n::tr("Generate the day digest automatically"),
                Some(lokalbot_i18n::tr("Writes the Timeline digest to your local journal at the chosen time, then finalizes yesterday after midnight so late activity is included.")),
                settings.day_digest_auto_enabled,
                |s, v| s.day_digest_auto_enabled = v,
                cx,
            ),
        );
        if settings.day_digest_auto_enabled {
            digest = digest.row(
                "settings.dayDigestHour",
                settings_row::row(
                    "settings.dayDigestHour",
                    lokalbot_i18n::format(
                        "Generate at {0}",
                        &[("0", hour_label(hour).to_string())],
                    ),
                    None,
                    settings_row::stepper(
                        "settings-digest-hour",
                        "",
                        hour > 0,
                        hour < 23,
                        move |step, _, cx| {
                            let next = (hour as i32 + step).clamp(0, 23) as u32;
                            hour_data.update(cx, |data, cx| {
                                data.update_settings(|s| s.day_digest_hour = next, cx)
                            });
                        },
                        cx,
                    ),
                    self.is_focused("settings.dayDigestHour"),
                    cx,
                ),
            );
        }
        digest = digest.row(
            "settings.dayDigestCustomPrompt",
            settings_row::stacked_row(
                "settings.dayDigestCustomPrompt",
                lokalbot_i18n::tr("Digest instructions (optional)"),
                Some(lokalbot_i18n::format("Shapes both scheduled and manual digests. The first {DIGEST_PROMPT_LIMIT} characters are used.", &[("DIGEST_PROMPT_LIMIT", format!("{}", DIGEST_PROMPT_LIMIT))]).into()),
                v_flex()
                    .gap(px(6.))
                    .child(Textarea::new(&self.digest_prompt).h(px(72.)).text_size(ty::BODY))
                    .when_some(counter, |this, (text, color)| {
                        this.child(div().text_size(ty::CAPTION).text_color(color).child(text))
                    }),
                self.is_focused("settings.dayDigestCustomPrompt"),
                cx,
            ),
        );

        let routines = self.routines_section(cx);
        let daily_notes = self.daily_note_export_section(cx);
        let overnight = self.overnight_review_section(cx);
        vec![digest, overnight, routines, daily_notes]
    }

    /// What capture can do on this desktop right now (`MemoryHealthSection`).
    fn screen_status(&self, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let (status, paused) = {
            let data = self.data.read(cx);
            (data.screen.clone(), data.day_memory_paused)
        };
        // What this desktop doesn't allow (window pixels, the credential
        // store) is said in the page's header, beside its fix.
        let mut notes: Vec<(Ico, String, bool)> = Vec::new();
        if paused {
            notes.push((
                Ico::Pause,
                lokalbot_i18n::tr("Day memory is paused, so nothing is captured.").into(),
                false,
            ));
        }
        let last = match (&status.last_capture, &status.last_text_source) {
            (Some(at), source) => lokalbot_i18n::format(
                "Last capture {0}{1}",
                &[
                    ("0", lokalbot_core::time::clock_time(*at).to_string()),
                    (
                        "1",
                        source
                            .as_deref()
                            .map(|s| format!(" · {}", text_source_label(s)))
                            .unwrap_or_default()
                            .to_string(),
                    ),
                ],
            ),
            (None, _) => {
                lokalbot_i18n::tr("No screen context captured since LokalBot started").into()
            }
        };
        notes.push((Ico::ScanText, last, false));
        if let Some(error) = &status.last_error {
            notes.push((
                Ico::CircleAlert,
                lokalbot_i18n::format(
                    "The last capture failed: {error}",
                    &[("error", error.to_string())],
                ),
                true,
            ));
        }
        let capture_data = self.data.clone();
        v_flex()
            .gap(px(8.))
            .children(notes.into_iter().map(|(icon, text, warn)| {
                h_flex()
                    .gap(px(8.))
                    .items_start()
                    .child(div().pt(px(2.)).child(ui::icon(
                        icon,
                        px(14.),
                        if warn {
                            lb.attention_text
                        } else {
                            lb.text_secondary
                        },
                    )))
                    .child(settings_row::help(text, cx).flex_1().min_w_0())
            }))
            .child(
                h_flex().child(
                    Button::new("settings-capture-now")
                        .outline()
                        .small()
                        .icon(Icon::new(Ico::Camera))
                        .label(lokalbot_i18n::tr("Capture Screen Now"))
                        .disabled(paused)
                        .on_click(move |_, _, cx| {
                            capture_data
                                .update(cx, |data, cx| data.request(AppEvent::CaptureScreenNow, cx))
                        }),
                ),
            )
            .into_any_element()
    }

    /// Screen text recognition: what reads here, in which languages, and the
    /// download that would help. Never started on its own.
    fn screen_text_model_row(&self, cx: &mut Context<Self>) -> AnyElement {
        let status = self.data.read(cx).models.screen_text.clone();
        let failed = status
            .download
            .and_then(|download| self.data.read(cx).downloads.get(download.id).cloned())
            .and_then(|progress| progress.error);
        let help = screen_text_help(&status);
        let control = screen_text_control(&self.data, "settings-download-ocr", cx);
        settings_row::row(
            "settings.screenTextRecognition",
            lokalbot_i18n::tr("Screen text recognition"),
            Some(match failed {
                Some(error) => lokalbot_i18n::format(
                    "{help} The download failed: {error}",
                    &[("help", help.to_string()), ("error", format!("{}", error))],
                )
                .into(),
                None => help.into(),
            }),
            control,
            self.is_focused("settings.screenTextRecognition"),
            cx,
        )
        .into_any_element()
    }
}

/// What recognition does on this computer and what it would take to do more.
pub(crate) fn screen_text_help(status: &OcrStatus) -> String {
    let list = |names: &[String]| names.join(", ");
    let mut sentences = vec![
        lokalbot_i18n::tr(
            "Reads text from the window's pixels on this PC when accessibility shows little.",
        )
        .to_string(),
    ];
    let offers_ocrs = status.download.is_some_and(|d| d.id == ocr::OCR_MODEL_ID);
    match status.backend {
        OcrBackend::Tesseract => sentences.push(lokalbot_i18n::format(
            "Tesseract reads {languages} here.",
            &[("languages", list(&status.reading))],
        )),
        OcrBackend::Windows => sentences.push(lokalbot_i18n::format(
            "Windows reads {languages} here with its built-in recognizer.",
            &[("languages", list(&status.reading))],
        )),
        OcrBackend::Ocrs | OcrBackend::None
            if status.backend == OcrBackend::Ocrs || offers_ocrs =>
        {
            sentences.push(lokalbot_i18n::format(
                "ocrs ({size}, model license {0}) reads unaccented Latin letters.",
                &[
                    ("size", super::models::size_label(ocr::total_size())),
                    ("0", ocr::OCR_MODEL_LICENSE.to_string()),
                ],
            ));
        }
        _ => {}
    }
    if !status.missing.is_empty() {
        let languages = list(&status.missing);
        if status
            .download
            .is_some_and(|d| d.id == ocr::OCR_LANGUAGES_ID)
        {
            sentences.push(lokalbot_i18n::format(
                "To read {languages}, download their language data from the Tesseract project ({license}).",
                &[
                    ("languages", languages),
                    ("license", ocr::OCR_LANGUAGES_LICENSE.to_string()),
                ],
            ));
        } else if status.needs_program {
            sentences.push(lokalbot_i18n::format(
                "To read {languages}, install the Tesseract program with your package manager.",
                &[("languages", languages)],
            ));
        } else if cfg!(windows) {
            sentences.push(lokalbot_i18n::format(
                "To read {languages}, add the language in Windows Settings under Time & language.",
                &[("languages", languages)],
            ));
        }
    }
    sentences.join(" ")
}

/// Download when that would help, its progress while it runs, or Ready.
pub(crate) fn screen_text_control(
    data: &Entity<AppData>,
    id: &'static str,
    cx: &mut App,
) -> AnyElement {
    let lb = cx.lb().clone();
    let (status, progress) = {
        let state = data.read(cx);
        let status = state.models.screen_text.clone();
        let progress = status
            .download
            .and_then(|download| state.downloads.get(download.id).cloned());
        (status, progress)
    };
    match (status.download, progress) {
        (Some(_), Some(progress)) if progress.error.is_none() => div()
            .text_size(ty::SECONDARY)
            .text_color(lb.text_secondary)
            .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                "Downloading · {0}%",
                &[("0", format!("{}", (progress.fraction() * 100.).round()))],
            )))
            .into_any_element(),
        (Some(download), _) => {
            let data = data.clone();
            Button::new(id)
                .primary()
                .small()
                .icon(Icon::new(Ico::CircleArrowDown))
                .label(lokalbot_i18n::format(
                    "Download · {size}",
                    &[("size", super::models::size_label(download.bytes))],
                ))
                .on_click(move |_, _, cx| {
                    data.update(cx, |data, cx| {
                        data.request(AppEvent::DownloadModel(download.id.to_string()), cx)
                    })
                })
                .into_any_element()
        }
        (None, _) if status.is_ready() => {
            settings_row::value(lokalbot_i18n::tr("Ready"), cx).into_any_element()
        }
        (None, _) => div().into_any_element(),
    }
}

/// `MemoryHealthSection.textSourceLabel`.
pub(super) fn text_source_label(source: &str) -> String {
    let base = source.strip_suffix("_redacted");
    let label = match base.unwrap_or(source) {
        "accessibility" => lokalbot_i18n::tr("Accessibility").to_string(),
        "hybrid" => lokalbot_i18n::tr("Hybrid").to_string(),
        "ocr" => "OCR".to_string(),
        other => {
            let mut chars = other.chars();
            chars
                .next()
                .map(|first| first.to_uppercase().chain(chars).collect())
                .unwrap_or_default()
        }
    };
    if base.is_some() {
        lokalbot_i18n::format("{label}, redacted", &[("label", label.to_string())])
    } else {
        label
    }
}

#[cfg(test)]
mod screen_text_tests {
    use lokalbot_ai::ocr::{OCR_LANGUAGES_ID, OCR_MODEL_ID, OcrBackend, OcrDownload, OcrStatus};

    use super::screen_text_help;

    fn download(id: &'static str) -> Option<OcrDownload> {
        Some(OcrDownload { id, bytes: 1 })
    }

    #[test]
    fn tesseract_names_what_it_reads_and_the_download_for_the_rest() {
        let help = screen_text_help(&OcrStatus {
            backend: OcrBackend::Tesseract,
            reading: vec!["English".into()],
            missing: vec!["简体中文".into()],
            download: download(OCR_LANGUAGES_ID),
            needs_program: false,
        });
        assert!(help.contains("Tesseract reads English here."), "{help}");
        assert!(help.contains("To read 简体中文, download"), "{help}");
        assert!(!help.contains("ocrs"), "{help}");
    }

    #[test]
    fn no_program_says_to_install_it_and_offers_ocrs() {
        let help = screen_text_help(&OcrStatus {
            backend: OcrBackend::None,
            reading: Vec::new(),
            missing: vec!["Русский".into()],
            download: download(OCR_MODEL_ID),
            needs_program: true,
        });
        assert!(help.contains("ocrs ("), "{help}");
        assert!(help.contains("unaccented Latin letters"), "{help}");
        assert!(
            help.contains("To read Русский, install the Tesseract program"),
            "{help}"
        );
    }

    #[test]
    fn nothing_missing_asks_for_nothing() {
        for backend in [OcrBackend::Ocrs, OcrBackend::Tesseract, OcrBackend::Windows] {
            let help = screen_text_help(&OcrStatus {
                backend,
                reading: vec!["English".into()],
                ..Default::default()
            });
            assert!(!help.contains("To read"), "{help}");
        }
    }

    #[test]
    fn the_old_latin_only_claim_is_gone() {
        let help = screen_text_help(&OcrStatus::default());
        assert!(!help.contains("Latin script only"), "{help}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_sources_have_labels() {
        assert_eq!(text_source_label("ocr"), "OCR");
        assert_eq!(text_source_label("hybrid_redacted"), "Hybrid, redacted");
        assert_eq!(text_source_label("accessibility"), "Accessibility");
    }

    #[test]
    fn hours_read_like_the_mac() {
        assert_eq!(hour_label(18), "6 PM");
        assert_eq!(hour_label(0), "12 AM");
        assert_eq!(hour_label(12), "12 PM");
        assert_eq!(hour_label(9), "9 AM");
    }
}
