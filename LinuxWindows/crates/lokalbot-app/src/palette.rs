//! The commands the Ctrl+K palette and Quick Recall can run
//! (`PaletteCommands.swift`), computed live from app state so titles follow
//! recording and dictation status.

use gpui_kit::{App, AppContext as _};
use lokalbot_engine::{Command, DictationCommand};
use uuid::Uuid;

use crate::state::{AgentRequest, AppData, AskRequest, DictationHud, Section, SettingsCategory};
use crate::ui::Ico;

/// Where a command's result appears. Workspace commands show something in the
/// main window. Background commands (recording, dictation) act in place.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Placement {
    Workspace,
    Background,
}

/// What running a command does.
#[derive(Clone, Debug, PartialEq)]
pub enum CommandAction {
    ToggleRecording,
    Go(Section),
    Actions,
    FollowUp,
    OpenAsk,
    /// "Ask…": the panel, from anywhere.
    QuickRecall,
    /// "Import Recording…", from anywhere.
    ImportRecording,
    AskAbout(String),
    ToggleDictation,
    CopyLastDictation,
    Settings(SettingsCategory),
    Meeting(Uuid),
    Agent(AgentRequest),
}

/// One command the palette and Quick Recall can run.
#[derive(Clone, Debug)]
pub struct PaletteCommand {
    pub id: String,
    pub icon: Ico,
    pub title: String,
    pub subtitle: String,
    /// English words that still find a translated command.
    pub search_aliases: String,
    pub placement: Placement,
    pub action: CommandAction,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Matching {
    /// Each query word may appear anywhere (the Ctrl+K palette).
    Substring,
    /// Each query word must start a word. Quick Recall mixes commands with
    /// memory search, so "ion" must not offer Dictation.
    WordPrefix,
}

pub fn words(text: &str) -> Vec<String> {
    text.to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|word| !word.is_empty())
        .map(str::to_string)
        .collect()
}

/// Commands whose title, subtitle, and aliases contain every query word. An
/// empty query matches nothing; callers decide what idle shows.
pub fn filter(commands: &[PaletteCommand], query: &str, matching: Matching) -> Vec<PaletteCommand> {
    let tokens = match matching {
        Matching::Substring => query
            .to_lowercase()
            .split_whitespace()
            .map(str::to_string)
            .collect(),
        Matching::WordPrefix => words(query),
    };
    if tokens.is_empty() {
        return Vec::new();
    }
    commands
        .iter()
        .filter(|command| {
            let haystack = format!(
                "{} {} {}",
                command.title, command.subtitle, command.search_aliases
            );
            let lowered = haystack.to_lowercase();
            match matching {
                Matching::Substring => tokens.iter().all(|t| lowered.contains(t.as_str())),
                Matching::WordPrefix => {
                    // Chinese titles have no spaces between words; match those
                    // anywhere instead.
                    let candidates = words(&haystack);
                    tokens.iter().all(|token| {
                        if token.is_ascii() {
                            candidates.iter().any(|c| c.starts_with(token.as_str()))
                        } else {
                            lowered.contains(token.as_str())
                        }
                    })
                }
            }
        })
        .cloned()
        .collect()
}

fn command(
    id: &str,
    icon: Ico,
    title: &'static str,
    subtitle: &'static str,
    placement: Placement,
    action: CommandAction,
) -> PaletteCommand {
    PaletteCommand {
        id: id.to_string(),
        icon,
        title: lokalbot_i18n::tr(title).to_string(),
        subtitle: lokalbot_i18n::tr(subtitle).to_string(),
        search_aliases: format!("{title} {subtitle}"),
        placement,
        action,
    }
}

/// Titles for the dictation command in each of its states.
fn dictation_title(state: &DictationHud) -> &'static str {
    match state {
        DictationHud::Starting
        | DictationHud::Transcribing
        | DictationHud::Preparing(_)
        | DictationHud::Composing => "Cancel dictation",
        DictationHud::Listening { .. } => "Stop & compose dictation",
        _ => "Start dictation",
    }
}

/// `in_workspace` adds commands that act on the main window's current section
/// (Agent tasks), which only make sense from inside it.
pub fn commands(data: &AppData, in_workspace: bool, cx: &App) -> Vec<PaletteCommand> {
    use CommandAction as A;
    use Placement::{Background, Workspace};
    let recording = data.recording.is_active();
    let dictation = dictation_title(&data.dictation);
    let mut list = vec![
        command(
            "record",
            if recording {
                Ico::CircleStop
            } else {
                Ico::CircleDot
            },
            if recording {
                "Stop recording"
            } else {
                "Record now"
            },
            "Recording",
            Background,
            A::ToggleRecording,
        ),
        command(
            "nav.today",
            Ico::Sun,
            "Go to Today",
            "Home",
            Workspace,
            A::Go(Section::Today),
        ),
        command(
            "nav.actions",
            Ico::ListChecks,
            "Review all actions",
            "Today",
            Workspace,
            A::Actions,
        ),
        command(
            "nav.timeline",
            Ico::ChartGantt,
            "Go to Timeline",
            "Library",
            Workspace,
            A::Go(Section::Timeline),
        ),
        command(
            "nav.meetings",
            Ico::AudioLines,
            "Go to Meetings",
            "Library",
            Workspace,
            A::Go(Section::Meetings),
        ),
        command(
            "followUp",
            Ico::Reply,
            "Draft follow-up for latest meeting",
            "Meetings",
            Workspace,
            A::FollowUp,
        ),
        command(
            "nav.people",
            Ico::Users,
            "Go to People",
            "Library",
            Workspace,
            A::Go(Section::People),
        ),
        command(
            "nav.projects",
            Ico::Folder,
            "Go to Projects",
            "Library",
            Workspace,
            A::Go(Section::Projects),
        ),
        command(
            "nav.ask",
            Ico::TextSearch,
            "Go to Ask",
            "Library",
            Workspace,
            A::OpenAsk,
        ),
        command(
            "dictation",
            Ico::Mic,
            dictation,
            "Automation",
            Background,
            A::ToggleDictation,
        ),
    ];
    list.extend([
        command(
            "ask.panel",
            Ico::TextSearch,
            "Ask…",
            "Library",
            Background,
            A::QuickRecall,
        ),
        command(
            "recording.import",
            Ico::Upload,
            "Import Recording…",
            "Recording",
            Workspace,
            A::ImportRecording,
        ),
    ]);
    // From Quick Recall this hands focus back, ready to paste.
    if !data.recent_dictations.is_empty() {
        list.push(command(
            "dictation.copyLast",
            Ico::Copy,
            "Copy last dictation",
            "Dictation",
            Background,
            A::CopyLastDictation,
        ));
    }
    list.extend([
        command(
            "nav.dictation",
            Ico::Mic,
            if data.settings.dictation_enabled {
                "Go to Dictation (on)"
            } else {
                "Go to Dictation (off)"
            },
            "Write",
            Workspace,
            A::Settings(SettingsCategory::Dictation),
        ),
        command(
            "nav.cotyping",
            Ico::TextCursor,
            if data.settings.cotyping_enabled {
                "Go to Autocomplete (on)"
            } else {
                "Go to Autocomplete (off)"
            },
            "Write",
            Workspace,
            A::Settings(SettingsCategory::Writing),
        ),
        command(
            "nav.agent",
            Ico::WandSparkles,
            "Go to Agent",
            "Automation",
            Workspace,
            A::Go(Section::Agent),
        ),
        command(
            "nav.models",
            Ico::Brain,
            "Go to Models",
            "Settings",
            Workspace,
            A::Settings(SettingsCategory::Models),
        ),
        command(
            "nav.settings",
            Ico::Settings,
            "Go to Settings",
            "Settings",
            Workspace,
            A::Settings(SettingsCategory::Overview),
        ),
    ]);
    if in_workspace && data.section == Section::Agent {
        list.extend([
            command(
                "agent.new",
                Ico::SquarePen,
                "New Agent task",
                "Ctrl+N",
                Workspace,
                A::Agent(AgentRequest::NewTask),
            ),
            command(
                "agent.search",
                Ico::Search,
                "Search Agent tasks",
                "Ctrl+Shift+F",
                Workspace,
                A::Agent(AgentRequest::SearchTasks),
            ),
            command(
                "agent.find",
                Ico::TextSearch,
                "Find in this task",
                "Ctrl+F",
                Workspace,
                A::Agent(AgentRequest::FindInTask),
            ),
            command(
                "agent.results",
                Ico::PanelRight,
                "Toggle results and sources",
                "Ctrl+Alt+B",
                Workspace,
                A::Agent(AgentRequest::ToggleResults),
            ),
        ]);
        // User-owned titles are added after translation, as they are.
        for (id, title, workspace) in crate::pages::agent::palette_tasks(cx).into_iter().take(30) {
            list.push(PaletteCommand {
                id: format!("agent.task.{id}"),
                icon: Ico::MessageSquareText,
                title,
                subtitle: lokalbot_i18n::format("Agent task · {0}", &[("0", workspace)]),
                search_aliases: String::new(),
                placement: Workspace,
                action: A::Agent(AgentRequest::SelectTask(id)),
            });
        }
    }
    list
}

/// Everything the palette lists: commands plus recent meetings when idle; typed
/// queries add one handoff row into Ask. The palette stays a command surface,
/// Ask is the search surface.
pub fn palette_results(data: &AppData, query: &str, cx: &App) -> Vec<PaletteCommand> {
    let actions = commands(data, true, cx);
    let trimmed = query.trim();
    if trimmed.is_empty() {
        let mut results = actions;
        results.extend(data.meetings.iter().take(8).map(|meeting| {
            let duration = lokalbot_core::time::timer(meeting.duration_seconds());
            PaletteCommand {
                id: format!("meeting.{}", meeting.id),
                icon: Ico::AudioLines,
                title: meeting.display_title(),
                subtitle: lokalbot_i18n::format(
                    "Open · {0} · {1}",
                    &[("0", meeting.app_name.clone()), ("1", duration)],
                ),
                search_aliases: String::new(),
                placement: Placement::Workspace,
                action: CommandAction::Meeting(meeting.id),
            }
        }));
        return results;
    }
    let mut results = filter(&actions, trimmed, Matching::Substring);
    results.push(PaletteCommand {
        id: "ask.handoff".to_string(),
        icon: Ico::TextSearch,
        title: lokalbot_i18n::format("Search “{0}” in Ask", &[("0", trimmed.to_string())]),
        subtitle: lokalbot_i18n::tr("Ask").to_string(),
        search_aliases: String::new(),
        placement: Placement::Workspace,
        action: CommandAction::AskAbout(trimmed.to_string()),
    });
    results
}

/// Runs a command. Workspace commands bring the main window forward.
pub fn run(command: &PaletteCommand, cx: &mut App) {
    use CommandAction as A;
    log::debug!("running command {}", command.id);
    let data = AppData::global(cx);
    match &command.action {
        A::ToggleRecording => data.update(cx, |data, cx| data.toggle_recording(cx)),
        A::Go(section) => {
            let section = *section;
            data.update(cx, |data, cx| {
                data.meeting_focus = None;
                data.navigate(section, cx);
            });
        }
        A::Actions => data.update(cx, |data, cx| data.open_actions(cx)),
        A::FollowUp => draft_follow_up_for_latest(&data, cx),
        A::OpenAsk => data.update(cx, |data, cx| data.navigate(Section::Ask, cx)),
        A::QuickRecall => crate::windows::quick_recall::open(cx),
        A::ImportRecording => crate::pages::meetings::list::choose_recordings(data.clone(), cx),
        A::AskAbout(query) => {
            let question = query.clone();
            data.update(cx, |data, cx| {
                data.ask(
                    AskRequest {
                        day: None,
                        question,
                        meeting_ids: Vec::new(),
                        submit: false,
                    },
                    cx,
                )
            });
        }
        A::ToggleDictation => {
            crate::bridge::send(Command::Dictation(DictationCommand::ToggleFromMenu), cx)
        }
        A::CopyLastDictation => {
            crate::bridge::send(Command::Dictation(DictationCommand::CopyRecent(None)), cx)
        }
        A::Settings(category) => {
            let category = *category;
            data.update(cx, |data, cx| data.open_settings(category, cx));
        }
        A::Meeting(id) => {
            let id = *id;
            data.update(cx, |data, cx| {
                data.open_meeting(id, Default::default(), None, cx)
            });
        }
        A::Agent(request) => {
            let request = request.clone();
            data.update(cx, |data, cx| {
                data.agent_request = Some(request);
                data.navigate(Section::Agent, cx);
            });
        }
    }
    if command.placement == Placement::Workspace {
        crate::desktop::show_main_window(cx);
    }
}

/// Opens the newest meeting that has outcomes, with its follow-up draft.
fn draft_follow_up_for_latest(data: &gpui_kit::Entity<AppData>, cx: &mut App) {
    let (library, meetings) = {
        let data = data.read(cx);
        (data.library.clone(), data.meetings.clone())
    };
    let data = data.clone();
    cx.spawn(async move |cx| {
        let found = cx
            .background_spawn(async move {
                meetings
                    .into_iter()
                    .take(50)
                    .find(|meeting| matches!(library.outcomes(meeting), Ok(Some(_))))
                    .map(|meeting| meeting.id)
            })
            .await;
        data.update(cx, |data, cx| match found {
            Some(id) => {
                data.follow_up_request = Some(id);
                data.open_meeting(id, Default::default(), None, cx);
            }
            None => data.show_message(
                lokalbot_i18n::tr("No meeting has action items or decisions to follow up on yet."),
                cx,
            ),
        });
    })
    .detach();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Vec<PaletteCommand> {
        let make = |id: &str, title: &str, subtitle: &str, aliases: &str| PaletteCommand {
            id: id.to_string(),
            icon: Ico::Search,
            title: title.to_string(),
            subtitle: subtitle.to_string(),
            search_aliases: aliases.to_string(),
            placement: Placement::Workspace,
            action: CommandAction::OpenAsk,
        };
        vec![
            make("record", "Record now", "Recording", ""),
            make("dictation", "Start dictation", "Automation", ""),
            make("nav.meetings", "Go to Meetings", "Library", ""),
            make(
                "followUp",
                "Draft follow-up for latest meeting",
                "Meetings",
                "",
            ),
            make(
                "nav.settings",
                "前往设置",
                "设置",
                "Go to Settings Settings",
            ),
        ]
    }

    fn ids(query: &str, matching: Matching) -> Vec<String> {
        filter(&sample(), query, matching)
            .into_iter()
            .map(|c| c.id)
            .collect()
    }

    #[test]
    fn an_empty_query_matches_nothing() {
        assert!(ids("", Matching::Substring).is_empty());
        assert!(ids("   ", Matching::WordPrefix).is_empty());
    }

    #[test]
    fn the_palette_matches_words_anywhere() {
        assert_eq!(ids("ion", Matching::Substring), ["dictation"]);
        assert_eq!(ids("follow-up", Matching::Substring), ["followUp"]);
        assert_eq!(ids("GO MEET", Matching::Substring), ["nav.meetings"]);
    }

    #[test]
    fn quick_recall_matches_only_word_starts() {
        assert!(ids("ion", Matching::WordPrefix).is_empty());
        assert_eq!(ids("rec", Matching::WordPrefix), ["record"]);
        assert_eq!(ids("Record now", Matching::WordPrefix), ["record"]);
        assert_eq!(
            ids("meet", Matching::WordPrefix),
            ["nav.meetings", "followUp"]
        );
        assert_eq!(ids("draft follow", Matching::WordPrefix), ["followUp"]);
        assert!(ids("failover", Matching::WordPrefix).is_empty());
    }

    #[test]
    fn translated_commands_match_english_aliases_and_chinese() {
        assert_eq!(ids("settings", Matching::WordPrefix), ["nav.settings"]);
        assert_eq!(ids("设置", Matching::WordPrefix), ["nav.settings"]);
        assert_eq!(ids("设置", Matching::Substring), ["nav.settings"]);
    }

    #[test]
    fn dictation_titles_follow_its_state() {
        assert_eq!(dictation_title(&DictationHud::Idle), "Start dictation");
        assert_eq!(dictation_title(&DictationHud::Starting), "Cancel dictation");
        assert_eq!(
            dictation_title(&DictationHud::Composing),
            "Cancel dictation"
        );
        assert_eq!(
            dictation_title(&DictationHud::Listening {
                level: 0.0,
                elapsed: 0.0,
                microphone_live: true,
                capture_status: Default::default(),
            }),
            "Stop & compose dictation"
        );
    }
}
