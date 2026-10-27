//! Day Memory: activity tracking, screen context and the day digest.

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::Textarea;
use gpui_kit::component::slider::Slider;
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, Context, IntoElement as _, ParentElement as _, SharedString, Styled as _, div, px,
};
use lokalbot_core::ScreenContextMode;

use super::{Section, SettingsPage};
use crate::state::AppEvent;
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

fn hour_label(hour: u32) -> String {
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
        let lb = cx.lb().clone();

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
        let mut memory = Section::new(lokalbot_i18n::tr("Day Memory"))
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
            memory = memory
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
                    "settings.screenTextRecognition",
                    self.screen_text_model_row(cx),
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
                    "settings.captureManage",
                    settings_row::content_row(
                        "settings.captureManage",
                        h_flex()
                            .gap(px(8.))
                            .flex_wrap()
                            .child(Button::new("settings-manage-retention").outline().small().label(lokalbot_i18n::tr("Manage retention and cleanup…")).on_click(
                                cx.listener(|this, _, window, cx| this.reveal("settings.retentionDays", window, cx)),
                            ))
                            .child(Button::new("settings-manage-exclusions").outline().small().label(lokalbot_i18n::tr("Manage capture exclusions…")).on_click(
                                cx.listener(|this, _, window, cx| this.reveal("settings.excludedApps", window, cx)),
                            )),
                        false,
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
                            lokalbot_i18n::tr("Captures context after app or window changes, a pause in typing or pointer input, a clipboard change, or the idle fallback, without storing keys, pointer positions, or clipboard contents. Accessible text is preferred; on-device OCR fills gaps. Private windows, excluded apps and sites, password fields, and detected credentials are never captured, and nothing is captured while day memory is paused or the screen is locked. Images are encrypted with a key kept in this PC's credential store; extracted text follows the same retention (see Privacy & Data). Saved moments keep their encrypted frame and text until you unsave or delete them. Excluded apps log as “Private”."),
                            cx,
                        ),
                        false,
                        cx,
                    ),
                );
        } else {
            memory = memory
                .row(
                    "settings.activityManage",
                    settings_row::content_row(
                        "settings.activityManage",
                        h_flex()
                            .gap(px(8.))
                            .flex_wrap()
                            .child(Button::new("settings-manage-retention").outline().small().label(lokalbot_i18n::tr("Manage retention…")).on_click(
                                cx.listener(|this, _, window, cx| this.reveal("settings.retentionDays", window, cx)),
                            ))
                            .child(Button::new("settings-manage-exclusions").outline().small().label(lokalbot_i18n::tr("Manage exclusions…")).on_click(
                                cx.listener(|this, _, window, cx| this.reveal("settings.excludedApps", window, cx)),
                            )),
                        false,
                        cx,
                    ),
                )
                .row(
                    "settings.activityDetails",
                    settings_row::content_row(
                        "settings.activityDetails",
                        self.details(
                            "settings.activityDetails",
                            lokalbot_i18n::tr("What is recorded"),
                            lokalbot_i18n::tr("Every few seconds LokalBot notes the app in front and its window title, and how long you stay. With screen context off it never records what you type, the clipboard, or what is on screen. Excluded apps and sites are logged as “Private” with the time only, password managers are always excluded, and passwords or keys in window titles are redacted. Window titles are cleared after the retention period in Privacy & Data."),
                            cx,
                        ),
                        false,
                        cx,
                    ),
                );
        }

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

        vec![memory, digest]
    }

    /// What capture can do on this desktop right now (`MemoryHealthSection`).
    fn screen_status(&self, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let (status, settings, paused) = {
            let data = self.data.read(cx);
            (
                data.screen.clone(),
                data.settings.clone(),
                data.day_memory_paused,
            )
        };
        let visual = settings.screen_context_capture_mode == ScreenContextMode::TextAndVisual;
        let mut notes: Vec<(Ico, String, bool)> = Vec::new();
        if let Some(limitation) = &status.capture_limitation {
            notes.push((Ico::TriangleAlert, limitation.clone(), true));
        }
        if visual && let Some(images) = &status.images_unavailable {
            notes.push((Ico::TriangleAlert, images.clone(), true));
        }
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

    /// The OCR models: what they do, their size, and Download when missing.
    fn screen_text_model_row(&self, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let (installed, progress) = {
            let data = self.data.read(cx);
            (
                data.models.screen_text_ready,
                data.downloads.get(lokalbot_ai::ocr::OCR_MODEL_ID).cloned(),
            )
        };
        let size = super::models::size_label(lokalbot_ai::ocr::total_size());
        let help = lokalbot_i18n::format(
            "Reads text from the window's pixels on this PC when accessibility shows little. ocrs, {size}, models under {0}. Latin script only.",
            &[
                ("size", size.to_string()),
                ("0", lokalbot_ai::ocr::OCR_MODEL_LICENSE.to_string()),
            ],
        );
        let data = self.data.clone();
        let control: AnyElement = match (&progress, installed) {
            (Some(progress), _) if progress.error.is_none() => div()
                .text_size(ty::SECONDARY)
                .text_color(lb.text_secondary)
                .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                    "Downloading · {0}%",
                    &[("0", format!("{}", (progress.fraction() * 100.).round()))],
                )))
                .into_any_element(),
            (_, true) => settings_row::value(lokalbot_i18n::tr("Ready"), cx).into_any_element(),
            _ => Button::new("settings-download-ocr")
                .primary()
                .small()
                .icon(Icon::new(Ico::CircleArrowDown))
                .label(lokalbot_i18n::format(
                    "Download · {size}",
                    &[("size", size.to_string())],
                ))
                .on_click(move |_, _, cx| {
                    data.update(cx, |data, cx| {
                        data.request(
                            AppEvent::DownloadModel(lokalbot_ai::ocr::OCR_MODEL_ID.to_string()),
                            cx,
                        )
                    })
                })
                .into_any_element(),
        };
        let failed = progress.and_then(|p| p.error);
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

/// `MemoryHealthSection.textSourceLabel`.
fn text_source_label(source: &str) -> String {
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
