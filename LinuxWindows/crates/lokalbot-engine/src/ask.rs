//! Answering questions in Ask, and writing project notes.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Result, anyhow};
use uuid::Uuid;

use lokalbot_ai::ask::AskEvent;
use lokalbot_core::{ChatMessage, ChatRole, Conversation};

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

    pub fn ask(&self, conversation_id: Uuid, question: String, scope: AskScope) {
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

    pub fn write_project_note(&self, project_id: String) {
        let shared = self.shared.clone();
        let models = self.models.clone();
        std::thread::spawn(move || {
            shared.emit(EngineEvent::ProjectNote {
                project_id: project_id.clone(),
                running: true,
            });
            let result = (|| -> Result<()> {
                if !models.missing(&models.think_requirements()).is_empty() {
                    return Err(anyhow!(
                        "Download the Think model in Settings → Models first."
                    ));
                }
                let settings = shared.settings();
                let think = shared.think(&settings)?;
                let projects = shared.library.projects()?;
                let project = projects
                    .into_iter()
                    .find(|p| p.id == project_id)
                    .ok_or_else(|| anyhow!("That project no longer exists."))?;
                let summary =
                    lokalbot_ai::project_status::generate(&think, &shared.library, &project)?;
                shared.library.save_project_summary(summary)?;
                Ok(())
            })();
            if let Err(err) = result {
                shared.error(format!("Could not write the project note: {err:#}"));
            }
            shared.emit(EngineEvent::ProjectNote {
                project_id,
                running: false,
            });
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
                let think = shared.think(&settings)?;
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

fn answer(
    shared: &Shared,
    models: &Models,
    conversation_id: Uuid,
    question: &str,
    scope: &AskScope,
    cancel: &AtomicBool,
) -> Result<()> {
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
        return Err(anyhow!(
            "Ask needs the Think model. Download it in Settings → Models, then ask again."
        ));
    }
    progress("", &[], Some("Preparing the assistant".into()));
    let think = shared.think(&settings)?;

    let mut conversation = library
        .conversations()?
        .into_iter()
        .find(|c| c.id == conversation_id)
        .unwrap_or_else(|| Conversation {
            id: conversation_id,
            title: title_for(question),
            created_at: lokalbot_core::time::now_seconds(),
            updated_at: lokalbot_core::time::now_seconds(),
            messages: Vec::new(),
        });
    let history = conversation.messages.clone();

    let mut text = String::new();
    let mut activity: Vec<String> = Vec::new();
    let mut last_emit = Instant::now() - Duration::from_secs(1);
    let scope = lokalbot_ai::ask::AskScope {
        meeting_ids: scope.meeting_ids.clone(),
        since: scope.since,
        until: scope.until,
        include_meetings: scope.include_meetings,
        include_screen: scope.include_screen,
        include_activity: scope.include_activity,
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
            &history,
            &scope,
            cancel,
            &mut on_event,
        )?
    } else {
        lokalbot_ai::ask::answer(
            &think,
            library,
            question,
            &history,
            &scope,
            cancel,
            &mut on_event,
        )?
    };

    conversation.messages.push(ChatMessage {
        id: Uuid::new_v4(),
        role: ChatRole::User,
        text: question.to_string(),
        activity: Vec::new(),
        created_at: Some(lokalbot_core::time::now_seconds()),
    });
    let mut reply = reply;
    if cancel.load(Ordering::Relaxed) && !reply.text.is_empty() {
        reply.text.push_str("\n\n_Response stopped._");
    }
    conversation.messages.push(reply);
    conversation.updated_at = lokalbot_core::time::now_seconds();
    library.save_conversation(&conversation)?;
    Ok(())
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
