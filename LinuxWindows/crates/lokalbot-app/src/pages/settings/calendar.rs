//! Meetings → Calendar (`SettingsView.swift` "Calendar"): calendar-assisted
//! detection, the private links it reads (kept in the credential store and
//! shown only by host), Evolution on Linux, and how matches are used.

use gpui_kit::component::Sizable as _;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::v_flex;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    App, AppContext as _, Context, Entity, IntoElement, ParentElement as _, SharedString,
    Styled as _, Subscription, Window, div, px,
};
use lokalbot_core::Settings;
use lokalbot_engine::CalendarStatus;

use super::{Section, SettingsPage};
use crate::i18n::h_flex;
use crate::state::AppEvent;
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico, settings_row};

pub struct CalendarState {
    link: Entity<InputState>,
    addresses: Entity<InputState>,
    /// Saved links, read from the credential store when Settings opens.
    links: Option<Vec<String>>,
    /// A read of the credential store is under way.
    loading_links: bool,
    error: Option<SharedString>,
}

impl CalendarState {
    pub fn new(settings: &Settings, window: &mut Window, cx: &mut Context<SettingsPage>) -> Self {
        let link = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder(crate::i18n::placeholder(
                    "https:// or webcal:// link",
                    window,
                    cx,
                ))
                .masked(true)
        });
        let addresses = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder(crate::i18n::placeholder("you@example.com", window, cx))
                .default_value(settings.calendar_my_email_addresses.clone())
        });
        Self {
            link,
            addresses,
            links: None,
            loading_links: false,
            error: None,
        }
    }

    pub fn subscribe(
        state: &Self,
        window: &mut Window,
        cx: &mut Context<SettingsPage>,
    ) -> Vec<Subscription> {
        vec![
            cx.subscribe_in(
                &state.addresses,
                window,
                |page, input, event: &InputEvent, _, cx| {
                    if matches!(event, InputEvent::Change) {
                        let value = input.read(cx).value().to_string();
                        page.update_settings(move |s| s.calendar_my_email_addresses = value, cx);
                    }
                },
            ),
            cx.subscribe_in(&state.link, window, |page, _, event: &InputEvent, _, cx| {
                if matches!(event, InputEvent::Change) && page.calendar.error.take().is_some() {
                    cx.notify();
                }
            }),
        ]
    }

    pub fn sync(&mut self, old: &Settings, new: &Settings, window: &mut Window, cx: &mut App) {
        if old.calendar_my_email_addresses != new.calendar_my_email_addresses {
            super::sync_input(
                &self.addresses,
                &new.calendar_my_email_addresses,
                window,
                cx,
            );
        }
    }

    /// Reads the saved links off the main thread, once.
    fn load_links(&mut self, cx: &mut Context<SettingsPage>) {
        if self.links.is_some() || self.loading_links {
            return;
        }
        self.loading_links = true;
        cx.spawn(async move |page, cx| {
            let links = cx
                .background_spawn(async move { lokalbot_engine::secrets::calendar_links() })
                .await;
            let _ = page.update(cx, |page, cx| {
                page.calendar.loading_links = false;
                match links {
                    Ok(links) => page.calendar.links = Some(links),
                    Err(err) => {
                        log::warn!("calendar links could not be read: {err:#}");
                        page.calendar.links = Some(Vec::new());
                        page.calendar.error = Some(
                            lokalbot_i18n::tr("The system credential store is not available.")
                                .into(),
                        );
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }
}

impl SettingsPage {
    pub(super) fn calendar_section(&mut self, cx: &mut Context<Self>) -> Section {
        let settings = self.data.read(cx).settings.clone();
        let mut section = Section::new(lokalbot_i18n::tr("Calendar")).row(
            "settings.calendarDetectionEnabled",
            self.toggle(
                "settings.calendarDetectionEnabled",
                lokalbot_i18n::tr("Use calendar to improve detection"),
                Some(lokalbot_i18n::tr("Reads your calendars to confirm meetings, title recordings, and suggest attendee names for speakers. Attendee emails stay in local meeting metadata.")),
                settings.calendar_detection_enabled,
                |s, v| s.calendar_detection_enabled = v,
                cx,
            ),
        );
        if !settings.calendar_detection_enabled {
            return section;
        }
        section = section.row("settings.calendarLinks", self.calendar_links_row(cx));
        if cfg!(target_os = "linux") {
            section = section.row(
                "settings.calendarEvolutionEnabled",
                self.toggle(
                    "settings.calendarEvolutionEnabled",
                    lokalbot_i18n::tr("Use GNOME and Evolution calendars"),
                    Some(lokalbot_i18n::tr("Reads the calendars of Evolution Data Server, including those added in GNOME Online Accounts. They are read on this computer.")),
                    settings.calendar_evolution_enabled,
                    |s, v| s.calendar_evolution_enabled = v,
                    cx,
                ),
            );
        }
        section
            .row(
                "settings.calendarMyEmailAddresses",
                settings_row::stacked_row(
                    "settings.calendarMyEmailAddresses",
                    lokalbot_i18n::tr("My email addresses"),
                    Some(lokalbot_i18n::tr("Your addresses in these calendars, separated by commas, so you are not listed among the attendees and invitations you declined are skipped.").into()),
                    Input::new(&self.calendar.addresses),
                    self.is_focused("settings.calendarMyEmailAddresses"),
                    cx,
                ),
            )
            .row("settings.calendarStatus", self.calendar_status_row(cx))
            .row(
                "settings.useCalendarTitles",
                self.toggle(
                    "settings.useCalendarTitles",
                    lokalbot_i18n::tr("Use calendar titles for recordings"),
                    None,
                    settings.use_calendar_titles,
                    |s, v| s.use_calendar_titles = v,
                    cx,
                ),
            )
            .row(
                "settings.requireCalendarForBrowser",
                self.toggle(
                    "settings.requireCalendarForBrowser",
                    lokalbot_i18n::tr("Require a calendar match for browser auto-recording"),
                    Some(lokalbot_i18n::tr("Only auto-record a browser tab while a scheduled event with a meeting link is in progress.")),
                    settings.require_calendar_for_browser,
                    |s, v| s.require_calendar_for_browser = v,
                    cx,
                ),
            )
            .row(
                "settings.useCalendarAgenda",
                self.toggle(
                    "settings.useCalendarAgenda",
                    lokalbot_i18n::tr("Use invitation agendas"),
                    Some(lokalbot_i18n::tr("Off by default. Saves the invitation's agenda (without joining details, links, phone numbers, or addresses) with calendar-matched recordings, and uses it for meeting notes and meeting preparation. Agendas already saved stay with their meeting until it is deleted.")),
                    settings.use_calendar_agenda,
                    |s, v| s.use_calendar_agenda = v,
                    cx,
                ),
            )
    }

    fn calendar_links_row(&mut self, cx: &mut Context<Self>) -> gpui_kit::AnyElement {
        let lb = cx.lb().clone();
        self.calendar.load_links(cx);
        let links = self.calendar.links.clone().unwrap_or_default();
        let mut list = v_flex().gap(px(6.));
        for (index, link) in links.iter().enumerate() {
            let page = cx.entity();
            let data = self.data.clone();
            list = list.child(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .child(ui::icon(Ico::Calendar, px(14.), lb.text_secondary))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_size(ty::BODY)
                            .text_color(lb.text)
                            .child(lokalbot_platform::calendar::redacted_link(link)),
                    )
                    .child(
                        Button::new(SharedString::from(format!(
                            "settings-calendar-remove-{index}"
                        )))
                        .ghost()
                        .small()
                        .label(lokalbot_i18n::tr("Remove"))
                        .on_click(move |_, _, cx| {
                            let mut remaining = Vec::new();
                            page.update(cx, |page, cx| {
                                if let Some(links) = page.calendar.links.as_mut()
                                    && index < links.len()
                                {
                                    links.remove(index);
                                    remaining = links.clone();
                                }
                                cx.notify();
                            });
                            data.update(cx, |data, cx| {
                                data.request(AppEvent::SetCalendarLinks(remaining), cx)
                            });
                        }),
                    ),
            );
        }
        let page = cx.entity();
        let data = self.data.clone();
        let input = self.calendar.link.clone();
        let add = Button::new("settings-calendar-add")
            .outline()
            .small()
            .label(lokalbot_i18n::tr("Add"))
            .on_click(move |_, window, cx| {
                let raw = input.read(cx).value().trim().to_string();
                if raw.is_empty() {
                    return;
                }
                let Ok(link) = lokalbot_platform::calendar::normalize_link(&raw) else {
                    page.update(cx, |page, cx| {
                        page.calendar.error = Some(
                            lokalbot_i18n::tr("Calendar links start with https:// or webcal://.")
                                .into(),
                        );
                        cx.notify();
                    });
                    return;
                };
                let mut links = Vec::new();
                page.update(cx, |page, cx| {
                    let saved = page.calendar.links.get_or_insert_with(Vec::new);
                    if !saved.contains(&link) {
                        saved.push(link);
                    }
                    links = saved.clone();
                    page.calendar.error = None;
                    cx.notify();
                });
                input.update(cx, |input, cx| input.set_value("", window, cx));
                data.update(cx, |data, cx| {
                    data.request(AppEvent::SetCalendarLinks(links), cx)
                });
            });
        let content = v_flex()
            .gap(px(8.))
            .child(list)
            .child(
                h_flex()
                    .gap(px(8.))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .child(Input::new(&self.calendar.link).mask_toggle()),
                    )
                    .child(add),
            )
            .when_some(self.calendar.error.clone(), |this, error| {
                this.child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.attention_text)
                        .child(error),
                )
            });
        settings_row::stacked_row(
            "settings.calendarLinks",
            lokalbot_i18n::tr("Calendar links"),
            Some(lokalbot_i18n::tr("A private iCal or CalDAV link, such as Google Calendar's secret address in iCal format or a published Outlook calendar. Links are kept in the system credential store and read every five minutes; only the calendar's host is shown.").into()),
            content,
            self.is_focused("settings.calendarLinks"),
            cx,
        )
        .into_any_element()
    }

    fn calendar_status_row(&self, cx: &mut Context<Self>) -> gpui_kit::AnyElement {
        let snapshot = self.data.read(cx).calendar.clone();
        // Counted as Today lists them: personal appointments are not meetings.
        let meetings_today = lokalbot_core::calendar::upcoming::schedule(
            &snapshot.events,
            chrono::Local::now().date_naive(),
        )
        .len();
        let status: SharedString = match snapshot.status {
            CalendarStatus::Off | CalendarStatus::NoSources => {
                lokalbot_i18n::tr("No calendar is connected yet.").into()
            }
            CalendarStatus::Loading => lokalbot_i18n::tr("Reading your calendars…").into(),
            CalendarStatus::Ready => lokalbot_i18n::format(
                "{count} meetings today · Updated {time}",
                &[
                    ("count", meetings_today.to_string()),
                    (
                        "time",
                        snapshot
                            .refreshed_at
                            .map(lokalbot_core::time::clock_time)
                            .unwrap_or_default(),
                    ),
                ],
            )
            .into(),
            CalendarStatus::Failed => lokalbot_i18n::tr("Your calendars could not be read.").into(),
        };
        let mut help = vec![status.to_string()];
        help.extend(snapshot.problems.iter().cloned());
        let data = self.data.clone();
        settings_row::row(
            "settings.calendarStatus",
            lokalbot_i18n::tr("Calendar status"),
            Some(help.join("\n").into()),
            Button::new("settings-calendar-refresh")
                .outline()
                .small()
                .label(lokalbot_i18n::tr("Refresh"))
                .on_click(move |_, _, cx| {
                    data.update(cx, |data, cx| data.request(AppEvent::RefreshCalendar, cx))
                }),
            self.is_focused("settings.calendarStatus"),
            cx,
        )
        .into_any_element()
    }
}
