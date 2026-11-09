//! Day Memory → Routines (`SettingsView.routinesSection`): fixed local renderers
//! that write Markdown into a folder the person chooses.

use chrono::{Duration, NaiveDate, Utc};
use gpui_kit::component::Sizable as _;
use gpui_kit::component::button::Button;
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::v_flex;
use gpui_kit::{AnyElement, Context, IntoElement as _, ParentElement as _, Styled as _, div, px};
use lokalbot_core::settings::MemoryRoutineKind;

use super::exports::{choose_folder, folder_button};
use super::{Section, SettingsPage, hour_label};
use crate::state::AppEvent;
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::settings_row;

/// The Mac's weekday numbers: 1 is Sunday.
fn weekday_name(weekday: u32) -> String {
    // 2023-01-01 was a Sunday.
    let sunday = NaiveDate::from_ymd_opt(2023, 1, 1).expect("valid date");
    (sunday + Duration::days(i64::from(weekday.clamp(1, 7)) - 1))
        .format_localized("%A", lokalbot_i18n::date_locale())
        .to_string()
}

/// "5 min ago", "yesterday", in the interface language where it can.
pub(super) fn relative_time(at: chrono::DateTime<Utc>) -> String {
    let seconds = (Utc::now() - at).num_seconds().max(0);
    if seconds < 60 {
        return lokalbot_i18n::tr("just now").to_string();
    }
    if seconds < 3_600 {
        return lokalbot_i18n::format("{0} min ago", &[("0", format!("{}", seconds / 60))]);
    }
    if seconds < 86_400 {
        return lokalbot_i18n::format("{0} hr ago", &[("0", format!("{}", seconds / 3_600))]);
    }
    crate::state::day_label(at)
}

fn status_label(status: &str) -> &'static str {
    match status {
        "succeeded" => lokalbot_i18n::tr("Succeeded"),
        "failed" => lokalbot_i18n::tr("Failed"),
        "running" => lokalbot_i18n::tr("Running"),
        "cancelled" => lokalbot_i18n::tr("Cancelled"),
        _ => lokalbot_i18n::tr("Unknown"),
    }
}

fn set_routine(values: &mut Vec<MemoryRoutineKind>, kind: MemoryRoutineKind, enabled: bool) {
    if enabled {
        if !values.contains(&kind) {
            values.push(kind);
        }
    } else {
        values.retain(|value| *value != kind);
    }
}

impl SettingsPage {
    pub(super) fn routines_section(&mut self, cx: &mut Context<Self>) -> Section {
        let settings = self.data.read(cx).settings.clone();
        let data = self.data.clone();
        let mut section = Section::new(lokalbot_i18n::tr("Routines")).row(
            "settings.memoryRoutinesEnabled",
            settings_row::row(
                "settings.memoryRoutinesEnabled",
                lokalbot_i18n::tr("Enable safe local routines"),
                Some(lokalbot_i18n::tr("Routines write Markdown into a folder you choose. They can't run scripts, contact services, send messages, or change meetings.").into()),
                settings_row::switch(
                    "settings.memoryRoutinesEnabled",
                    settings.memory_routines_enabled,
                    move |on, _, cx| {
                        data.update(cx, |data, cx| {
                            data.update_settings(|s| s.memory_routines_enabled = on, cx)
                        });
                        if on && data.read(cx).settings.memory_routine_folder.is_empty() {
                            choose_folder(
                                data.clone(),
                                "Choose routine output folder",
                                |s, folder| s.memory_routine_folder = folder,
                                Some(|s| s.memory_routines_enabled = false),
                                cx,
                            );
                        }
                    },
                ),
                self.is_focused("settings.memoryRoutinesEnabled"),
                cx,
            ),
        );
        if settings.memory_routines_enabled {
            section = self.routine_rows(section, cx);
        }
        section.row(
            "settings.routineDetails",
            self.details(
                "settings.routineDetails",
                "How routines run",
                "Each routine has a fixed local read scope and writes Markdown only inside the chosen folder. Missed daily or weekly runs catch up after wake, each run stops after 30 seconds, and every attempt is recorded in the local database.",
                cx,
            ),
        )
    }

    fn routine_rows(&mut self, mut section: Section, cx: &mut Context<Self>) -> Section {
        let settings = self.data.read(cx).settings.clone();
        let hour = settings.memory_routine_hour.min(23);
        let hour_data = self.data.clone();
        let days: Vec<(u32, gpui_kit::SharedString)> =
            (1..=7).map(|day| (day, weekday_name(day).into())).collect();
        section = section
            .row(
                "settings.memoryRoutineFolder",
                settings_row::row(
                    "settings.memoryRoutineFolder",
                    lokalbot_i18n::tr("Output folder"),
                    None,
                    folder_button(
                        "settings-routine-folder",
                        &settings.memory_routine_folder,
                        self.data.clone(),
                        "Choose routine output folder",
                        |s, folder| s.memory_routine_folder = folder,
                    ),
                    false,
                    cx,
                ),
            )
            .row(
                "settings.memoryRoutineHour",
                settings_row::row(
                    "settings.memoryRoutineHour",
                    lokalbot_i18n::format("Daily time: {0}", &[("0", hour_label(hour))]),
                    None,
                    settings_row::stepper(
                        "settings-routine-hour",
                        hour_label(hour),
                        hour > 0,
                        hour < 23,
                        move |step, _, cx| {
                            let next = (hour as i32 + step).clamp(0, 23) as u32;
                            hour_data.update(cx, |data, cx| {
                                data.update_settings(|s| s.memory_routine_hour = next, cx)
                            });
                        },
                        cx,
                    ),
                    false,
                    cx,
                ),
            )
            .row(
                "settings.memoryRoutineWeekday",
                self.choice(
                    "settings.memoryRoutineWeekday",
                    lokalbot_i18n::tr("Weekly log day"),
                    None,
                    days,
                    settings.memory_routine_weekday.clamp(1, 7),
                    |s, v| s.memory_routine_weekday = v,
                    cx,
                ),
            );
        for kind in MemoryRoutineKind::ALL {
            let data = self.data.clone();
            let id: &'static str = match kind {
                MemoryRoutineKind::PostMeetingFollowUp => "settings.routinePostMeetingFollowUp",
                MemoryRoutineKind::DailyStandup => "settings.routineDailyStandup",
                MemoryRoutineKind::WeeklyWorkLog => "settings.routineWeeklyWorkLog",
                MemoryRoutineKind::UnfinishedActions => "settings.routineUnfinishedActions",
                MemoryRoutineKind::LocalJournal => "settings.routineLocalJournal",
            };
            section = section.row(
                id,
                settings_row::row(
                    id,
                    lokalbot_i18n::tr(kind.display_name()),
                    Some(lokalbot_i18n::tr(kind.detail()).into()),
                    settings_row::switch(
                        id,
                        settings.enabled_memory_routines.contains(&kind),
                        move |on, _, cx| {
                            data.update(cx, |data, cx| {
                                data.update_settings(
                                    |s| set_routine(&mut s.enabled_memory_routines, kind, on),
                                    cx,
                                )
                            });
                        },
                    ),
                    false,
                    cx,
                ),
            );
        }
        section
            .row("settings.routineRunNow", self.routine_run_now(cx))
            .row("settings.routineHistory", self.routine_history(cx))
    }

    fn routine_run_now(&self, cx: &mut Context<Self>) -> AnyElement {
        let data = self.data.clone();
        let state = self.data.read(cx);
        let enabled = state.settings.enabled_memory_routines.clone();
        let status = state.routines.clone();
        let running: Option<gpui_kit::SharedString> = status
            .current
            .filter(|_| status.is_running)
            .map(|kind| lokalbot_i18n::tr(kind.display_name()).into());
        settings_row::row(
            "settings.routineRunNow",
            lokalbot_i18n::tr("Run now"),
            running,
            Button::new("settings-routine-run")
                .outline()
                .small()
                .label(lokalbot_i18n::tr("Run now"))
                .dropdown_caret(true)
                .dropdown_menu(move |mut menu, _, _| {
                    for kind in MemoryRoutineKind::ALL
                        .into_iter()
                        .filter(|kind| !kind.is_event_driven())
                    {
                        let data = data.clone();
                        menu = menu.item(
                            PopupMenuItem::new(lokalbot_i18n::tr(kind.display_name()))
                                .disabled(!enabled.contains(&kind))
                                .on_click(move |_, _, cx| {
                                    data.update(cx, |data, cx| {
                                        data.request(AppEvent::RunRoutine(kind), cx)
                                    })
                                }),
                        );
                    }
                    menu
                }),
            false,
            cx,
        )
        .into_any_element()
    }

    fn routine_history(&self, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let runs = self.data.read(cx).routines.recent_runs.clone();
        let error = self.data.read(cx).routines.last_error.clone();
        let rows = runs.into_iter().take(8).map(|run| {
            let failed = run.status == "failed";
            let color = if failed {
                lb.attention_text
            } else {
                lb.text_secondary
            };
            crate::i18n::h_flex()
                .gap(px(12.))
                .text_size(ty::SECONDARY)
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .text_color(lb.text)
                        .child(lokalbot_i18n::tr(run.kind.display_name())),
                )
                .child(div().text_color(color).child(format!(
                    "{} · {}",
                    status_label(&run.status),
                    relative_time(run.started_at)
                )))
        });
        settings_row::stacked_row(
            "settings.routineHistory",
            lokalbot_i18n::tr("Recent run history"),
            error.map(Into::into),
            v_flex().gap(px(6.)).children(rows),
            false,
            cx,
        )
        .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn weekdays_count_from_sunday_like_the_mac() {
        assert_eq!(weekday_name(1), "Sunday");
        assert_eq!(weekday_name(6), "Friday");
        assert_eq!(weekday_name(9), "Saturday");
    }

    #[test]
    fn enabling_a_routine_adds_it_once() {
        let mut values = vec![MemoryRoutineKind::DailyStandup];
        set_routine(&mut values, MemoryRoutineKind::DailyStandup, true);
        assert_eq!(values.len(), 1);
        set_routine(&mut values, MemoryRoutineKind::LocalJournal, true);
        assert_eq!(values.len(), 2);
        set_routine(&mut values, MemoryRoutineKind::DailyStandup, false);
        assert_eq!(values, vec![MemoryRoutineKind::LocalJournal]);
    }
}
