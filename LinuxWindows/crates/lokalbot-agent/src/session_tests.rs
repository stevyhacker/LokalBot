//! Controller behavior (`AgentSessionControllerTests.swift`), driven through
//! a fake launcher and transport: no process, model or network.

use std::sync::Arc;

use parking_lot::{Mutex, RwLock};
use serde_json::Value;

use super::*;
use crate::endpoint::{Destination, ProviderApi, ReasoningDialect};
use crate::rpc::tests::RecordingTransport;
use crate::rpc::{LineTransport, REQUEST_TIMEOUT};

struct FakeLauncher {
    transport: Arc<RecordingTransport>,
    requests: Mutex<Vec<LaunchRequest>>,
    clients: Mutex<Vec<RpcClient<RequestTag>>>,
    failure: Mutex<Option<LaunchError>>,
    /// Keep `done` until the test releases it (a slow model warm-up).
    hold: Mutex<bool>,
    held: Mutex<Vec<Box<dyn FnOnce() + Send>>>,
    /// Launches as if through a plan relay.
    plan: Mutex<Option<SubscriptionPlan>>,
}

impl Launcher for FakeLauncher {
    fn launch(
        &self,
        request: LaunchRequest,
        sink: Sink<RequestTag>,
        done: Box<dyn FnOnce(Result<Launched, LaunchError>) + Send>,
    ) {
        self.requests.lock().push(request);
        if let Some(error) = self.failure.lock().clone() {
            done(Err(error));
            return;
        }
        let client = RpcClient::new(sink, REQUEST_TIMEOUT);
        client.attach(self.transport.clone() as Arc<dyn LineTransport>);
        self.clients.lock().push(client.clone());
        let launched = Launched {
            client,
            process: None,
            lease: None,
            relay: None,
            capability: None,
            endpoint: LlmEndpoint {
                base_url: "http://127.0.0.1:17872/v1".into(),
                model: "qwen3.5-4b".into(),
                context_tokens: 32_768,
                api_key: None,
                reasoning_dialect: ReasoningDialect::LlamaServer,
                api: ProviderApi::ChatCompletions,
                plan: *self.plan.lock(),
            },
            reports_session_file: false,
        };
        if *self.hold.lock() {
            self.held.lock().push(Box::new(move || done(Ok(launched))));
        } else {
            done(Ok(launched));
        }
    }
}

struct Harness {
    env: Arc<AgentEnvironment>,
    launcher: Arc<FakeLauncher>,
    rx: async_channel::Receiver<TaskInput>,
    tx: Inbox,
    session: AgentSession,
    /// Dropped last: Windows can't remove the library while it is open.
    _dir: tempfile::TempDir,
}

impl Harness {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let root = dunce::canonicalize(dir.path()).unwrap().join("LokalBot");
        let paths = lokalbot_core::LibraryPaths::new(&root);
        let library = Library::open(paths.clone()).unwrap();
        let launcher = Arc::new(FakeLauncher {
            transport: Arc::new(RecordingTransport::default()),
            requests: Mutex::new(Vec::new()),
            clients: Mutex::new(Vec::new()),
            failure: Mutex::new(None),
            hold: Mutex::new(false),
            held: Mutex::new(Vec::new()),
            plan: Mutex::new(None),
        });
        let env = Arc::new(AgentEnvironment {
            library,
            dirs: AgentDirectories::new(&paths),
            layout: RuntimeLayout::for_library(&paths),
            settings: Arc::new(RwLock::new(Settings::default())),
            launcher: launcher.clone(),
        });
        let (tx, rx) = async_channel::unbounded();
        let session = AgentSession::new(env.clone(), Uuid::new_v4(), tx.clone());
        Self {
            env,
            launcher,
            rx,
            tx,
            session,
            _dir: dir,
        }
    }

    fn another_session(&self) -> AgentSession {
        AgentSession::new(self.env.clone(), Uuid::new_v4(), self.tx.clone())
    }

    fn pump(&mut self) {
        // Responses can arrive from the timeout thread; give it a moment.
        std::thread::sleep(std::time::Duration::from_millis(5));
        while let Ok(input) = self.rx.try_recv() {
            self.session.handle(input.generation, input.input);
        }
    }

    fn start(&mut self) {
        self.session.start();
        self.pump();
        assert_eq!(self.session.state, SessionState::Ready);
    }

    fn client(&self) -> RpcClient<RequestTag> {
        self.launcher.clients.lock().last().unwrap().clone()
    }

    fn event(&mut self, line: &str) {
        self.client().handle_line(line);
        self.pump();
    }

    fn lines(&self) -> Vec<Value> {
        self.launcher
            .transport
            .lines
            .lock()
            .iter()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect()
    }

    fn last_line(&self) -> Value {
        self.lines().pop().unwrap()
    }

    /// Acknowledges the newest request that has an id.
    fn ack(&mut self, success: bool) {
        let line = self
            .lines()
            .into_iter()
            .rev()
            .find(|l| l.get("type").and_then(|t| t.as_str()) != Some("extension_ui_response"))
            .unwrap();
        let id = line["id"].as_str().unwrap().to_string();
        let command = line["type"].as_str().unwrap().to_string();
        let response = if success {
            format!(r#"{{"id":"{id}","type":"response","command":"{command}","success":true}}"#)
        } else {
            format!(
                r#"{{"id":"{id}","type":"response","command":"{command}","success":false,"error":"rejected by pi"}}"#
            )
        };
        self.event(&response);
    }

    fn confirm(&mut self, id: &str, payload: Value) {
        let message = serde_json::to_string(&payload.to_string()).unwrap();
        self.event(&format!(
            r#"{{"type":"extension_ui_request","id":"{id}","method":"confirm","title":"lokalbot_tool_approval","message":{message}}}"#
        ));
    }

    fn workspace(&self) -> String {
        self.session.workspace.to_string_lossy().into_owned()
    }

    fn send(&mut self, text: &str) {
        self.session.draft = text.into();
        self.session.submit(false);
        self.pump();
    }
}

fn file_payload(tool: &str, workspace: &str, path: &str) -> Value {
    serde_json::json!({"tool": tool, "workspace": workspace, "path": path, "content": "x", "truncated": false})
}

#[test]
fn start_reaches_ready_in_the_dedicated_workspace_with_the_library_protected() {
    let mut h = Harness::new();
    h.start();
    let request = h.launcher.requests.lock()[0].clone();
    assert_eq!(request.workspace, h.env.dirs.default_workspace());
    assert!(request.workspace.is_dir());
    assert!(
        request
            .private_roots
            .contains(&h.env.dirs.library_root().to_path_buf())
    );
    assert_eq!(request.session, SessionChoice::Fresh);
    assert_eq!(h.session.workspace_display_name(), "Agent Workspace");
}

#[test]
fn private_library_workspace_cannot_launch() {
    let mut h = Harness::new();
    h.session.workspace = h.env.dirs.library_root().join("meetings");
    h.session.start();
    h.pump();
    assert_eq!(h.session.state, SessionState::Idle);
    assert!(h.launcher.requests.lock().is_empty());
    assert_eq!(
        h.session.composer_error.as_deref(),
        Some(PRIVATE_WORKSPACE_NOTICE)
    );
    assert_eq!(
        h.session.workspace_display_name(),
        "Private Library · read-only"
    );
}

#[test]
fn unsupported_backend_fails_without_spawning_and_points_to_models() {
    let mut h = Harness::new();
    *h.launcher.failure.lock() = Some(LaunchError::Configuration("Pick a model".into()));
    h.session.start();
    h.pump();
    assert_eq!(h.session.state, SessionState::Failed("Pick a model".into()));
    assert_eq!(h.session.recovery_action, Some(RecoveryAction::OpenModels));
}

#[test]
fn a_plan_task_checks_the_plans_approval_before_each_message() {
    let mut h = Harness::new();
    let plan = SubscriptionPlan::ChatGpt;
    plan.set_approved(&mut h.env.settings.write(), true);
    *h.launcher.plan.lock() = Some(plan);
    h.start();
    assert_eq!(
        h.session.presented_model().destination,
        Destination::Remote("ChatGPT plan".into()),
        "the relay listens here, but OpenAI answers"
    );
    plan.set_approved(&mut h.env.settings.write(), false);
    let sent = h.lines().len();
    h.send("Summarize my day");
    assert_eq!(
        h.session.composer_error,
        Some(plan.approval_required_message())
    );
    assert_eq!(h.lines().len(), sent, "nothing reaches pi");
    plan.set_approved(&mut h.env.settings.write(), true);
    h.send("Summarize my day");
    assert_eq!(h.last_line()["type"], "prompt");
}

#[test]
fn submit_starts_then_sends_and_streams_the_answer() {
    let mut h = Harness::new();
    h.send("Draft a follow-up from my last meeting");
    assert_eq!(h.session.state, SessionState::Running);
    assert!(h.session.draft.is_empty());
    let prompt = h.last_line();
    assert_eq!(prompt["type"], "prompt");
    assert_eq!(prompt["message"], "Draft a follow-up from my last meeting");
    assert_eq!(
        h.session.session_title.as_deref(),
        Some("Draft a follow-up from my last…")
    );
    h.ack(true);
    h.event(r#"{"type":"agent_start"}"#);
    h.event(r#"{"type":"message_start","message":{"role":"assistant"}}"#);
    h.event(r#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"Hello"}}"#);
    h.event(r#"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Hello there"}]}}"#);
    h.event(r#"{"type":"agent_settled"}"#);
    assert_eq!(h.session.state, SessionState::Ready);
    assert!(
        matches!(&h.session.items()[1], TranscriptItem::Assistant { text, is_streaming: false, .. } if text == "Hello there")
    );
    assert!(h.session.requires_close_confirmation());
}

#[test]
fn confirm_request_raises_a_card_and_replies() {
    let mut h = Harness::new();
    h.start();
    let ws = h.workspace();
    let path = format!("{ws}/hello.txt");
    h.confirm("uuid-1", file_payload("write", &ws, &path));
    assert_eq!(h.session.pending_approvals().len(), 1);
    assert_eq!(h.session.task_status(), "Needs approval");
    assert!(
        h.session
            .can_allow_for_session(h.session.pending_approvals()[0])
    );
    h.session
        .respond_to_approval("uuid-1", true, ApprovalScope::Once);
    let reply = h.last_line();
    assert_eq!(reply["type"], "extension_ui_response");
    assert_eq!(reply["id"], "uuid-1");
    assert_eq!(reply["confirmed"], true);
    assert!(h.session.pending_approvals().is_empty());
}

#[test]
fn denial_is_sent_and_leaves_a_notice() {
    let mut h = Harness::new();
    h.start();
    let ws = h.workspace();
    h.confirm("uuid-2", file_payload("write", &ws, &format!("{ws}/a.txt")));
    h.session
        .respond_to_approval("uuid-2", false, ApprovalScope::Once);
    assert_eq!(h.last_line()["confirmed"], false);
    assert!(h.session.items().iter().any(|i| matches!(i, TranscriptItem::Notice { text, .. } if text == "You denied this write request. Nothing changed.")));
}

#[test]
fn session_scope_auto_approves_repeats_inside_the_workspace() {
    let mut h = Harness::new();
    h.start();
    let ws = h.workspace();
    h.confirm("w1", file_payload("write", &ws, &format!("{ws}/a.txt")));
    h.session
        .respond_to_approval("w1", true, ApprovalScope::Session);
    h.confirm("w2", file_payload("write", &ws, &format!("{ws}/b.txt")));
    assert!(h.session.pending_approvals().is_empty());
    assert_eq!(h.last_line()["id"], "w2");
    assert_eq!(h.last_line()["confirmed"], true);
    // A different tool still asks.
    h.confirm("e1", file_payload("edit", &ws, &format!("{ws}/b.txt")));
    assert_eq!(h.session.pending_approvals().len(), 1);
}

#[test]
fn read_mode_approves_reads_but_shows_changes_and_shell() {
    let mut h = Harness::new();
    h.start();
    h.session.set_approval_mode(ApprovalMode::ApproveReads);
    let ws = h.workspace();
    h.confirm(
        "r1",
        serde_json::json!({"tool": "read", "workspace": ws, "path": "/etc/hostname"}),
    );
    assert_eq!(h.last_line()["confirmed"], true);
    h.confirm("w1", file_payload("write", &ws, &format!("{ws}/a.txt")));
    h.confirm(
        "b1",
        serde_json::json!({"tool": "bash", "workspace": ws, "command": "ls"}),
    );
    assert_eq!(h.session.pending_approvals().len(), 2);
    // Widening the mode answers the cards it now allows, but never bash.
    h.session
        .set_approval_mode(ApprovalMode::ApproveReadsAndEdits);
    let pending: Vec<String> = h
        .session
        .pending_approvals()
        .iter()
        .map(|r| r.tool.clone())
        .collect();
    assert_eq!(pending, vec!["bash"]);
    assert!(
        !h.session
            .can_allow_for_session(h.session.pending_approvals()[0])
    );
}

#[test]
fn approval_mode_survives_close_and_applies_to_new_tasks() {
    let mut h = Harness::new();
    h.start();
    h.session.set_approval_mode(ApprovalMode::FullAccess);
    h.session.shutdown();
    assert_eq!(h.session.approval_mode(), ApprovalMode::FullAccess);
    assert_eq!(
        h.another_session().approval_mode(),
        ApprovalMode::FullAccess
    );
    h.session.set_approval_mode(ApprovalMode::AskBeforeChanges);
    assert_eq!(
        h.another_session().approval_mode(),
        ApprovalMode::AskBeforeChanges
    );
}

#[test]
fn incomplete_shell_requests_are_declined_even_with_full_access() {
    let mut h = Harness::new();
    h.start();
    h.session.set_approval_mode(ApprovalMode::FullAccess);
    let ws = h.workspace();
    h.confirm(
        "b1",
        serde_json::json!({"tool": "bash", "workspace": ws, "command": "ls", "truncated": true}),
    );
    assert_eq!(h.last_line()["confirmed"], false);
    assert!(h.session.items().iter().any(|i| matches!(i, TranscriptItem::Notice { text, is_error: true, .. } if text.starts_with("The shell command could not be reviewed"))));
    h.confirm(
        "b2",
        serde_json::json!({"tool": "bash", "workspace": ws, "command": "ls"}),
    );
    assert_eq!(h.last_line()["confirmed"], true);
}

#[test]
fn other_tools_show_their_arguments_and_ask_outside_full_access() {
    let mut h = Harness::new();
    h.start();
    let ws = h.workspace();
    h.confirm("m1", serde_json::json!({"tool": "mcp__stub__touch", "workspace": ws, "arguments": "{\n  \"path\": \"x\"\n}"}));
    let pending = h.session.pending_approvals();
    assert_eq!(
        pending[0].arguments.as_deref(),
        Some("{\n  \"path\": \"x\"\n}")
    );
    h.session
        .respond_to_approval("m1", true, ApprovalScope::Once);
    h.session.set_approval_mode(ApprovalMode::FullAccess);
    let long = "x".repeat(70_000);
    h.confirm(
        "m2",
        serde_json::json!({"tool": "codemode", "workspace": ws, "arguments": long}),
    );
    assert_eq!(h.last_line()["confirmed"], false);
}

#[test]
fn unsupported_interactions_are_declined() {
    let mut h = Harness::new();
    h.start();
    h.event(r#"{"type":"extension_ui_request","id":"s1","method":"select","title":"Pick"}"#);
    assert_eq!(h.last_line()["cancelled"], true);
}

#[test]
fn transport_death_fails_the_session_with_the_stderr_tail() {
    let mut h = Harness::new();
    h.start();
    h.client().handle_close(vec!["fatal: out of memory".into()]);
    h.pump();
    let SessionState::Failed(message) = &h.session.state else {
        panic!("expected failure, got {:?}", h.session.state);
    };
    assert!(message.starts_with("The agent process exited unexpectedly."));
    assert!(message.contains("out of memory"));
    assert_eq!(h.session.recovery_action, Some(RecoveryAction::Restart));
    // Restart launches a fresh process.
    h.session.start();
    h.pump();
    assert_eq!(h.session.state, SessionState::Ready);
    assert_eq!(h.launcher.requests.lock().len(), 2);
}

#[test]
fn queued_follow_up_waits_for_the_turn_then_goes_as_an_ordinary_prompt() {
    let mut h = Harness::new();
    h.send("first");
    h.ack(true);
    h.event(r#"{"type":"agent_start"}"#);
    h.session.draft = "second".into();
    h.session.submit(false);
    assert_eq!(h.session.queued_prompts.len(), 1);
    let prompts_before = h.lines().iter().filter(|l| l["type"] == "prompt").count();
    h.event(r#"{"type":"agent_settled"}"#);
    let prompts: Vec<Value> = h
        .lines()
        .into_iter()
        .filter(|l| l["type"] == "prompt")
        .collect();
    assert_eq!(prompts.len(), prompts_before + 1);
    assert_eq!(prompts.last().unwrap()["message"], "second");
    assert!(prompts.last().unwrap().get("streamingBehavior").is_none());
    assert!(h.session.queued_prompts.is_empty());
}

#[test]
fn steering_uses_the_native_steer_command() {
    let mut h = Harness::new();
    h.send("first");
    h.ack(true);
    h.event(r#"{"type":"agent_start"}"#);
    h.session.draft = "change course".into();
    h.session.submit(true);
    let line = h.last_line();
    assert_eq!(line["type"], "steer");
    assert_eq!(line["message"], "change course");
}

#[test]
fn terminal_provider_failure_pauses_the_queue() {
    let mut h = Harness::new();
    h.send("first");
    h.ack(true);
    h.event(r#"{"type":"agent_start"}"#);
    h.session.draft = "second".into();
    h.session.submit(false);
    h.event(r#"{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"502 Bad Gateway"}}"#);
    h.event(r#"{"type":"agent_settled"}"#);
    assert_eq!(h.session.turn_error.as_deref(), Some("502 Bad Gateway"));
    assert!(h.session.queue_is_paused);
    assert_eq!(h.session.queued_prompts.len(), 1);
    assert_eq!(h.session.failed_prompt.as_ref().unwrap().text, "first");
    assert_eq!(h.session.task_status(), "Needs attention");
}

#[test]
fn send_next_resumes_a_paused_queue() {
    let mut h = Harness::new();
    h.send("first");
    h.ack(true);
    h.event(r#"{"type":"agent_start"}"#);
    h.session.draft = "second".into();
    h.session.submit(false);
    h.event(r#"{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"502 Bad Gateway"}}"#);
    h.event(r#"{"type":"agent_settled"}"#);
    assert!(h.session.queue_is_paused);
    h.session.send_next_queued();
    h.pump();
    assert!(!h.session.queue_is_paused);
    assert!(h.session.queued_prompts.is_empty());
    let line = h.last_line();
    assert_eq!(line["type"], "prompt");
    assert_eq!(line["message"], "second");
}

#[test]
fn send_next_starts_an_idle_task_and_delivers_its_restored_queue() {
    let mut h = Harness::new();
    h.session
        .restore_queue(vec![crate::tasks::QueuedPrompt::new(
            "restored follow-up",
            Vec::new(),
        )]);
    assert!(h.session.queue_is_paused);
    h.session.send_next_queued();
    h.pump();
    assert!(h.session.queued_prompts.is_empty());
    let line = h.last_line();
    assert_eq!(line["type"], "prompt");
    assert_eq!(line["message"], "restored follow-up");
}

#[test]
fn stop_cancels_pending_approvals_before_aborting_and_keeps_follow_ups() {
    let mut h = Harness::new();
    h.send("first");
    h.ack(true);
    h.event(r#"{"type":"agent_start"}"#);
    let ws = h.workspace();
    h.confirm("w1", file_payload("write", &ws, &format!("{ws}/a.txt")));
    h.session.draft = "later".into();
    h.session.submit(false);
    h.session.abort();
    let lines = h.lines();
    let cancel = lines.iter().position(|l| l["cancelled"] == true).unwrap();
    let abort = lines.iter().position(|l| l["type"] == "abort").unwrap();
    assert!(cancel < abort);
    assert!(h.session.pending_approvals().is_empty());
    assert!(h.session.is_stopping);
    // An approval arriving while stopping is cancelled at once.
    h.confirm("w2", file_payload("write", &ws, &format!("{ws}/b.txt")));
    assert_eq!(h.last_line()["cancelled"], true);
    h.ack(true);
    assert!(!h.session.is_stopping);
    h.event(r#"{"type":"agent_settled"}"#);
    assert_eq!(
        h.session.queued_prompts.len(),
        1,
        "follow-ups stay unsent while paused"
    );
}

#[test]
fn rejected_prompt_stays_available_for_explicit_retry() {
    let mut h = Harness::new();
    h.start();
    h.send("please do it");
    h.ack(false);
    assert_eq!(h.session.state, SessionState::Ready);
    assert_eq!(h.session.composer_error.as_deref(), Some("rejected by pi"));
    assert_eq!(h.session.draft, "please do it", "the draft comes back");
    assert_eq!(
        h.session.failed_prompt.as_ref().unwrap().text,
        "please do it"
    );
}

#[test]
fn duplicate_submission_while_awaiting_acknowledgement_is_not_sent() {
    let mut h = Harness::new();
    h.start();
    h.send("once");
    assert!(h.session.is_sending);
    assert!(!h.session.send("twice", Vec::new(), false, false));
    assert_eq!(
        h.lines().iter().filter(|l| l["type"] == "prompt").count(),
        1
    );
}

#[test]
fn shutdown_during_launch_discards_the_late_launch() {
    let mut h = Harness::new();
    *h.launcher.hold.lock() = true;
    h.session.start();
    assert_eq!(h.session.state, SessionState::Starting);
    h.session.shutdown();
    for release in h.launcher.held.lock().drain(..) {
        release();
    }
    h.pump();
    assert_eq!(h.session.state, SessionState::Idle);
    assert!(h.session.client.is_none());
}

#[test]
fn unsaved_conversation_cannot_be_parked() {
    let mut h = Harness::new();
    h.send("work");
    h.ack(true);
    h.event(r#"{"type":"agent_settled"}"#);
    assert!(
        !h.session.park(),
        "no saved file yet, so parking would lose it"
    );
    assert_eq!(h.session.state, SessionState::Ready);
}

#[test]
fn reasoning_level_is_written_for_the_extension_and_follows_changes() {
    let mut h = Harness::new();
    h.env.settings.write().agent_reasoning_level = Some(ReasoningLevel::Low);
    h.start();
    let read = |h: &Harness| -> String {
        let text = std::fs::read_to_string(h.session.reasoning_level_file()).unwrap();
        serde_json::from_str::<Value>(&text).unwrap()["level"]
            .as_str()
            .unwrap()
            .to_string()
    };
    assert_eq!(read(&h), "low");
    h.env.settings.write().agent_reasoning_level = Some(ReasoningLevel::Max);
    h.session.reasoning_level_did_change();
    // qwen3.5 accepts Off–High: Max clamps to High.
    assert_eq!(read(&h), "high");
    h.session.shutdown();
    assert!(!h.session.reasoning_level_file().exists());
}

#[test]
fn history_restore_rebuilds_the_visible_conversation() {
    let mut h = Harness::new();
    let ws = h.env.dirs.default_workspace();
    std::fs::create_dir_all(h.env.dirs.sessions()).unwrap();
    std::fs::create_dir_all(&ws).unwrap();
    std::fs::write(
        h.env.dirs.sessions().join("s.jsonl"),
        format!(
            "{}\n{}\n",
            serde_json::json!({"type": "session", "id": "s", "cwd": ws.to_string_lossy()}),
            serde_json::json!({"type": "message", "id": "u", "parentId": null, "message": {"role": "user", "content": "old question"}}),
        ),
    )
    .unwrap();
    assert!(h.session.can_resume_previous_session());
    h.session.resume_previous_session();
    h.pump();
    assert_eq!(
        h.session.state,
        SessionState::Starting,
        "waiting for get_messages"
    );
    assert_eq!(
        h.launcher.requests.lock()[0].session,
        SessionChoice::ContinueRecent
    );
    let line = h.last_line();
    assert_eq!(line["type"], "get_messages");
    let id = line["id"].as_str().unwrap().to_string();
    h.event(&format!(
        r#"{{"id":"{id}","type":"response","command":"get_messages","success":true,"data":{{"messages":[{{"role":"user","content":"old question"}},{{"role":"assistant","content":[{{"type":"text","text":"old answer"}}]}}]}}}}"#
    ));
    assert_eq!(h.session.state, SessionState::Ready);
    let texts: Vec<String> = h
        .session
        .items()
        .iter()
        .map(|i| i.searchable_text())
        .collect();
    assert_eq!(
        texts,
        vec![
            "old question",
            "old answer",
            "Resumed the most recent session for this working folder."
        ]
    );
    assert_eq!(h.session.session_title.as_deref(), Some("old question"));
}

#[test]
fn queue_can_be_edited_and_cancelled_before_anything_is_sent() {
    let mut h = Harness::new();
    h.send("first");
    h.ack(true);
    h.event(r#"{"type":"agent_start"}"#);
    h.session.draft = "one".into();
    h.session.submit(false);
    h.session.draft = "two".into();
    h.session.submit(false);
    let first = h.session.queued_prompts[0].id;
    let second = h.session.queued_prompts[1].id;
    h.session.cancel_queued(second);
    h.session.edit_queued(first);
    assert_eq!(h.session.draft, "one");
    assert!(h.session.queued_prompts.is_empty());
    assert_eq!(
        h.lines().iter().filter(|l| l["type"] == "prompt").count(),
        1
    );
}

#[test]
fn session_titles_cut_at_a_word() {
    assert_eq!(make_session_title("Short title\nmore"), "Short title");
    assert_eq!(
        make_session_title("Prepare a concise stand-up update from my recent meetings"),
        "Prepare a concise stand-up update…"
    );
}
