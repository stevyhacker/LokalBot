//! Answering questions in Ask, and writing project notes.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Result, anyhow};
use uuid::Uuid;

use lokalbot_ai::ask::AskEvent;
use lokalbot_ai::remote_gate::Priority;
use lokalbot_core::personal::{self, Origin};
use lokalbot_core::{
    AskSourceScope, ChatMessage, ChatRole, Conversation, Library, NEW_CONVERSATION_TITLE,
    QuestionScope, RememberReceipt, Settings,
};

use crate::models::Models;
use crate::{AskScope, AskUpdate, EngineEvent, FollowUpUpdate, Shared};

pub struct AskWorker {
    shared: Arc<Shared>,
    models: Models,
    running: Arc<AtomicBool>,
    cancel: Arc<AtomicBool>,
}

impl AskWorker {
    pub fn new(shared: Arc<Shared>, models: Models) -> Self {
        Self {
            shared,
            models,
            running: Arc::new(AtomicBool::new(false)),
            cancel: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn stop(&self) {
        self.cancel.store(true, Ordering::Relaxed);
    }

    pub fn ask(
        &self,
        conversation_id: Uuid,
        question: String,
        scope: AskScope,
        retry_of: Option<Uuid>,
    ) {
        if self.running.swap(true, Ordering::SeqCst) {
            self.shared
                .message("LokalBot is still answering the previous question.");
            return;
        }
        self.cancel.store(false, Ordering::Relaxed);
        let shared = self.shared.clone();
        let models = self.models.clone();
        let running = self.running.clone();
        let cancel = self.cancel.clone();
        std::thread::spawn(move || {
            let result = answer(
                &shared,
                &models,
                conversation_id,
                &question,
                &scope,
                retry_of,
                &cancel,
            );
            running.store(false, Ordering::SeqCst);
            match result {
                Ok(()) => shared.emit(EngineEvent::Ask(AskUpdate::Finished { conversation_id })),
                Err(err) => shared.emit(EngineEvent::Ask(AskUpdate::Failed {
                    conversation_id,
                    message: format!("{err:#}"),
                })),
            }
            shared.emit(EngineEvent::LibraryChanged);
        });
    }
}

impl AskWorker {
    /// Rewrites a meeting's follow-up outline with Think. Like macOS, only a
    /// model running on this PC may write it; the outline stays available.
    pub fn write_follow_up(&self, meeting_id: Uuid) {
        let shared = self.shared.clone();
        let models = self.models.clone();
        std::thread::spawn(move || {
            shared.emit(EngineEvent::FollowUp(FollowUpUpdate::Writing {
                meeting_id,
            }));
            let result = (|| -> Result<(lokalbot_ai::follow_up::FollowUpDraft, String)> {
                if !models.missing(&models.think_requirements()).is_empty() {
                    return Err(anyhow!(
                        "Download the Think model in Settings → Models to write follow-ups. The outline stays available."
                    ));
                }
                let settings = shared.settings();
                let think = shared
                    .think(&settings)?
                    .with_priority(Priority::Interactive, "follow-up draft");
                if !think.is_local() {
                    return Err(anyhow!(
                        "Choose a Think model on this PC to write follow-ups. The outline stays available."
                    ));
                }
                let meeting = shared
                    .library
                    .list_meetings()?
                    .into_iter()
                    .find(|m| m.id == meeting_id)
                    .ok_or_else(|| anyhow!("That meeting no longer exists."))?;
                let draft = lokalbot_ai::follow_up::generate(&think, &shared.library, &meeting)?;
                Ok((draft, think.model_label()))
            })();
            shared.emit(EngineEvent::FollowUp(match result {
                Ok((draft, model)) => FollowUpUpdate::Written {
                    meeting_id,
                    subject: draft.subject,
                    body: draft.body,
                    model,
                },
                Err(err) => FollowUpUpdate::Failed {
                    meeting_id,
                    message: format!("{err:#}"),
                },
            }));
        });
    }
}

/// One question as it was sent.
struct Question<'a> {
    conversation_id: Uuid,
    text: &'a str,
    scope: &'a AskScope,
    retry_of: Option<Uuid>,
    cancel: &'a AtomicBool,
}

fn answer(
    shared: &Shared,
    models: &Models,
    conversation_id: Uuid,
    question: &str,
    scope: &AskScope,
    retry_of: Option<Uuid>,
    cancel: &AtomicBool,
) -> Result<()> {
    let settings = shared.settings();
    run_question(
        &shared.library,
        &settings,
        &|event| shared.emit(event),
        Question {
            conversation_id,
            text: question,
            scope,
            retry_of,
            cancel,
        },
        |history| {
            ask_model(
                shared,
                models,
                conversation_id,
                question,
                history,
                scope,
                cancel,
            )
        },
    )
}

/// `ChatViewModel.sendResolved` and `run`. The question is saved as it is sent,
/// so a failed or stopped answer leaves it in the conversation with an error
/// turn to retry; `Err` means nothing could be saved at all. `model` answers from
/// the turns allowed to reach it.
fn run_question(
    library: &Library,
    settings: &Settings,
    emit: &dyn Fn(EngineEvent),
    question: Question,
    model: impl FnOnce(&[ChatMessage]) -> Result<(ChatMessage, Vec<Uuid>)>,
) -> Result<()> {
    let Question {
        conversation_id,
        text,
        scope,
        retry_of,
        cancel,
    } = question;
    let now = lokalbot_core::time::now_seconds();
    let mut conversation = library
        .conversations()?
        .into_iter()
        .find(|c| c.id == conversation_id)
        .unwrap_or_else(|| Conversation {
            id: conversation_id,
            title: title_for(text),
            created_at: now,
            updated_at: now,
            messages: Vec::new(),
        });
    if conversation.title == NEW_CONVERSATION_TITLE {
        conversation.title = title_for(text);
    }
    if let Some(failed) = retry_of {
        lokalbot_core::remove_failed_turn(&mut conversation.messages, failed);
    }
    let saved = question_scope(scope);
    // "Remember …" is saved locally, without a model call or a model. With an
    // attached screen it stays a question about that screen.
    if !scope.attached_screens
        && settings.ask_memory_enabled
        && let Some(statement) = personal::remember_statement(text)
    {
        remember(library, emit, &mut conversation, text, &statement, &saved);
        return Ok(());
    }
    // Only complete pairs asked within this question's boundary reach the model.
    let history = lokalbot_core::finalized_history(&conversation.messages, &saved);
    conversation
        .messages
        .push(ChatMessage::new(ChatRole::User, text).with_scope(&saved));
    conversation.updated_at = lokalbot_core::time::now_seconds();
    save(library, emit, &conversation);
    emit(EngineEvent::Ask(AskUpdate::Progress {
        conversation_id,
        question: text.to_string(),
        text: String::new(),
        activity: Vec::new(),
        status: Some("Preparing the assistant".into()),
    }));
    emit(EngineEvent::LibraryChanged);

    let turn = match model(&history) {
        _ if cancel.load(Ordering::Relaxed) => failed_turn(STOPPED_TURN.to_string(), &saved),
        Ok((mut reply, used_claims)) => {
            if !used_claims.is_empty() {
                reply.used_claim_ids = Some(used_claims.clone());
            }
            library.personal().mark_used(&used_claims);
            reply.with_scope(&saved)
        }
        Err(err) => {
            log::warn!("Ask could not answer: {err:#}");
            failed_turn(friendly_failure(&err), &saved)
        }
    };
    // Deleted while it was being answered: it stays deleted.
    if !library.conversation_exists(conversation_id) {
        return Ok(());
    }
    conversation.messages.push(turn);
    conversation.updated_at = lokalbot_core::time::now_seconds();
    save(library, emit, &conversation);
    Ok(())
}

/// What a stopped turn says (`finalizeInterruptedTurn`). What arrived before
/// Stop isn't kept: an answer cut short shouldn't read as a finished one.
const STOPPED_TURN: &str = "Response stopped. Retry when you're ready.";

fn failed_turn(text: String, saved: &QuestionScope) -> ChatMessage {
    ChatMessage {
        is_error: true,
        ..ChatMessage::new(ChatRole::Assistant, text).with_scope(saved)
    }
}

/// `ChatViewModel.friendlyFailureMessage`. A refusal keeps its reason: only the
/// person can change what's refused, and it holds nothing from the library.
fn friendly_failure(err: &anyhow::Error) -> String {
    use lokalbot_ai::AiError;
    const UNKNOWN: &str = "The assistant could not complete that request. Check the selected model in Settings, then try again.";
    match lokalbot_ai::ai_error(err) {
        Some(AiError::ConsentRequired(reason) | AiError::Unavailable(reason)) => reason.clone(),
        Some(AiError::NoModel | AiError::ModelMissing(_)) => {
            "No Think model is selected. Choose one in Settings → Models, then try again.".into()
        }
        Some(AiError::ServerStart(_)) => {
            "The on-device assistant could not start. Close memory-heavy apps or choose a smaller model, then try again.".into()
        }
        Some(AiError::ServerUnreachable(_)) => {
            "The selected assistant could not be reached. Check its settings, then try again.".into()
        }
        Some(AiError::HttpStatus {
            code: 401 | 403, ..
        }) => "The selected assistant rejected its API key. Check the key in Settings, then try again.".into(),
        Some(AiError::HttpStatus { code: 429, .. }) => {
            "The selected assistant is rate-limited. Wait briefly, then try again.".into()
        }
        _ => UNKNOWN.into(),
    }
}

/// Everything that needs the model: its answer and the Personal Context items it
/// was given.
fn ask_model(
    shared: &Shared,
    models: &Models,
    conversation_id: Uuid,
    question: &str,
    history: &[ChatMessage],
    scope: &AskScope,
    cancel: &AtomicBool,
) -> Result<(ChatMessage, Vec<Uuid>)> {
    let library = &shared.library;
    let settings = shared.settings();
    let progress = |text: &str, activity: &[String], status: Option<String>| {
        shared.emit(EngineEvent::Ask(AskUpdate::Progress {
            conversation_id,
            question: question.to_string(),
            text: text.to_string(),
            activity: activity.to_vec(),
            status,
        }));
    };
    if !models.missing(&models.think_requirements()).is_empty() {
        return Err(lokalbot_ai::AiError::Unavailable(
            "Ask needs the Think model. Download it in Settings → Models, then ask again.".into(),
        )
        .into());
    }
    let think = shared
        .think(&settings)?
        .with_priority(Priority::Interactive, "chat");

    let mut text = String::new();
    let mut activity: Vec<String> = Vec::new();
    let mut last_emit = Instant::now() - Duration::from_secs(1);
    let (ambient, used_claims) = ambient_context(shared, &settings, question, history, scope);
    let attached_screens = scope.attached_screens;
    let scope = lokalbot_ai::ask::AskScope {
        meeting_ids: scope.meeting_ids.clone(),
        since: scope.since,
        until: scope.until,
        include_meetings: scope.include_meetings,
        include_screen: scope.include_screen,
        include_activity: scope.include_activity,
        personal_context: ambient.personal_context,
        work_memory: ambient.work_memory,
        search_by_meaning: settings.semantic_search_enabled,
        // Files only while it's on with a folder: then `search_files` is offered.
        include_files: scope.include_files && settings.file_search_enabled,
        file_folders: if scope.include_files && settings.file_search_enabled {
            settings.file_search_folders.clone()
        } else {
            Vec::new()
        },
        screen_ids: scope.screen_ids.clone(),
        screen_app: scope.screen_app.clone(),
        attached_context: None,
        moments: moment_words(shared),
    };
    let attached = attached_screens.then(|| attached_screen_context(library, &scope));
    let scope = lokalbot_ai::ask::AskScope {
        attached_context: attached.flatten(),
        ..scope
    };
    let mut on_event = |event| {
        match event {
            AskEvent::Delta(delta) => text.push_str(&delta),
            AskEvent::Answer(answer) => text = answer,
            AskEvent::Activity(step) => activity.push(step),
            AskEvent::Status(status) => progress(&text, &activity, Some(status)),
        }
        if last_emit.elapsed() > Duration::from_millis(60) {
            last_emit = Instant::now();
            progress(&text, &activity, None);
        }
    };
    // Each tool call is a model call: a CPU-only or small-window model
    // answers in one retrieve-first turn instead.
    let reply = if lokalbot_ai::ask_agent::uses_tool_loop(&think) {
        lokalbot_ai::ask_agent::answer_with_tools(
            &think,
            library,
            question,
            history,
            &scope,
            cancel,
            &mut on_event,
        )?
    } else {
        lokalbot_ai::ask::answer(
            &think,
            library,
            question,
            history,
            &scope,
            cancel,
            &mut on_event,
        )?
    };
    Ok((reply, used_claims))
}

/// The boundary to save with a question. A caller that named none gets the
/// sources it enabled and the ids it bound, so nothing reads as "everything".
fn question_scope(scope: &AskScope) -> QuestionScope {
    if !scope.saved.sources.is_empty() {
        return scope.saved.clone();
    }
    let on = [
        (AskSourceScope::Meetings, scope.include_meetings),
        (AskSourceScope::Today, scope.include_activity),
        (AskSourceScope::Screen, scope.include_screen),
        (AskSourceScope::Files, scope.include_files),
    ];
    QuestionScope {
        sources: on
            .into_iter()
            .filter_map(|(source, on)| on.then_some(source))
            .collect(),
        meeting_ids: (!scope.meeting_ids.is_empty()).then(|| scope.meeting_ids.clone()),
        screen_snapshot_ids: (!scope.screen_ids.is_empty()).then(|| scope.screen_ids.clone()),
        ..scope.saved.clone()
    }
}

/// A failed save keeps the answer on screen for this run instead of losing it;
/// Ask says it isn't saved.
fn save(library: &Library, emit: &dyn Fn(EngineEvent), conversation: &Conversation) {
    if let Err(err) = library.save_conversation(conversation) {
        log::warn!("saving a conversation failed: {err:#}");
        if let Some(problem) = library.load_conversations().problem() {
            emit(EngineEvent::Message {
                text: problem,
                is_error: true,
            });
        }
    }
}

/// `ChatViewModel.remember`: the statement and its receipt, or why it wasn't kept.
fn remember(
    library: &Library,
    emit: &dyn Fn(EngineEvent),
    conversation: &mut Conversation,
    question: &str,
    statement: &str,
    saved: &QuestionScope,
) {
    let now = lokalbot_core::time::now_seconds();
    let said = ChatMessage::new(ChatRole::User, question).with_scope(saved);
    let message_id = said.id;
    conversation.messages.push(said);
    let result = library.personal().remember(
        statement,
        None,
        Origin::Said {
            conversation_id: conversation.id,
            message_id,
        },
    );
    let (text, claim_id) = match result {
        Ok(claim) => (claim.text, Some(claim.id)),
        Err(err) => (err.message(), None),
    };
    conversation.messages.push(ChatMessage {
        remember_receipt: Some(RememberReceipt { claim_id }),
        ..ChatMessage::new(ChatRole::Assistant, text).with_scope(saved)
    });
    conversation.updated_at = now;
    save(library, emit, conversation);
}

#[derive(Default)]
struct Ambient {
    personal_context: String,
    work_memory: String,
}

/// A question limited to some sources or days doesn't get what was distilled from
/// everything: work memory and learned items would carry content past its
/// boundary. The person's own statements carry no source, so they still apply.
fn is_unscoped(scope: &AskScope) -> bool {
    scope.meeting_ids.is_empty()
        && scope.screen_ids.is_empty()
        && scope.screen_app.is_none()
        && scope.since.is_none()
        && scope.until.is_none()
        && scope.include_meetings
        && scope.include_activity
        && scope.include_screen
        && scope.include_files
}

fn ambient_context(
    shared: &Shared,
    settings: &lokalbot_core::Settings,
    question: &str,
    history: &[ChatMessage],
    scope: &AskScope,
) -> (Ambient, Vec<Uuid>) {
    let unscoped = is_unscoped(scope);
    let mut ambient = Ambient::default();
    if unscoped {
        ambient.work_memory =
            lokalbot_core::evidence::read_work_memory(shared.library.paths().root())
                .map(|bytes| {
                    lokalbot_ai::selection::work_memory_context(&bytes, settings.dreaming_enabled)
                })
                .unwrap_or_default();
    }
    let mut used = Vec::new();
    if settings.ask_memory_enabled {
        let recent: Vec<String> = history
            .iter()
            .filter(|message| message.role == ChatRole::User)
            .map(|message| message.text.clone())
            .collect();
        let start = recent.len().saturating_sub(2);
        let selection = personal::select_context(
            &shared.library.personal().usable_claims(unscoped),
            question,
            &recent[start..],
            personal::CONTEXT_BUDGET,
        );
        ambient.personal_context = selection.block;
        used = selection.claim_ids;
    }
    (ambient, used)
}

/// The assistant hears a file's moment through the person's transcription model.
fn moment_words(shared: &Shared) -> lokalbot_ai::ask::MomentWords {
    let hear = shared.moments.lock().clone();
    lokalbot_ai::ask::MomentWords(hear.map(|moments| {
        Arc::new(move |hit: &lokalbot_core::files::FileHit| moments.passage(hit))
            as lokalbot_ai::ask::HearMoment
    }))
}

/// Screen context the person attached, as primary evidence for the model, while
/// the conversation shows only their question (`ScreenAskContext.prompt`).
fn attached_screen_context(
    library: &lokalbot_core::Library,
    scope: &lokalbot_ai::ask::AskScope,
) -> Option<String> {
    let clean = |text: &str| {
        text.replace(['«', '»'], "")
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
    };
    let mut sources = Vec::new();
    if scope.include_screen {
        for id in &scope.screen_ids {
            let Ok(Some(moment)) = library.screen_moment(*id) else {
                continue;
            };
            if scope.since.is_some_and(|s| moment.ts < s)
                || scope.until.is_some_and(|u| moment.ts >= u)
            {
                continue;
            }
            let window = if moment.window_title.is_empty() {
                String::new()
            } else {
                format!(" — {}", clean(&moment.window_title))
            };
            let when = moment
                .ts
                .with_timezone(&chrono::Local)
                .format("%b %-d, %Y at %H:%M");
            sources.push(format!(
                "- [screen:{id}] {}{window}, {when}\n  Captured text: {}",
                moment.app,
                clean(moment.text.as_deref().unwrap_or(""))
            ));
        }
    }
    (!sources.is_empty()).then(|| {
        format!(
            "Screen context explicitly selected by the user. Treat it as primary evidence and use the exact [screen:ID] marker when citing it:\n{}",
            sources.join("\n")
        )
    })
}

fn title_for(question: &str) -> String {
    let trimmed = question.trim();
    if trimmed.chars().count() <= 60 {
        return trimmed.to_string();
    }
    let mut title: String = trimmed.chars().take(57).collect();
    if let Some(space) = title.rfind(' ') {
        title.truncate(space);
    }
    title.push('…');
    title
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A library with a chat key, and what `run_question` asks the model.
    struct Fixture {
        _dir: tempfile::TempDir,
        library: Library,
        settings: Settings,
        conversation: Uuid,
    }

    impl Fixture {
        fn new() -> Self {
            let dir = tempfile::tempdir().unwrap();
            let library = Library::open(lokalbot_core::LibraryPaths::new(dir.path())).unwrap();
            std::fs::create_dir_all(library.paths().chats_dir()).unwrap();
            library.set_chat_key_source(Arc::new(|_| Ok([7; 32])));
            Self {
                _dir: dir,
                library,
                settings: Settings::default(),
                conversation: Uuid::new_v4(),
            }
        }

        /// Sends a question. `answer` plays the model; the turns it was given
        /// come back.
        fn ask(
            &self,
            text: &str,
            scope: &AskScope,
            retry_of: Option<Uuid>,
            answer: Result<&str>,
        ) -> Option<Vec<String>> {
            self.ask_with(text, scope, retry_of, &AtomicBool::new(false), answer)
        }

        fn ask_with(
            &self,
            text: &str,
            scope: &AskScope,
            retry_of: Option<Uuid>,
            cancel: &AtomicBool,
            answer: Result<&str>,
        ) -> Option<Vec<String>> {
            let mut asked = None;
            run_question(
                &self.library,
                &self.settings,
                &|_| {},
                Question {
                    conversation_id: self.conversation,
                    text,
                    scope,
                    retry_of,
                    cancel,
                },
                |history| {
                    asked = Some(history.iter().map(|m| m.text.clone()).collect());
                    // The question is on disk before the model hears it.
                    let saved = self.messages();
                    assert_eq!(saved.last().unwrap().text, text);
                    assert_eq!(saved.last().unwrap().role, ChatRole::User);
                    answer.map(|answer| (ChatMessage::new(ChatRole::Assistant, answer), Vec::new()))
                },
            )
            .unwrap();
            asked
        }

        fn messages(&self) -> Vec<ChatMessage> {
            self.library
                .conversations()
                .unwrap()
                .into_iter()
                .find(|c| c.id == self.conversation)
                .map(|c| c.messages)
                .unwrap_or_default()
        }

        fn texts(&self) -> Vec<String> {
            self.messages().into_iter().map(|m| m.text).collect()
        }
    }

    fn within(sources: &[AskSourceScope]) -> AskScope {
        AskScope {
            include_meetings: sources.contains(&AskSourceScope::Meetings),
            include_activity: sources.contains(&AskSourceScope::Today),
            include_screen: sources.contains(&AskSourceScope::Screen),
            include_files: sources.contains(&AskSourceScope::Files),
            saved: QuestionScope {
                sources: sources.to_vec(),
                ..Default::default()
            },
            ..Default::default()
        }
    }

    /// The model never hears an earlier, wider answer in a narrower question, and
    /// each turn keeps the boundary it was asked within.
    #[test]
    fn a_narrower_question_doesnt_hear_earlier_wider_answers() {
        let f = Fixture::new();
        let everything = within(&AskSourceScope::ALL);
        let meetings = within(&[AskSourceScope::Meetings]);
        assert_eq!(
            f.ask("Everything?", &everything, None, Ok("From screens")),
            Some(Vec::new())
        );
        assert_eq!(
            f.ask("Meetings?", &meetings, None, Ok("From meetings")),
            Some(Vec::new()),
            "the wider pair stayed out"
        );
        assert_eq!(
            f.ask("Meetings again?", &meetings, None, Ok("Still meetings")),
            Some(vec!["Meetings?".into(), "From meetings".into()])
        );
        assert_eq!(
            f.ask("All again?", &everything, None, Ok("Fine"))
                .unwrap()
                .len(),
            6,
            "wider questions may hear narrower answers"
        );
        let saved = f.messages();
        assert_eq!(saved[2].source_scopes, [AskSourceScope::Meetings]);
        assert_eq!(saved[3].source_scopes, [AskSourceScope::Meetings]);
        assert_eq!(saved[0].source_scopes, AskSourceScope::ALL);
    }

    #[test]
    fn a_failed_answer_stays_in_the_conversation_and_retrying_replaces_it() {
        let f = Fixture::new();
        let scope = within(&[AskSourceScope::Meetings]);
        f.ask(
            "Decided?",
            &scope,
            None,
            Err(lokalbot_ai::AiError::ServerUnreachable("x".into()).into()),
        );
        let saved = f.messages();
        assert_eq!(saved.len(), 2);
        assert_eq!(saved[0].text, "Decided?");
        assert!(saved[1].is_error);
        assert!(saved[1].text.contains("could not be reached"));
        assert_eq!(saved[1].source_scopes, [AskSourceScope::Meetings]);
        assert!(lokalbot_core::can_retry(&saved, saved[1].id, false));

        // Not part of what the model hears next, and asked again without doubling.
        let asked = f.ask("Decided?", &scope, Some(saved[1].id), Ok("Redis."));
        assert_eq!(asked, Some(Vec::new()));
        assert_eq!(f.texts(), ["Decided?", "Redis."]);
        assert!(!f.messages()[1].is_error);
    }

    #[test]
    fn stopping_leaves_a_retryable_turn_and_no_part_answer() {
        let f = Fixture::new();
        let cancel = AtomicBool::new(true);
        f.ask_with(
            "Decided?",
            &within(&AskSourceScope::ALL),
            None,
            &cancel,
            Ok("Half an ans"),
        );
        let saved = f.messages();
        assert_eq!(saved.len(), 2);
        assert_eq!(saved[1].text, STOPPED_TURN);
        assert!(saved[1].is_error);
        assert!(lokalbot_core::can_retry(&saved, saved[1].id, false));
    }

    #[test]
    fn remember_saves_without_a_model_unless_a_screen_is_attached() {
        let f = Fixture::new();
        let plain = within(&[AskSourceScope::Meetings]);
        let asked = f.ask("Remember that I like tea", &plain, None, Ok("unused"));
        assert_eq!(asked, None, "no model call");
        let saved = f.messages();
        assert_eq!(saved[0].text, "Remember that I like tea");
        assert_eq!(saved[1].text, "I like tea");
        assert!(saved[1].remember_receipt.is_some());
        assert_eq!(saved[1].source_scopes, [AskSourceScope::Meetings]);

        let attached = AskScope {
            attached_screens: true,
            screen_ids: vec![7],
            ..within(&AskSourceScope::ALL)
        };
        let asked = f.ask("Remember this page", &attached, None, Ok("It shows mail"));
        assert!(asked.is_some(), "a question about the attached screen");
        assert_eq!(f.messages().last().unwrap().text, "It shows mail");
        assert!(f.messages().last().unwrap().remember_receipt.is_none());
    }

    #[test]
    fn a_conversation_deleted_while_answering_stays_deleted() {
        let f = Fixture::new();
        run_question(
            &f.library,
            &f.settings,
            &|_| {},
            Question {
                conversation_id: f.conversation,
                text: "Decided?",
                scope: &within(&AskSourceScope::ALL),
                retry_of: None,
                cancel: &AtomicBool::new(false),
            },
            |_| {
                f.library.delete_conversation(f.conversation).unwrap();
                Ok((ChatMessage::new(ChatRole::Assistant, "Redis."), Vec::new()))
            },
        )
        .unwrap();
        assert!(f.messages().is_empty());
        assert!(!f.library.conversation_exists(f.conversation));
    }

    #[test]
    fn a_failed_answer_keeps_its_question_and_scope_and_says_what_to_do() {
        let saved = QuestionScope {
            sources: vec![AskSourceScope::Meetings],
            day_scope_key: Some("2026-10-01".into()),
            meeting_ids: Some(vec![Uuid::nil()]),
            ..Default::default()
        };
        let turn = failed_turn(STOPPED_TURN.to_string(), &saved);
        assert!(turn.is_error);
        assert_eq!(turn.role, ChatRole::Assistant);
        assert_eq!(turn.source_scopes, saved.sources);
        assert_eq!(turn.day_scope_key, saved.day_scope_key);
        assert_eq!(turn.meeting_ids, saved.meeting_ids);
        // The Mac reads this text to show a stopped turn.
        assert!(turn.text.to_lowercase().starts_with("response stopped"));
    }

    #[test]
    fn failures_read_as_the_mac_words_them() {
        use lokalbot_ai::AiError;
        let friendly = |err: AiError| friendly_failure(&err.into());
        assert!(friendly(AiError::ServerUnreachable("x".into())).contains("could not be reached"));
        assert!(
            friendly(AiError::HttpStatus {
                code: 401,
                detail: "secret detail".into(),
                retry_after: None
            })
            .contains("rejected its API key")
        );
        assert!(
            friendly(AiError::HttpStatus {
                code: 429,
                detail: String::new(),
                retry_after: None
            })
            .contains("rate-limited")
        );
        assert!(
            !friendly(AiError::HttpStatus {
                code: 500,
                detail: "secret detail".into(),
                retry_after: None
            })
            .contains("secret")
        );
        assert!(friendly(AiError::ServerStart("x".into())).contains("could not start"));
        // A refusal keeps its reason, so the person can act on it.
        assert_eq!(
            friendly(AiError::ConsentRequired("Use HTTPS.".into())),
            "Use HTTPS."
        );
        assert!(friendly_failure(&anyhow!("/home/me/secret")).contains("could not complete"));
    }

    #[test]
    fn a_caller_that_names_no_boundary_saves_what_it_enabled() {
        let scope = AskScope {
            include_meetings: true,
            meeting_ids: vec![Uuid::nil()],
            ..Default::default()
        };
        let saved = question_scope(&scope);
        assert_eq!(saved.sources, [AskSourceScope::Meetings]);
        assert_eq!(saved.meeting_ids, Some(vec![Uuid::nil()]));
        assert_eq!(saved.screen_snapshot_ids, None);
        let named = QuestionScope {
            sources: vec![AskSourceScope::Screen],
            ..Default::default()
        };
        let scope = AskScope {
            saved: named.clone(),
            ..scope
        };
        assert_eq!(question_scope(&scope), named);
    }

    #[test]
    fn restricted_questions_are_told_apart() {
        let all = AskScope {
            meeting_ids: Vec::new(),
            include_meetings: true,
            include_activity: true,
            include_screen: true,
            include_files: true,
            screen_ids: Vec::new(),
            attached_screens: false,
            screen_app: None,
            since: None,
            until: None,
            saved: QuestionScope::default(),
        };
        assert!(is_unscoped(&all));
        for restricted in [
            AskScope {
                include_meetings: false,
                ..all.clone()
            },
            AskScope {
                include_activity: false,
                ..all.clone()
            },
            AskScope {
                include_screen: false,
                ..all.clone()
            },
            AskScope {
                include_files: false,
                ..all.clone()
            },
            AskScope {
                since: Some(chrono::Utc::now()),
                ..all.clone()
            },
            AskScope {
                until: Some(chrono::Utc::now()),
                ..all.clone()
            },
            AskScope {
                meeting_ids: vec![Uuid::nil()],
                ..all.clone()
            },
            AskScope {
                screen_ids: vec![7],
                ..all.clone()
            },
            AskScope {
                screen_app: Some("Mail".into()),
                ..all.clone()
            },
        ] {
            assert!(!is_unscoped(&restricted), "{restricted:?}");
        }
    }
}
