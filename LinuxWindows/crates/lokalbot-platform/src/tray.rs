//! The system tray icon and its menu, the Linux/Windows counterpart of the
//! macOS menu bar extra (`MenuBarView.swift`, `MenuBarStatusBlock.swift`,
//! `MenuBarRows.swift`, `MenuBarStatus.swift`).
//!
//! A tray menu is drawn by the desktop, not by LokalBot, so the Mac's panel
//! becomes the closest native menu: its status block as the first rows (a
//! heading and its lines, which cannot be chosen, then the block's buttons as
//! items), then rows with an icon and their text, and the switch as a check
//! item. What the Mac shows at a row's far side (a shortcut, a time, a timer)
//! is right-aligned on Windows and follows the text on Linux.
//!
//! Linux publishes a StatusNotifierItem over D-Bus (`ksni`; KDE, GNOME with
//! the AppIndicator extension, waybar…) whose rows name freedesktop icons, so
//! the host paints them in its own menu colours. Windows uses `tray-icon` on a
//! worker thread with its own message loop; its rows draw the pixels the app
//! hands to [`Tray::new`]. Create the tray from any thread (the GPUI main
//! thread is fine); `on_event` runs on a background thread.

use lokalbot_core::settings::{AutoRecordMode, DictationTriggerMode};

/// The symbol at the start of a menu row (`MenuBarRowIcon`, the status
/// block's tile). Linux hosts look it up in the icon theme by
/// [`TrayGlyph::icon_name`]; Windows draws the pixels given to [`Tray::new`].
/// [`TrayGlyph::Record`] and [`TrayGlyph::Stop`] are drawn here, in the
/// recording red, as the Mac's buttons draw them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TrayGlyph {
    /// `circle.fill` in red: Record now, Record, and the recording heading.
    Record,
    /// `record.circle`: Not recording.
    Idle,
    /// `stop.fill` in red: Stop.
    Stop,
    /// `calendar`: a meeting about to start.
    Calendar,
    /// Join the call.
    Join,
    /// `pause`: day memory is paused, Pause day memory.
    Pause,
    /// `play`: Resume, Resume day memory.
    Resume,
    /// `exclamationmark.triangle`: something needs attention.
    Warning,
    /// `checkmark.shield`: settings changes waiting for approval.
    Approval,
    /// `mic`: dictation and the microphone.
    Microphone,
    /// The call's audio while recording.
    CallAudio,
    /// `stop.circle`: Stop dictation.
    StopDictation,
    /// `xmark.circle`: Cancel dictation.
    Cancel,
    /// `magnifyingglass`: Quick Recall.
    Search,
    /// `doc.on.doc`: Copy last dictation.
    Copy,
    /// Earlier dictations (the port's menu for the Mac's context menu).
    History,
    /// `waveform`: a recent meeting.
    Meeting,
    /// Open notes, Open live notes.
    Notes,
    /// Capture Screen Now.
    Capture,
    /// `macwindow`: Open LokalBot.
    Window,
    /// `gearshape`: Settings….
    Settings,
    /// A newer LokalBot on offer.
    Update,
    /// `power`: Quit LokalBot.
    Quit,
    /// No symbol: keeps a status line's words in line with its heading's,
    /// as the Mac indents the block's lines past its tile.
    Blank,
}

impl TrayGlyph {
    pub const ALL: [TrayGlyph; 24] = [
        Self::Record,
        Self::Idle,
        Self::Stop,
        Self::Calendar,
        Self::Join,
        Self::Pause,
        Self::Resume,
        Self::Warning,
        Self::Approval,
        Self::Microphone,
        Self::CallAudio,
        Self::StopDictation,
        Self::Cancel,
        Self::Search,
        Self::Copy,
        Self::History,
        Self::Meeting,
        Self::Notes,
        Self::Capture,
        Self::Window,
        Self::Settings,
        Self::Update,
        Self::Quit,
        Self::Blank,
    ];

    /// The freedesktop icon name, symbolic so GTK and GNOME Shell paint it in
    /// the menu's own text colour on light and dark menus alike. Every name is
    /// in Adwaita, Yaru, elementary and Breeze (KDE falls back to the name
    /// without "-symbolic"). [`TrayGlyph::Blank`] has none.
    pub fn icon_name(self) -> &'static str {
        match self {
            Self::Record | Self::Idle => "media-record-symbolic",
            Self::Stop | Self::StopDictation => "media-playback-stop-symbolic",
            Self::Calendar => "x-office-calendar-symbolic",
            Self::Join => "camera-web-symbolic",
            Self::Pause => "media-playback-pause-symbolic",
            Self::Resume => "media-playback-start-symbolic",
            Self::Warning => "dialog-warning-symbolic",
            Self::Approval => "security-high-symbolic",
            Self::Microphone => "audio-input-microphone-symbolic",
            Self::CallAudio => "audio-speakers-symbolic",
            Self::Cancel => "process-stop-symbolic",
            Self::Search => "system-search-symbolic",
            Self::Copy => "edit-copy-symbolic",
            Self::History => "document-open-recent-symbolic",
            Self::Meeting => "call-start-symbolic",
            Self::Notes => "text-x-generic-symbolic",
            Self::Capture => "camera-photo-symbolic",
            Self::Window => "computer-symbolic",
            Self::Settings => "emblem-system-symbolic",
            Self::Update => "software-update-available-symbolic",
            Self::Quit => "system-shutdown-symbolic",
            Self::Blank => "",
        }
    }

    /// The glyphs drawn here rather than taken from the theme or the app:
    /// the red Record and Stop, and the clear [`TrayGlyph::Blank`].
    pub fn drawn(self) -> Option<TrayIcon> {
        match self {
            Self::Record => Some(red_mark(GLYPH_SIZE, false)),
            Self::Stop => Some(red_mark(GLYPH_SIZE, true)),
            Self::Blank => Some((
                vec![0; (GLYPH_SIZE * GLYPH_SIZE * 4) as usize],
                GLYPH_SIZE,
                GLYPH_SIZE,
            )),
            _ => None,
        }
    }
}

/// Pixels on a side of a drawn glyph: twice the menus' 16 px icons, so they
/// stay sharp at 200 % and are scaled down elsewhere.
const GLYPH_SIZE: u32 = 32;

/// #FF3B30, the system red the macOS menu bar uses.
const RECORDING_RED: [u8; 3] = [0xFF, 0x3B, 0x30];
/// #FF9F0A, the attention amber (`LBTokens.Palette.attention`).
const ATTENTION_AMBER: [u8; 3] = [0xFF, 0x9F, 0x0A];

/// A red dot, or a red rounded square for Stop, with soft edges.
fn red_mark(size: u32, square: bool) -> TrayIcon {
    let s = size as f32;
    let mut pixels = vec![0u8; (size * size * 4) as usize];
    for y in 0..size {
        for x in 0..size {
            let (px, py) = (x as f32 + 0.5 - s / 2., y as f32 + 0.5 - s / 2.);
            // Signed distance from the shape's edge, negative inside.
            let distance = if square {
                let half = s * 0.3;
                let radius = s * 0.08;
                let (qx, qy) = (px.abs() - half + radius, py.abs() - half + radius);
                (qx.max(0.).powi(2) + qy.max(0.).powi(2)).sqrt() + qx.max(qy).min(0.) - radius
            } else {
                (px * px + py * py).sqrt() - s * 0.34
            };
            let alpha = (0.5 - distance).clamp(0., 1.);
            if alpha > 0. {
                let index = ((y * size + x) * 4) as usize;
                pixels[index..index + 3].copy_from_slice(&RECORDING_RED);
                pixels[index + 3] = (alpha * 255.).round() as u8;
            }
        }
    }
    (pixels, size, size)
}

/// What a row shows: its words, an icon before them, and what the Mac shows
/// at the far side.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TrayLabel {
    pub text: String,
    pub icon: Option<TrayGlyph>,
    /// A shortcut, a time or a timer. Windows right-aligns it; Linux menus
    /// have no such column, so it follows the text after a middle dot.
    pub trailing: Option<String>,
}

impl TrayLabel {
    pub fn new(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            icon: None,
            trailing: None,
        }
    }

    pub fn icon(mut self, glyph: TrayGlyph) -> Self {
        self.icon = Some(glyph);
        self
    }

    /// Nothing is shown for `None` or an empty text.
    pub fn trailing(mut self, trailing: Option<impl Into<String>>) -> Self {
        self.trailing = trailing.map(Into::into).filter(|text| !text.is_empty());
        self
    }

    /// The dbusmenu label: a single "_" marks an access key there, so each is
    /// doubled.
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    fn linux_text(&self) -> String {
        let text = match &self.trailing {
            Some(trailing) => format!("{} · {trailing}", self.text),
            None => self.text.clone(),
        };
        text.replace('_', "__")
    }

    /// The Win32 menu text: "&" marks an access key there, and text after a
    /// tab is drawn right-aligned in the shortcut column.
    #[cfg_attr(not(windows), allow(dead_code))]
    fn windows_text(&self) -> String {
        let text = self.text.replace('&', "&&").replace('\t', " ");
        match &self.trailing {
            Some(trailing) => format!("{text}\t{}", trailing.replace('&', "&&")),
            None => text,
        }
    }
}

impl From<&str> for TrayLabel {
    fn from(text: &str) -> Self {
        Self::new(text)
    }
}

impl From<String> for TrayLabel {
    fn from(text: String) -> Self {
        Self::new(text)
    }
}

/// One menu row.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TrayItem {
    /// A row that cannot be chosen: the status block's heading and lines, a
    /// group's heading.
    Status(TrayLabel),
    Action {
        id: String,
        label: TrayLabel,
        enabled: bool,
    },
    /// A row with a checkmark, for a switch. Tray menus draw no icon beside
    /// a checkmark.
    Toggle {
        id: String,
        label: String,
        checked: bool,
    },
    /// A row that opens more rows.
    Submenu {
        label: TrayLabel,
        items: Vec<TrayItem>,
    },
    Separator,
}

impl TrayItem {
    pub fn action(id: &str, label: impl Into<TrayLabel>) -> Self {
        Self::Action {
            id: id.into(),
            label: label.into(),
            enabled: true,
        }
    }

    pub fn status(label: impl Into<TrayLabel>) -> Self {
        Self::Status(label.into())
    }

    /// The same row, greyed out when `enabled` is false.
    pub fn enabled(self, enabled: bool) -> Self {
        match self {
            Self::Action { id, label, .. } => Self::Action { id, label, enabled },
            other => other,
        }
    }

    /// The row's words, without what sits at its far side.
    pub fn text(&self) -> Option<&str> {
        match self {
            Self::Status(label) | Self::Action { label, .. } | Self::Submenu { label, .. } => {
                Some(&label.text)
            }
            Self::Toggle { label, .. } => Some(label),
            Self::Separator => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TrayEvent {
    /// The icon itself was clicked (left click on Windows, activate on Linux).
    Activated,
    /// A menu item was chosen, by its id.
    Item(String),
    /// The menu is about to open (Linux hosts say so; on Windows the right
    /// button went down): a chance to bring its status up to date.
    MenuOpening,
}

/// What the menu shows (`MenuBarStatus` and the panel's other inputs).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TrayMenuState {
    /// Included in equality so a new interface language rebuilds the menu.
    pub interface_language: String,
    /// The status block's one state.
    pub block: TrayBlock,
    /// Attention items listed under the block: every one while a recording
    /// or a dictation leads, the rest when the first of them is the block.
    pub more_attention: Vec<TrayAttention>,
    /// A meeting is being recorded: it holds the microphone.
    pub recording: bool,
    /// What dictation is doing.
    pub dictation: TrayDictation,
    /// How long the dictation has been spoken, while it is.
    pub dictation_timer: Option<String>,
    pub dictation_enabled: bool,
    /// The dictation shortcut's label.
    pub dictation_shortcut: String,
    pub dictation_trigger: DictationTriggerMode,
    /// Quick Recall's shortcut, while the shortcut is on.
    pub quick_recall_shortcut: Option<String>,
    /// Recent dictations to copy again, newest first.
    pub recent_dictations: Vec<TrayDictationEntry>,
    /// The latest meetings, the one just saved first.
    pub recent_meetings: Vec<TrayMeeting>,
    pub autocomplete_enabled: bool,
    /// Day memory runs, so it can be paused.
    pub tracking_enabled: bool,
    pub day_memory_paused: bool,
    /// Screen context is on: offer "Capture Screen Now".
    pub screen_capture: bool,
    /// A newer LokalBot is on offer.
    pub update: Option<TrayUpdate>,
}

impl TrayMenuState {
    /// The recording dot, or the glyph: faint while day memory is paused,
    /// with a dot while something needs attention (`MenuBarLabel`).
    pub fn icon_state(&self) -> TrayIconState {
        let recording = match &self.block {
            TrayBlock::Recording(recording) => Some(recording.timer.clone()),
            _ => None,
        };
        TrayIconState {
            recording: recording.is_some(),
            timer: recording.filter(|timer| !timer.is_empty()),
            dimmed: self.tracking_enabled && self.day_memory_paused,
            attention: matches!(self.block, TrayBlock::Attention(_))
                || !self.more_attention.is_empty(),
        }
    }
}

/// The status block's one state, picked in this order: recording, dictating,
/// needs attention, a meeting about to start, day memory paused, just
/// stopped, idle (`MenuBarStatus.Block`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TrayBlock {
    Recording(TrayRecording),
    Dictating(TrayDictation),
    Attention(TrayAttention),
    MeetingSoon(TraySoonMeeting),
    Paused {
        habit: AutoRecordMode,
    },
    /// A recording made here that ended within two minutes.
    JustStopped {
        meeting_id: String,
        title: String,
        /// "12 min".
        duration: String,
    },
    Idle {
        habit: AutoRecordMode,
    },
}

impl Default for TrayBlock {
    fn default() -> Self {
        Self::Idle {
            habit: AutoRecordMode::default(),
        }
    }
}

/// The recording in progress.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TrayRecording {
    pub title: String,
    /// "12:04".
    pub timer: String,
    /// What the recorder warns about, in the interface language.
    pub warnings: Vec<String>,
    pub microphone: TraySource,
    /// `None` while only the microphone is recorded.
    pub call_audio: Option<TraySource>,
}

/// Whether sound is arriving from one source of the recording
/// (`MenuBarAudioLine.Source`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TraySource {
    /// The recorder's own words, such as "Receiving audio" (Mac keys).
    pub status: String,
    pub receiving: bool,
}

/// A calendar meeting that starts within 15 minutes or is under way and not
/// being recorded.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TraySoonMeeting {
    pub event_id: String,
    pub title: String,
    /// "In 5 min", "Starting now", "In progress".
    pub status: String,
    /// "6:00 PM – 6:30 PM".
    pub schedule: String,
    /// Recording starts on its own when the call does.
    pub auto_records: bool,
    /// Other people or a link: a call, recorded with the event's context.
    pub is_call: bool,
    /// A call with a link to join.
    pub joinable: bool,
}

/// One thing the menu asks the person to fix (`MenuBarAttention`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TrayAttention {
    /// The app's latest error, until it is dismissed.
    Error(String),
    /// Requests from the terminal waiting for an answer.
    Approvals(usize),
}

/// A dictation the clipboard may have lost.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TrayDictationEntry {
    pub id: String,
    /// The start of the text, on one line.
    pub preview: String,
    /// "2:20 PM — Can you check…".
    pub menu_title: String,
}

/// A meeting in the Recent meetings list.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TrayMeeting {
    pub id: String,
    pub title: String,
    /// "Just now", "11:00 AM", "Yesterday", "Nov 9".
    pub when: String,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum TrayDictation {
    #[default]
    Idle,
    Starting,
    Recording,
    Transcribing,
    Composing,
}

impl TrayDictation {
    fn is_working(self) -> bool {
        !matches!(self, Self::Idle)
    }

    /// The dictation row and button (`dictationTitle`).
    fn button(self) -> &'static str {
        match self {
            Self::Idle => "Start dictation",
            Self::Recording => "Stop dictation",
            Self::Starting | Self::Transcribing | Self::Composing => "Cancel dictation",
        }
    }

    fn glyph(self) -> TrayGlyph {
        match self {
            Self::Idle => TrayGlyph::Microphone,
            Self::Recording => TrayGlyph::StopDictation,
            Self::Starting | Self::Transcribing | Self::Composing => TrayGlyph::Cancel,
        }
    }
}

/// The update row (Sparkle's "Install Update…").
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TrayUpdate {
    pub version: String,
    pub action: TrayUpdateAction,
    /// Downloading or installing.
    pub busy: bool,
}

/// What the update row does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrayUpdateAction {
    /// LokalBot replaces itself and relaunches.
    Install,
    /// Opens the download.
    Download,
    /// A package manager updates this copy: opens Settings, which says how.
    Show,
}

/// Menu item ids used by [`standard_items`].
pub mod item_ids {
    pub const RECORD: &str = "record";
    pub const STOP_RECORDING: &str = "stop-recording";
    pub const COPY_LAST_DICTATION: &str = "copy-last-dictation";
    /// Quick Recall.
    pub const ASK: &str = "ask";
    pub const OPEN: &str = "open";
    pub const SETTINGS: &str = "settings";
    pub const PAUSE_DAY_MEMORY: &str = "pause-day-memory";
    pub const RESUME_DAY_MEMORY: &str = "resume-day-memory";
    pub const CAPTURE_SCREEN: &str = "capture-screen";
    pub const INSTALL_UPDATE: &str = "install-update";
    pub const DOWNLOAD_UPDATE: &str = "download-update";
    pub const SHOW_UPDATE: &str = "show-update";
    pub const QUIT: &str = "quit";
    /// Open live notes: the meeting being recorded.
    pub const LIVE_TRANSCRIPT: &str = "live-transcript";
    pub const DICTATION_BUTTON: &str = "dictation-button";
    pub const AUTOCOMPLETE_ENABLED: &str = "autocomplete-enabled";
    pub const APPROVALS: &str = "approvals";
    /// Clears the latest error.
    pub const DISMISS_ERROR: &str = "dismiss-error";
    /// Followed by a meeting id: opens its notes.
    pub const MEETING_PREFIX: &str = "meeting:";
    /// Followed by a recent dictation's id.
    pub const DICTATION_PREFIX: &str = "dictation:";
    /// Followed by a calendar event's id: opens its call link.
    pub const JOIN_PREFIX: &str = "join:";
    /// Followed by a calendar event's id: records it with its context.
    pub const RECORD_EVENT_PREFIX: &str = "record-event:";
}

/// A menu row shows one line, so long titles shorten (`shortMenuTitle`).
fn short_title(title: &str) -> String {
    shortened(title, 30, "...")
}

/// A line of the status block: a meeting's title, a schedule.
fn short_line(line: &str) -> String {
    shortened(line.lines().next().unwrap_or(line), 60, "…")
}

/// An error on one line of a menu.
fn short_error(error: &str) -> String {
    shortened(error.lines().next().unwrap_or(error), 80, "…")
}

fn shortened(text: &str, limit: usize, ellipsis: &str) -> String {
    if text.chars().count() <= limit {
        return text.to_string();
    }
    let mut out: String = text
        .chars()
        .take(limit - ellipsis.chars().count())
        .collect();
    out.push_str(ellipsis);
    out
}

/// "A settings change is waiting for your approval", or how many are.
fn approvals_text(count: usize) -> String {
    use lokalbot_i18n::tr;
    if count == 1 {
        tr("A settings change is waiting for your approval").to_string()
    } else {
        lokalbot_i18n::fill(
            tr("%lld settings changes are waiting for your approval"),
            &[lokalbot_i18n::number(count).as_str()],
        )
    }
}

/// What makes a recording start. While day memory is paused the line says
/// meetings are not: pausing never touches recording (`habitText`).
fn habit_text(habit: AutoRecordMode, paused: bool) -> &'static str {
    use lokalbot_i18n::tr;
    match habit {
        AutoRecordMode::Automatic if paused => tr("Meetings still record when they start"),
        AutoRecordMode::Automatic => tr("Records meetings when they start"),
        AutoRecordMode::Ask => tr("Asks before recording meetings"),
        AutoRecordMode::Manual => tr("Manual recording only"),
    }
}

/// One source of the recording on one row: its name while sound arrives,
/// otherwise the recorder's words for it (`MenuBarAudioLineRow`).
fn source_row(source: &TraySource, name: &str, detailed: &str, glyph: TrayGlyph) -> TrayItem {
    let text = if source.receiving {
        name.to_string()
    } else {
        lokalbot_i18n::fill(detailed, &[lokalbot_i18n::tr(&source.status)])
    };
    TrayItem::status(TrayLabel::new(text).icon(glyph))
}

/// The status block's rows: what LokalBot is doing in one heading, its
/// lines, and its buttons, always in the same place under it
/// (`MenuBarStatusBlock`).
fn block_items(state: &TrayMenuState, items: &mut Vec<TrayItem>) {
    use item_ids::*;
    use lokalbot_i18n::tr;
    // A dictation holds the microphone: Record waits for it.
    let record = |text: &str| {
        TrayItem::action(RECORD, TrayLabel::new(text).icon(TrayGlyph::Record))
            .enabled(!state.dictation.is_working())
    };
    let heading = |text: &str, glyph: TrayGlyph| TrayLabel::new(text).icon(glyph);
    // A line under the heading, in line with the heading's words.
    let line = |text: &str| TrayItem::status(TrayLabel::new(text).icon(TrayGlyph::Blank));
    match &state.block {
        TrayBlock::Recording(recording) => {
            let title = if recording.warnings.is_empty() {
                tr("Recording")
            } else {
                tr("Recording needs attention")
            };
            items.push(TrayItem::status(
                heading(title, TrayGlyph::Record).trailing(Some(recording.timer.clone())),
            ));
            items.push(line(&short_line(&recording.title)));
            match &recording.call_audio {
                Some(call) => {
                    items.push(source_row(
                        &recording.microphone,
                        tr("Microphone"),
                        tr("Mic · %@"),
                        TrayGlyph::Microphone,
                    ));
                    items.push(source_row(
                        call,
                        tr("Call audio"),
                        tr("Call audio · %@"),
                        TrayGlyph::CallAudio,
                    ));
                }
                None => items.push(source_row(
                    &recording.microphone,
                    tr("Microphone only"),
                    tr("Mic · %@"),
                    TrayGlyph::Microphone,
                )),
            }
            for warning in &recording.warnings {
                items.push(TrayItem::status(
                    TrayLabel::new(short_error(warning)).icon(TrayGlyph::Warning),
                ));
            }
            items.push(TrayItem::action(
                STOP_RECORDING,
                heading(tr("Stop"), TrayGlyph::Stop),
            ));
            items.push(TrayItem::action(
                LIVE_TRANSCRIPT,
                heading(tr("Open live notes"), TrayGlyph::Notes),
            ));
        }
        TrayBlock::Dictating(phase) => {
            let shortcut = [state.dictation_shortcut.as_str()];
            let (title, progress) = match phase {
                TrayDictation::Starting | TrayDictation::Idle => (
                    tr("Starting dictation"),
                    tr("Connecting to the microphone").to_string(),
                ),
                TrayDictation::Recording => (
                    tr("Dictating"),
                    lokalbot_i18n::fill(
                        match state.dictation_trigger {
                            DictationTriggerMode::Toggle => tr("Press %@ again to compose"),
                            DictationTriggerMode::PushToTalk => tr("Release %@ to compose"),
                            DictationTriggerMode::TapOrHold => tr("Release or tap %@ to compose"),
                        },
                        &shortcut,
                    ),
                ),
                TrayDictation::Transcribing => (
                    tr("Transcribing"),
                    tr("Turning speech into a writing request").to_string(),
                ),
                TrayDictation::Composing => (
                    tr("Composing"),
                    tr("Writing for the focused app").to_string(),
                ),
            };
            let timer = state
                .dictation_timer
                .clone()
                .filter(|_| *phase == TrayDictation::Recording);
            items.push(TrayItem::status(
                heading(title, TrayGlyph::Microphone).trailing(timer),
            ));
            items.push(line(&progress));
            items.push(TrayItem::action(
                DICTATION_BUTTON,
                heading(tr(phase.button()), phase.glyph()),
            ));
        }
        TrayBlock::Attention(TrayAttention::Error(message)) => {
            items.push(TrayItem::status(heading(
                tr("Needs attention"),
                TrayGlyph::Warning,
            )));
            items.push(line(&short_error(message)));
            items.push(TrayItem::action(
                DISMISS_ERROR,
                heading(tr("Dismiss"), TrayGlyph::Cancel),
            ));
        }
        TrayBlock::Attention(TrayAttention::Approvals(count)) => {
            items.push(TrayItem::status(heading(
                approvals_text(*count).as_str(),
                TrayGlyph::Approval,
            )));
            items.push(TrayItem::action(
                APPROVALS,
                heading(tr("Review"), TrayGlyph::Approval),
            ));
        }
        TrayBlock::MeetingSoon(meeting) => {
            items.push(TrayItem::status(
                heading(short_line(&meeting.title).as_str(), TrayGlyph::Calendar)
                    .trailing(Some(meeting.status.clone())),
            ));
            items.push(line(&short_line(&meeting.schedule)));
            if meeting.auto_records {
                items.push(line(tr("Recording starts when the call does")));
            }
            if meeting.joinable {
                items.push(TrayItem::action(
                    &format!("{JOIN_PREFIX}{}", meeting.event_id),
                    heading(tr("Join"), TrayGlyph::Join),
                ));
            }
            // A solo event without a link may not be a call: it is recorded
            // like any other manual start, without the event's context.
            let record_event = if meeting.is_call {
                TrayItem::action(
                    &format!("{RECORD_EVENT_PREFIX}{}", meeting.event_id),
                    heading(tr("Record"), TrayGlyph::Record),
                )
                .enabled(!state.dictation.is_working())
            } else {
                record(tr("Record"))
            };
            items.push(record_event);
        }
        TrayBlock::Paused { habit } => {
            items.push(TrayItem::status(heading(
                tr("Day memory is paused"),
                TrayGlyph::Pause,
            )));
            items.push(line(habit_text(*habit, true)));
            items.push(TrayItem::action(
                RESUME_DAY_MEMORY,
                heading(tr("Resume"), TrayGlyph::Resume),
            ));
            items.push(record(tr("Record now")));
        }
        TrayBlock::JustStopped {
            meeting_id,
            title,
            duration,
        } => {
            items.push(TrayItem::status(heading(
                tr("Not recording"),
                TrayGlyph::Idle,
            )));
            items.push(line(&short_line(&lokalbot_i18n::fill(
                tr("%@ saved · %@"),
                &[title.as_str(), duration.as_str()],
            ))));
            items.push(record(tr("Record now")));
            items.push(TrayItem::action(
                &format!("{MEETING_PREFIX}{meeting_id}"),
                heading(tr("Open notes"), TrayGlyph::Notes),
            ));
        }
        TrayBlock::Idle { habit } => {
            items.push(TrayItem::status(heading(
                tr("Not recording"),
                TrayGlyph::Idle,
            )));
            items.push(line(habit_text(*habit, false)));
            items.push(record(tr("Record now")));
        }
    }
    // The rest of what needs attention, each with its fix on its row.
    for item in &state.more_attention {
        items.push(match item {
            TrayAttention::Error(message) => TrayItem::action(
                DISMISS_ERROR,
                TrayLabel::new(short_error(message))
                    .icon(TrayGlyph::Warning)
                    .trailing(Some(tr("Dismiss"))),
            ),
            TrayAttention::Approvals(count) => TrayItem::action(
                APPROVALS,
                TrayLabel::new(approvals_text(*count))
                    .icon(TrayGlyph::Approval)
                    .trailing(Some(tr("Review"))),
            ),
        });
    }
}

/// The macOS menu bar panel as a menu: the status block, then Quick Recall,
/// dictation and the last dictation; the two most recent meetings; the
/// Autocomplete switch, Pause day memory and (port-only) Capture Screen Now;
/// then Open LokalBot, Settings…, the update on offer and Quit LokalBot.
pub fn standard_items(state: &TrayMenuState) -> Vec<TrayItem> {
    use item_ids::*;
    use lokalbot_i18n::tr;
    let mut items = Vec::new();
    block_items(state, &mut items);
    items.push(TrayItem::Separator);

    items.push(TrayItem::action(
        ASK,
        TrayLabel::new(tr("Quick Recall…"))
            .icon(TrayGlyph::Search)
            .trailing(state.quick_recall_shortcut.clone()),
    ));
    // Starts dictation; while one runs, the same row stops or cancels it. A
    // meeting recording holds the microphone, so the row waits for it.
    let working = state.dictation.is_working();
    let dictation_trailing = if state.dictation == TrayDictation::Recording {
        state.dictation_timer.clone()
    } else if !working && state.dictation_enabled {
        Some(state.dictation_shortcut.clone())
    } else {
        None
    };
    items.push(
        TrayItem::action(
            DICTATION_BUTTON,
            TrayLabel::new(tr(state.dictation.button()))
                .icon(state.dictation.glyph())
                .trailing(dictation_trailing),
        )
        .enabled(!state.recording || working),
    );
    // The way back to a dictation the clipboard lost: the newest with its
    // preview, earlier ones in a menu of their own (`LastDictationMenuRow`).
    if let Some((latest, earlier)) = state.recent_dictations.split_first() {
        items.push(TrayItem::action(
            COPY_LAST_DICTATION,
            TrayLabel::new(lokalbot_i18n::format(
                "Copy last dictation — {preview}",
                &[("preview", short_title(&latest.preview))],
            ))
            .icon(TrayGlyph::Copy),
        ));
        if !earlier.is_empty() {
            items.push(TrayItem::Submenu {
                label: TrayLabel::new(tr("Earlier dictations")).icon(TrayGlyph::History),
                items: earlier
                    .iter()
                    .map(|entry| {
                        TrayItem::action(
                            &format!("{DICTATION_PREFIX}{}", entry.id),
                            entry.menu_title.as_str(),
                        )
                    })
                    .collect(),
            });
        }
    }
    items.push(TrayItem::Separator);

    items.push(TrayItem::status(tr("Recent meetings")));
    if state.recent_meetings.is_empty() {
        items.push(TrayItem::status(tr("No meetings yet")));
    }
    for meeting in &state.recent_meetings {
        items.push(TrayItem::action(
            &format!("{MEETING_PREFIX}{}", meeting.id),
            TrayLabel::new(short_title(&meeting.title))
                .icon(TrayGlyph::Meeting)
                .trailing(Some(meeting.when.clone())),
        ));
    }
    items.push(TrayItem::Separator);

    items.push(TrayItem::Toggle {
        id: AUTOCOMPLETE_ENABLED.into(),
        label: tr("Autocomplete").to_string(),
        checked: state.autocomplete_enabled,
    });
    if state.tracking_enabled {
        items.push(if state.day_memory_paused {
            TrayItem::action(
                RESUME_DAY_MEMORY,
                TrayLabel::new(tr("Resume day memory")).icon(TrayGlyph::Resume),
            )
        } else {
            TrayItem::action(
                PAUSE_DAY_MEMORY,
                TrayLabel::new(tr("Pause day memory")).icon(TrayGlyph::Pause),
            )
        });
    }
    if state.screen_capture && !state.day_memory_paused {
        items.push(TrayItem::action(
            CAPTURE_SCREEN,
            TrayLabel::new(tr("Capture Screen Now")).icon(TrayGlyph::Capture),
        ));
    }
    items.push(TrayItem::Separator);

    items.push(TrayItem::action(
        OPEN,
        TrayLabel::new(tr("Open LokalBot")).icon(TrayGlyph::Window),
    ));
    items.push(TrayItem::action(
        SETTINGS,
        TrayLabel::new(tr("Settings…")).icon(TrayGlyph::Settings),
    ));
    if let Some(update) = &state.update {
        let version = [("version", update.version.clone())];
        let row = |id: &str, text: String| {
            TrayItem::action(id, TrayLabel::new(text).icon(TrayGlyph::Update))
        };
        items.push(match (update.busy, update.action) {
            (true, _) => row(
                INSTALL_UPDATE,
                lokalbot_i18n::format("Installing LokalBot {version}…", &version),
            )
            .enabled(false),
            (false, TrayUpdateAction::Install) => row(
                INSTALL_UPDATE,
                lokalbot_i18n::format("Install LokalBot {version} and Relaunch", &version),
            ),
            (false, TrayUpdateAction::Download) => row(
                DOWNLOAD_UPDATE,
                lokalbot_i18n::format("Download LokalBot {version}…", &version),
            ),
            (false, TrayUpdateAction::Show) => row(
                SHOW_UPDATE,
                lokalbot_i18n::format("LokalBot {version} is available", &version),
            ),
        });
    }
    items.push(TrayItem::action(
        QUIT,
        TrayLabel::new(tr("Quit LokalBot")).icon(TrayGlyph::Quit),
    ));
    items
}

/// RGBA pixels, width and height.
pub type TrayIcon = (Vec<u8>, u32, u32);

/// How the tray icon looks.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TrayIconState {
    /// A meeting is being recorded: the red dot, which wins over the rest.
    pub recording: bool,
    /// "MM:SS" while recording, for the tooltip.
    pub timer: Option<String>,
    /// Day memory is paused: the icon is drawn faint.
    pub dimmed: bool,
    /// Something needs attention: a dot on the top right corner.
    pub attention: bool,
}

impl TrayIconState {
    /// The parts that change the picture, not only the tooltip.
    fn variant(&self) -> (bool, bool, bool) {
        (
            self.recording,
            self.dimmed && !self.recording,
            self.attention && !self.recording,
        )
    }
}

/// How much of the icon is left while day memory is paused
/// (`MenuBarIcon.dimmedOpacity`).
const DIMMED_OPACITY: f32 = 0.38;

/// The icon as `state` draws it: the red recording dot, or the icon faint
/// while day memory is paused, with an amber dot cut into its top right
/// corner while something needs attention (`MenuBarIcon.image`).
pub fn icon_variant(icon: &TrayIcon, state: &TrayIconState) -> TrayIcon {
    if state.recording {
        return recording_variant(icon);
    }
    let (pixels, width, height) = icon;
    let mut out = pixels.clone();
    if state.dimmed {
        for pixel in out.as_chunks_mut::<4>().0 {
            pixel[3] = (f32::from(pixel[3]) * DIMMED_OPACITY).round() as u8;
        }
    }
    if state.attention {
        let (w, h) = (*width as f32, *height as f32);
        let side = w.min(h);
        let radius = side * 0.2;
        // The clear ring that separates the dot from the icon under it.
        let gap = side * 0.08;
        let (cx, cy) = (w - radius - side * 0.02, radius + side * 0.02);
        for y in 0..*height {
            for x in 0..*width {
                let distance =
                    ((x as f32 + 0.5 - cx).powi(2) + (y as f32 + 0.5 - cy).powi(2)).sqrt();
                let index = ((y * width + x) * 4) as usize;
                let Some(pixel) = out.get_mut(index..index + 4) else {
                    continue;
                };
                if distance <= radius {
                    pixel[..3].copy_from_slice(&ATTENTION_AMBER);
                    pixel[3] = 0xFF;
                } else if distance <= radius + gap {
                    pixel.copy_from_slice(&[0, 0, 0, 0]);
                }
            }
        }
    }
    (out, *width, *height)
}

/// The icon with a red recording dot in its lower right corner.
pub fn recording_variant(icon: &TrayIcon) -> TrayIcon {
    let (pixels, width, height) = icon;
    let mut out = pixels.clone();
    let (w, h) = (*width as f32, *height as f32);
    let radius = w.min(h) * 0.24;
    let (cx, cy) = (w - radius - w * 0.04, h - radius - h * 0.04);
    for y in 0..*height {
        for x in 0..*width {
            let distance = ((x as f32 + 0.5 - cx).powi(2) + (y as f32 + 0.5 - cy).powi(2)).sqrt();
            let index = ((y * width + x) * 4) as usize;
            let Some(pixel) = out.get_mut(index..index + 4) else {
                continue;
            };
            if distance <= radius {
                pixel[..3].copy_from_slice(&RECORDING_RED);
                pixel[3] = 0xFF;
            } else if distance <= radius + w.min(h) * 0.06 {
                pixel.copy_from_slice(&[0xFF, 0xFF, 0xFF, 0xFF]);
            }
        }
    }
    (out, *width, *height)
}

/// "LokalBot — Recording 12:04", "LokalBot — Needs attention, Day memory is
/// paused": the icon's state in words, as the Mac's status item says it to
/// assistive tools.
fn tooltip_text(base: &str, state: &TrayIconState) -> String {
    use lokalbot_i18n::tr;
    let mut words: Vec<String> = Vec::new();
    if state.recording {
        words.push(match &state.timer {
            Some(timer) => format!("{} {timer}", tr("Recording")),
            None => tr("Recording").to_string(),
        });
    } else {
        if state.attention {
            words.push(tr("Needs attention").to_string());
        }
        if state.dimmed {
            words.push(tr("Day memory is paused").to_string());
        }
    }
    if words.is_empty() {
        base.to_string()
    } else {
        format!("{base} — {}", words.join(", "))
    }
}

/// The tray icon. Dropping it removes the icon.
pub struct Tray {
    inner: backend::Tray,
}

impl Tray {
    /// `glyphs` are the row icons' pixels for menus that draw pixels
    /// (Windows); Linux names its icons instead. Glyphs that are
    /// [`TrayGlyph::drawn`] here need none.
    pub fn new(
        icon_rgba: TrayIcon,
        tooltip: &str,
        items: Vec<TrayItem>,
        glyphs: Vec<(TrayGlyph, TrayIcon)>,
        on_event: Box<dyn Fn(TrayEvent) + Send>,
    ) -> anyhow::Result<Tray> {
        let (_, width, height) = &icon_rgba;
        anyhow::ensure!(
            icon_rgba.0.len() == (*width as usize) * (*height as usize) * 4,
            "the tray icon must be {width}×{height} RGBA pixels"
        );
        Ok(Tray {
            inner: backend::Tray::new(icon_rgba, tooltip.to_string(), items, glyphs, on_event)?,
        })
    }

    /// Shows the recording dot, the dimmed icon or the attention dot, and
    /// says so in the tooltip.
    pub fn set_icon_state(&self, state: TrayIconState) -> anyhow::Result<()> {
        self.inner.set_icon_state(state)
    }

    /// Replaces the menu.
    pub fn set_items(&self, items: Vec<TrayItem>) -> anyhow::Result<()> {
        self.inner.set_items(items)
    }

    pub fn set_tooltip(&self, tooltip: &str) -> anyhow::Result<()> {
        self.inner.set_tooltip(tooltip.to_string())
    }
}

#[cfg(target_os = "linux")]
mod backend {
    use std::collections::HashMap;
    use std::sync::OnceLock;

    use ksni::blocking::TrayMethods as _;
    use ksni::menu::{CheckmarkItem, MenuItem, StandardItem, SubMenu};

    use super::{
        TrayEvent, TrayGlyph, TrayIcon, TrayIconState, TrayItem, TrayLabel, icon_variant,
        tooltip_text,
    };

    /// ARGB32 in network byte order, as StatusNotifierItem expects.
    fn pixmap(icon: &TrayIcon) -> Vec<ksni::Icon> {
        let (pixels, width, height) = icon;
        let data = pixels
            .as_chunks::<4>()
            .0
            .iter()
            .flat_map(|[r, g, b, a]| [*a, *r, *g, *b])
            .collect();
        vec![ksni::Icon {
            width: *width as i32,
            height: *height as i32,
            data,
        }]
    }

    /// PNG data for the glyphs drawn here, made once.
    fn drawn_png(glyph: TrayGlyph) -> Option<&'static [u8]> {
        static PNGS: OnceLock<HashMap<TrayGlyph, Vec<u8>>> = OnceLock::new();
        PNGS.get_or_init(|| {
            TrayGlyph::ALL
                .iter()
                .filter_map(|glyph| Some((*glyph, encode_png(&glyph.drawn()?)?)))
                .collect()
        })
        .get(&glyph)
        .map(Vec::as_slice)
    }

    fn encode_png((pixels, width, height): &TrayIcon) -> Option<Vec<u8>> {
        let mut out = Vec::new();
        let mut encoder = png::Encoder::new(&mut out, *width, *height);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        let mut writer = encoder.write_header().ok()?;
        writer.write_image_data(pixels).ok()?;
        writer.finish().ok()?;
        Some(out)
    }

    /// A row's icon as dbusmenu carries it: a theme name, or PNG data for the
    /// red glyphs.
    fn icon_fields(label: &TrayLabel) -> (String, Vec<u8>) {
        match label.icon {
            None => (String::new(), Vec::new()),
            Some(glyph) => match drawn_png(glyph) {
                Some(png) => (String::new(), png.to_vec()),
                None => (glyph.icon_name().to_string(), Vec::new()),
            },
        }
    }

    struct Sni {
        base_icon: TrayIcon,
        icon: Vec<ksni::Icon>,
        tooltip: String,
        state: TrayIconState,
        items: Vec<TrayItem>,
        on_event: Box<dyn Fn(TrayEvent) + Send>,
    }

    impl ksni::Tray for Sni {
        fn id(&self) -> String {
            crate::APP_ID.into()
        }

        fn title(&self) -> String {
            "LokalBot".into()
        }

        fn icon_pixmap(&self) -> Vec<ksni::Icon> {
            self.icon.clone()
        }

        fn tool_tip(&self) -> ksni::ToolTip {
            ksni::ToolTip {
                title: tooltip_text(&self.tooltip, &self.state),
                ..Default::default()
            }
        }

        fn activate(&mut self, _x: i32, _y: i32) {
            (self.on_event)(TrayEvent::Activated);
        }

        /// The app answers with the menu as it is now; hosts that ask before
        /// opening it show the status current.
        fn menu_about_to_show(&mut self) {
            (self.on_event)(TrayEvent::MenuOpening);
        }

        fn menu(&self) -> Vec<MenuItem<Self>> {
            menu_items(&self.items)
        }
    }

    fn menu_items(items: &[TrayItem]) -> Vec<MenuItem<Sni>> {
        items
            .iter()
            .map(|item| match item {
                TrayItem::Status(label) => {
                    let (icon_name, icon_data) = icon_fields(label);
                    StandardItem {
                        label: label.linux_text(),
                        enabled: false,
                        icon_name,
                        icon_data,
                        ..Default::default()
                    }
                    .into()
                }
                TrayItem::Action { id, label, enabled } => {
                    let id = id.clone();
                    let (icon_name, icon_data) = icon_fields(label);
                    StandardItem {
                        label: label.linux_text(),
                        enabled: *enabled,
                        icon_name,
                        icon_data,
                        activate: Box::new(move |tray: &mut Sni| {
                            (tray.on_event)(TrayEvent::Item(id.clone()))
                        }),
                        ..Default::default()
                    }
                    .into()
                }
                TrayItem::Toggle { id, label, checked } => {
                    let id = id.clone();
                    CheckmarkItem {
                        label: label.replace('_', "__"),
                        checked: *checked,
                        activate: Box::new(move |tray: &mut Sni| {
                            (tray.on_event)(TrayEvent::Item(id.clone()))
                        }),
                        ..Default::default()
                    }
                    .into()
                }
                TrayItem::Submenu { label, items } => {
                    let (icon_name, icon_data) = icon_fields(label);
                    SubMenu {
                        label: label.linux_text(),
                        icon_name,
                        icon_data,
                        submenu: menu_items(items),
                        ..Default::default()
                    }
                    .into()
                }
                TrayItem::Separator => MenuItem::Separator,
            })
            .collect()
    }

    pub(super) struct Tray {
        handle: ksni::blocking::Handle<Sni>,
    }

    impl Tray {
        pub(super) fn new(
            icon: TrayIcon,
            tooltip: String,
            items: Vec<TrayItem>,
            // Rows name theme icons here.
            _glyphs: Vec<(TrayGlyph, TrayIcon)>,
            on_event: Box<dyn Fn(TrayEvent) + Send>,
        ) -> anyhow::Result<Self> {
            let tray = Sni {
                icon: pixmap(&icon),
                base_icon: icon,
                tooltip,
                state: TrayIconState::default(),
                items,
                on_event,
            };
            let handle = tray.spawn().map_err(|err| {
                anyhow::anyhow!(
                    "the desktop has no system tray ({err}). On GNOME, the AppIndicator extension adds one."
                )
            })?;
            Ok(Self { handle })
        }

        fn update(&self, change: impl FnOnce(&mut Sni)) -> anyhow::Result<()> {
            self.handle
                .update(change)
                .ok_or_else(|| anyhow::anyhow!("the tray stopped"))
        }

        pub(super) fn set_icon_state(&self, state: TrayIconState) -> anyhow::Result<()> {
            self.update(|tray| {
                if tray.state.variant() != state.variant() {
                    tray.icon = pixmap(&icon_variant(&tray.base_icon, &state));
                }
                tray.state = state;
            })
        }

        pub(super) fn set_items(&self, items: Vec<TrayItem>) -> anyhow::Result<()> {
            self.update(|tray| tray.items = items)
        }

        pub(super) fn set_tooltip(&self, tooltip: String) -> anyhow::Result<()> {
            self.update(|tray| tray.tooltip = tooltip)
        }
    }

    impl Drop for Tray {
        fn drop(&mut self) {
            self.handle.shutdown().wait();
        }
    }
}

#[cfg(windows)]
mod backend {
    use std::collections::HashMap;
    use std::sync::{Arc, Once};

    use crossbeam_channel::{Receiver, Sender, bounded, unbounded};
    use parking_lot::Mutex;
    use tray_icon::menu::{
        CheckMenuItem, Icon as MenuIcon, IconMenuItem, Menu, MenuEvent, MenuItem,
        PredefinedMenuItem, Submenu,
    };
    use tray_icon::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};

    use super::{
        TrayEvent, TrayGlyph, TrayIcon, TrayIconState, TrayItem, TrayLabel, icon_variant,
        tooltip_text,
    };

    type Handler = Arc<Mutex<Box<dyn Fn(TrayEvent) + Send>>>;

    /// `tray-icon` and `muda` allow one event handler each per process.
    static HANDLER: Mutex<Option<Handler>> = Mutex::new(None);

    fn install_handlers() {
        static ONCE: Once = Once::new();
        ONCE.call_once(|| {
            MenuEvent::set_event_handler(Some(|event: MenuEvent| {
                deliver(TrayEvent::Item(event.id.0));
            }));
            TrayIconEvent::set_event_handler(Some(|event: TrayIconEvent| match event {
                TrayIconEvent::Click {
                    button: MouseButton::Left,
                    button_state: MouseButtonState::Up,
                    ..
                } => deliver(TrayEvent::Activated),
                // The menu opens when the right button comes up: the app
                // sends it current before then.
                TrayIconEvent::Click {
                    button: MouseButton::Right,
                    button_state: MouseButtonState::Down,
                    ..
                } => deliver(TrayEvent::MenuOpening),
                _ => {}
            }));
        });
    }

    fn deliver(event: TrayEvent) {
        let handler = HANDLER.lock().clone();
        if let Some(handler) = handler {
            (handler.lock())(event);
        }
    }

    enum Command {
        Icon(TrayIconState),
        Items(Vec<TrayItem>),
        Tooltip(String),
        Stop,
    }

    pub(super) struct Tray {
        commands: Sender<Command>,
        thread_id: u32,
        thread: Option<std::thread::JoinHandle<()>>,
    }

    /// The row icons, made once on the tray thread.
    type Glyphs = HashMap<TrayGlyph, MenuIcon>;

    fn glyph_icons(given: Vec<(TrayGlyph, TrayIcon)>) -> Glyphs {
        let drawn = TrayGlyph::ALL
            .into_iter()
            .filter_map(|glyph| Some((glyph, glyph.drawn()?)));
        given
            .into_iter()
            .chain(drawn)
            .filter_map(|(glyph, (pixels, width, height))| {
                match MenuIcon::from_rgba(pixels, width, height) {
                    Ok(icon) => Some((glyph, icon)),
                    Err(err) => {
                        log::warn!("tray: no icon for {glyph:?}: {err}");
                        None
                    }
                }
            })
            .collect()
    }

    /// A row that cannot be chosen, or an action, with its icon when there is one.
    fn row(
        id: Option<&str>,
        label: &TrayLabel,
        enabled: bool,
        glyphs: &Glyphs,
        menu: &Menu,
    ) -> anyhow::Result<()> {
        let text = label.windows_text();
        let icon = label.icon.and_then(|glyph| glyphs.get(&glyph).cloned());
        match (id, icon) {
            (Some(id), Some(icon)) => {
                menu.append(&IconMenuItem::with_id(id, &text, enabled, Some(icon), None))?
            }
            (Some(id), None) => menu.append(&MenuItem::with_id(id, &text, enabled, None))?,
            (None, Some(icon)) => {
                menu.append(&IconMenuItem::new(&text, enabled, Some(icon), None))?
            }
            (None, None) => menu.append(&MenuItem::new(&text, enabled, None))?,
        }
        Ok(())
    }

    fn menu(items: &[TrayItem], glyphs: &Glyphs) -> anyhow::Result<Menu> {
        let menu = Menu::new();
        for item in items {
            match item {
                TrayItem::Status(label) => row(None, label, false, glyphs, &menu)?,
                TrayItem::Action { id, label, enabled } => {
                    row(Some(id.as_str()), label, *enabled, glyphs, &menu)?
                }
                TrayItem::Toggle { id, label, checked } => menu.append(&CheckMenuItem::with_id(
                    id.as_str(),
                    label.replace('&', "&&"),
                    true,
                    *checked,
                    None,
                ))?,
                TrayItem::Submenu { label, items } => {
                    let submenu = Submenu::new(label.windows_text(), true);
                    for item in items {
                        if let TrayItem::Action { id, label, enabled } = item {
                            let icon = label.icon.and_then(|glyph| glyphs.get(&glyph).cloned());
                            match icon {
                                Some(icon) => submenu.append(&IconMenuItem::with_id(
                                    id.as_str(),
                                    label.windows_text(),
                                    *enabled,
                                    Some(icon),
                                    None,
                                ))?,
                                None => submenu.append(&MenuItem::with_id(
                                    id.as_str(),
                                    label.windows_text(),
                                    *enabled,
                                    None,
                                ))?,
                            }
                        }
                    }
                    menu.append(&submenu)?
                }
                TrayItem::Separator => menu.append(&PredefinedMenuItem::separator())?,
            }
        }
        Ok(menu)
    }

    fn icon(icon: &TrayIcon) -> anyhow::Result<tray_icon::Icon> {
        Ok(tray_icon::Icon::from_rgba(icon.0.clone(), icon.1, icon.2)?)
    }

    fn run(
        base: TrayIcon,
        mut tooltip: String,
        items: Vec<TrayItem>,
        glyphs: Vec<(TrayGlyph, TrayIcon)>,
        commands: Receiver<Command>,
        ready: Sender<anyhow::Result<u32>>,
    ) {
        let glyphs = glyph_icons(glyphs);
        let created = (|| -> anyhow::Result<_> {
            TrayIconBuilder::new()
                .with_id(crate::APP_ID)
                .with_icon(icon(&base)?)
                .with_tooltip(&tooltip)
                .with_menu(Box::new(menu(&items, &glyphs)?))
                .with_menu_on_left_click(false)
                .build()
                .map_err(Into::into)
        })();
        let tray = match created {
            Ok(tray) => tray,
            Err(err) => {
                let _ = ready.send(Err(err));
                return;
            }
        };
        let mut state = TrayIconState::default();
        crate::win32_loop::run(
            |thread_id| {
                let _ = ready.send(Ok(thread_id));
            },
            || {
                while let Ok(command) = commands.try_recv() {
                    let result: anyhow::Result<()> = match command {
                        Command::Icon(next) => {
                            let picture = if next.variant() != state.variant() {
                                icon(&icon_variant(&base, &next)).and_then(|shown| {
                                    tray.set_icon(Some(shown)).map_err(Into::into)
                                })
                            } else {
                                Ok(())
                            };
                            state = next;
                            picture.and_then(|()| {
                                tray.set_tooltip(Some(tooltip_text(&tooltip, &state)))
                                    .map_err(Into::into)
                            })
                        }
                        Command::Items(items) => menu(&items, &glyphs).map(|menu| {
                            tray.set_menu(Some(Box::new(menu)));
                        }),
                        Command::Tooltip(text) => {
                            tooltip = text;
                            tray.set_tooltip(Some(tooltip_text(&tooltip, &state)))
                                .map_err(Into::into)
                        }
                        Command::Stop => return false,
                    };
                    if let Err(err) = result {
                        log::warn!("tray: {err:#}");
                    }
                }
                true
            },
        );
        drop(tray);
    }

    impl Tray {
        pub(super) fn new(
            icon: TrayIcon,
            tooltip: String,
            items: Vec<TrayItem>,
            glyphs: Vec<(TrayGlyph, TrayIcon)>,
            on_event: Box<dyn Fn(TrayEvent) + Send>,
        ) -> anyhow::Result<Self> {
            install_handlers();
            *HANDLER.lock() = Some(Arc::new(Mutex::new(on_event)));
            let (commands, receiver) = unbounded();
            let (ready_tx, ready_rx) = bounded(1);
            let thread = std::thread::Builder::new()
                .name("lokalbot-tray".into())
                .spawn(move || run(icon, tooltip, items, glyphs, receiver, ready_tx))?;
            let thread_id = ready_rx
                .recv()
                .map_err(|_| anyhow::anyhow!("the tray thread stopped"))??;
            Ok(Self {
                commands,
                thread_id,
                thread: Some(thread),
            })
        }

        fn send(&self, command: Command) -> anyhow::Result<()> {
            self.commands
                .send(command)
                .map_err(|_| anyhow::anyhow!("the tray stopped"))?;
            crate::win32_loop::wake(self.thread_id);
            Ok(())
        }

        pub(super) fn set_icon_state(&self, state: TrayIconState) -> anyhow::Result<()> {
            self.send(Command::Icon(state))
        }

        pub(super) fn set_items(&self, items: Vec<TrayItem>) -> anyhow::Result<()> {
            self.send(Command::Items(items))
        }

        pub(super) fn set_tooltip(&self, tooltip: String) -> anyhow::Result<()> {
            self.send(Command::Tooltip(tooltip))
        }
    }

    impl Drop for Tray {
        fn drop(&mut self) {
            let _ = self.send(Command::Stop);
            if let Some(thread) = self.thread.take() {
                let _ = thread.join();
            }
            *HANDLER.lock() = None;
        }
    }
}

#[cfg(not(any(windows, target_os = "linux")))]
mod backend {
    use super::{TrayEvent, TrayGlyph, TrayIcon, TrayIconState, TrayItem};

    pub(super) struct Tray;

    impl Tray {
        pub(super) fn new(
            _: TrayIcon,
            _: String,
            _: Vec<TrayItem>,
            _: Vec<(TrayGlyph, TrayIcon)>,
            _: Box<dyn Fn(TrayEvent) + Send>,
        ) -> anyhow::Result<Self> {
            anyhow::bail!("no system tray on this system")
        }
        pub(super) fn set_icon_state(&self, _: TrayIconState) -> anyhow::Result<()> {
            Ok(())
        }
        pub(super) fn set_items(&self, _: Vec<TrayItem>) -> anyhow::Result<()> {
            Ok(())
        }
        pub(super) fn set_tooltip(&self, _: String) -> anyhow::Result<()> {
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The rows' words, each with what sits at its far side.
    fn rows(items: &[TrayItem]) -> Vec<String> {
        items
            .iter()
            .filter_map(|item| {
                let trailing = match item {
                    TrayItem::Status(label)
                    | TrayItem::Action { label, .. }
                    | TrayItem::Submenu { label, .. } => label.trailing.clone(),
                    _ => None,
                };
                let text = item.text()?;
                Some(match trailing {
                    Some(trailing) => format!("{text} | {trailing}"),
                    None => text.to_string(),
                })
            })
            .collect()
    }

    fn find<'a>(items: &'a [TrayItem], text: &str) -> &'a TrayItem {
        items
            .iter()
            .find(|item| item.text() == Some(text))
            .unwrap_or_else(|| panic!("no row {text:?} in {:?}", rows(items)))
    }

    fn id_of(item: &TrayItem) -> &str {
        match item {
            TrayItem::Action { id, .. } | TrayItem::Toggle { id, .. } => id,
            _ => "",
        }
    }

    fn enabled(item: &TrayItem) -> bool {
        matches!(
            item,
            TrayItem::Action { enabled: true, .. } | TrayItem::Toggle { .. }
        )
    }

    fn icon(item: &TrayItem) -> Option<TrayGlyph> {
        match item {
            TrayItem::Status(label)
            | TrayItem::Action { label, .. }
            | TrayItem::Submenu { label, .. } => label.icon,
            _ => None,
        }
    }

    fn meeting(id: &str, title: &str, when: &str) -> TrayMeeting {
        TrayMeeting {
            id: id.into(),
            title: title.into(),
            when: when.into(),
        }
    }

    #[test]
    fn the_menu_reads_like_the_mac_panel() {
        let items = standard_items(&TrayMenuState {
            block: TrayBlock::Idle {
                habit: AutoRecordMode::Automatic,
            },
            dictation_enabled: true,
            dictation_shortcut: "Alt+Space".into(),
            quick_recall_shortcut: Some("Ctrl+Shift+Space".into()),
            recent_meetings: vec![
                meeting("A", "Design review meeting", "11:00 AM"),
                meeting("B", "Engineering standup", "10:00 AM"),
            ],
            autocomplete_enabled: true,
            tracking_enabled: true,
            ..Default::default()
        });
        assert_eq!(
            rows(&items),
            [
                "Not recording",
                "Records meetings when they start",
                "Record now",
                "Quick Recall… | Ctrl+Shift+Space",
                "Start dictation | Alt+Space",
                "Recent meetings",
                "Design review meeting | 11:00 AM",
                "Engineering standup | 10:00 AM",
                "Autocomplete",
                "Pause day memory",
                "Open LokalBot",
                "Settings…",
                "Quit LokalBot",
            ]
        );
        // Every row that can be chosen has an icon; the switch is a check item.
        for item in &items {
            if let TrayItem::Action { label, .. } = item {
                assert!(label.icon.is_some(), "{} has no icon", label.text);
            }
        }
        assert!(items.contains(&TrayItem::Toggle {
            id: item_ids::AUTOCOMPLETE_ENABLED.into(),
            label: "Autocomplete".into(),
            checked: true,
        }));
        assert_eq!(icon(find(&items, "Record now")), Some(TrayGlyph::Record));
        assert_eq!(id_of(find(&items, "Design review meeting")), "meeting:A");
        // Gone with the redesign: the Tools caption, the dictation switch,
        // View all and Star on GitHub.
        for gone in ["Tools", "Recent", "View all", "Star on GitHub"] {
            assert!(items.iter().all(|item| item.text() != Some(gone)), "{gone}");
        }
        assert!(!items.iter().any(|item| {
            item.text()
                .is_some_and(|t| t.starts_with("Dictation shortcut"))
        }));
        // Without its shortcut on, Quick Recall shows none; no meetings yet.
        let bare = standard_items(&TrayMenuState::default());
        assert_eq!(
            find(&bare, "Quick Recall…"),
            &TrayItem::action(
                item_ids::ASK,
                TrayLabel::new("Quick Recall…").icon(TrayGlyph::Search)
            )
        );
        assert_eq!(
            find(&bare, "No meetings yet"),
            &TrayItem::status("No meetings yet")
        );
        assert!(!rows(&bare).contains(&"Pause day memory".to_string()));
    }

    #[test]
    fn recording_leads_with_the_meeting_its_sources_and_stop() {
        let recording = |call_audio, warnings: Vec<String>| TrayMenuState {
            block: TrayBlock::Recording(TrayRecording {
                title: "Weekly sync".into(),
                timer: "12:04".into(),
                warnings,
                microphone: TraySource {
                    status: "Receiving audio".into(),
                    receiving: true,
                },
                call_audio,
            }),
            recording: true,
            ..Default::default()
        };
        let items = standard_items(&recording(
            Some(TraySource {
                status: "Waiting for audio".into(),
                receiving: false,
            }),
            Vec::new(),
        ));
        assert_eq!(
            rows(&items[..6]),
            [
                "Recording | 12:04",
                "Weekly sync",
                "Microphone",
                "Call audio · Waiting for audio",
                "Stop",
                "Open live notes",
            ]
        );
        assert_eq!(id_of(&items[4]), item_ids::STOP_RECORDING);
        assert_eq!(icon(&items[4]), Some(TrayGlyph::Stop));
        assert_eq!(id_of(&items[5]), item_ids::LIVE_TRANSCRIPT);
        // The recording holds the microphone: dictation waits.
        assert!(!enabled(find(&items, "Start dictation")));

        let alone = standard_items(&recording(None, vec!["The microphone went quiet".into()]));
        assert_eq!(
            rows(&alone[..4]),
            [
                "Recording needs attention | 12:04",
                "Weekly sync",
                "Microphone only",
                "The microphone went quiet",
            ]
        );
        assert_eq!(icon(&alone[3]), Some(TrayGlyph::Warning));
    }

    #[test]
    fn day_memory_paused_offers_resume_and_still_records() {
        let items = standard_items(&TrayMenuState {
            block: TrayBlock::Paused {
                habit: AutoRecordMode::Automatic,
            },
            tracking_enabled: true,
            day_memory_paused: true,
            screen_capture: true,
            ..Default::default()
        });
        assert_eq!(
            rows(&items[..4]),
            [
                "Day memory is paused",
                "Meetings still record when they start",
                "Resume",
                "Record now",
            ]
        );
        assert_eq!(id_of(&items[2]), item_ids::RESUME_DAY_MEMORY);
        assert_eq!(
            id_of(find(&items, "Resume day memory")),
            item_ids::RESUME_DAY_MEMORY
        );
        // Nothing is captured while day memory is paused.
        assert!(
            items
                .iter()
                .all(|item| id_of(item) != item_ids::CAPTURE_SCREEN)
        );
        let capturing = standard_items(&TrayMenuState {
            screen_capture: true,
            tracking_enabled: true,
            ..Default::default()
        });
        assert_eq!(
            id_of(find(&capturing, "Capture Screen Now")),
            item_ids::CAPTURE_SCREEN
        );
        assert_eq!(
            id_of(find(&capturing, "Pause day memory")),
            item_ids::PAUSE_DAY_MEMORY
        );
    }

    #[test]
    fn a_saved_recording_is_named_with_open_notes() {
        let items = standard_items(&TrayMenuState {
            block: TrayBlock::JustStopped {
                meeting_id: "M1".into(),
                title: "Design review".into(),
                duration: "12 min".into(),
            },
            recent_meetings: vec![meeting("M1", "Design review", "Just now")],
            ..Default::default()
        });
        assert_eq!(
            rows(&items[..4]),
            [
                "Not recording",
                "Design review saved · 12 min",
                "Record now",
                "Open notes",
            ]
        );
        assert_eq!(id_of(&items[3]), "meeting:M1");
        assert!(rows(&items).contains(&"Design review | Just now".to_string()));
    }

    #[test]
    fn a_meeting_about_to_start_offers_join_and_record() {
        let soon = |is_call, joinable| {
            standard_items(&TrayMenuState {
                block: TrayBlock::MeetingSoon(TraySoonMeeting {
                    event_id: "E1".into(),
                    title: "Design review meeting".into(),
                    status: "In 5 min".into(),
                    schedule: "6:00 PM – 6:30 PM".into(),
                    auto_records: true,
                    is_call,
                    joinable,
                }),
                ..Default::default()
            })
        };
        let items = soon(true, true);
        assert_eq!(
            rows(&items[..5]),
            [
                "Design review meeting | In 5 min",
                "6:00 PM – 6:30 PM",
                "Recording starts when the call does",
                "Join",
                "Record",
            ]
        );
        assert_eq!(id_of(&items[3]), "join:E1");
        assert_eq!(id_of(&items[4]), "record-event:E1");
        // A solo event is recorded like any manual start, and has no Join.
        let solo = soon(false, false);
        assert_eq!(id_of(find(&solo, "Record")), item_ids::RECORD);
        assert!(solo.iter().all(|item| item.text() != Some("Join")));
    }

    #[test]
    fn what_needs_attention_leads_or_is_listed_under_the_block() {
        let items = standard_items(&TrayMenuState {
            block: TrayBlock::Attention(TrayAttention::Error(
                "The microphone stopped\nsecond line".into(),
            )),
            more_attention: vec![TrayAttention::Approvals(2)],
            ..Default::default()
        });
        assert_eq!(
            rows(&items[..4]),
            [
                "Needs attention",
                "The microphone stopped",
                "Dismiss",
                "2 settings changes are waiting for your approval | Review",
            ]
        );
        assert_eq!(id_of(&items[2]), item_ids::DISMISS_ERROR);
        assert_eq!(id_of(&items[3]), item_ids::APPROVALS);

        let approvals = standard_items(&TrayMenuState {
            block: TrayBlock::Attention(TrayAttention::Approvals(1)),
            ..Default::default()
        });
        assert_eq!(
            rows(&approvals[..2]),
            ["A settings change is waiting for your approval", "Review"]
        );
        assert_eq!(id_of(&approvals[1]), item_ids::APPROVALS);

        // Under a recording, an error keeps its fix on its own row.
        let recording = standard_items(&TrayMenuState {
            block: TrayBlock::Recording(TrayRecording::default()),
            more_attention: vec![TrayAttention::Error("Disk is full".into())],
            ..Default::default()
        });
        let error = find(&recording, "Disk is full");
        assert_eq!(id_of(error), item_ids::DISMISS_ERROR);
        assert_eq!(icon(error), Some(TrayGlyph::Warning));
    }

    #[test]
    fn dictation_says_how_to_finish_and_offers_stop_or_cancel() {
        let dictating = |phase, trigger| {
            standard_items(&TrayMenuState {
                block: TrayBlock::Dictating(phase),
                dictation: phase,
                dictation_timer: Some("00:07".into()),
                dictation_enabled: true,
                dictation_shortcut: "Alt+Space".into(),
                dictation_trigger: trigger,
                ..Default::default()
            })
        };
        let items = dictating(TrayDictation::Recording, DictationTriggerMode::Toggle);
        assert_eq!(
            rows(&items[..3]),
            [
                "Dictating | 00:07",
                "Press Alt+Space again to compose",
                "Stop dictation",
            ]
        );
        assert_eq!(id_of(&items[2]), item_ids::DICTATION_BUTTON);
        // The row below says the same, with the timer at its far side.
        assert!(rows(&items[3..]).contains(&"Stop dictation | 00:07".to_string()));
        // A dictation holds the microphone: a Record shown meanwhile waits.
        let starting = standard_items(&TrayMenuState {
            dictation: TrayDictation::Starting,
            ..Default::default()
        });
        assert!(!enabled(find(&starting, "Record now")));
        assert!(enabled(find(
            &standard_items(&TrayMenuState::default()),
            "Record now"
        )));
        let held = dictating(TrayDictation::Recording, DictationTriggerMode::PushToTalk);
        assert_eq!(held[1].text(), Some("Release Alt+Space to compose"));
        let tapped = dictating(TrayDictation::Recording, DictationTriggerMode::TapOrHold);
        assert_eq!(
            tapped[1].text(),
            Some("Release or tap Alt+Space to compose")
        );
        let composing = dictating(TrayDictation::Composing, DictationTriggerMode::Toggle);
        assert_eq!(
            rows(&composing[..3]),
            [
                "Composing",
                "Writing for the focused app",
                "Cancel dictation"
            ]
        );
        assert_eq!(icon(&composing[2]), Some(TrayGlyph::Cancel));
    }

    #[test]
    fn a_recent_dictation_can_be_copied_from_the_menu() {
        let entry = |id: &str, preview: &str| TrayDictationEntry {
            id: id.into(),
            preview: preview.into(),
            menu_title: format!("2:20 PM — {preview}"),
        };
        let copy = TrayItem::action(
            item_ids::COPY_LAST_DICTATION,
            TrayLabel::new("Copy last dictation — Can you check the build").icon(TrayGlyph::Copy),
        );
        assert!(!standard_items(&TrayMenuState::default()).contains(&copy));
        let items = standard_items(&TrayMenuState {
            recent_dictations: vec![entry("1", "Can you check the build")],
            ..Default::default()
        });
        let dictation = items
            .iter()
            .position(|item| id_of(item) == item_ids::DICTATION_BUTTON)
            .unwrap();
        assert_eq!(items[dictation + 1], copy);
        assert!(
            !items
                .iter()
                .any(|item| matches!(item, TrayItem::Submenu { .. }))
        );

        // Earlier ones sit in a menu of their own, each copied by its id.
        let items = standard_items(&TrayMenuState {
            recent_dictations: vec![
                entry("1", "Can you check the build"),
                entry("2", "Send the notes"),
            ],
            ..Default::default()
        });
        assert_eq!(items[dictation + 1], copy);
        assert_eq!(
            items[dictation + 2],
            TrayItem::Submenu {
                label: TrayLabel::new("Earlier dictations").icon(TrayGlyph::History),
                items: vec![TrayItem::action("dictation:2", "2:20 PM — Send the notes")],
            }
        );
    }

    #[test]
    fn an_offered_update_sits_above_quit() {
        let update = |action, busy| {
            standard_items(&TrayMenuState {
                update: Some(TrayUpdate {
                    version: "0.10.11".into(),
                    action,
                    busy,
                }),
                ..Default::default()
            })
        };
        let row = |id: &str, text: &str| {
            TrayItem::action(id, TrayLabel::new(text).icon(TrayGlyph::Update))
        };
        let items = update(TrayUpdateAction::Install, false);
        let count = items.len();
        assert_eq!(
            items[count - 2],
            row(
                item_ids::INSTALL_UPDATE,
                "Install LokalBot 0.10.11 and Relaunch"
            )
        );
        assert_eq!(items[count - 1].text(), Some("Quit LokalBot"));
        assert_eq!(id_of(&items[count - 1]), item_ids::QUIT);
        assert!(update(TrayUpdateAction::Download, false).contains(&row(
            item_ids::DOWNLOAD_UPDATE,
            "Download LokalBot 0.10.11…"
        )));
        // A package manager's copy: Settings says how to update it.
        assert!(
            update(TrayUpdateAction::Show, false)
                .contains(&row(item_ids::SHOW_UPDATE, "LokalBot 0.10.11 is available"))
        );
        assert!(update(TrayUpdateAction::Install, true).contains(
            &row(item_ids::INSTALL_UPDATE, "Installing LokalBot 0.10.11…").enabled(false)
        ));
        assert!(
            !standard_items(&TrayMenuState::default())
                .iter()
                .any(|item| id_of(item).contains("update"))
        );
    }

    #[test]
    fn long_titles_and_errors_are_shortened() {
        let items = standard_items(&TrayMenuState {
            recent_meetings: vec![meeting(
                "ABC",
                "A weekly sync with a very long title that keeps going",
                "Yesterday",
            )],
            ..Default::default()
        });
        assert!(rows(&items).contains(&"A weekly sync with a very l... | Yesterday".to_string()));
        assert_eq!(short_line(&"x".repeat(80)).chars().count(), 60);
        assert_eq!(short_error("first\nsecond"), "first");
    }

    #[test]
    fn labels_follow_each_desktops_menu_rules() {
        let label = TrayLabel::new("Q&A_notes").trailing(Some("11:00 AM"));
        assert_eq!(label.linux_text(), "Q&A__notes · 11:00 AM");
        assert_eq!(label.windows_text(), "Q&&A_notes\t11:00 AM");
        let plain = TrayLabel::new("Open LokalBot").trailing(Some(""));
        assert_eq!(plain.trailing, None);
        assert_eq!(plain.linux_text(), "Open LokalBot");
        assert_eq!(plain.windows_text(), "Open LokalBot");
    }

    #[test]
    fn every_glyph_has_a_theme_icon_and_red_ones_are_drawn() {
        for glyph in TrayGlyph::ALL {
            if glyph != TrayGlyph::Blank {
                assert!(glyph.icon_name().ends_with("-symbolic"), "{glyph:?}");
            }
        }
        let (blank, ..) = TrayGlyph::Blank.drawn().unwrap();
        assert!(blank.iter().all(|byte| *byte == 0));
        let (pixels, w, h) = TrayGlyph::Record.drawn().unwrap();
        assert_eq!((w, h), (GLYPH_SIZE, GLYPH_SIZE));
        let at =
            |x: u32, y: u32| &pixels[((y * w + x) * 4) as usize..((y * w + x) * 4 + 4) as usize];
        assert_eq!(at(16, 16), &[0xFF, 0x3B, 0x30, 0xFF]);
        assert_eq!(at(1, 1)[3], 0);
        assert!(TrayGlyph::Stop.drawn().is_some());
        assert!(TrayGlyph::Search.drawn().is_none());
    }

    #[test]
    fn the_icon_dims_while_paused_and_gets_a_dot_for_attention() {
        let icon = (vec![0x40u8; 32 * 32 * 4], 32, 32);
        let at = |pixels: &[u8], x: u32, y: u32| {
            pixels[((y * 32 + x) * 4) as usize..((y * 32 + x) * 4 + 4) as usize].to_vec()
        };
        let (recording, w, h) = recording_variant(&icon);
        assert_eq!((w, h), (32, 32));
        assert_eq!(at(&recording, 23, 23), [0xFF, 0x3B, 0x30, 0xFF]);
        assert_eq!(at(&recording, 2, 2), [0x40, 0x40, 0x40, 0x40]);

        let dimmed = icon_variant(
            &icon,
            &TrayIconState {
                dimmed: true,
                ..Default::default()
            },
        );
        assert_eq!(at(&dimmed.0, 2, 2), [0x40, 0x40, 0x40, 24]);

        let attention = icon_variant(
            &icon,
            &TrayIconState {
                attention: true,
                dimmed: true,
                ..Default::default()
            },
        );
        // The dot sits top right at full strength, cut out of the faint icon.
        assert_eq!(at(&attention.0, 25, 6), [0xFF, 0x9F, 0x0A, 0xFF]);
        assert_eq!(at(&attention.0, 18, 6)[3], 0);
        assert_eq!(at(&attention.0, 2, 30), [0x40, 0x40, 0x40, 24]);

        // Recording wins: the dot and the dimming wait until it ends.
        let both = icon_variant(
            &icon,
            &TrayIconState {
                recording: true,
                attention: true,
                dimmed: true,
                timer: None,
            },
        );
        assert_eq!(both.0, recording);
    }

    #[test]
    fn the_tooltip_says_what_the_icon_shows() {
        let state = |recording, timer: Option<&str>, attention, dimmed| TrayIconState {
            recording,
            timer: timer.map(Into::into),
            attention,
            dimmed,
        };
        assert_eq!(
            tooltip_text("LokalBot", &state(true, Some("01:02"), true, true)),
            "LokalBot — Recording 01:02"
        );
        assert_eq!(
            tooltip_text("LokalBot", &state(false, Some("01:02"), false, false)),
            "LokalBot"
        );
        assert_eq!(
            tooltip_text("LokalBot", &state(false, None, true, true)),
            "LokalBot — Needs attention, Day memory is paused"
        );
    }

    #[test]
    fn the_icon_state_follows_the_menu_state() {
        let paused = TrayMenuState {
            block: TrayBlock::Paused {
                habit: AutoRecordMode::Ask,
            },
            tracking_enabled: true,
            day_memory_paused: true,
            more_attention: vec![TrayAttention::Approvals(1)],
            ..Default::default()
        };
        assert_eq!(
            paused.icon_state(),
            TrayIconState {
                recording: false,
                timer: None,
                dimmed: true,
                attention: true,
            }
        );
        // Paused without day memory on is not paused.
        let off = TrayMenuState {
            tracking_enabled: false,
            ..paused.clone()
        };
        assert!(!off.icon_state().dimmed);
        let recording = TrayMenuState {
            block: TrayBlock::Recording(TrayRecording {
                timer: "00:42".into(),
                ..Default::default()
            }),
            ..Default::default()
        };
        assert_eq!(
            recording.icon_state(),
            TrayIconState {
                recording: true,
                timer: Some("00:42".into()),
                dimmed: false,
                attention: false,
            }
        );
    }

    #[test]
    fn bad_icon_sizes_are_refused() {
        let result = Tray::new(
            (vec![0; 10], 4, 4),
            "LokalBot",
            Vec::new(),
            Vec::new(),
            Box::new(|_| {}),
        );
        assert!(result.is_err());
    }
}
