//! What the tray menu says LokalBot is doing, and the meetings listed under
//! it (`MenuBarStatus.swift`, `MenuBarView.swift`). Display-only: nothing
//! here is stored or sent. `desktop.rs` hands the result to the tray.

use std::collections::HashSet;

use chrono::{DateTime, Local, Utc};
use lokalbot_core::Meeting;
use lokalbot_core::calendar::CalendarEvent;
use lokalbot_core::calendar::upcoming::{self as selector, UpcomingKind};
use lokalbot_core::settings::AutoRecordMode;
use lokalbot_engine::CalendarStatus;
use lokalbot_platform::tray::{
    TrayAttention, TrayBlock, TrayDictation, TrayDictationEntry, TrayGlyph, TrayIcon, TrayMeeting,
    TrayMenuState, TrayRecording, TraySoonMeeting, TraySource, TrayUpdate,
};

use crate::state::{AppData, DictationHud, RecordingState};

/// A calendar meeting leads the menu once it starts within this long, and
/// keeps the block while under way and not being recorded. Shorter than
/// Today's hour: the menu is a glance (`MenuBarStatus.soonWindow`).
const SOON_WINDOW_SECONDS: i64 = 15 * 60;
/// How long a recording that has just been saved is named in the block
/// (`MenuBarStatus.justStoppedWindow`).
const JUST_STOPPED_SECONDS: i64 = 2 * 60;
/// The menu keeps the two most recent meetings.
const RECENT_MEETING_LIMIT: usize = 2;

/// The menu as `data` stands at `now`.
pub fn menu_state(
    data: &AppData,
    now: DateTime<Utc>,
    update: Option<TrayUpdate>,
    approvals: usize,
) -> TrayMenuState {
    let settings = &data.settings;
    let live = data.recording.meeting();
    let dictation = dictation(&data.dictation);
    let attention = attention(
        data.toast
            .as_ref()
            .filter(|toast| toast.is_error)
            .map(|toast| toast.message.as_ref()),
        approvals,
    );
    let schedule =
        if settings.calendar_detection_enabled && data.calendar.status == CalendarStatus::Ready {
            selector::schedule(&data.calendar.events, lokalbot_core::time::local_day(now))
        } else {
            Vec::new()
        };
    // The recording in progress claims its event before the library lists it.
    let recordings: Vec<&Meeting> = live.into_iter().chain(data.meetings.iter()).collect();
    let recorded = crate::pages::today::model::recorded_event_ids(&recordings, &schedule);
    let soon = soon_meeting(&schedule, now, &recorded).map(|event| TraySoonMeeting {
        event_id: event.external_id.clone(),
        title: event.title.clone(),
        status: crate::pages::today::status_text(crate::pages::today::model::event_status(
            event, now,
        )),
        schedule: schedule_line(event),
        auto_records: settings.auto_record_mode == AutoRecordMode::Automatic,
        is_call: selector::kind(event) == UpcomingKind::Meeting,
        joinable: selector::kind(event) == UpcomingKind::Meeting && event.meeting_url.is_some(),
    });
    let stopped = just_stopped(&data.meetings, now);
    let (block, more_attention) = block(Inputs {
        recording: recording(data),
        dictation,
        attention,
        soon,
        paused: settings.tracking_enabled && data.day_memory_paused,
        just_stopped: stopped,
        habit: settings.auto_record_mode,
    });
    TrayMenuState {
        interface_language: lokalbot_i18n::current().code.into(),
        block,
        more_attention,
        recording: data.recording.is_active(),
        dictation,
        dictation_timer: match &data.dictation {
            DictationHud::Listening { elapsed, .. } => Some(lokalbot_core::time::timer(*elapsed)),
            _ => None,
        },
        dictation_enabled: settings.dictation_enabled,
        dictation_shortcut: settings.dictation_shortcut.clone(),
        dictation_trigger: settings.dictation_trigger_mode,
        quick_recall_shortcut: settings
            .quick_recall_enabled
            .then(|| settings.quick_recall_shortcut.clone()),
        recent_dictations: data
            .recent_dictations
            .iter()
            .map(|entry| TrayDictationEntry {
                id: entry.id.to_string(),
                preview: entry.preview(),
                menu_title: entry.menu_title(),
            })
            .collect(),
        recent_meetings: recent_meetings(&data.meetings, stopped, live.map(|m| m.id))
            .into_iter()
            .map(|(meeting, just_now)| TrayMeeting {
                id: meeting.id.to_string(),
                title: meeting.display_title(),
                when: when_label(meeting.started_at, just_now, now),
            })
            .collect(),
        autocomplete_enabled: settings.cotyping_enabled,
        tracking_enabled: settings.tracking_enabled,
        day_memory_paused: data.day_memory_paused,
        screen_capture: settings.tracking_enabled
            && settings.screen_context_capture_mode
                != lokalbot_core::ScreenContextMode::ActivityOnly,
        update,
    }
}

/// What dictation is doing, as the menu words it.
fn dictation(hud: &DictationHud) -> TrayDictation {
    match hud {
        DictationHud::Starting => TrayDictation::Starting,
        DictationHud::Listening { .. } => TrayDictation::Recording,
        DictationHud::Transcribing | DictationHud::Preparing(_) => TrayDictation::Transcribing,
        DictationHud::Composing => TrayDictation::Composing,
        _ => TrayDictation::Idle,
    }
}

/// The recording in progress: its meeting, timer, warnings, and whether
/// sound arrives from each source. The engine reports each track's state in
/// the Mac's words; levels stand in until its first report.
fn recording(data: &AppData) -> Option<TrayRecording> {
    let RecordingState::Recording {
        meeting,
        started,
        has_system_audio,
        mic_level,
        system_level,
    } = &data.recording
    else {
        return None;
    };
    let from_level = |level: f32| {
        if level > 0.01 {
            "Receiving audio"
        } else {
            "Waiting for audio"
        }
    };
    let (mic, system) = match &data.recording_statuses {
        Some((mic, system)) => (mic.to_string(), system.to_string()),
        None => (
            from_level(*mic_level).to_string(),
            from_level(*system_level).to_string(),
        ),
    };
    Some(TrayRecording {
        title: meeting.display_title(),
        timer: lokalbot_core::time::timer(started.elapsed().as_secs_f64()),
        warnings: data
            .capture_warnings
            .iter()
            .map(ToString::to_string)
            .collect(),
        microphone: source(mic),
        call_audio: has_system_audio.then(|| source(system)),
    })
}

/// Sound is arriving only while the recorder says so (`MemoryHealthTone.audio`).
fn source(status: String) -> TraySource {
    TraySource {
        receiving: status == "Receiving audio",
        status,
    }
}

/// Everything waiting, most blocking first: the latest error, then
/// approvals (`MenuBarAttention.items`). The port has no microphone
/// permission to lose.
fn attention(error: Option<&str>, approvals: usize) -> Vec<TrayAttention> {
    let mut items = Vec::new();
    if let Some(error) = error.filter(|error| !error.is_empty()) {
        items.push(TrayAttention::Error(error.to_string()));
    }
    if approvals > 0 {
        items.push(TrayAttention::Approvals(approvals));
    }
    items
}

/// What picks the status block.
struct Inputs<'a> {
    recording: Option<TrayRecording>,
    dictation: TrayDictation,
    attention: Vec<TrayAttention>,
    soon: Option<TraySoonMeeting>,
    /// Day memory runs and is paused.
    paused: bool,
    just_stopped: Option<&'a Meeting>,
    habit: AutoRecordMode,
}

/// The block in this order: recording, dictating, needs attention, a
/// meeting about to start, day memory paused, just stopped, idle. A
/// recording or a dictation leads even when something needs attention, so
/// Stop is never hidden; the waiting items are listed under it.
fn block(inputs: Inputs) -> (TrayBlock, Vec<TrayAttention>) {
    let Inputs {
        recording,
        dictation,
        mut attention,
        soon,
        paused,
        just_stopped,
        habit,
    } = inputs;
    if let Some(recording) = recording {
        return (TrayBlock::Recording(recording), attention);
    }
    if dictation != TrayDictation::Idle {
        return (TrayBlock::Dictating(dictation), attention);
    }
    if !attention.is_empty() {
        let first = attention.remove(0);
        return (TrayBlock::Attention(first), attention);
    }
    let block = if let Some(soon) = soon {
        TrayBlock::MeetingSoon(soon)
    } else if paused {
        TrayBlock::Paused { habit }
    } else if let Some(meeting) = just_stopped {
        TrayBlock::JustStopped {
            meeting_id: meeting.id.to_string(),
            title: meeting.display_title(),
            duration: crate::pages::meetings::model::duration_label(meeting),
        }
    } else {
        TrayBlock::Idle { habit }
    };
    (block, Vec::new())
}

/// The calendar meeting that leads the menu: the one under way, or the next
/// once it starts within 15 minutes. Events already recorded, and the one
/// being recorded now, are passed over (`TodayAgenda.nextMeeting`).
fn soon_meeting<'a>(
    schedule: &'a [CalendarEvent],
    now: DateTime<Utc>,
    recorded: &HashSet<String>,
) -> Option<&'a CalendarEvent> {
    let candidates: Vec<CalendarEvent> = schedule
        .iter()
        .filter(|event| !recorded.contains(&event.external_id))
        .cloned()
        .collect();
    let next = selector::primary(&candidates, now, None)?;
    if next.end <= now || (next.start - now).num_seconds() > SOON_WINDOW_SECONDS {
        return None;
    }
    schedule
        .iter()
        .find(|event| event.external_id == next.external_id)
}

/// "6:00 PM – 6:30 PM". The Mac adds the first attendee and a count
/// (`MenuBarStatusBlock.schedule`); here the menu's words reach every app on
/// the session bus (Linux), and the tray has never shown attendee names, so
/// it leaves them out.
fn schedule_line(event: &CalendarEvent) -> String {
    crate::pages::today::upcoming::interval(event)
}

/// The recording made here that ended within two minutes. An imported file
/// was not just recorded, whenever its audio ends.
fn just_stopped(meetings: &[Meeting], now: DateTime<Utc>) -> Option<&Meeting> {
    let window = chrono::Duration::seconds(JUST_STOPPED_SECONDS);
    meetings
        .iter()
        .filter(|meeting| {
            meeting.is_own_work()
                && !meeting.is_imported()
                && meeting
                    .ended_at
                    .is_some_and(|ended| ended > now - window && ended <= now + window)
        })
        .max_by_key(|meeting| meeting.ended_at)
}

/// The first meetings of the library, which lists the newest first, with the
/// one just saved in front, and whether each is that one. Sources folded into
/// a merged meeting and the recording in progress are not listed.
fn recent_meetings<'a>(
    meetings: &'a [Meeting],
    just_stopped: Option<&'a Meeting>,
    live: Option<uuid::Uuid>,
) -> Vec<(&'a Meeting, bool)> {
    let mut seen = HashSet::new();
    just_stopped
        .into_iter()
        .chain(meetings.iter())
        .filter(|meeting| {
            !meeting.is_merged_source() && Some(meeting.id) != live && seen.insert(meeting.id)
        })
        .take(RECENT_MEETING_LIMIT)
        .map(|meeting| (meeting, just_stopped.is_some_and(|m| m.id == meeting.id)))
        .collect()
}

/// When a recent meeting was, at the far side of its row.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum When {
    JustNow,
    Today,
    Yesterday,
    Earlier,
}

fn when(started: DateTime<Utc>, just_now: bool, now: DateTime<Utc>) -> When {
    let day = lokalbot_core::time::local_day(started);
    let today = lokalbot_core::time::local_day(now);
    if just_now {
        When::JustNow
    } else if day == today {
        When::Today
    } else if today.pred_opt() == Some(day) {
        When::Yesterday
    } else {
        When::Earlier
    }
}

/// "Just now", today's start time, "Yesterday", or the day
/// (`MenuBarPanelWhen`).
fn when_label(started: DateTime<Utc>, just_now: bool, now: DateTime<Utc>) -> String {
    match when(started, just_now, now) {
        When::JustNow => lokalbot_i18n::tr("Just now").to_string(),
        When::Today => lokalbot_core::time::clock_time(started),
        When::Yesterday => lokalbot_i18n::tr("Yesterday").to_string(),
        When::Earlier => started
            .with_timezone(&Local)
            .format_localized(
                lokalbot_i18n::date_pattern("%b %-d"),
                lokalbot_i18n::date_locale(),
            )
            .to_string(),
    }
}

/// The Lucide icon each menu row draws where the tray menu draws pixels
/// (Windows), as the app draws it elsewhere. Record, Stop and the blank are
/// drawn by the tray itself.
fn lucide(glyph: TrayGlyph) -> Option<crate::ui::Ico> {
    use crate::ui::Ico;
    Some(match glyph {
        TrayGlyph::Record | TrayGlyph::Stop | TrayGlyph::Blank => return None,
        TrayGlyph::Idle => Ico::CircleDot,
        TrayGlyph::Calendar => Ico::Calendar,
        TrayGlyph::Join => Ico::Video,
        TrayGlyph::Pause => Ico::Pause,
        TrayGlyph::Resume => Ico::Play,
        TrayGlyph::Warning => Ico::TriangleAlert,
        TrayGlyph::Approval => Ico::ShieldCheck,
        TrayGlyph::Microphone => Ico::Mic,
        TrayGlyph::CallAudio => Ico::Volume2,
        TrayGlyph::StopDictation => Ico::CircleStop,
        TrayGlyph::Cancel => Ico::CircleX,
        TrayGlyph::Search => Ico::Search,
        TrayGlyph::Copy => Ico::Copy,
        TrayGlyph::History => Ico::Clock,
        TrayGlyph::Meeting => Ico::AudioLines,
        TrayGlyph::Notes => Ico::FileText,
        TrayGlyph::Capture => Ico::Camera,
        TrayGlyph::Window => Ico::AppWindow,
        TrayGlyph::Settings => Ico::Settings,
        TrayGlyph::Update => Ico::CircleArrowDown,
        TrayGlyph::Quit => Ico::Power,
    })
}

/// Pixels on a side of a row icon; Windows scales them to its 16 px menus.
const GLYPH_PIXELS: u32 = 32;
/// The icons' grey on Windows' light tray menus: the Mac rows' secondary ink,
/// 6.7:1 on white.
const GLYPH_INK: [u8; 3] = [0x5C, 0x5C, 0x5C];

/// Every row icon the tray cannot draw itself, rasterized from the bundled
/// Lucide icons in [`GLYPH_INK`]. Only Windows' menus draw pixels, so only
/// Windows asks for them.
pub fn glyph_pixels() -> Vec<(TrayGlyph, TrayIcon)> {
    use gpui_kit::AssetSource as _;
    let renderer = gpui_kit::SvgRenderer::new(std::sync::Arc::new(crate::assets::Assets));
    let size = gpui_kit::size(
        gpui_kit::DevicePixels(GLYPH_PIXELS as i32),
        gpui_kit::DevicePixels(GLYPH_PIXELS as i32),
    );
    TrayGlyph::ALL
        .iter()
        .filter_map(|glyph| {
            let path = lucide(*glyph)?.path();
            let bytes = crate::assets::Assets.load(&path).ok()??;
            let svg = renderer.parse_svg(&bytes).ok()?;
            let image = renderer
                .render_parsed(&svg, gpui_kit::SvgSize::ExactSize(size))
                .ok()?;
            let image_size = image.size(0);
            let (width, height) = (
                u32::try_from(image_size.width.0).ok()?,
                u32::try_from(image_size.height.0).ok()?,
            );
            // BGRA, premultiplied: only the coverage is kept, in one ink.
            let pixels = image
                .as_bytes(0)?
                .as_chunks::<4>()
                .0
                .iter()
                .flat_map(|pixel| [GLYPH_INK[0], GLYPH_INK[1], GLYPH_INK[2], pixel[3]])
                .collect();
            Some((*glyph, (pixels, width, height)))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use chrono::{Duration, TimeZone as _};

    use super::*;

    fn noon() -> DateTime<Utc> {
        Local
            .with_ymd_and_hms(2026, 11, 14, 12, 0, 0)
            .single()
            .unwrap()
            .with_timezone(&Utc)
    }

    fn meeting(title: &str, started: DateTime<Utc>, minutes: i64) -> Meeting {
        let mut meeting = Meeting::new(title, "Zoom", started, "meetings/x");
        meeting.ended_at = Some(started + Duration::minutes(minutes));
        meeting
    }

    fn inputs() -> Inputs<'static> {
        Inputs {
            recording: None,
            dictation: TrayDictation::Idle,
            attention: Vec::new(),
            soon: None,
            paused: false,
            just_stopped: None,
            habit: AutoRecordMode::Ask,
        }
    }

    fn event(id: &str, start: DateTime<Utc>, minutes: i64) -> CalendarEvent {
        CalendarEvent {
            provider: "ics".into(),
            external_id: id.into(),
            title: id.into(),
            start,
            end: start + Duration::minutes(minutes),
            meeting_url: Some("https://meet.example/abc".into()),
            source_calendar_title: None,
            participant_names: Vec::new(),
            participant_identities: Vec::new(),
            agenda: None,
        }
    }

    #[test]
    fn the_block_follows_the_mac_order() {
        let saved = meeting("Standup", noon() - Duration::minutes(15), 14);
        let error = TrayAttention::Error("Disk is full".into());
        let approvals = TrayAttention::Approvals(2);
        let soon = TraySoonMeeting {
            event_id: "E".into(),
            ..Default::default()
        };

        // A recording leads and lists everything waiting under it.
        let (block, more) = block(Inputs {
            recording: Some(TrayRecording::default()),
            dictation: TrayDictation::Recording,
            attention: vec![error.clone(), approvals.clone()],
            ..inputs()
        });
        assert!(matches!(block, TrayBlock::Recording(_)));
        assert_eq!(more, [error.clone(), approvals.clone()]);

        let (block, more) = super::block(Inputs {
            dictation: TrayDictation::Composing,
            attention: vec![approvals.clone()],
            ..inputs()
        });
        assert_eq!(block, TrayBlock::Dictating(TrayDictation::Composing));
        assert_eq!(more, std::slice::from_ref(&approvals));

        // The first item waiting leads; the rest are listed.
        let (block, more) = super::block(Inputs {
            attention: vec![error.clone(), approvals.clone()],
            soon: Some(soon.clone()),
            paused: true,
            ..inputs()
        });
        assert_eq!(block, TrayBlock::Attention(error));
        assert_eq!(more, [approvals]);

        let (block, _) = super::block(Inputs {
            soon: Some(soon.clone()),
            paused: true,
            just_stopped: Some(&saved),
            ..inputs()
        });
        assert_eq!(block, TrayBlock::MeetingSoon(soon));

        let (block, _) = super::block(Inputs {
            paused: true,
            just_stopped: Some(&saved),
            habit: AutoRecordMode::Automatic,
            ..inputs()
        });
        assert_eq!(
            block,
            TrayBlock::Paused {
                habit: AutoRecordMode::Automatic
            }
        );

        let (block, _) = super::block(Inputs {
            just_stopped: Some(&saved),
            ..inputs()
        });
        assert_eq!(
            block,
            TrayBlock::JustStopped {
                meeting_id: saved.id.to_string(),
                title: "Standup".into(),
                duration: "14 min".into(),
            }
        );

        assert_eq!(
            super::block(inputs()).0,
            TrayBlock::Idle {
                habit: AutoRecordMode::Ask
            }
        );
    }

    #[test]
    fn errors_come_before_approvals() {
        assert_eq!(
            attention(Some("Disk is full"), 1),
            [
                TrayAttention::Error("Disk is full".into()),
                TrayAttention::Approvals(1)
            ]
        );
        assert!(attention(Some(""), 0).is_empty());
    }

    #[test]
    fn a_recording_is_just_stopped_for_two_minutes() {
        let now = noon();
        let ended_ago = |minutes: i64| meeting("Call", now - Duration::minutes(30 + minutes), 30);
        assert!(just_stopped(&[ended_ago(1)], now).is_some());
        assert!(just_stopped(&[ended_ago(3)], now).is_none());
        // An imported file, a merged source or one still recording is not.
        let mut imported = ended_ago(1);
        imported.imported_file_names = Some(vec!["call.m4a".into()]);
        let mut merged = ended_ago(1);
        merged.merged_into_meeting_id = Some(uuid::Uuid::new_v4());
        let mut live = ended_ago(1);
        live.ended_at = None;
        assert!(just_stopped(&[imported, merged, live], now).is_none());
        // The one that ended last wins.
        let earlier = ended_ago(1);
        let later = meeting("Later", now - Duration::minutes(10), 10);
        assert_eq!(
            just_stopped(&[earlier, later.clone()], now).map(|m| m.id),
            Some(later.id)
        );
    }

    #[test]
    fn recent_meetings_keep_two_with_the_saved_one_first() {
        let now = noon();
        let newest = meeting("Newest", now - Duration::hours(1), 20);
        let mut merged = meeting("Merged source", now - Duration::hours(2), 20);
        merged.merged_into_meeting_id = Some(uuid::Uuid::new_v4());
        let older = meeting("Older", now - Duration::hours(3), 20);
        let oldest = meeting("Oldest", now - Duration::hours(4), 20);
        let saved = meeting("Saved", now - Duration::minutes(15), 14);
        let library = [
            newest.clone(),
            merged,
            older.clone(),
            oldest.clone(),
            saved.clone(),
        ];

        let titles = |list: Vec<(&Meeting, bool)>| {
            list.into_iter()
                .map(|(m, just_now)| (m.title.clone(), just_now))
                .collect::<Vec<_>>()
        };
        assert_eq!(
            titles(recent_meetings(&library, None, None)),
            [("Newest".to_string(), false), ("Older".to_string(), false)]
        );
        assert_eq!(
            titles(recent_meetings(&library, Some(&saved), None)),
            [("Saved".to_string(), true), ("Newest".to_string(), false)]
        );
        // The recording in progress is not a recent meeting.
        assert_eq!(
            titles(recent_meetings(&library, None, Some(newest.id))),
            [("Older".to_string(), false), ("Oldest".to_string(), false)]
        );
    }

    #[test]
    fn a_recent_meeting_says_when_it_was() {
        let now = noon();
        assert_eq!(when(now - Duration::minutes(3), true, now), When::JustNow);
        assert_eq!(when(now - Duration::hours(2), false, now), When::Today);
        assert_eq!(when(now - Duration::days(1), false, now), When::Yesterday);
        assert_eq!(when(now - Duration::days(5), false, now), When::Earlier);
        assert_eq!(when_label(now, true, now), "Just now");
        assert_eq!(when_label(now - Duration::days(1), false, now), "Yesterday");
        assert_eq!(
            when_label(now - Duration::hours(2), false, now),
            lokalbot_core::time::clock_time(now - Duration::hours(2))
        );
    }

    #[test]
    fn a_meeting_leads_the_menu_from_fifteen_minutes_before() {
        let now = noon();
        let none = HashSet::new();
        let in_ten = [event("soon", now + Duration::minutes(10), 30)];
        assert_eq!(
            soon_meeting(&in_ten, now, &none).map(|e| e.external_id.as_str()),
            Some("soon")
        );
        let in_twenty = [event("later", now + Duration::minutes(20), 30)];
        assert!(soon_meeting(&in_twenty, now, &none).is_none());
        // Under way and not recorded: it keeps the block.
        let under_way = [event("now", now - Duration::minutes(5), 30)];
        assert!(soon_meeting(&under_way, now, &none).is_some());
        // Recorded already, or over: it does not.
        let recorded: HashSet<String> = ["now".to_string()].into();
        assert!(soon_meeting(&under_way, now, &recorded).is_none());
        let over = [event("over", now - Duration::minutes(40), 30)];
        assert!(soon_meeting(&over, now, &none).is_none());
    }

    #[test]
    fn the_schedule_is_the_time_without_attendees() {
        let mut call = event("Design review", noon(), 30);
        call.participant_names = vec!["Maya Chen".into(), "Ana".into()];
        let line = schedule_line(&call);
        assert_eq!(line, crate::pages::today::upcoming::interval(&call));
        assert!(!line.contains("Maya"));
    }

    #[test]
    fn sources_receive_only_while_the_recorder_says_so() {
        assert!(source("Receiving audio".into()).receiving);
        assert!(!source("Waiting for audio".into()).receiving);
        assert!(!source("Not attached".into()).receiving);
    }

    #[test]
    fn every_row_icon_but_the_red_ones_is_drawn_from_lucide() {
        let pixels = glyph_pixels();
        for glyph in TrayGlyph::ALL {
            let drawn = pixels.iter().find(|(g, _)| *g == glyph);
            match glyph.drawn() {
                Some(_) => assert!(drawn.is_none(), "{glyph:?}"),
                None => {
                    let (_, (rgba, width, height)) =
                        drawn.unwrap_or_else(|| panic!("no pixels for {glyph:?}"));
                    assert_eq!((*width, *height), (GLYPH_PIXELS, GLYPH_PIXELS));
                    assert_eq!(rgba.len(), (GLYPH_PIXELS * GLYPH_PIXELS * 4) as usize);
                    // Some ink, in the one grey, and clear around it.
                    let pixels = rgba.as_chunks::<4>().0;
                    assert!(pixels.iter().any(|p| p[3] > 200), "{glyph:?}");
                    assert!(pixels.iter().any(|p| p[3] == 0), "{glyph:?}");
                    assert!(pixels.iter().all(|p| p[..3] == GLYPH_INK));
                }
            }
        }
    }
}
