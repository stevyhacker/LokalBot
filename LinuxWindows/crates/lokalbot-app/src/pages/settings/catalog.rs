//! Searchable settings (`SettingDescriptor.swift`): title, category, extra
//! words to match, and the current value shown in results.

use lokalbot_core::Settings;
use lokalbot_core::settings::{AppTheme, TextSize};

use crate::state::SettingsCategory;

pub struct Entry {
    pub id: &'static str,
    pub title: &'static str,
    pub category: SettingsCategory,
    pub aliases: &'static str,
    pub value: fn(&Settings) -> String,
}

fn on_off(value: bool) -> String {
    if value {
        lokalbot_i18n::tr("On").into()
    } else {
        lokalbot_i18n::tr("Off").into()
    }
}

fn text(value: &str) -> String {
    if value.trim().is_empty() {
        lokalbot_i18n::tr("Not set").into()
    } else {
        value.chars().take(70).collect()
    }
}

/// The device list has no value of its own: it follows the switch above it.
fn details_or_off(settings: &Settings) -> String {
    if settings.companion_sharing_enabled {
        details(settings)
    } else {
        on_off(false)
    }
}

fn details(_: &Settings) -> String {
    lokalbot_i18n::tr("Open details").into()
}

pub fn theme_label(theme: AppTheme) -> &'static str {
    match theme {
        AppTheme::System => lokalbot_i18n::tr("Match System"),
        AppTheme::Light => lokalbot_i18n::tr("Light"),
        AppTheme::Dark => lokalbot_i18n::tr("Dark"),
    }
}

pub fn text_size_label(size: TextSize) -> &'static str {
    match size {
        TextSize::Small => lokalbot_i18n::tr("Small"),
        TextSize::Standard => lokalbot_i18n::tr("Default"),
        TextSize::Large => lokalbot_i18n::tr("Large"),
        TextSize::Larger => lokalbot_i18n::tr("Larger"),
        TextSize::Largest => lokalbot_i18n::tr("Largest"),
    }
}

use SettingsCategory::*;

pub const ENTRIES: &[Entry] = &[
    Entry {
        id: "settings.dreamingEnabled",
        title: "Review the day overnight",
        category: DayMemory,
        aliases: "dreamingEnabled dream morning brief projects goals pins overnight review",
        value: |s| on_off(s.dreaming_enabled),
    },
    Entry {
        id: "settings.dreamingHour",
        title: "Overnight review hour",
        category: DayMemory,
        aliases: "dream time overnight review after",
        value: |s| format!("{}:00", s.dreaming_hour),
    },
    Entry {
        id: "settings.dreamNow",
        title: "Review now",
        category: DayMemory,
        aliases: "dream now overnight review run morning brief",
        value: details,
    },
    Entry {
        id: "settings.clearWorkMemory",
        title: "Clear work memory",
        category: DayMemory,
        aliases: "delete overnight reviews projects goals patterns dream memory",
        value: details,
    },
    Entry {
        id: "settings.askMemoryEnabled",
        title: "Remember what I tell Ask",
        category: PersonalContext,
        aliases: "about you remember memory facts preferences goals principles values personal profile",
        value: |s| on_off(s.ask_memory_enabled),
    },
    Entry {
        id: "settings.personalLearningEnabled",
        title: "Learn about me from my meetings and work",
        category: PersonalContext,
        aliases: "learn about me automatic facts goals profile overnight typing coding agents work memory",
        value: |s| on_off(s.personal_learning_enabled),
    },
    Entry {
        id: "settings.personalLearningFromDictation",
        title: "Learn from my dictation",
        category: PersonalContext,
        aliases: "about you learn dictation dictated speech voice typing messages review",
        value: |s| on_off(s.personal_learning_from_dictation),
    },
    Entry {
        id: "settings.personalContextAccess",
        title: "What I shared about myself",
        category: PersonalContext,
        aliases: "external agents mcp cli personal context grant share items",
        value: details,
    },
    Entry {
        id: "settings.appLanguage",
        title: "App language",
        category: General,
        aliases: "language locale translation interface follow system",
        value: |s| lokalbot_i18n::picker_label(&s.app_language).into(),
    },
    Entry {
        id: "settings.launchAtLogin",
        title: "Launch LokalBot at login",
        category: General,
        aliases: "startup start automatically boot autostart",
        value: |s| on_off(s.launch_at_login),
    },
    Entry {
        id: "settings.runInTray",
        title: "Keep LokalBot running in the system tray",
        category: General,
        aliases: "tray background close window menu bar",
        value: |s| on_off(s.run_in_tray),
    },
    Entry {
        id: "settings.appTheme",
        title: "Theme",
        category: General,
        aliases: "appearance dark light mode",
        value: |s| theme_label(s.app_theme).into(),
    },
    Entry {
        id: "settings.textSize",
        title: "Text size",
        category: General,
        aliases: "font scale bigger smaller zoom",
        value: |s| text_size_label(s.text_size).into(),
    },
    Entry {
        id: "settings.quickRecallEnabled",
        title: "Enable the system-wide Ask shortcut",
        category: General,
        aliases: "quick recall hotkey global search",
        value: |s| on_off(s.quick_recall_enabled),
    },
    Entry {
        id: "settings.quickRecallShortcut",
        title: "Ask shortcut",
        category: General,
        aliases: "quick recall hotkey keyboard",
        value: |s| s.quick_recall_shortcut.clone(),
    },
    Entry {
        id: "settings.selectionActionsEnabled",
        title: "Enable the selection actions shortcut",
        category: General,
        aliases: "selected text rewrite translate summarize reply grammar improve shorten",
        value: |s| on_off(s.selection_actions_enabled),
    },
    Entry {
        id: "settings.selectionActionsShortcut",
        title: "Selection actions shortcut",
        category: General,
        aliases: "selected text rewrite hotkey keyboard",
        value: |s| s.selection_actions_shortcut.clone(),
    },
    Entry {
        id: "settings.checkForUpdates",
        title: "Check for updates automatically",
        category: General,
        aliases: "update updates upgrade automatic daily release github",
        value: |s| on_off(s.check_for_updates),
    },
    Entry {
        id: "settings.currentVersion",
        title: "Current version",
        category: General,
        aliases: "version about release update updates upgrade check install relaunch",
        value: |_| env!("CARGO_PKG_VERSION").into(),
    },
    Entry {
        id: "settings.autoRecordMode",
        title: "When a meeting is detected",
        category: Meetings,
        aliases: "auto record detect notification consent",
        value: |s| lokalbot_i18n::tr(s.auto_record_mode.label()).into(),
    },
    Entry {
        id: "settings.stopDebounceSeconds",
        title: "Wait before stopping",
        category: Meetings,
        aliases: "debounce stop delay",
        value: |s| {
            lokalbot_i18n::format(
                "{0} s after audio stops",
                &[("0", format!("{}", s.stop_debounce_seconds.round()))],
            )
        },
    },
    Entry {
        id: "settings.recordSystemAudio",
        title: "Record system audio",
        category: Meetings,
        aliases: "speakers other side loopback",
        value: |s| on_off(s.record_system_audio),
    },
    Entry {
        id: "settings.microphoneDevice",
        title: "Microphone",
        category: Meetings,
        aliases: "input device mic",
        value: |s| {
            if s.microphone_device.is_empty() {
                lokalbot_i18n::tr("System default").into()
            } else {
                s.microphone_device.clone()
            }
        },
    },
    Entry {
        id: "settings.calendarDetectionEnabled",
        title: "Use calendar to improve detection",
        category: Meetings,
        aliases: "calendar ical caldav google outlook evolution gnome schedule",
        value: |s| on_off(s.calendar_detection_enabled),
    },
    Entry {
        id: "settings.calendarLinks",
        title: "Calendar links",
        category: Meetings,
        aliases: "calendar ical caldav webcal feed google outlook link",
        value: details,
    },
    Entry {
        id: "settings.calendarMyEmailAddresses",
        title: "My email addresses",
        category: Meetings,
        aliases: "calendar email address attendee declined",
        value: |s| text(&s.calendar_my_email_addresses),
    },
    Entry {
        id: "settings.useCalendarTitles",
        title: "Use calendar titles for recordings",
        category: Meetings,
        aliases: "calendar title name recording",
        value: |s| on_off(s.use_calendar_titles),
    },
    Entry {
        id: "settings.requireCalendarForBrowser",
        title: "Require a calendar match for browser auto-recording",
        category: Meetings,
        aliases: "calendar browser google meet strict",
        value: |s| on_off(s.require_calendar_for_browser),
    },
    Entry {
        id: "settings.useCalendarAgenda",
        title: "Use invitation agendas",
        category: Meetings,
        aliases: "calendar agenda invitation notes",
        value: |s| on_off(s.use_calendar_agenda),
    },
    Entry {
        id: "settings.autoTranscribe",
        title: "Transcribe automatically after each meeting",
        category: Meetings,
        aliases: "transcription processing",
        value: |s| on_off(s.auto_transcribe),
    },
    Entry {
        id: "settings.autoSummarize",
        title: "Summarize automatically after transcription",
        category: Meetings,
        aliases: "summary notes processing",
        value: |s| on_off(s.auto_summarize),
    },
    Entry {
        id: "settings.noteTemplate",
        title: "Notes template",
        category: Meetings,
        aliases: "summary lecture study podcast",
        value: |s| lokalbot_i18n::tr(s.note_template.label()).into(),
    },
    Entry {
        id: "settings.summaryLanguage",
        title: "Notes language",
        category: Meetings,
        aliases: "summary translate language",
        value: |s| super::meetings::summary_language_label(&s.summary_language),
    },
    Entry {
        id: "settings.meetingNotesUseCalendarContext",
        title: "Give notes the calendar title and invited names",
        category: Meetings,
        aliases: "calendar notes context attendees",
        value: |s| on_off(s.meeting_notes_use_calendar_context),
    },
    Entry {
        id: "settings.multiSpeakerDiarization",
        title: "Separate voices by speaker",
        category: Meetings,
        aliases: "diarization speakers",
        value: |s| on_off(s.multi_speaker_diarization),
    },
    Entry {
        id: "settings.microphoneIsUser",
        title: "My microphone is me",
        category: Meetings,
        aliases: "speaker you owner",
        value: |s| on_off(s.microphone_is_user),
    },
    Entry {
        id: "settings.echoCancellation",
        title: "Remove the other side from your microphone track",
        category: Meetings,
        aliases: "echo speakers bleed cancellation",
        value: |s| on_off(s.echo_cancellation),
    },
    Entry {
        id: "settings.meetingNotesUseScreenTitles",
        title: "Give notes the titles of documents on screen",
        category: Meetings,
        aliases: "screen titles context notes",
        value: |s| on_off(s.meeting_notes_use_screen_titles),
    },
    Entry {
        id: "settings.meetingVisualContextEnabled",
        title: "Capture low-frequency visual context during meetings",
        category: Meetings,
        aliases: "screenshots screen recording frames",
        value: |s| on_off(s.meeting_visual_context_enabled),
    },
    Entry {
        id: "settings.suggestActionCompletion",
        title: "Suggest actions that look done",
        category: Meetings,
        aliases: "looks done completion hint screen",
        value: |s| on_off(s.suggest_action_completion),
    },
    Entry {
        id: "settings.rememberSpeakers",
        title: "Remembered people",
        category: Meetings,
        aliases: "voice profile speaker name forget recognize",
        value: details,
    },
    Entry {
        id: "settings.trackingEnabled",
        title: "Track app & window activity",
        category: DayMemory,
        aliases: "activity timeline tracking",
        value: |s| on_off(s.tracking_enabled),
    },
    Entry {
        id: "settings.screenContextCaptureMode",
        title: "Screen context",
        category: DayMemory,
        aliases: "screenshots ocr text capture visual images",
        value: |s| lokalbot_i18n::tr(s.screen_context_capture_mode.label()).into(),
    },
    Entry {
        id: "settings.screenTextRecognition",
        title: "Screen text recognition",
        category: DayMemory,
        aliases: "ocr model download screenshots text tesseract language script",
        value: details,
    },
    Entry {
        id: "settings.screenshotIntervalMinutes",
        title: "Idle fallback",
        category: DayMemory,
        aliases: "screen capture interval minutes screenshots",
        value: |s| {
            lokalbot_i18n::format(
                "at least every {0} min",
                &[("0", format!("{}", s.screenshot_interval_minutes.round()))],
            )
        },
    },
    Entry {
        id: "settings.codingAgentEvidenceEnabled",
        title: "Read coding agent sessions",
        category: DayMemory,
        aliases: "claude code codex agent transcripts sessions digest pull requests commits",
        value: |s| on_off(!s.enabled_coding_agents().is_empty()),
    },
    Entry {
        id: "settings.codingAgentExcludedFolders",
        title: "Never read sessions in these folders",
        category: DayMemory,
        aliases: "coding agent exclude folders projects repositories",
        value: |s| text(&s.coding_agent_excluded_folders),
    },
    Entry {
        id: "settings.dailyMemoryExportEnabled",
        title: "Export a daily memory note",
        category: DayMemory,
        aliases: "daily note obsidian logseq markdown journal export folder",
        value: |s| on_off(s.daily_memory_export_enabled),
    },
    Entry {
        id: "settings.dailyMemoryExportFormat",
        title: "Format",
        category: DayMemory,
        aliases: "daily note export obsidian logseq markdown",
        value: |s| {
            use lokalbot_core::settings::DailyMemoryExportFormat::*;
            match s.daily_memory_export_format {
                Markdown => "Markdown",
                Obsidian => "Obsidian",
                Logseq => "Logseq",
            }
            .to_string()
        },
    },
    Entry {
        id: "settings.memoryRoutinesEnabled",
        title: "Enable safe local routines",
        category: DayMemory,
        aliases: "routines stand-up standup weekly work log unfinished actions journal follow-up",
        value: |s| on_off(s.memory_routines_enabled),
    },
    Entry {
        id: "settings.memoryRoutineWeekday",
        title: "Weekly log day",
        category: DayMemory,
        aliases: "routines weekly work log weekday",
        value: details,
    },
    Entry {
        id: "settings.meetingNoteExportEnabled",
        title: "Export a note for each meeting",
        category: Meetings,
        aliases: "obsidian logseq markdown vault meeting notes export folder",
        value: |s| on_off(s.meeting_note_export_enabled),
    },
    Entry {
        id: "settings.meetingNoteExportFormat",
        title: "Format",
        category: Meetings,
        aliases: "obsidian logseq markdown meeting notes",
        value: |s| {
            use lokalbot_core::settings::ExportFormat::*;
            match s.meeting_note_export_format {
                Markdown => "Markdown",
                Obsidian => "Obsidian",
                Logseq => "Logseq",
            }
            .to_string()
        },
    },
    Entry {
        id: "settings.meetingNoteExportIncludesTranscript",
        title: "Include the transcript",
        category: Meetings,
        aliases: "meeting notes export transcript",
        value: |s| on_off(s.meeting_note_export_includes_transcript),
    },
    Entry {
        id: "settings.memoryHealth",
        title: "Memory health",
        category: Advanced,
        aliases: "diagnostics capture recovery status restart permissions",
        value: details,
    },
    Entry {
        id: "settings.runRetentionNow",
        title: "Run retention now",
        category: Advanced,
        aliases: "cleanup expire delete old screen context",
        value: details,
    },
    Entry {
        id: "settings.exportDiagnostics",
        title: "Export Diagnostics…",
        category: Advanced,
        aliases: "support health check logs report zip",
        value: details,
    },
    Entry {
        id: "settings.agentKind.screenMemory",
        title: "Let external agents read screen memory",
        category: DayMemory,
        aliases: "agents mcp cli access screen memory",
        value: |_| String::new(),
    },
    Entry {
        id: "settings.agentKind.files",
        title: "Let external agents search Files",
        category: Files,
        aliases: "agents mcp cli access files folders search",
        value: |_| String::new(),
    },
    Entry {
        id: "settings.askSources",
        title: "What Ask can search",
        category: General,
        aliases: "ask sources meetings day memory files personal context",
        value: |_| String::new(),
    },
    // Phones and tablets
    Entry {
        id: "settings.companionSharingEnabled",
        title: "Share with my phones and tablets",
        category: Devices,
        aliases: "phones tablets iphone ipad android devices companion mobile sync pair",
        value: |s| on_off(s.companion_sharing_enabled),
    },
    Entry {
        id: "settings.companionDevices",
        title: "Add a device",
        category: Devices,
        aliases: "pair qr code scan phone tablet devices remove paired",
        value: |s| details_or_off(s),
    },
    Entry {
        id: "settings.companionShareMeetings",
        title: "Share meetings",
        category: Devices,
        aliases: "phone tablet devices summaries actions decisions",
        value: |s| on_off(s.companion_share_meetings),
    },
    Entry {
        id: "settings.companionShareTranscripts",
        title: "Share transcripts",
        category: Devices,
        aliases: "phone tablet devices transcript text speakers",
        value: |s| on_off(s.companion_share_transcripts),
    },
    Entry {
        id: "settings.companionShareDigests",
        title: "Share Day Digests",
        category: Devices,
        aliases: "phone tablet devices digest journal",
        value: |s| on_off(s.companion_share_digests),
    },
    Entry {
        id: "settings.companionShareTimeline",
        title: "Share the Timeline",
        category: Devices,
        aliases: "phone tablet devices timeline sessions apps",
        value: |s| on_off(s.companion_share_timeline),
    },
    Entry {
        id: "settings.companionShareWindowTitles",
        title: "Include window titles",
        category: Devices,
        aliases: "phone tablet devices timeline windows",
        value: |s| on_off(s.companion_share_window_titles),
    },
    Entry {
        id: "settings.companionSharePeople",
        title: "Share people",
        category: Devices,
        aliases: "phone tablet devices names open work",
        value: |s| on_off(s.companion_share_people),
    },
    Entry {
        id: "settings.companionShareProjects",
        title: "Share projects",
        category: Devices,
        aliases: "phone tablet devices tracked projects",
        value: |s| on_off(s.companion_share_projects),
    },
    Entry {
        id: "settings.companionHistory",
        title: "Shared history",
        category: Devices,
        aliases: "phone tablet devices days window limit older records",
        value: |s| {
            super::history_label(lokalbot_engine::companion::HistoryWindow::from_days(
                s.companion_history,
            ))
            .into()
        },
    },
    Entry {
        id: "settings.companionAnswersQuestions",
        title: "Answer questions from my devices",
        category: Devices,
        aliases: "phone tablet ask question think",
        value: |s| on_off(s.companion_answers_questions),
    },
    Entry {
        id: "settings.companionAcceptsRecordings",
        title: "Accept recordings from my devices",
        category: Devices,
        aliases: "phone tablet record recording audio upload",
        value: |s| on_off(s.companion_accepts_recordings),
    },
    Entry {
        id: "settings.companionPort",
        title: "Port",
        category: Devices,
        aliases: "phone tablet devices network listener tcp firewall",
        value: |s| s.companion_port.to_string(),
    },
    Entry {
        id: "settings.companionAdvertisesOnBonjour",
        title: "Advertise on the local network",
        category: Devices,
        aliases: "bonjour mdns discovery wi-fi phone tablet devices tailscale firewall",
        value: |s| on_off(s.companion_advertises_on_bonjour),
    },
    Entry {
        id: "settings.retentionCleanup",
        title: "Review expired context…",
        category: Privacy,
        aliases: "cleanup retention expired delete",
        value: details,
    },
    Entry {
        id: "settings.dayDigestAutoEnabled",
        title: "Generate the day digest automatically",
        category: DayMemory,
        aliases: "digest journal schedule",
        value: |s| on_off(s.day_digest_auto_enabled),
    },
    Entry {
        id: "settings.dayDigestCustomPrompt",
        title: "Digest instructions (optional)",
        category: DayMemory,
        aliases: "digest prompt instructions",
        value: |s| text(&s.day_digest_custom_prompt),
    },
    Entry {
        id: "settings.cotypingEnabled",
        title: "Enable autocomplete",
        category: Writing,
        aliases: "cotyping suggestions autocomplete typing ghost inline completion input method input source wayland fcitx ibus",
        value: |s| on_off(s.cotyping_enabled),
    },
    Entry {
        id: "settings.autocompletePreview",
        title: "Try the real autocomplete",
        category: Writing,
        aliases: "autocomplete practice preview rehearsal try test",
        value: details,
    },
    Entry {
        id: "settings.cotypingMaxWords",
        title: "Suggestion length",
        category: Writing,
        aliases: "autocomplete words length max words",
        value: |s| {
            lokalbot_i18n::format(
                "up to {0} words",
                &[("0", format!("{}", s.cotyping_max_words))],
            )
        },
    },
    Entry {
        id: "settings.cotypingMultiLine",
        title: "Allow multi-line suggestions",
        category: Writing,
        aliases: "autocomplete lines",
        value: |s| on_off(s.cotyping_multi_line),
    },
    Entry {
        id: "settings.cotypingDebounceMs",
        title: "Pause before suggesting",
        category: Writing,
        aliases: "autocomplete delay latency milliseconds debounce",
        value: |s| lokalbot_i18n::format("{0} ms", &[("0", format!("{}", s.cotyping_debounce_ms))]),
    },
    Entry {
        id: "settings.cotypingAcceptGranularity",
        title: "Each accept takes",
        category: Writing,
        aliases: "autocomplete accept tab word phrase",
        value: |s| super::writing::granularity_label(s.cotyping_accept_granularity).into(),
    },
    Entry {
        id: "settings.cotypingUseVisibleContext",
        title: "Use visible text above the field",
        category: Writing,
        aliases: "autocomplete screen context reply message email conversation",
        value: |s| on_off(s.cotyping_use_visible_context),
    },
    Entry {
        id: "settings.cotypingUseMeetingMemory",
        title: "Use meeting and work memory",
        category: Writing,
        aliases: "autocomplete context notes decisions projects people",
        value: |s| on_off(s.cotyping_use_meeting_memory),
    },
    Entry {
        id: "settings.cotypingAcceptKey",
        title: "Accept next",
        category: Writing,
        aliases: "autocomplete tab right arrow key shortcut",
        value: |s| super::writing::accept_key_label(s.cotyping_accept_key).into(),
    },
    Entry {
        id: "settings.cotypingFullAcceptKey",
        title: "Accept the rest",
        category: Writing,
        aliases: "autocomplete backtick right arrow whole suggestion key shortcut",
        value: |s| super::writing::full_accept_key_label(s.cotyping_full_accept_key).into(),
    },
    Entry {
        id: "settings.cotypingAutoAcceptTrailingPunctuation",
        title: "Accept punctuation with the word",
        category: Writing,
        aliases: "autocomplete tab full stop comma period",
        value: |s| on_off(s.cotyping_auto_accept_trailing_punctuation),
    },
    Entry {
        id: "settings.cotypingEscapeBehavior",
        title: "Escape on a suggestion",
        category: Writing,
        aliases: "autocomplete esc dismiss pause suggestion",
        value: |s| super::writing::escape_label(s.cotyping_escape_behavior).into(),
    },
    Entry {
        id: "settings.cotypingAddSpaceAfterAccept",
        title: "Add a space after accepting a word",
        category: Writing,
        aliases: "autocomplete spacing",
        value: |s| on_off(s.cotyping_add_space_after_accept),
    },
    Entry {
        id: "settings.cotypingSuggestInIntegratedTerminals",
        title: "Suggest in integrated terminals",
        category: Writing,
        aliases: "autocomplete vs code terminal xterm browser",
        value: |s| on_off(s.cotyping_suggest_in_integrated_terminals),
    },
    Entry {
        id: "settings.cotypingMatchHostStyle",
        title: "Match the app font and text color",
        category: Writing,
        aliases: "autocomplete ghost style color font",
        value: |s| on_off(s.cotyping_match_host_style),
    },
    Entry {
        id: "settings.cotypingAutocorrect",
        title: "Autocorrect the current word",
        category: Writing,
        aliases: "autocomplete spelling typo correction dictionary",
        value: |s| on_off(s.cotyping_autocorrect),
    },
    Entry {
        id: "settings.cotypingEmoji",
        title: "Emoji autocomplete",
        category: Writing,
        aliases: "autocomplete shortcode smiley",
        value: |s| on_off(s.cotyping_emoji),
    },
    Entry {
        id: "settings.cotypingMacros",
        title: "Macros",
        category: Writing,
        aliases: "autocomplete slash math date unit currency calculator",
        value: |s| on_off(s.cotyping_macros),
    },
    Entry {
        id: "settings.cotypingUseAppContext",
        title: "Use app and window context",
        category: Writing,
        aliases: "autocomplete window title",
        value: |s| on_off(s.cotyping_use_app_context),
    },
    Entry {
        id: "settings.cotypingUseClipboard",
        title: "Use clipboard as temporary context",
        category: Writing,
        aliases: "autocomplete copy paste",
        value: |s| on_off(s.cotyping_use_clipboard),
    },
    Entry {
        id: "settings.cotypingUseWindowText",
        title: "Use the focused window as context",
        category: Writing,
        aliases: "autocomplete window screen ocr text recognition whole screen conversation",
        value: |s| on_off(s.cotyping_use_window_text),
    },
    Entry {
        id: "settings.cotypingUseScreenMemory",
        title: "Use screen-derived work memory",
        category: Writing,
        aliases: "autocomplete saved context screen activity",
        value: |s| on_off(s.cotyping_use_screen_memory),
    },
    Entry {
        id: "settings.cotypingUseLocalLearning",
        title: "Learn locally from accepted completions",
        category: Writing,
        aliases: "autocomplete forget learned text examples",
        value: |s| on_off(s.cotyping_use_local_learning),
    },
    Entry {
        id: "settings.cotypingLearningExamplesInPrompt",
        title: "Learned examples per suggestion",
        category: Writing,
        aliases: "autocomplete learning examples prompt",
        value: |s| {
            s.cotyping_learning_examples_in_prompt
                .clamp(1, 5)
                .to_string()
        },
    },
    Entry {
        id: "settings.cotypingLanguages",
        title: "Languages",
        category: Writing,
        aliases: "autocomplete language spelling",
        value: |s| text(&s.cotyping_languages),
    },
    Entry {
        id: "settings.cotypingExtendedContext",
        title: "Notes for autocomplete",
        category: Writing,
        aliases: "glossary jargon context notes",
        value: |s| text(&s.cotyping_extended_context),
    },
    Entry {
        id: "settings.cotypingBackend",
        title: "Where autocomplete runs",
        category: Writing,
        aliases: "autocomplete server remote openrouter ollama llama-server model api key",
        value: |s| super::writing_server::backend_label(s.cotyping_backend).into(),
    },
    Entry {
        id: "settings.autocompleteStatistics",
        title: "Statistics",
        category: Writing,
        aliases: "autocomplete usage words accepted time saved measurements",
        value: details,
    },
    Entry {
        id: "settings.cotypingExcludedApps",
        title: "Never suggest in these apps",
        category: Writing,
        aliases: "exclude autocomplete applications exclusions",
        value: |s| {
            lokalbot_i18n::format(
                "{0} selected",
                &[("0", format!("{}", s.cotyping_excluded_app_list().len()))],
            )
        },
    },
    Entry {
        id: "settings.cotypingExcludedDomains",
        title: "Never suggest on these sites",
        category: Writing,
        aliases: "exclude autocomplete websites domains exclusions",
        value: |s| {
            lokalbot_i18n::format(
                "{0} selected",
                &[("0", format!("{}", s.cotyping_excluded_domain_list().len()))],
            )
        },
    },
    Entry {
        id: "settings.cotypingUserName",
        title: "Your name",
        category: Writing,
        aliases: "writing profile name compose",
        value: |s| text(&s.cotyping_user_name),
    },
    Entry {
        id: "settings.cotypingStyleNote",
        title: "Writing style",
        category: Writing,
        aliases: "writing profile tone compose",
        value: |s| text(&s.cotyping_style_note),
    },
    Entry {
        id: "settings.dictationEnabled",
        title: "Enable dictation shortcut",
        category: Dictation,
        aliases: "dictation voice typing speech",
        value: |s| on_off(s.dictation_enabled),
    },
    Entry {
        id: "settings.dictationShortcut",
        title: "Shortcut",
        category: Dictation,
        aliases: "dictation hotkey keyboard",
        value: |s| s.dictation_shortcut.clone(),
    },
    Entry {
        id: "settings.dictationTriggerMode",
        title: "Trigger",
        category: Dictation,
        aliases: "push to talk toggle hold",
        value: |s| lokalbot_i18n::tr(s.dictation_trigger_mode.label()).into(),
    },
    Entry {
        id: "settings.dictationIntent",
        title: "Intent",
        category: Dictation,
        aliases: "dictation transcribe compose rewrite draft reply",
        value: |s| match s.dictation_intent {
            lokalbot_core::settings::DictationIntent::Transcribe => {
                lokalbot_i18n::tr("Transcribe").into()
            }
            lokalbot_core::settings::DictationIntent::Compose => {
                lokalbot_i18n::tr("Compose").into()
            }
        },
    },
    Entry {
        id: "settings.dictationOutputMode",
        title: "After a shortcut recording",
        category: Dictation,
        aliases: "paste clipboard output",
        value: |s| lokalbot_i18n::tr(s.dictation_output_mode.label()).into(),
    },
    Entry {
        id: "settings.dictationShowOverlay",
        title: "Show floating dictation status",
        category: Dictation,
        aliases: "overlay hud",
        value: |s| on_off(s.dictation_show_overlay),
    },
    Entry {
        id: "settings.dictationPlaysStartSound",
        title: "Play a sound when the microphone is ready",
        category: Dictation,
        aliases: "start sound cue beep tone",
        value: |s| on_off(s.dictation_plays_start_sound),
    },
    Entry {
        id: "settings.dictationLivePreview",
        title: "Show live transcript",
        category: Dictation,
        aliases: "preview overlay words while speaking",
        value: |s| on_off(s.dictation_live_preview),
    },
    Entry {
        id: "settings.dictationRetainAudio",
        title: "Keep dictation audio files",
        category: Dictation,
        aliases: "save recordings wav retain",
        value: |s| on_off(s.dictation_retain_audio),
    },
    Entry {
        id: "settings.dictationTranscribeModel",
        title: "Transcribe model",
        category: Dictation,
        aliases: "speech asr model language transcription",
        value: |s| s.transcription_model.clone(),
    },
    Entry {
        id: "settings.dictationUseScreenContext",
        title: "Use the focused window as context",
        category: Dictation,
        aliases: "compose screen ocr window",
        value: |s| on_off(s.dictation_use_screen_context),
    },
    Entry {
        id: "settings.dictationUseVisibleContext",
        title: "Use visible text above the field",
        category: Dictation,
        aliases: "compose nearby messages labels accessibility",
        value: |s| on_off(s.dictation_use_visible_context),
    },
    Entry {
        id: "settings.dictationUseMeetingMemory",
        title: "Use meeting and work memory",
        category: Dictation,
        aliases: "compose saved facts grounding",
        value: |s| on_off(s.dictation_use_meeting_memory),
    },
    Entry {
        id: "settings.dictationUseScreenMemory",
        title: "Use screen-derived work memory",
        category: Dictation,
        aliases: "compose saved facts grounding",
        value: |s| on_off(s.dictation_use_screen_memory),
    },
    Entry {
        id: "settings.dictationCompositionBuiltInModelID",
        title: "Compose model",
        category: Dictation,
        aliases: "composition think model llm rewrite",
        value: |s| {
            lokalbot_ai::catalog::entry(&s.dictation_composition_built_in_model_id)
                .map(|entry| entry.display_name.to_string())
                .unwrap_or_else(|| lokalbot_i18n::tr("Same as Think").to_string())
        },
    },
    Entry {
        id: "settings.models",
        title: "Models",
        category: Models,
        aliases: "transcribe think autocomplete model llm whisper qwen download",
        value: details,
    },
    Entry {
        id: "settings.llamaBackend",
        title: "llama.cpp",
        category: Models,
        aliases: "nvidia gpu acceleration vulkan cpu llama runtime",
        value: |s| s.llama_backend.clone(),
    },
    Entry {
        id: "settings.cotypingBuiltInModelID",
        title: "Autocomplete model",
        category: Models,
        aliases: "autocomplete writing suggestions weights lfm",
        value: |s| super::models::model_name(&s.cotyping_built_in_model_id),
    },
    Entry {
        id: "settings.summarizerBackend",
        title: "Connections",
        category: Models,
        aliases: "ollama openai server remote api key url chatgpt claude plan subscription anthropic openrouter",
        value: |s| lokalbot_i18n::tr(s.summarizer_backend.label()).into(),
    },
    Entry {
        id: "settings.semanticSearchEnabled",
        title: "Search by meaning",
        category: Models,
        aliases: "semantic embeddings",
        value: |s| on_off(s.semantic_search_enabled),
    },
    Entry {
        id: "settings.modelDownloadSource",
        title: "Download models from",
        category: Models,
        aliases: "model download source mirror hf-mirror modelscope hugging face china mainland blocked 下载 模型下载 下载源 镜像 魔搭 中国 大陆",
        value: |s| match s.model_download_source {
            lokalbot_core::settings::ModelDownloadSource::HuggingFace => "Hugging Face".into(),
            lokalbot_core::settings::ModelDownloadSource::HfMirror => {
                lokalbot_i18n::tr("HF-Mirror (hf-mirror.com)").into()
            }
            lokalbot_core::settings::ModelDownloadSource::ModelScope => {
                lokalbot_i18n::tr("ModelScope (modelscope.cn)").into()
            }
        },
    },
    Entry {
        id: "settings.transcriptionModel",
        title: "Transcribe model",
        category: Models,
        aliases: "ASR speech whisper qwen",
        value: |s| super::model_options::transcription_name(s),
    },
    Entry {
        id: "settings.transcriptionLanguage",
        title: "Transcription language",
        category: Models,
        aliases: "ASR spoken language",
        value: |s| {
            lokalbot_i18n::tr(lokalbot_speech::language::language_name(
                &s.transcription_language,
            ))
            .into()
        },
    },
    Entry {
        id: "settings.transcriptionPrompt",
        title: "Transcription vocabulary",
        category: Models,
        aliases: "names acronyms spelling",
        value: |s| text(&s.transcription_prompt),
    },
    Entry {
        id: "settings.autoTranscriptionVocabulary",
        title: "Add known names to transcription",
        category: Models,
        aliases: "names attendees calendar vocabulary spelling",
        value: |s| on_off(s.auto_transcription_vocabulary),
    },
    Entry {
        id: "settings.remoteTranscription",
        title: "Transcription server",
        category: Models,
        aliases: "remote speech to text openai groq openrouter whisper.cpp audio server",
        value: |s| text(&s.remote_transcription_base_url),
    },
    Entry {
        id: "settings.modelChecks",
        title: "Check model setup",
        category: Models,
        aliases: "test model check connection sample",
        value: details,
    },
    Entry {
        id: "settings.modelBrowse",
        title: "Add a model from Hugging Face",
        category: Models,
        aliases: "browse hugging face custom gguf import search model",
        value: details,
    },
    Entry {
        id: "settings.thinkReasoningLevel",
        title: "Think reasoning level",
        category: Models,
        aliases: "reasoning effort thinking budget think off low medium high",
        value: |s| {
            lokalbot_i18n::tr(lokalbot_agent::session::reasoning_name(
                s.think_reasoning_level,
            ))
            .into()
        },
    },
    Entry {
        id: "settings.speechVoice",
        title: "Read-aloud voice",
        category: Models,
        aliases: "read aloud speech voice kokoro text to speech tts",
        value: |s| {
            lokalbot_speech::kokoro::voice(&s.speech_voice)
                .display_name
                .into()
        },
    },
    Entry {
        id: "settings.modelStorage",
        title: "Model Storage",
        category: Models,
        aliases: "disk space remove delete unused downloaded models folder",
        value: details,
    },
    Entry {
        id: "settings.libraryLocation",
        title: "Library location",
        category: Privacy,
        aliases: "storage folder data path",
        value: details,
    },
    Entry {
        id: "settings.retentionDays",
        title: "Keep screen context",
        category: Privacy,
        aliases: "retention delete days cleanup window titles history activity screenshots",
        value: |s| lokalbot_i18n::format("{0} days", &[("0", format!("{}", s.retention_days))]),
    },
    Entry {
        id: "settings.keepOCRTextForever",
        title: "Keep screen text forever",
        category: Privacy,
        aliases: "retention ocr text",
        value: |s| on_off(s.keep_ocr_text_forever),
    },
    Entry {
        id: "settings.fileSearchEnabled",
        title: "Search my files",
        category: Files,
        aliases: "files folders documents pdf photos pictures screenshots search by meaning digup",
        value: |s| on_off(s.file_search_enabled),
    },
    Entry {
        id: "settings.fileSearchFolders",
        title: "Folders to search",
        category: Files,
        aliases: "files folders documents downloads desktop pictures add folder",
        value: |s| s.file_search_folders.len().to_string(),
    },
    Entry {
        id: "settings.fileSearchIncludesMedia",
        title: "Include recordings and video",
        category: Files,
        aliases: "files audio video recordings podcasts movies sound moments",
        value: |s| on_off(s.file_search_includes_media),
    },
    Entry {
        id: "settings.fileSearchReadsOnBattery",
        title: "Read big folders on battery",
        category: Files,
        aliases: "files battery charger power plugged in first pass indexing",
        value: |s| on_off(s.file_search_reads_on_battery),
    },
    Entry {
        id: "settings.filesAccess",
        title: "External file access",
        category: Privacy,
        aliases: "mcp agent files folders documents search_files search-files",
        value: details,
    },
    Entry {
        id: "settings.agentAccess",
        title: "Allow external agents to read your meeting library",
        category: Privacy,
        aliases: "mcp claude cursor cli agents",
        value: details,
    },
    Entry {
        id: "settings.screenMemoryAccess",
        title: "Allow external agents to read screen memory",
        category: Privacy,
        aliases: "mcp agents screen activity timeline",
        value: details,
    },
    Entry {
        id: "settings.excludedApps",
        title: "Never capture these apps",
        category: Privacy,
        aliases: "exclusions private password activity",
        value: |s| {
            lokalbot_i18n::format(
                "{0} selected",
                &[("0", format!("{}", s.excluded_app_list().len()))],
            )
        },
    },
    Entry {
        id: "settings.excludedScreenDomains",
        title: "Never capture these sites",
        category: Privacy,
        aliases: "exclusions domains websites private",
        value: |s| {
            lokalbot_i18n::format(
                "{0} selected",
                &[("0", format!("{}", s.excluded_domain_list().len()))],
            )
        },
    },
    Entry {
        id: "settings.setupAgain",
        title: "Set Up LokalBot Again",
        category: Advanced,
        aliases: "setup onboarding welcome assistant wizard first run",
        value: details,
    },
    Entry {
        id: "settings.agentCLI",
        title: "Agent CLI",
        category: Advanced,
        aliases: "cli terminal claude codex install path mcp",
        value: details,
    },
    Entry {
        id: "settings.resourceMonitor",
        title: "Resource Monitor",
        category: Advanced,
        aliases: "cpu memory ram activity performance loaded models usage",
        value: details,
    },
    Entry {
        id: "settings.logs",
        title: "Logs",
        category: Advanced,
        aliases: "diagnostics logs folder support",
        value: details,
    },
    Entry {
        id: "settings.version",
        title: "Version",
        category: Advanced,
        aliases: "build about version",
        value: |_| env!("CARGO_PKG_VERSION").into(),
    },
    Entry {
        id: "settings.settingsControlAccess",
        title: "External settings access",
        category: Privacy,
        aliases: "cli terminal agent configure settings control change",
        value: |_| lokalbot_i18n::tr("Open details").into(),
    },
    Entry {
        id: "settings.permissions",
        title: "Permissions",
        category: Privacy,
        aliases: "microphone screen recording accessibility input monitoring shortcuts calendar access",
        value: details,
    },
    Entry {
        id: "settings.screenMemoryScope",
        title: "Granted history",
        category: Privacy,
        aliases: "screen memory scope agent mcp today week retained external",
        value: |_| lokalbot_i18n::tr("Open details").into(),
    },
    Entry {
        id: "settings.generationBudgetPreset",
        title: "Think processing budget",
        category: Models,
        aliases: "generation budget limit tokens time requests unlimited conservative generous summary meeting notes",
        value: details,
    },
    Entry {
        id: "settings.builtInModelID",
        title: "Think model",
        category: Models,
        aliases: "built-in gguf llama local model",
        value: |s| s.built_in_model_id.clone(),
    },
    Entry {
        id: "settings.openAIBaseURL",
        title: "OpenAI-compatible server URL",
        category: Models,
        aliases: "remote processing endpoint host base URL",
        value: |s| text(&s.openai_base_url),
    },
    Entry {
        id: "settings.openAIModel",
        title: "OpenAI-compatible model",
        category: Models,
        aliases: "remote inference model name",
        value: |s| text(&s.openai_model),
    },
    Entry {
        id: "settings.ollamaBaseURL",
        title: "Ollama server URL",
        category: Models,
        aliases: "local remote endpoint host",
        value: |s| text(&s.ollama_base_url),
    },
    Entry {
        id: "settings.speechSpeed",
        title: "Read-aloud speed",
        category: Models,
        aliases: "kokoro tts rate read aloud voice",
        value: |s| format!("{:.1}×", s.speech_speed),
    },
    Entry {
        id: "settings.customModels",
        title: "Imported Think models",
        category: Models,
        aliases: "hugging face gguf import custom model file",
        value: details,
    },
    Entry {
        id: "settings.unusedModels",
        title: "Unused models",
        category: Models,
        aliases: "storage disk delete remove downloaded",
        value: details,
    },
    Entry {
        id: "settings.dayDigestHour",
        title: "Day digest hour",
        category: DayMemory,
        aliases: "journal daily summary time",
        value: |s| s.day_digest_hour.to_string(),
    },
    Entry {
        id: "settings.dailyMemoryExportFolder",
        title: "Daily memory export folder",
        category: DayMemory,
        aliases: "markdown obsidian logseq export folder",
        value: |s| text(&s.daily_memory_export_folder),
    },
    Entry {
        id: "settings.dailyMemoryExportHour",
        title: "Daily memory export hour",
        category: DayMemory,
        aliases: "markdown obsidian logseq export time",
        value: |s| s.daily_memory_export_hour.to_string(),
    },
    Entry {
        id: "settings.meetingNoteExportFolder",
        title: "Meeting note export folder",
        category: DayMemory,
        aliases: "obsidian logseq markdown vault meeting notes export folder",
        value: |s| text(&s.meeting_note_export_folder),
    },
    Entry {
        id: "settings.memoryRoutineFolder",
        title: "Routine folder",
        category: DayMemory,
        aliases: "routines standup work log journal folder",
        value: |s| text(&s.memory_routine_folder),
    },
    Entry {
        id: "settings.memoryRoutineHour",
        title: "Routine hour",
        category: DayMemory,
        aliases: "routines standup time",
        value: |s| s.memory_routine_hour.to_string(),
    },
    Entry {
        id: "settings.codingAgentReadsClaudeCode",
        title: "Read Claude Code sessions",
        category: DayMemory,
        aliases: "coding agent claude code sessions",
        value: |s| on_off(s.coding_agent_reads_claude_code),
    },
    Entry {
        id: "settings.codingAgentReadsCodex",
        title: "Read Codex sessions",
        category: DayMemory,
        aliases: "coding agent codex sessions",
        value: |s| on_off(s.coding_agent_reads_codex),
    },
    Entry {
        id: "settings.dictationMicrophoneID",
        title: "Microphone",
        category: Dictation,
        aliases: "dictation input device headset bluetooth built-in mic",
        value: |s| text(&s.dictation_microphone_id),
    },
    Entry {
        id: "settings.dictationWritingProfile",
        title: "Writing profile",
        category: Dictation,
        aliases: "dictation compose tone name style terminology",
        value: details,
    },
    Entry {
        id: "settings.dictationRecent",
        title: "Recent dictations",
        category: Dictation,
        aliases: "copy history again last",
        value: details,
    },
    Entry {
        id: "settings.calendarEvolutionEnabled",
        title: "Read calendars from Evolution Data Server",
        category: Meetings,
        aliases: "gnome online accounts evolution calendar linux",
        value: |s| on_off(s.calendar_evolution_enabled),
    },
    Entry {
        id: "settings.cotypingForgetLearned",
        title: "Forget learned completions",
        category: Writing,
        aliases: "autocomplete local learning delete clear",
        value: details,
    },
    Entry {
        id: "settings.githubStar",
        title: "Star on GitHub",
        category: General,
        aliases: "open source repository star",
        value: details,
    },
];

/// Entries whose title, aliases or category contain every query word.
pub fn search(query: &str) -> Vec<&'static Entry> {
    search_in(query, lokalbot_i18n::current().code)
}

fn search_in(query: &str, locale: &str) -> Vec<&'static Entry> {
    let normalized = query.trim().to_lowercase();
    if normalized.is_empty() {
        return Vec::new();
    }
    let mut found: Vec<&'static Entry> = ENTRIES
        .iter()
        .filter(|entry| {
            let languages = if entry.id == "settings.appLanguage" {
                lokalbot_i18n::LANGUAGES
                    .iter()
                    .map(|l| format!("{} {}", l.name, l.english_name))
                    .collect::<Vec<_>>()
                    .join(" ")
            } else {
                String::new()
            };
            lokalbot_core::text::settings_search_matches(
                query,
                &[
                    entry.title,
                    entry.aliases,
                    entry.id.trim_start_matches("settings."),
                    category_key(entry.category),
                    lokalbot_i18n::translate(locale, category_key(entry.category)),
                    lokalbot_i18n::translate(locale, entry.title),
                    &languages,
                ],
            )
        })
        .collect();
    // Exact titles, then titles that start with the query, then the rest.
    let score = |entry: &Entry| {
        let title = entry.title.to_lowercase();
        if title == normalized {
            3
        } else if title.starts_with(&normalized) {
            2
        } else {
            1
        }
    };
    found.sort_by(|a, b| {
        score(b)
            .cmp(&score(a))
            .then_with(|| a.title.to_lowercase().cmp(&b.title.to_lowercase()))
    });
    found
}

/// The control a setting's search result opens: the setting itself, or the
/// switch it shows behind while that is off (`SettingDescriptor.focusTarget`).
pub fn focus_target<'a>(id: &'a str, settings: &Settings) -> &'a str {
    use lokalbot_core::ScreenContextMode;
    use lokalbot_core::settings::SummarizerBackend;
    let key = id.trim_start_matches("settings.");
    if !settings.calendar_detection_enabled
        && matches!(
            key,
            "useCalendarTitles"
                | "requireCalendarForBrowser"
                | "useCalendarAgenda"
                | "calendarLinks"
                | "calendarMyEmailAddresses"
                | "calendarEvolutionEnabled"
        )
    {
        return "settings.calendarDetectionEnabled";
    }
    if !settings.daily_memory_export_enabled
        && matches!(
            key,
            "dailyMemoryExportFormat" | "dailyMemoryExportFolder" | "dailyMemoryExportHour"
        )
    {
        return "settings.dailyMemoryExportEnabled";
    }
    if !settings.meeting_note_export_enabled
        && matches!(
            key,
            "meetingNoteExportFormat"
                | "meetingNoteExportFolder"
                | "meetingNoteExportIncludesTranscript"
        )
    {
        return "settings.meetingNoteExportEnabled";
    }
    if !settings.memory_routines_enabled
        && matches!(
            key,
            "memoryRoutineWeekday" | "memoryRoutineFolder" | "memoryRoutineHour"
        )
    {
        return "settings.memoryRoutinesEnabled";
    }
    if matches!(key, "openAIBaseURL" | "openAIModel")
        && settings.summarizer_backend != SummarizerBackend::OpenAICompatible
    {
        return "settings.summarizerBackend";
    }
    if key == "ollamaBaseURL" && settings.summarizer_backend != SummarizerBackend::Ollama {
        return "settings.summarizerBackend";
    }
    // The level sits on Think's row, the model it applies to.
    if key == "thinkReasoningLevel" {
        return "settings.builtInModelID";
    }
    if key == "screenshotIntervalMinutes"
        && settings.screen_context_capture_mode == ScreenContextMode::ActivityOnly
    {
        return "settings.screenContextCaptureMode";
    }
    // Phones & tablets shows its other controls only while sharing is on.
    if !settings.companion_sharing_enabled
        && key.starts_with("companion")
        && key != "companionSharingEnabled"
    {
        return "settings.companionSharingEnabled";
    }
    id
}

/// Said under a result that opens another control.
pub fn prerequisite(id: &str, settings: &Settings) -> Option<&'static str> {
    (focus_target(id, settings) != id).then(|| {
        lokalbot_i18n::tr("Enable the parent feature to edit this setting. Opens that control.")
    })
}

pub fn category_title(category: SettingsCategory) -> &'static str {
    lokalbot_i18n::tr(category_key(category))
}

pub fn category_key(category: SettingsCategory) -> &'static str {
    match category {
        Overview => "Overview",
        General => "General",
        Meetings => "Meetings",
        DayMemory => "Day Memory",
        PersonalContext => "Personal Context",
        Writing => "Writing",
        Dictation => "Dictation",
        Files => "Files",
        Models => "Models",
        Devices => "Phones & tablets",
        Privacy => "Privacy & Data",
        Advanced => "Advanced",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_names_and_localized_titles_are_searchable() {
        for language in lokalbot_i18n::LANGUAGES {
            assert!(
                search_in(language.name, "en")
                    .iter()
                    .any(|e| e.id == "settings.appLanguage"),
                "{}",
                language.name
            );
        }
        for (query, locale) in [("Sprache", "de"), ("界面语言", "zh-Hans")] {
            assert!(
                search_in(query, locale)
                    .iter()
                    .any(|e| e.id == "settings.appLanguage")
            );
        }
    }

    #[test]
    fn phones_and_tablets_can_be_found() {
        let phones: Vec<&str> = search("phones").iter().map(|e| e.id).collect();
        assert!(phones.contains(&"settings.companionSharingEnabled"));
        assert!(
            search("pair qr")
                .iter()
                .any(|e| e.id == "settings.companionDevices")
        );
        assert!(
            search("bonjour")
                .iter()
                .any(|e| e.id == "settings.companionAdvertisesOnBonjour")
        );
        assert!(
            search("firewall")
                .iter()
                .any(|e| e.id == "settings.companionPort")
        );
        for entry in ENTRIES
            .iter()
            .filter(|e| e.id.starts_with("settings.companion"))
        {
            assert_eq!(entry.category, Devices, "{}", entry.id);
        }
    }

    #[test]
    fn search_matches_every_word() {
        let hits: Vec<&str> = search("dark").iter().map(|e| e.id).collect();
        assert_eq!(hits, ["settings.appTheme"]);
        assert!(
            search("shortcut ask")
                .iter()
                .any(|e| e.id == "settings.quickRecallShortcut")
        );
        assert!(search("   ").is_empty());
        let ids: std::collections::HashSet<_> = ENTRIES.iter().map(|e| e.id).collect();
        assert_eq!(ids.len(), ENTRIES.len(), "ids are unique");
    }

    #[test]
    fn features_missing_on_this_platform_are_not_offered() {
        assert!(search("chime").is_empty());
        // What was added lately can be found.
        assert!(
            search("sessions")
                .iter()
                .any(|e| e.id == "settings.codingAgentEvidenceEnabled")
        );
        assert!(
            search("obsidian")
                .iter()
                .any(|e| e.id == "settings.meetingNoteExportEnabled")
        );
        let autocomplete: Vec<&str> = search("autocomplete").iter().map(|e| e.id).collect();
        assert!(autocomplete.contains(&"settings.cotypingEnabled"));
        assert!(autocomplete.contains(&"settings.cotypingBuiltInModelID"));
        assert!(!autocomplete.contains(&"settings.autocompleteAvailability"));
        // Updates check, download and install here too.
        let updates: Vec<&str> = search("updates").iter().map(|e| e.id).collect();
        assert_eq!(
            updates,
            ["settings.checkForUpdates", "settings.currentVersion"]
        );
    }

    #[test]
    fn punctuation_and_diacritics_fold_and_exact_titles_lead() {
        // "auto-record" used to miss.
        assert!(
            search("auto-record")
                .iter()
                .any(|e| e.id == "settings.autoRecordMode")
        );
        assert_eq!(search("Theme")[0].id, "settings.appTheme");
        // "Thème" finds it too.
        assert!(search("Thème").iter().any(|e| e.id == "settings.appTheme"));
        let budget = search("think processing budget");
        assert_eq!(budget[0].id, "settings.generationBudgetPreset");
    }

    #[test]
    fn settings_that_could_not_be_found_can_be_now() {
        for (query, id) in [
            ("budget", "settings.generationBudgetPreset"),
            ("transcribe model", "settings.transcriptionModel"),
            ("built-in think", "settings.builtInModelID"),
            ("digest hour", "settings.dayDigestHour"),
            ("microphone", "settings.dictationMicrophoneID"),
            ("granted history", "settings.screenMemoryScope"),
            ("evolution", "settings.calendarEvolutionEnabled"),
            ("change settings terminal", "settings.settingsControlAccess"),
            ("permissions", "settings.permissions"),
        ] {
            assert!(search(query).iter().any(|e| e.id == id), "{query}");
        }
    }

    #[test]
    fn a_setting_behind_a_switch_opens_the_switch() {
        let off = Settings::default();
        assert_eq!(
            focus_target("settings.useCalendarTitles", &off),
            "settings.calendarDetectionEnabled"
        );
        assert_eq!(
            focus_target("settings.meetingNoteExportFormat", &off),
            "settings.meetingNoteExportEnabled"
        );
        assert_eq!(
            focus_target("settings.openAIBaseURL", &off),
            "settings.summarizerBackend"
        );
        assert_eq!(
            focus_target("settings.thinkReasoningLevel", &off),
            "settings.builtInModelID"
        );
        assert_eq!(
            focus_target("settings.screenshotIntervalMinutes", &off),
            "settings.screenContextCaptureMode"
        );
        assert_eq!(
            focus_target("settings.companionPort", &off),
            "settings.companionSharingEnabled"
        );
        assert!(prerequisite("settings.useCalendarTitles", &off).is_some());
        let on = Settings {
            calendar_detection_enabled: true,
            ..Default::default()
        };
        assert_eq!(
            focus_target("settings.useCalendarTitles", &on),
            "settings.useCalendarTitles"
        );
        assert!(prerequisite("settings.useCalendarTitles", &on).is_none());
        assert_eq!(focus_target("settings.appTheme", &off), "settings.appTheme");
    }

    #[test]
    fn screen_context_settings_are_searchable() {
        let ocr: Vec<&str> = search("ocr").iter().map(|e| e.id).collect();
        assert!(ocr.contains(&"settings.screenContextCaptureMode"));
        assert!(ocr.contains(&"settings.screenTextRecognition"));
        assert!(ocr.contains(&"settings.keepOCRTextForever"));
        assert!(!search("screenshot").is_empty());
    }
}
