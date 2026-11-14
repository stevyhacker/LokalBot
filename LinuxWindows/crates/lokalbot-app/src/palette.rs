//! The commands Quick Recall can run (`PaletteCommands.swift`), computed live
//! from app state so titles follow recording and dictation status. Ctrl+K and
//! the system-wide shortcut open the same window, so there is one list.

use gpui_kit::{App, AppContext as _};
use lokalbot_engine::{Command, DictationCommand};

use crate::state::{AgentRequest, AppData, DictationHud, Section, SettingsCategory};
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
    /// "Import Recording…", from anywhere (the port's own command).
    ImportRecording,
    ToggleDictation,
    CopyLastDictation,
    Settings(SettingsCategory),
    Agent(AgentRequest),
}

/// One command Quick Recall can run.
#[derive(Clone, Debug)]
pub struct PaletteCommand {
    pub id: String,
    pub icon: Ico,
    pub title: String,
    /// The area the command belongs to ("Library", "Recording"). Typed words
    /// match it; the row does not show it.
    pub subtitle: String,
    /// English words that still find a translated command.
    pub search_aliases: String,
    pub placement: Placement,
    /// Grey text after the title, when it says something ("2 open").
    pub detail: Option<String>,
    /// The command's own keyboard shortcut, shown at the row's end.
    pub shortcut: Option<String>,
    pub action: CommandAction,
}

impl PaletteCommand {
    fn with_detail(mut self, detail: Option<String>) -> Self {
        self.detail = detail;
        self
    }

    fn with_shortcut(mut self, shortcut: Option<&str>) -> Self {
        self.shortcut = shortcut.filter(|s| !s.is_empty()).map(str::to_string);
        self
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Matching {
    /// Each query word may appear anywhere.
    Substring,
    /// Each query word must start a word of the command.
    WordPrefix,
}

/// The commands typed words find, in two parts (`PaletteCommandFilter.split`).
/// `leading` are those where each typed word starts a word of the command;
/// Quick Recall lists them first, so Return runs the top one. `loose` only
/// hold the words somewhere ("ion" in "Start dictation"); Quick Recall lists
/// them under the search results, where they can be found but Return alone
/// never runs one. Each part keeps the catalog's order.
pub fn split(
    commands: &[PaletteCommand],
    query: &str,
) -> (Vec<PaletteCommand>, Vec<PaletteCommand>) {
    let leading = filter(commands, query, Matching::WordPrefix);
    let loose = filter(commands, query, Matching::Substring)
        .into_iter()
        .filter(|command| !leading.iter().any(|lead| lead.id == command.id))
        .collect();
    (leading, loose)
}

/// The order before anything is typed: what acts in place (recording,
/// dictation) first, then the rest as the catalog lists them.
pub fn idle_order(commands: Vec<PaletteCommand>) -> Vec<PaletteCommand> {
    let (background, rest): (Vec<_>, Vec<_>) = commands
        .into_iter()
        .partition(|command| command.placement == Placement::Background);
    background.into_iter().chain(rest).collect()
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
        detail: None,
        shortcut: None,
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
/// (Agent tasks), which only make sense when Quick Recall was opened from it.
pub fn commands(data: &AppData, in_workspace: bool, cx: &App) -> Vec<PaletteCommand> {
    use CommandAction as A;
    use Placement::{Background, Workspace};
    let recording = data.recording.is_active();
    let dictation = dictation_title(&data.dictation);
    let open_actions = data
        .open_action_count
        .filter(|count| *count > 0)
        .map(|count| lokalbot_i18n::fill(lokalbot_i18n::tr("%lld open"), &[&count.to_string()]));
    // The dictation shortcut is registered only while Dictation is on.
    let dictation_shortcut = data
        .settings
        .dictation_enabled
        .then_some(data.settings.dictation_shortcut.as_str());
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
        )
        .with_shortcut(Some("Ctrl+Shift+R")),
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
            Section::Actions.icon(),
            "Review all actions",
            "Home",
            Workspace,
            A::Actions,
        )
        .with_detail(open_actions),
        command(
            "nav.timeline",
            Section::Timeline.icon(),
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
            Section::Ask.icon(),
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
        )
        .with_shortcut(dictation_shortcut),
    ];
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
    // The port's own: the Mac imports from its File menu.
    list.push(command(
        "recording.import",
        Ico::Import,
        "Import Recording…",
        "Recording",
        Workspace,
        A::ImportRecording,
    ));
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
        )
        .with_shortcut(Some("Ctrl+,")),
    ]);
    if in_workspace && data.section == Section::Agent {
        list.extend([
            command(
                "agent.new",
                Ico::SquarePen,
                "New Agent task",
                "Agent",
                Workspace,
                A::Agent(AgentRequest::NewTask),
            )
            .with_shortcut(Some("Ctrl+N")),
            command(
                "agent.search",
                Ico::Search,
                "Search Agent tasks",
                "Agent",
                Workspace,
                A::Agent(AgentRequest::SearchTasks),
            )
            .with_shortcut(Some("Ctrl+Shift+F")),
            command(
                "agent.find",
                Ico::TextSearch,
                "Find in this task",
                "Agent",
                Workspace,
                A::Agent(AgentRequest::FindInTask),
            )
            .with_shortcut(Some("Ctrl+F")),
            command(
                "agent.results",
                Ico::PanelRight,
                "Toggle results and sources",
                "Agent",
                Workspace,
                A::Agent(AgentRequest::ToggleResults),
            )
            .with_shortcut(Some("Ctrl+Alt+B")),
        ]);
        // User-owned titles are added after translation, as they are.
        for (id, title, workspace) in crate::pages::agent::palette_tasks(cx).into_iter().take(30) {
            list.push(PaletteCommand {
                id: format!("agent.task.{id}"),
                icon: Ico::MessageSquareText,
                title,
                subtitle: lokalbot_i18n::format("Agent task · {0}", &[("0", workspace.clone())]),
                search_aliases: String::new(),
                placement: Workspace,
                detail: Some(workspace),
                shortcut: None,
                action: A::Agent(AgentRequest::SelectTask(id)),
            });
        }
    }
    list
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
        A::ImportRecording => crate::pages::meetings::list::choose_recordings(data.clone(), cx),
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
        A::Agent(request) => {
            let request = request.clone();
            data.update(cx, |data, cx| {
                data.agent_request = Some(request);
                data.navigate(Section::Agent, cx);
            });
        }
    }
    // Settings has its own window; everything else is in the main one.
    if command.placement == Placement::Workspace && !matches!(command.action, A::Settings(_)) {
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
            placement: if id.starts_with("record") || id.starts_with("dictation") {
                Placement::Background
            } else {
                Placement::Workspace
            },
            detail: None,
            shortcut: None,
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
    fn substring_matching_finds_words_anywhere() {
        assert_eq!(ids("ion", Matching::Substring), ["dictation"]);
        assert_eq!(ids("follow-up", Matching::Substring), ["followUp"]);
        assert_eq!(ids("GO MEET", Matching::Substring), ["nav.meetings"]);
    }

    #[test]
    fn word_start_matching() {
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

    fn split_ids(query: &str) -> (Vec<String>, Vec<String>) {
        let (leading, loose) = split(&sample(), query);
        (
            leading.into_iter().map(|c| c.id).collect(),
            loose.into_iter().map(|c| c.id).collect(),
        )
    }

    #[test]
    fn commands_matching_only_inside_a_word_come_last() {
        // "ion" sits inside "dictation": findable, but never under Return.
        assert_eq!(split_ids("ion"), (vec![], vec!["dictation".to_string()]));
        assert_eq!(split_ids("rec"), (vec!["record".to_string()], vec![]));
        // "meet" starts a word of both; "eet" only sits inside them.
        assert_eq!(
            split_ids("meet"),
            (
                vec!["nav.meetings".to_string(), "followUp".to_string()],
                vec![]
            )
        );
        assert_eq!(
            split_ids("eet"),
            (
                vec![],
                vec!["nav.meetings".to_string(), "followUp".to_string()]
            )
        );
        assert_eq!(split_ids(""), (vec![], vec![]));
    }

    #[test]
    fn before_typing_commands_that_act_in_place_lead() {
        let ids: Vec<String> = idle_order(sample()).into_iter().map(|c| c.id).collect();
        assert_eq!(
            ids,
            [
                "record",
                "dictation",
                "nav.meetings",
                "followUp",
                "nav.settings"
            ]
        );
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
