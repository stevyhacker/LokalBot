//! The first-day steps (`GettingStartedCard.swift`). On a day with nothing to
//! show yet they are Today's content; after that they stay under the day
//! until hidden.

use gpui_kit::component::button::ButtonVariants as _;
use gpui_kit::component::{Disableable as _, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Context, FontWeight, IntoElement, ParentElement as _, SharedString,
    Styled as _, div, px,
};
use lokalbot_engine::CalendarStatus;

use super::{CARD_TITLE_COMPACT, TodayPage, card_surface, record_button};
use crate::i18n::h_flex;
use crate::state::{AppEvent, Section, SettingsCategory};
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico};

impl TodayPage {
    pub(super) fn render_getting_started(&self, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let data = self.data.read(cx);
        let recording = data.recording.is_active();
        let has_meeting = recording || data.meetings.iter().any(|m| m.is_own_work());
        let has_sample = data.sample_meeting().is_some();
        let calendar_on = data.settings.calendar_detection_enabled;
        let calendar_connected = calendar_on && data.calendar.status == CalendarStatus::Ready;
        let autocomplete = data.settings.cotyping_enabled;
        let model_ready = data.models.transcription_ready;
        let downloading = !data.downloads.is_empty();

        let handle = self.data.clone();
        let on =
            move |change: fn(&mut crate::state::AppData, &mut Context<crate::state::AppData>)| {
                let data = handle.clone();
                move |_: &gpui_kit::ClickEvent, _: &mut gpui_kit::Window, cx: &mut App| {
                    data.update(cx, change)
                }
            };
        let button =
            |id: &'static str, label: &'static str| ui::controls::bordered(id, label).small();

        let steps: Vec<AnyElement> = vec![
            step(
                has_meeting,
                lokalbot_i18n::tr("Record or import your first meeting").into(),
                vec![
                    record_button("welcome-record", cx)
                        .small()
                        .disabled(recording)
                        .on_click(on(|data, cx| data.start_recording(cx)))
                        .into_any_element(),
                    button("welcome-import", lokalbot_i18n::tr("Import Recording…"))
                        .on_click({
                            let data = self.data.clone();
                            move |_, _, cx| {
                                crate::pages::meetings::list::choose_recordings(data.clone(), cx)
                            }
                        })
                        .into_any_element(),
                ],
                cx,
            ),
            step(
                has_sample,
                lokalbot_i18n::tr("Try the sample meeting").into(),
                vec![
                    button("welcome-sample", lokalbot_i18n::tr("Open sample"))
                        .on_click(on(|data, cx| data.try_sample(cx)))
                        .into_any_element(),
                ],
                cx,
            ),
            step(
                calendar_connected,
                lokalbot_i18n::tr("Show your next meeting here").into(),
                if calendar_connected {
                    Vec::new()
                } else {
                    vec![
                        button("welcome-calendar", lokalbot_i18n::tr("Connect Calendar…"))
                            .on_click({
                                let data = self.data.clone();
                                // The switch while calendar use is off, else
                                // the calendar links it reads.
                                let focus = if calendar_on {
                                    "settings.calendarLinks"
                                } else {
                                    "settings.calendarDetectionEnabled"
                                };
                                move |_, _, cx| {
                                    data.update(cx, |data, cx| {
                                        data.open_settings(SettingsCategory::Meetings, cx);
                                        data.settings_focus = Some(focus.to_string());
                                        cx.notify();
                                    })
                                }
                            })
                            .into_any_element(),
                    ]
                },
                cx,
            ),
            // Timeline is where day tracking is explained and turned on.
            step(
                false,
                lokalbot_i18n::tr("See where your time goes").into(),
                vec![
                    button(
                        "welcome-tracking",
                        lokalbot_i18n::tr("Turn on day tracking"),
                    )
                    .on_click(on(|data, cx| data.navigate(Section::Timeline, cx)))
                    .into_any_element(),
                ],
                cx,
            ),
            step(
                autocomplete,
                lokalbot_i18n::tr("Try autocomplete").into(),
                vec![
                    button("welcome-autocomplete", lokalbot_i18n::tr("Try it"))
                        .on_click(on(|data, cx| {
                            data.open_settings(SettingsCategory::Writing, cx)
                        }))
                        .into_any_element(),
                ],
                cx,
            ),
            // Get the transcription model onto disk before the first recap
            // needs it.
            step(
                model_ready,
                if model_ready {
                    lokalbot_i18n::tr("Transcription model ready — recaps run entirely on-device.")
                } else {
                    lokalbot_i18n::tr("Download the transcription model")
                }
                .into(),
                if model_ready {
                    Vec::new()
                } else if downloading {
                    vec![
                        h_flex()
                            .gap(px(8.))
                            .items_center()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(gpui_kit::component::spinner::Spinner::new().small())
                            .child(lokalbot_i18n::tr("Downloading…"))
                            .into_any_element(),
                    ]
                } else {
                    vec![
                        button("welcome-download", lokalbot_i18n::tr("Download"))
                            .on_click(on(|data, cx| data.request(AppEvent::PrepareModels, cx)))
                            .into_any_element(),
                    ]
                },
                cx,
            ),
        ];
        let count = steps.len();
        let hide = self.data.clone();
        card_surface(None, cx)
            .child(
                v_flex()
                    .w_full()
                    .gap(px(4.))
                    .px(px(18.))
                    .py(px(16.))
                    .child(
                        h_flex()
                            .w_full()
                            .items_center()
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .text_size(CARD_TITLE_COMPACT)
                                    .font_weight(FontWeight::BOLD)
                                    .text_color(lb.text)
                                    .child(lokalbot_i18n::tr("Get started")),
                            )
                            .child(
                                gpui_kit::component::button::Button::new("welcome-dismiss")
                                    .text()
                                    .small()
                                    .text_color(lb.accent_text)
                                    .label(lokalbot_i18n::tr("Hide"))
                                    .tooltip(lokalbot_i18n::tr("Dismiss"))
                                    .on_click(move |_, _, cx| {
                                        hide.update(cx, |data, cx| {
                                            data.update_settings(
                                                |s| s.getting_started_dismissed = true,
                                                cx,
                                            )
                                        })
                                    }),
                            ),
                    )
                    .child(
                        v_flex()
                            .w_full()
                            .children(steps.into_iter().enumerate().flat_map(|(ix, step)| {
                                let mut parts = vec![step];
                                if ix + 1 < count {
                                    parts.push(ui::divider(cx).into_any_element());
                                }
                                parts
                            })),
                    ),
            )
            .into_any_element()
    }
}

/// One step: done or not, what it is, and the buttons that do it.
fn step(done: bool, label: SharedString, actions: Vec<AnyElement>, cx: &App) -> AnyElement {
    let lb = cx.lb();
    h_flex()
        .w_full()
        .min_h(px(42.))
        .py(px(6.))
        .gap(px(10.))
        .items_center()
        .child(if done {
            ui::icon(Ico::CircleCheck, px(18.), lb.success_text).into_any_element()
        } else {
            ui::icon(Ico::Circle, px(18.), lb.accent_text).into_any_element()
        })
        .child(
            div()
                .flex_1()
                .min_w_0()
                .text_size(ty::BODY)
                .text_color(lb.text)
                .child(ui::text::paragraph(label)),
        )
        .child(
            h_flex()
                .flex_none()
                .flex_wrap()
                .gap(px(6.))
                .items_center()
                .when(!actions.is_empty(), |this| this.children(actions)),
        )
        .into_any_element()
}
