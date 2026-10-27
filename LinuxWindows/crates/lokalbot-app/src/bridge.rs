//! Connects the window to the background engine: page requests become engine
//! commands, and engine updates land in `AppData`.

use std::sync::Arc;
use std::time::{Duration, Instant};

use gpui_kit::{App, Context, Entity, Global, SharedString};
use lokalbot_engine::{
    AskUpdate, BackgroundKind as EngineBackgroundKind, Command, DictationCommand, DictationUpdate,
    Engine, EngineEvent, FollowUpUpdate, RecordingUpdate, Stage,
};

use crate::state::{
    AppData, AppEvent, AskStream, BackgroundItem, BackgroundKind, DictationHud, DownloadProgress,
    FollowUpWriting, ModelStatus, ProcessingStage, RecordingState,
};

pub struct EngineHandle(pub Arc<Engine>);

impl Global for EngineHandle {}

pub fn send(command: Command, cx: &App) {
    if let Some(engine) = cx.try_global::<EngineHandle>() {
        engine.0.send(command);
    }
}

/// Starts the engine and forwards its events into `data` on the UI thread.
pub fn start(data: &Entity<AppData>, cx: &mut App) -> anyhow::Result<()> {
    let (library, settings) = {
        let data = data.read(cx);
        (data.library.clone(), data.settings.clone())
    };
    let (sender, receiver) = smol::channel::unbounded::<EngineEvent>();
    let engine = Engine::start(library, settings, move |event| {
        let _ = sender.send_blocking(event);
    })?;
    cx.set_global(EngineHandle(Arc::new(engine)));
    let data = data.clone();
    cx.spawn(async move |cx| {
        while let Ok(event) = receiver.recv().await {
            cx.update(|cx| {
                data.update(cx, |data, cx| apply(data, event, cx));
                crate::hud::sync(cx);
            });
        }
    })
    .detach();
    Ok(())
}

/// Turns a page request into an engine command. Returns false for requests
/// the app handles itself.
pub fn handle_request(event: &AppEvent, cx: &mut App) -> bool {
    let command = match event {
        AppEvent::StartRecording => Command::StartRecording {
            title: None,
            app_name: None,
        },
        AppEvent::StopRecording => Command::StopRecording,
        AppEvent::ProcessMeeting {
            meeting_id,
            transcribe,
            summarize,
        } => Command::ProcessMeeting {
            meeting_id: *meeting_id,
            transcribe: *transcribe,
            summarize: *summarize,
        },
        AppEvent::RegenerateDigest(day) => Command::RegenerateDigest(*day),
        AppEvent::AskQuestion {
            conversation_id,
            question,
            scope,
        } => Command::Ask {
            conversation_id: *conversation_id,
            question: question.clone(),
            scope: lokalbot_engine::AskScope {
                meeting_ids: scope.meeting_ids.clone(),
                include_meetings: scope.include_meetings,
                include_activity: scope.include_activity,
                include_screen: scope.include_screen,
                since: scope.since,
                until: scope.until,
            },
        },
        AppEvent::StopAnswer => Command::StopAnswer,
        AppEvent::DownloadModel(id) => Command::DownloadModel(id.clone()),
        AppEvent::CancelDownload(id) => Command::CancelDownload(id.clone()),
        AppEvent::DeleteModel(id) => Command::DeleteModel(id.clone()),
        AppEvent::PrepareModels => Command::PrepareModels,
        AppEvent::SetDayMemoryPaused(paused) => Command::SetDayMemoryPaused(*paused),
        AppEvent::WriteProjectNote(id) => Command::WriteProjectNote(id.clone()),
        AppEvent::WriteFollowUp(meeting_id) => Command::WriteFollowUp(*meeting_id),
        AppEvent::LivePreview(command) => Command::LivePreview(*command),
        AppEvent::ToggleDictation => Command::Dictation(DictationCommand::Toggle),
        AppEvent::CancelDictation => Command::Dictation(DictationCommand::Cancel),
        AppEvent::CaptureScreenNow => Command::CaptureScreenNow,
        AppEvent::RecordCalendarEvent(event) => Command::RecordCalendarEvent(event.clone()),
        AppEvent::SetCalendarLinks(links) => Command::SetCalendarLinks(links.clone()),
        AppEvent::RefreshCalendar => Command::RefreshCalendar,
        AppEvent::PrepareMeeting { event, generate } => Command::PrepareMeeting {
            event: event.clone(),
            generate: *generate,
        },
        AppEvent::SettingsChanged => {
            let settings = AppData::global(cx).read(cx).settings.clone();
            Command::UpdateSettings(Box::new(settings))
        }
        _ => return false,
    };
    send(command, cx);
    true
}

fn apply(data: &mut AppData, event: EngineEvent, cx: &mut Context<AppData>) {
    match event {
        EngineEvent::Recording(update) => match update {
            RecordingUpdate::Started {
                meeting,
                has_system_audio,
            } => {
                data.recording = RecordingState::Recording {
                    meeting,
                    started: Instant::now(),
                    has_system_audio,
                    mic_level: 0.0,
                    system_level: 0.0,
                };
                data.recording_statuses = Some((
                    "Waiting for audio".into(),
                    if has_system_audio {
                        "Waiting for audio".into()
                    } else {
                        "Not attached".into()
                    },
                ));
                data.reload(cx);
            }
            RecordingUpdate::Levels {
                mic,
                system,
                mic_status,
                system_status,
                ..
            } => {
                if let RecordingState::Recording {
                    mic_level,
                    system_level,
                    ..
                } = &mut data.recording
                {
                    *mic_level = mic;
                    *system_level = system;
                }
                data.recording_statuses = Some((mic_status.into(), system_status.into()));
            }
            RecordingUpdate::Stopped { warnings, .. } => {
                if let RecordingState::Recording {
                    meeting, started, ..
                } = &data.recording
                {
                    let minutes = (started.elapsed().as_secs_f64() / 60.0).round().max(1.0) as u64;
                    crate::desktop::notify_recording_saved(meeting.display_title(), minutes);
                }
                data.recording = RecordingState::Idle;
                data.recording_statuses = None;
                if let Some(first) = warnings.first() {
                    data.show_error(first.clone(), cx);
                }
                data.reload(cx);
            }
            RecordingUpdate::Failed { message } => {
                data.recording = RecordingState::Idle;
                data.show_error(message, cx);
            }
        },
        EngineEvent::Processing { meeting_id, stage } => match stage {
            Some(stage) => {
                data.processing.insert(meeting_id, convert_stage(stage));
            }
            None => {
                data.processing.remove(&meeting_id);
            }
        },
        EngineEvent::LibraryChanged => data.reload(cx),
        EngineEvent::Ask(update) => match update {
            AskUpdate::Progress {
                conversation_id,
                question,
                text,
                activity,
                status,
            } => {
                data.ask_stream = Some(AskStream {
                    conversation_id,
                    question,
                    text,
                    activity,
                    status: status.map(SharedString::from),
                    error: None,
                });
            }
            AskUpdate::Finished { .. } => {
                data.ask_stream = None;
                data.revision += 1;
            }
            AskUpdate::Failed {
                conversation_id,
                message,
            } => {
                let question = data
                    .ask_stream
                    .as_ref()
                    .map(|s| s.question.clone())
                    .unwrap_or_default();
                data.ask_stream = Some(AskStream {
                    conversation_id,
                    question,
                    text: String::new(),
                    activity: Vec::new(),
                    status: None,
                    error: Some(message.into()),
                });
            }
        },
        EngineEvent::Download(update) => {
            if update.finished {
                data.downloads.remove(&update.id);
                data.sample_models_changed(cx);
            } else if let Some(error) = update.error {
                data.downloads.insert(
                    update.id,
                    DownloadProgress {
                        done_bytes: 0,
                        total_bytes: 0,
                        error: Some(error.into()),
                    },
                );
            } else {
                data.downloads.insert(
                    update.id,
                    DownloadProgress {
                        done_bytes: update.done_bytes,
                        total_bytes: update.total_bytes,
                        error: None,
                    },
                );
            }
        }
        EngineEvent::Models(status) => {
            data.models = ModelStatus {
                installed: status.installed,
                transcription_ready: status.transcription_ready,
                think_ready: status.think_ready,
                autocomplete_ready: status.autocomplete_ready,
                embeddings_ready: status.embeddings_ready,
                screen_text_ready: status.screen_text_ready,
                runtime_backend: status.runtime_backend.map(SharedString::from),
                runtime_needs_check: status.runtime_needs_check,
                runtime_storage: status.runtime_storage,
            };
            data.sample_models_changed(cx);
        }
        EngineEvent::Digest { running } => data.digest_running = running,
        EngineEvent::ProjectNote {
            project_id,
            running,
        } => {
            data.project_notes_running.retain(|id| id != &project_id);
            if running {
                data.project_notes_running.push(project_id);
            }
        }
        EngineEvent::Background(items) => {
            data.background = items
                .into_iter()
                .map(|item| BackgroundItem {
                    id: item.id.into(),
                    kind: match item.kind {
                        EngineBackgroundKind::Meeting => BackgroundKind::Meeting,
                        EngineBackgroundKind::Digest => BackgroundKind::Digest,
                        EngineBackgroundKind::Download => BackgroundKind::Download,
                        EngineBackgroundKind::Reindex => BackgroundKind::Reindex,
                    },
                    title: item.title.into(),
                    detail: item.detail.into(),
                    progress: item.progress,
                })
                .collect();
        }
        EngineEvent::Message { text, is_error } => {
            if is_error {
                data.show_error(text, cx);
            } else {
                data.show_message(text, cx);
            }
        }
        EngineEvent::MeetingDetected { app_name, title } => {
            cx.emit(AppEvent::MeetingDetected { app_name, title });
        }
        EngineEvent::Autocomplete(update) => crate::autocomplete::engine_update(update, cx),
        EngineEvent::LivePreview(preview) => data.live_preview = preview,
        EngineEvent::Screen(status) => data.screen = status,
        EngineEvent::Calendar(snapshot) => data.calendar = snapshot,
        EngineEvent::RecentDictations(entries) => data.recent_dictations = entries,
        EngineEvent::MeetingPreparation(preparation) => {
            data.meeting_preparation = Some(preparation)
        }
        EngineEvent::FollowUp(update) => {
            data.follow_up = Some(match update {
                FollowUpUpdate::Writing { meeting_id } => (meeting_id, FollowUpWriting::Writing),
                FollowUpUpdate::Written {
                    meeting_id,
                    subject,
                    body,
                    model,
                } => (
                    meeting_id,
                    FollowUpWriting::Written {
                        subject: subject.into(),
                        body: body.into(),
                        model: model.into(),
                    },
                ),
                FollowUpUpdate::Failed {
                    meeting_id,
                    message,
                } => (meeting_id, FollowUpWriting::Failed(message.into())),
            });
        }
        EngineEvent::Dictation(update) => {
            data.dictation = match update {
                DictationUpdate::Starting => DictationHud::Starting,
                DictationUpdate::Listening {
                    level,
                    elapsed_seconds,
                    ..
                } => DictationHud::Listening {
                    level,
                    elapsed: elapsed_seconds,
                },
                DictationUpdate::Transcribing => DictationHud::Transcribing,
                DictationUpdate::Composing => DictationHud::Composing,
                DictationUpdate::Finished { text, notice, .. } => {
                    data.last_dictation = Some(text.into());
                    schedule_hud_dismiss(
                        cx,
                        Duration::from_millis(if notice.is_some() { 2600 } else { 0 }),
                    );
                    match notice {
                        Some(notice) => DictationHud::Notice(notice.into()),
                        None => DictationHud::Idle,
                    }
                }
                DictationUpdate::Failed { message } => {
                    schedule_hud_dismiss(cx, Duration::from_secs(4));
                    DictationHud::Failed(message.into())
                }
                DictationUpdate::Cancelled => DictationHud::Idle,
            };
        }
    }
    cx.notify();
}

fn schedule_hud_dismiss(cx: &mut Context<AppData>, after: Duration) {
    cx.spawn(async move |this, cx| {
        smol::Timer::after(after).await;
        let _ = this.update(cx, |data, cx| {
            if matches!(
                data.dictation,
                DictationHud::Notice(_) | DictationHud::Failed(_)
            ) {
                data.dictation = DictationHud::Idle;
                cx.notify();
            }
        });
        cx.update(crate::hud::sync);
    })
    .detach();
}

fn convert_stage(stage: Stage) -> ProcessingStage {
    match stage {
        Stage::Queued => ProcessingStage::Queued,
        Stage::WaitingForModels => ProcessingStage::WaitingForModels,
        Stage::PreparingModel(name) => ProcessingStage::PreparingModel(name.into()),
        Stage::Transcribing => ProcessingStage::Transcribing,
        Stage::IdentifyingSpeakers => ProcessingStage::IdentifyingSpeakers,
        Stage::Summarizing => ProcessingStage::Summarizing,
        Stage::Failed(message) => ProcessingStage::Failed(message.into()),
    }
}
