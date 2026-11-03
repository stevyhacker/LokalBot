//! Agents changing settings from the terminal (`Services/AppControl/*`): the
//! control socket, which exists only while the person allows it, the approvals
//! that wait for them, the audit log with Undo, and the agent setup request.
//!
//! Every request re-checks the Privacy marker, so revoking the grant takes
//! effect even for a connection already accepted. The socket has no method that
//! approves anything: [`ControlHost::approve`] is called only from the approval
//! window, by the person.

mod handler;
pub mod permissions;
pub mod setup;
mod wake;

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use chrono::Utc;
use gpui_kit::{App, AppContext as _, Context, Entity, Global, Subscription};
use lokalbot_core::control::approvals::{ApprovalProblem, ApprovalRequest, Approvals, Subject};
use lokalbot_core::control::audit::{self, AgentSettingsChanges, Entry};
use lokalbot_core::control::change::{ChangeClass, ChangePlan, PlanItem, apply_items};
use lokalbot_core::control::encoded;
use lokalbot_core::control::protocol::{AppSecret, ControlError, Request};
use lokalbot_core::control::registry::{self, SettingKind, TextFormat};
use lokalbot_core::control::setup::SetupRequest;
use lokalbot_core::retention::{RetentionReview, RetentionReviewError};
use lokalbot_core::{LibraryPaths, Settings, access};
use lokalbot_platform::control_socket::{ControlServer, Reply, listen_control};
use lokalbot_platform::notify::NotificationHandle;
use lokalbot_platform::shortcuts::Shortcut;
use parking_lot::Mutex;
use serde_json::{Value, json};
use uuid::Uuid;

use crate::pages::settings::model_setup::ModelSetup;
use crate::state::AppData;

/// What reaches the UI thread from the socket and notifications.
pub(crate) enum Incoming {
    Request {
        request: Request,
        caller: String,
        reply: Reply,
    },
    ShowApprovals,
}

pub struct ControlHost {
    pub(crate) data: Entity<AppData>,
    pub(crate) paths: LibraryPaths,
    server: Option<ControlServer>,
    /// "Allow external agents to change LokalBot settings".
    pub enabled: bool,
    pub approvals: Approvals,
    pub changes: AgentSettingsChanges,
    /// The request an agent left with `setup start`.
    pub setup_pending: Option<SetupRequest>,
    /// Bumped when a setup request changes read access, for Settings to reread.
    pub access_generation: u64,
    pub(crate) model_setup: ModelSetup,
    pub(crate) wake: wake::WakeState,
    sender: smol::channel::Sender<Incoming>,
    notifications: Arc<Mutex<HashMap<Uuid, NotificationHandle>>>,
    _quit: Option<Subscription>,
}

pub struct ControlHandle(pub Entity<ControlHost>);

impl Global for ControlHandle {}

pub fn global(cx: &App) -> Option<Entity<ControlHost>> {
    cx.try_global::<ControlHandle>().map(|h| h.0.clone())
}

/// Starts the control host; the socket opens only if the grant is on.
pub fn start(data: &Entity<AppData>, cx: &mut App) {
    let (sender, receiver) = smol::channel::unbounded::<Incoming>();
    let paths = data.read(cx).library.paths().clone();
    let host = cx.new(|cx| {
        let mut host = ControlHost {
            data: data.clone(),
            changes: AgentSettingsChanges::new(&paths),
            enabled: access::settings_control_enabled(&paths),
            paths,
            server: None,
            approvals: Approvals::new(),
            setup_pending: None,
            access_generation: 0,
            model_setup: ModelSetup::default(),
            wake: Default::default(),
            sender,
            notifications: Default::default(),
            // The socket goes when LokalBot quits.
            _quit: Some(cx.on_app_quit(|host: &mut ControlHost, _| {
                host.server = None;
                async {}
            })),
        };
        if host.enabled
            && let Err(err) = host.start_server()
        {
            log::warn!("could not open the settings control socket: {err}");
        }
        host.check_setup(cx);
        host
    });
    cx.set_global(ControlHandle(host.clone()));
    let for_requests = host.clone();
    cx.spawn(async move |cx| {
        while let Ok(incoming) = receiver.recv().await {
            cx.update(|cx| {
                for_requests.update(cx, |host, cx| match incoming {
                    Incoming::Request {
                        request,
                        caller,
                        reply,
                    } => host.handle(request, caller, reply, cx),
                    Incoming::ShowApprovals => {
                        cx.defer(crate::windows::settings_approval::open);
                    }
                });
            });
        }
    })
    .detach();
    // Setup requests, wakes and expiries have no notification to arrive by, so
    // a once-a-second look at two files finds them.
    cx.spawn(async move |cx| {
        loop {
            smol::Timer::after(Duration::from_secs(1)).await;
            cx.update(|cx| host.update(cx, |host, cx| host.tick(cx)));
        }
    })
    .detach();
}

/// True when an agent's setup request waits, which replaces the first-run wizard.
pub fn setup_waiting(cx: &App) -> bool {
    global(cx).is_some_and(|host| host.read(cx).setup_pending.is_some())
}

/// Settings as the app would hold them after `items`, or why not. The values go
/// through the real decoder, and shortcuts and model ids through their checks.
pub(crate) fn checked_apply(
    items: &[PlanItem],
    settings: &Settings,
) -> Result<Settings, ControlError> {
    let updated = apply_items(items, settings, Utc::now())?;
    for item in items {
        let invalid =
            || ControlError::invalid_value(item.spec.key, "isn't a value LokalBot accepts");
        match item.spec.kind {
            SettingKind::Text(TextFormat::Shortcut) => {
                let text = item
                    .stored
                    .as_ref()
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                if Shortcut::parse(text).is_err() {
                    return Err(ControlError::invalid_value(
                        item.spec.key,
                        "isn't a key combination, such as Ctrl+Shift+Space",
                    ));
                }
            }
            SettingKind::Text(TextFormat::ModelId)
                if matches!(item.spec.key, "builtInModelID" | "cotypingBuiltInModelID") =>
            {
                let id = item
                    .stored
                    .as_ref()
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                if lokalbot_ai::catalog::entry(id).is_none() {
                    return Err(invalid());
                }
            }
            _ => {}
        }
    }
    let parse = |text: &str| Shortcut::parse(text).ok();
    let dictation = parse(&updated.dictation_shortcut);
    let quick_recall = parse(&updated.quick_recall_shortcut);
    let selection = parse(&updated.selection_actions_shortcut);
    let touched = |key: &str| items.iter().any(|item| item.spec.key == key);
    if (touched("dictationShortcut") || touched("quickRecallShortcut"))
        && dictation.is_some()
        && dictation == quick_recall
    {
        return Err(ControlError::invalid_value(
            if touched("dictationShortcut") {
                "dictationShortcut"
            } else {
                "quickRecallShortcut"
            },
            "is already used by another LokalBot shortcut",
        ));
    }
    if touched("selectionActionsShortcut")
        && let Some(selection) = selection
        && selection
            .selection_actions_problem(dictation.as_ref(), quick_recall.as_ref())
            .is_some()
    {
        return Err(ControlError::invalid_value(
            "selectionActionsShortcut",
            "is already taken by another shortcut or the system",
        ));
    }
    Ok(updated)
}

impl ControlHost {
    /// Turning the grant on opens the socket; off closes it and denies what waits.
    pub fn set_enabled(&mut self, enabled: bool, cx: &mut Context<Self>) {
        if enabled {
            if let Err(err) = access::set_settings_control(&self.paths, true) {
                self.show_error(
                    lokalbot_i18n::format(
                        "Could not allow settings access: {err}",
                        &[("err", err.to_string())],
                    ),
                    cx,
                );
                return;
            }
            self.enabled = true;
            if let Err(err) = self.start_server() {
                self.show_error(
                    lokalbot_i18n::format(
                        "Could not open the settings control socket: {err}",
                        &[("err", err.to_string())],
                    ),
                    cx,
                );
            }
        } else {
            if let Err(err) = access::set_settings_control(&self.paths, false) {
                self.show_error(
                    lokalbot_i18n::format(
                        "Could not change agent access: {err}",
                        &[("err", err.to_string())],
                    ),
                    cx,
                );
            }
            self.enabled = false;
            self.server = None;
            // Requests already waiting go with the grant.
            for id in self.approvals.deny_all(Utc::now()) {
                self.withdraw(id);
            }
        }
        cx.notify();
    }

    fn start_server(&mut self) -> std::io::Result<()> {
        if self.server.is_none() {
            let sender = self.sender.clone();
            self.server = Some(listen_control(
                self.paths.root(),
                move |request, caller, reply| {
                    let _ = sender.send_blocking(Incoming::Request {
                        request,
                        caller,
                        reply,
                    });
                },
            )?);
        }
        Ok(())
    }

    pub(crate) fn show_error(&self, message: String, cx: &mut Context<Self>) {
        self.data
            .update(cx, |data, cx| data.show_error(message, cx));
    }

    fn tick(&mut self, cx: &mut Context<Self>) {
        let now = Utc::now();
        for id in self.approvals.expire_stale(now) {
            self.withdraw(id);
            cx.notify();
        }
        // The cards count down.
        if !self.approvals.pending.is_empty() {
            cx.notify();
        }
        let data = self.data.clone();
        self.model_setup.poll(&data, cx);
        self.check_setup(cx);
        self.tick_wake(cx);
    }

    /// Tells the person a request is waiting: a notification, or the approval
    /// window when notifications are off, because only the person can answer.
    pub(crate) fn announce(&self, request: &ApprovalRequest) {
        let title = lokalbot_i18n::tr("Approve a settings change?").to_string();
        let body = lokalbot_i18n::format(
            "{caller} asks: {headline}. Review it in LokalBot.",
            &[
                ("caller", request.caller.clone()),
                ("headline", request.headline()),
            ],
        );
        let id = request.id;
        let handles = self.notifications.clone();
        let sender = self.sender.clone();
        std::thread::spawn(move || {
            let clicked = sender.clone();
            let result = lokalbot_platform::notify::notify_with_timeout(
                &title,
                &body,
                &[],
                Some(Box::new(move |action| {
                    if action == "default" {
                        let _ = clicked.send_blocking(Incoming::ShowApprovals);
                    }
                })),
                None,
            );
            match result {
                Ok(handle) => {
                    handles.lock().insert(id, handle);
                }
                Err(err) => {
                    log::debug!("approval notification failed: {err:#}");
                    let _ = sender.send_blocking(Incoming::ShowApprovals);
                }
            }
        });
    }

    /// Removes a request's notification once it is answered or expires.
    pub(crate) fn withdraw(&self, id: Uuid) {
        if let Some(handle) = self.notifications.lock().remove(&id) {
            std::thread::spawn(move || handle.close());
        }
    }

    pub fn deny(&mut self, id: Uuid, cx: &mut Context<Self>) {
        self.approvals.deny(id, Utc::now());
        self.withdraw(id);
        cx.notify();
    }

    /// The person approved a request on its card. A problem stays on the card.
    pub fn approve(&mut self, id: Uuid, cx: &mut Context<Self>) {
        let request = match self.approvals.waiting(id, Utc::now()) {
            Ok(Some(request)) => request,
            Ok(None) => return,
            Err(error) => {
                self.approvals.set_problem(id, error.message);
                cx.notify();
                return;
            }
        };
        match &request.subject {
            Subject::Secret(secret, value) => {
                let (secret, value) = (*secret, value.expose().to_string());
                let caller = request.caller.clone();
                cx.spawn(async move |this, cx| {
                    let saved = cx
                        .background_spawn(async move { save_secret(secret, &value) })
                        .await;
                    let _ = this.update(cx, |host, cx| {
                        match saved {
                            Ok(()) => {
                                host.secret_changed(secret, true, &caller, cx);
                                host.approvals.finish_approved(
                                    id,
                                    json!({"applied": true, "secret": secret.raw_value()}),
                                    Utc::now(),
                                );
                                host.withdraw(id);
                            }
                            Err(err) => host.approvals.set_problem(id, err.to_string()),
                        }
                        cx.notify();
                    });
                })
                .detach();
            }
            Subject::Settings(_) => {
                if let Err(problem) = self.approve_settings(&request, cx) {
                    let shown = problem.to_string();
                    self.approvals.set_problem(id, shown);
                }
                cx.notify();
            }
        }
    }

    /// Applies the changes an approved card showed to the settings as they are
    /// now. Settings the request left as they were stay as the person has them
    /// since. When approving would widen more than the card showed, or a shorter
    /// retention policy would delete more than its review, the card gets the new
    /// changes and keeps waiting.
    fn approve_settings(
        &mut self,
        request: &ApprovalRequest,
        cx: &mut Context<Self>,
    ) -> Result<(), ApprovalProblem> {
        let settings = self.data.read(cx).settings.clone();
        let plan = ChangePlan::rebasing(&request.items, &encoded(&settings));
        let read_only: Vec<&str> = plan.read_only().iter().map(|i| i.spec.key).collect();
        if !read_only.is_empty() {
            return Err(ApprovalProblem::Control(ControlError::read_only(
                &read_only,
            )));
        }
        let items = plan.changed();
        // Check every value before anything is deleted.
        checked_apply(&items, &settings).map_err(ApprovalProblem::Control)?;
        let needed = self
            .retention_review(&items, &settings, cx)
            .map_err(|err| ApprovalProblem::Retry(format!("{err:#}")))?;
        if plan.widens_beyond(&request.items) {
            let keys: Vec<&str> = items.iter().map(|i| i.spec.key).collect();
            let changes: Vec<Value> = plan
                .entries()
                .into_iter()
                .filter(|entry| entry["key"].as_str().is_some_and(|key| keys.contains(&key)))
                .collect();
            self.approvals.update(request.id, |pending| {
                pending.items = items.clone();
                pending.changes = changes;
                pending.retention = needed.clone();
            });
            return Err(ApprovalProblem::Retry(
                lokalbot_core::control::approvals::CHANGED_WHILE_WAITING.to_string(),
            ));
        }
        let caller = request.caller.clone();
        let id = request.id;
        let Some(needed) = needed else {
            return self.finish_approved_settings(id, items, plan, Vec::new(), &caller, cx);
        };
        let scope_changed = lokalbot_i18n::tr(
            "The cleanup scope changed. Review the updated counts before applying it.",
        );
        let Some(shown) = request.retention.clone().filter(|shown| {
            shown.days == needed.days && shown.keep_text_forever == needed.keep_text_forever
        }) else {
            self.approvals
                .update(id, |pending| pending.retention = Some(needed));
            return Err(ApprovalProblem::Retry(scope_changed.to_string()));
        };
        let library = self.data.read(cx).library.clone();
        let (days, forever) = (shown.days, shown.keep_text_forever);
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_spawn(async move { library.apply_retention_review(&shown, Utc::now()) })
                .await;
            let _ = this.update(cx, |host, cx| {
                let outcome = match result {
                    Ok(report) => {
                        let warnings = if report.failures.is_empty() {
                            Vec::new()
                        } else {
                            vec![json!(format!(
                                "{} moments could not be fully cleaned up.",
                                report.failures.len()
                            ))]
                        };
                        host.data
                            .update(cx, |data, cx| data.mark_library_changed(cx));
                        host.finish_approved_settings(id, items, plan, warnings, &caller, cx)
                    }
                    Err(err) if err.downcast_ref::<RetentionReviewError>().is_some() => {
                        let library = host.data.read(cx).library.clone();
                        if let Ok(fresh) = library.retention_review(days, forever, Utc::now(), true)
                        {
                            host.approvals
                                .update(id, |pending| pending.retention = Some(fresh));
                        }
                        Err(ApprovalProblem::Retry(scope_changed.to_string()))
                    }
                    Err(err) => Err(ApprovalProblem::Retry(format!("{err:#}"))),
                };
                if let Err(problem) = outcome {
                    host.approvals.set_problem(id, problem.to_string());
                }
                cx.notify();
            });
        })
        .detach();
        Ok(())
    }

    fn finish_approved_settings(
        &mut self,
        id: Uuid,
        items: Vec<PlanItem>,
        plan: ChangePlan,
        mut warnings: Vec<Value>,
        caller: &str,
        cx: &mut Context<Self>,
    ) -> Result<(), ApprovalProblem> {
        warnings.extend(
            self.apply_agent_settings(&items, caller, cx)
                .map_err(ApprovalProblem::Control)?,
        );
        self.approvals.finish_approved(
            id,
            json!({"applied": true, "changes": plan.entries(), "warnings": warnings}),
            Utc::now(),
        );
        self.withdraw(id);
        Ok(())
    }

    /// Applies checked plan items and records them for the audit log and Undo.
    /// Returns a warning for each value that did not stick.
    pub(crate) fn apply_agent_settings(
        &mut self,
        items: &[PlanItem],
        caller: &str,
        cx: &mut Context<Self>,
    ) -> Result<Vec<Value>, ControlError> {
        if items.is_empty() {
            return Ok(Vec::new());
        }
        let settings = self.data.read(cx).settings.clone();
        let updated = checked_apply(items, &settings)?;
        self.data.update(cx, |data, cx| {
            data.update_settings(move |current| *current = updated, cx)
        });
        self.changes.record(items, caller, Utc::now());
        cx.notify();
        let effective = encoded(&self.data.read(cx).settings);
        Ok(items
            .iter()
            .filter(|item| {
                !lokalbot_core::control::optional_json_eq(
                    effective.get(item.spec.key),
                    item.stored.as_ref(),
                )
            })
            .map(|item| {
                json!(format!(
                    "{} could not be applied; LokalBot kept the earlier value.",
                    item.spec.key
                ))
            })
            .collect())
    }

    /// The person clicked Undo. It restores the earlier value while the setting
    /// still holds the agent's.
    pub fn undo(&mut self, entry: &Entry, cx: &mut Context<Self>) {
        let settings = self.data.read(cx).settings.clone();
        if !audit::can_undo(entry, &settings) {
            return;
        }
        let Some(spec) = registry::spec(&entry.key) else {
            return;
        };
        let item = PlanItem {
            spec: *spec,
            previous: entry.value.clone(),
            stored: entry.previous.clone(),
            change: ChangeClass::Preference,
        };
        if let Err(error) = self.apply_agent_settings(&[item], "You (Undo)", cx) {
            self.show_error(error.message, cx);
        }
    }

    /// The cleanup a change's shorter retention policy needs reviewed, or `None`
    /// when the change deletes nothing. On the UI thread as on the Mac: it is
    /// rare, and the card needs it. A review that can't be built refuses the
    /// change rather than skipping the review.
    pub(crate) fn retention_review(
        &self,
        items: &[PlanItem],
        settings: &Settings,
        cx: &Context<Self>,
    ) -> anyhow::Result<Option<RetentionReview>> {
        let Some((days, forever)) = retention_target(items, settings) else {
            return Ok(None);
        };
        if !crate::pages::settings::needs_retention_review(
            settings.retention_days,
            settings.keep_ocr_text_forever,
            days,
            forever,
        ) {
            return Ok(None);
        }
        self.data
            .read(cx)
            .library
            .retention_review(days, forever, Utc::now(), true)
            .map(Some)
    }

    pub(crate) fn secret_changed(
        &mut self,
        secret: AppSecret,
        is_set: bool,
        caller: &str,
        cx: &mut Context<Self>,
    ) {
        self.changes
            .record_secret(secret, is_set, caller, Utc::now());
        cx.notify();
    }
}

/// Saves or, when blank, removes an API key in the system credential store.
pub(crate) fn save_secret(secret: AppSecret, value: &str) -> anyhow::Result<()> {
    match secret {
        AppSecret::OpenAICompatible => lokalbot_engine::secrets::save_openai_api_key(value),
        AppSecret::RemoteTranscription => {
            lokalbot_engine::secrets::save_remote_transcription_api_key(value)
        }
        AppSecret::AutocompleteServer => {
            lokalbot_engine::secrets::save_autocomplete_server_api_key(value)
        }
    }
}

pub(crate) fn secret_is_set(secret: AppSecret) -> bool {
    match secret {
        AppSecret::OpenAICompatible => lokalbot_engine::secrets::openai_api_key(),
        AppSecret::RemoteTranscription => lokalbot_engine::secrets::remote_transcription_api_key(),
        AppSecret::AutocompleteServer => lokalbot_engine::secrets::autocomplete_server_api_key(),
    }
    .is_some()
}

fn retention_target(items: &[PlanItem], settings: &Settings) -> Option<(u32, bool)> {
    let days = items.iter().find(|i| i.spec.key == "retentionDays");
    let forever = items.iter().find(|i| i.spec.key == "keepOCRTextForever");
    if days.is_none() && forever.is_none() {
        return None;
    }
    let defaults = Settings::default();
    let keep = match forever {
        Some(item) => item
            .stored
            .as_ref()
            .and_then(Value::as_bool)
            .unwrap_or(defaults.keep_ocr_text_forever),
        None => settings.keep_ocr_text_forever,
    };
    let target = match days {
        Some(item) => item
            .stored
            .as_ref()
            .and_then(Value::as_u64)
            .map_or(defaults.retention_days, |d| d as u32),
        None => settings.retention_days,
    };
    Some((target, keep))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(key: &str, stored: Value) -> PlanItem {
        PlanItem {
            spec: *registry::spec(key).unwrap(),
            previous: None,
            stored: Some(stored),
            change: ChangeClass::Preference,
        }
    }

    #[test]
    fn shortcuts_and_models_are_checked_before_they_apply() {
        let settings = Settings::default();
        let error =
            checked_apply(&[item("dictationShortcut", json!("not a key"))], &settings).unwrap_err();
        assert_eq!(error.code, "invalid_value");
        assert!(
            checked_apply(&[item("dictationShortcut", json!("Ctrl+Alt+D"))], &settings).is_ok()
        );
        let taken = checked_apply(
            &[item(
                "dictationShortcut",
                json!(settings.quick_recall_shortcut),
            )],
            &settings,
        )
        .unwrap_err();
        assert_eq!(taken.code, "invalid_value");
        let model = checked_apply(&[item("builtInModelID", json!("no-such-model"))], &settings)
            .unwrap_err();
        assert_eq!(model.code, "invalid_value");
    }

    #[test]
    fn a_background_launch_is_the_autostart_launch() {
        assert_eq!(
            lokalbot_core::control::protocol::BACKGROUND_LAUNCH_ARGUMENT,
            lokalbot_platform::autostart::AUTOSTART_ARG
        );
    }

    #[test]
    fn speech_choices_match_what_this_app_can_run() {
        use lokalbot_core::control::registry::Stored;
        let spec = registry::spec("transcriptionModel").unwrap();
        for choice in spec.kind.choices().unwrap() {
            let Stored::Text(id) = choice.stored else {
                panic!("{}", choice.token)
            };
            assert!(
                lokalbot_speech::models::is_remote(id)
                    || lokalbot_speech::models::find(id).is_some(),
                "{id}"
            );
        }
        let voices = registry::spec("speechVoice").unwrap();
        for choice in voices.kind.choices().unwrap() {
            let Stored::Text(id) = choice.stored else {
                panic!("{}", choice.token)
            };
            assert!(
                lokalbot_speech::kokoro::VOICES.iter().any(|v| v.id == id),
                "{id}"
            );
        }
    }

    #[test]
    fn retention_targets_follow_what_the_request_changes() {
        let settings = Settings::default();
        assert_eq!(retention_target(&[], &settings), None);
        assert_eq!(
            retention_target(&[item("retentionDays", json!(7))], &settings),
            Some((7, false))
        );
        assert_eq!(
            retention_target(&[item("keepOCRTextForever", json!(true))], &settings),
            Some((settings.retention_days, true))
        );
    }
}
