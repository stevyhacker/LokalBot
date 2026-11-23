use std::time::Duration;

use chrono::Utc;
use gpui_kit::{AppContext as _, Context};
use lokalbot_core::Settings;
use lokalbot_core::access;
use lokalbot_core::control::approvals::Subject;
use lokalbot_core::control::change::{
    ChangePlan, ChangeRequest, snapshot_entries, specs_for_category,
};
use lokalbot_core::control::encoded;
use lokalbot_core::control::protocol::{
    self as protocol, AppSecret, ControlError, MODEL_PRESETS, PERMISSION_NAMES, Request, Response,
    SETTINGS_DESTINATIONS, SecretValue, VERSION, validated_secret_value,
};
use lokalbot_core::control::registry::{self, SettingCategory, SettingTier};
use lokalbot_core::control::reprocess;
use lokalbot_core::control::setup::SetupPlan;
use lokalbot_core::settings::SummarizerBackend;
use lokalbot_platform::control_socket::Reply;
use serde_json::{Map, Value, json};
use uuid::Uuid;

use super::{ControlHost, permissions, save_secret, secret_is_set};
use crate::pages::settings::catalog;
use crate::pages::settings::models::{Preset, model_bytes};
use crate::state::{AppData, AppEvent, DictationHud, ProcessingStage, SettingsCategory};

fn find_meeting(
    data: &AppData,
    params: &Map<String, Value>,
) -> Result<lokalbot_core::Meeting, ControlError> {
    if data.meetings_loaded {
        return reprocess::meeting(&data.meetings, params);
    }
    let meetings = data.library.list_meetings().map_err(|err| {
        ControlError::invalid_request(format!("LokalBot could not read the library: {err:#}"))
    })?;
    reprocess::meeting(&meetings, params)
}

fn processing_status(
    meeting: &lokalbot_core::Meeting,
    stage: Option<&ProcessingStage>,
    folder: &std::path::Path,
) -> Value {
    let state = stage.map_or("idle", stage_state);
    let message = stage.map(stage_message);
    reprocess::status(meeting, state, message.as_deref(), folder)
}

fn stage_state(stage: &ProcessingStage) -> &'static str {
    match stage {
        ProcessingStage::Queued => "queued",
        ProcessingStage::WaitingForModels => "waitingForModels",
        ProcessingStage::PreparingModel(_) => "preparing",
        ProcessingStage::Transcribing => "transcribing",
        ProcessingStage::IdentifyingSpeakers => "identifyingSpeakers",
        ProcessingStage::Summarizing => "summarizing",
        ProcessingStage::Failed(_) => "failed",
    }
}

fn stage_message(stage: &ProcessingStage) -> String {
    match stage {
        ProcessingStage::Queued => "Queued…".into(),
        ProcessingStage::WaitingForModels => {
            "Waiting for models — the recording is saved. Download the selected models in Settings → Models.".into()
        }
        ProcessingStage::PreparingModel(model) => format!("Preparing {model}…"),
        ProcessingStage::Transcribing => "Transcribing…".into(),
        ProcessingStage::IdentifyingSpeakers => "Identifying speakers…".into(),
        ProcessingStage::Summarizing => "Summarizing…".into(),
        ProcessingStage::Failed(message) => format!("Failed: {message}"),
    }
}

fn preset_token(preset: Preset) -> &'static str {
    match preset {
        Preset::Balanced => "recommended",
        Preset::Lightweight => "lightweight",
    }
}

fn preset_named(value: Option<&Value>) -> Result<Preset, ControlError> {
    match value.and_then(Value::as_str) {
        Some("recommended") => Ok(Preset::Balanced),
        Some("lightweight") => Ok(Preset::Lightweight),
        _ => Err(ControlError::invalid_request(format!(
            "Choose a model preset: {}.",
            MODEL_PRESETS.join(", ")
        ))),
    }
}

pub(crate) fn suggested_preset(memory_bytes: u64, settings: &Settings) -> (Preset, String) {
    const GIB: f64 = 1_073_741_824.0;
    let gigabytes = memory_bytes as f64 / GIB;
    let balanced = &lokalbot_ai::catalog::PRESETS[0];
    let stack = model_bytes(balanced.think, settings)
        + model_bytes(balanced.autocomplete, settings)
        + 1_073_741_824;
    let comfortable = stack as f64 / GIB * 1.3 <= gigabytes * 0.6;
    let memory = format!("{} GB", gigabytes.round() as i64);
    if comfortable {
        (
            Preset::Balanced,
            format!("This PC has {memory} of memory, enough for the balanced models."),
        )
    } else {
        (
            Preset::Lightweight,
            format!(
                "This PC has {memory} of memory; the lightweight models leave room for other apps."
            ),
        )
    }
}

fn hello() -> Value {
    json!({
        "app": "LokalBot",
        "version": env!("CARGO_PKG_VERSION"),
        "protocol": VERSION,
        "bundleIdentifier": lokalbot_platform::APP_ID,
        "pid": std::process::id(),
    })
}

fn role_status(
    ready: bool,
    in_use: Option<&str>,
    data: &AppData,
) -> (&'static str, String, Option<f64>, Option<String>) {
    if ready {
        return ("ready", "Ready".to_string(), None, None);
    }
    if let Some(download) = in_use.and_then(|id| data.downloads.get(id)) {
        if let Some(error) = &download.error {
            return (
                "needsAttention",
                "Needs attention".to_string(),
                None,
                Some(error.to_string()),
            );
        }
        let progress = f64::from(download.fraction());
        return (
            "downloading",
            format!("Downloading… {}%", (progress * 100.0) as i64),
            Some(progress),
            None,
        );
    }
    ("notDownloaded", "Download required".to_string(), None, None)
}

fn models_json(data: &AppData) -> Value {
    let settings = &data.settings;
    let think_id = (settings.summarizer_backend == SummarizerBackend::BuiltIn)
        .then_some(settings.built_in_model_id.as_str());
    let roles = [
        (
            "transcribe",
            data.models.transcription_ready,
            Some(settings.transcription_model.as_str()),
        ),
        ("think", data.models.think_ready, think_id),
        (
            "autocomplete",
            data.models.autocomplete_ready,
            Some(settings.cotyping_built_in_model_id.as_str()),
        ),
    ];
    let mut entries = Map::new();
    for (name, ready, id) in roles {
        let (state, label, progress, error) = role_status(ready, id, data);
        let mut entry = Map::new();
        entry.insert("state".into(), json!(state));
        entry.insert("label".into(), json!(label));
        if let Some(progress) = progress {
            entry.insert("progress".into(), json!(progress));
        }
        if let Some(error) = error {
            entry.insert("error".into(), json!(error));
        }
        entries.insert(name.into(), Value::Object(entry));
    }
    json!({
        "meetingReady": data.models.transcription_ready && data.models.think_ready,
        "allReady": data.models.transcription_ready
            && data.models.think_ready
            && data.models.autocomplete_ready,
        "roles": entries,
    })
}

fn merged(value: Value, other: Value) -> Value {
    let mut object = value.as_object().cloned().unwrap_or_default();
    if let Some(other) = other.as_object() {
        for (key, value) in other {
            object.insert(key.clone(), value.clone());
        }
    }
    Value::Object(object)
}

impl ControlHost {
    pub(super) fn handle(
        &mut self,
        request: Request,
        caller: String,
        reply: Reply,
        cx: &mut Context<Self>,
    ) {
        if request.protocol != VERSION {
            return reply(Response::failure(ControlError::unsupported_protocol()));
        }
        if !access::settings_control_enabled(&self.paths) {
            return reply(Response::failure(ControlError::settings_access_disabled()));
        }
        let params = request.params.unwrap_or_default();
        match request.method.as_str() {
            protocol::METHOD_SECRET_LIST => return self.secret_list(reply, cx),
            protocol::METHOD_SECRET_SET => return self.secret_set(params, caller, reply, cx),
            protocol::METHOD_SECRET_CLEAR => return self.secret_clear(params, caller, reply, cx),
            _ => {}
        }
        let result = self.answer(&request.method, &params, &caller, cx);
        reply(match result {
            Ok(value) => Response::success(value),
            Err(error) => Response::failure(error),
        });
    }

    fn answer(
        &mut self,
        method: &str,
        params: &Map<String, Value>,
        caller: &str,
        cx: &mut Context<Self>,
    ) -> Result<Value, ControlError> {
        match method {
            protocol::METHOD_HELLO => Ok(hello()),
            protocol::METHOD_SETTINGS_LIST => {
                let specs = specs_for_category(params.get("category").and_then(Value::as_str))?;
                let settings = &self.data.read(cx).settings;
                Ok(json!(snapshot_entries(settings, &specs)))
            }
            protocol::METHOD_SETTINGS_GET => {
                let Some(keys) = params.get("keys").and_then(Value::as_array) else {
                    return Err(ControlError::invalid_request(
                        "settings.get needs a \"keys\" array.",
                    ));
                };
                let mut specs = Vec::with_capacity(keys.len());
                for key in keys.iter().filter_map(Value::as_str) {
                    specs.push(registry::spec(key).ok_or_else(|| ControlError::unknown_key(key))?);
                }
                let settings = &self.data.read(cx).settings;
                Ok(json!(snapshot_entries(settings, &specs)))
            }
            protocol::METHOD_SETTINGS_SET => self.set_settings(params, caller, cx),
            protocol::METHOD_SETTINGS_REQUEST => {
                let Some(id) = params.get("id").and_then(Value::as_str) else {
                    return Err(ControlError::invalid_request(
                        "settings.request needs an \"id\".",
                    ));
                };
                let found = Uuid::parse_str(id)
                    .ok()
                    .and_then(|uuid| self.approvals.request(uuid, Utc::now()).map(|r| r.json()));
                found.ok_or_else(|| ControlError::unknown_request(id))
            }
            protocol::METHOD_MEETINGS_REPROCESS => self.reprocess_meeting(params, caller, cx),
            protocol::METHOD_MEETINGS_PROCESSING => self.processing_state(params, cx),
            protocol::METHOD_SETUP_PLAN => self.setup_plan(params, cx),
            protocol::METHOD_SETUP_FINISH => {
                self.data.update(cx, |data, cx| {
                    data.update_settings(|s| s.onboarding_completed = true, cx)
                });
                cx.defer(|cx| {
                    crate::windows::close_onboarding(cx);
                    crate::windows::agent_setup::close(cx);
                });
                Ok(json!({"finished": true}))
            }
            protocol::METHOD_MODELS_STATUS => Ok(self.models_status(cx)),
            protocol::METHOD_MODELS_PRESET => {
                let preset = preset_named(params.get("preset"))?;
                let data = self.data.clone();
                self.model_setup
                    .apply(preset.patch(), preset.title(), &data, cx);
                self.changes.record_event(
                    "models.preset",
                    json!(preset_token(preset)),
                    caller,
                    Utc::now(),
                );
                Ok(self.models_status(cx))
            }
            protocol::METHOD_MODELS_DOWNLOAD => {
                self.data
                    .update(cx, |data, cx| data.request(AppEvent::PrepareModels, cx));
                Ok(self.models_status(cx))
            }
            protocol::METHOD_MODELS_CANCEL => {
                self.model_setup.cancel();
                Ok(self.models_status(cx))
            }
            protocol::METHOD_PERMISSIONS_LIST => Ok(self.permissions_json(cx)),
            protocol::METHOD_PERMISSIONS_REQUEST => {
                let name = params.get("name").and_then(Value::as_str).unwrap_or("");
                if !PERMISSION_NAMES.contains(&name) {
                    return Err(ControlError::invalid_request(format!(
                        "Name a permission: {}.",
                        PERMISSION_NAMES.join(", ")
                    )));
                }
                permissions::request(name, &self.data, cx);
                Ok(self.permissions_json(cx))
            }
            protocol::METHOD_LAUNCH_AT_LOGIN => {
                let Some(enabled) = params.get("enabled").and_then(Value::as_bool) else {
                    return Err(ControlError::invalid_request(
                        "app.launchAtLogin needs \"enabled\": true or false.",
                    ));
                };
                self.data.update(cx, |data, cx| {
                    data.update_settings(|s| s.launch_at_login = enabled, cx)
                });
                self.changes
                    .record_event("launchAtLogin", json!(enabled), caller, Utc::now());
                Ok(json!({"launchAtLogin": enabled}))
            }
            protocol::METHOD_RESTART => self.restart(cx),
            protocol::METHOD_DOCTOR => Ok(self.doctor(cx)),
            protocol::METHOD_STATUS => Ok(self.status(cx)),
            protocol::METHOD_OPEN => self.open_settings(params, cx),
            other => Err(ControlError::unknown_method(other)),
        }
    }

    fn reprocess_meeting(
        &mut self,
        params: &Map<String, Value>,
        caller: &str,
        cx: &mut Context<Self>,
    ) -> Result<Value, ControlError> {
        let (transcribe, summarize) = reprocess::work(params)?;
        let (meeting, folder) = {
            let data = self.data.read(cx);
            let meeting = find_meeting(data, params)?;
            let folder = data.library.meeting_dir(&meeting);
            (meeting, folder)
        };
        reprocess::require_transcript(&meeting, &folder, transcribe)?;
        let meeting_id = meeting.id;
        self.data.update(cx, |data, cx| {
            data.request(
                AppEvent::ProcessMeeting {
                    meeting_id,
                    transcribe,
                    summarize,
                },
                cx,
            );
            if !data.is_processing(meeting_id) {
                data.processing.insert(meeting_id, ProcessingStage::Queued);
                cx.notify();
            }
        });
        log::info!(
            "app-control reprocess meeting={meeting_id} transcribe={transcribe} summarize={summarize} caller={caller}"
        );
        let stage = self.data.read(cx).processing.get(&meeting_id).cloned();
        Ok(processing_status(&meeting, stage.as_ref(), &folder))
    }

    fn processing_state(
        &mut self,
        params: &Map<String, Value>,
        cx: &mut Context<Self>,
    ) -> Result<Value, ControlError> {
        let data = self.data.read(cx);
        let meeting = find_meeting(data, params)?;
        let folder = data.library.meeting_dir(&meeting);
        let stage = data.processing.get(&meeting.id);
        Ok(processing_status(&meeting, stage, &folder))
    }

    fn set_settings(
        &mut self,
        params: &Map<String, Value>,
        caller: &str,
        cx: &mut Context<Self>,
    ) -> Result<Value, ControlError> {
        let request = ChangeRequest::from_params(Some(params))?;
        let settings = self.data.read(cx).settings.clone();
        let plan = ChangePlan::make(
            &request,
            &encoded(&settings),
            &encoded(&Settings::default()),
        )?;
        let entries = plan.entries();
        let changed = plan.changed();
        super::checked_apply(&changed, &settings)?;
        if request.dry_run {
            return Ok(json!({"applied": false, "dryRun": true, "changes": entries}));
        }
        let read_only: Vec<&str> = plan.read_only().iter().map(|i| i.spec.key).collect();
        if !read_only.is_empty() {
            return Err(ControlError::read_only(&read_only));
        }
        if !plan.widening().is_empty() {
            let keys: Vec<&str> = changed.iter().map(|i| i.spec.key).collect();
            let changes: Vec<Value> = entries
                .into_iter()
                .filter(|entry| entry["key"].as_str().is_some_and(|key| keys.contains(&key)))
                .collect();
            let retention = self
                .retention_review(&changed, &settings, cx)
                .map_err(|err| ControlError::invalid_request(format!("{err:#}")))?;
            let (pending, is_new) = self.approvals.submit(
                Subject::Settings(request),
                caller,
                changed,
                changes,
                retention,
                Utc::now(),
            )?;
            if is_new {
                self.announce(&pending);
            }
            cx.notify();
            return Err(ControlError::needs_approval(
                pending.json(),
                &pending.headline(),
            ));
        }
        let applicable: Vec<_> = plan.applicable().into_iter().cloned().collect();
        if applicable.is_empty() {
            return Ok(json!({"applied": false, "changes": entries}));
        }
        let warnings = self.apply_agent_settings(&applicable, caller, cx)?;
        Ok(json!({"applied": true, "changes": entries, "warnings": warnings}))
    }

    fn secret_named(params: &Map<String, Value>) -> Result<AppSecret, ControlError> {
        let Some(name) = params.get("name").and_then(Value::as_str) else {
            return Err(ControlError::invalid_request(
                "Name the API key in \"name\".",
            ));
        };
        AppSecret::parse(name).ok_or_else(|| ControlError::unknown_secret(name))
    }

    fn secret_list(&mut self, reply: Reply, cx: &mut Context<Self>) {
        cx.background_spawn(async move {
            let entries: Vec<Value> = AppSecret::ALL
                .iter()
                .map(|secret| {
                    json!({
                        "name": secret.raw_value(),
                        "title": secret.title(),
                        "summary": secret.summary(),
                        "isSet": secret_is_set(*secret),
                    })
                })
                .collect();
            reply(Response::success(json!(entries)));
        })
        .detach();
    }

    fn secret_set(
        &mut self,
        params: Map<String, Value>,
        caller: String,
        reply: Reply,
        cx: &mut Context<Self>,
    ) {
        let secret = match Self::secret_named(&params) {
            Ok(secret) => secret,
            Err(error) => return reply(Response::failure(error)),
        };
        let raw = params.get("value").and_then(Value::as_str).unwrap_or("");
        let Some(value) = validated_secret_value(raw) else {
            return reply(Response::failure(ControlError::invalid_request(
                "secret.set needs the key as one line in \"value\".",
            )));
        };
        cx.spawn(async move |this, cx| {
            let saved = cx
                .background_spawn(async move { secret_is_set(secret) })
                .await;
            let response = this
                .update(cx, |host, cx| {
                    let hint = AppSecret::hint(&value);
                    let change = json!({
                        "key": format!("secret.{}", secret.raw_value()),
                        "title": secret.title(),
                        "tier": "consent",
                        "change": "widening",
                        "previous": if saved { "saved" } else { "not set" },
                        "value": format!("new key {hint}").trim().to_string(),
                    });
                    let submitted = host.approvals.submit(
                        Subject::Secret(secret, SecretValue::new(value)),
                        &caller,
                        Vec::new(),
                        vec![change],
                        None,
                        Utc::now(),
                    );
                    cx.notify();
                    match submitted {
                        Ok((pending, is_new)) => {
                            if is_new {
                                host.announce(&pending);
                            }
                            ControlError::needs_approval(pending.json(), &pending.headline())
                        }
                        Err(error) => error,
                    }
                })
                .unwrap_or_else(|_| ControlError::app_not_running("LokalBot is shutting down."));
            reply(Response::failure(response));
        })
        .detach();
    }

    fn secret_clear(
        &mut self,
        params: Map<String, Value>,
        caller: String,
        reply: Reply,
        cx: &mut Context<Self>,
    ) {
        let secret = match Self::secret_named(&params) {
            Ok(secret) => secret,
            Err(error) => return reply(Response::failure(error)),
        };
        cx.spawn(async move |this, cx| {
            let cleared = cx
                .background_spawn(async move { save_secret(secret, "") })
                .await;
            let response = match cleared {
                Ok(()) => {
                    let _ = this.update(cx, |host, cx| {
                        host.secret_changed(secret, false, &caller, cx)
                    });
                    Response::success(json!({"cleared": secret.raw_value()}))
                }
                Err(_) => Response::failure(ControlError::other(
                    "credential_store_error",
                    format!(
                        "LokalBot couldn't remove the {} from the system credential store.",
                        secret.title()
                    ),
                )),
            };
            reply(response);
        })
        .detach();
    }

    fn memory_suggestion(&self, cx: &Context<Self>) -> (Preset, String) {
        let memory = lokalbot_platform::process_usage::total_memory_bytes().unwrap_or(0);
        suggested_preset(memory, &self.data.read(cx).settings)
    }

    fn models_status(&self, cx: &Context<Self>) -> Value {
        let data = self.data.read(cx);
        let (suggestion, reason) = self.memory_suggestion(cx);
        let current = Preset::ALL
            .into_iter()
            .find(|preset| preset.matches(&data.settings))
            .map_or("custom", preset_token);
        let mut status = merged(
            models_json(data),
            json!({
                "preset": current,
                "suggestedPreset": preset_token(suggestion),
                "suggestionReason": reason,
            }),
        );
        if let Some(title) = self.model_setup.pending_title() {
            status = merged(status, json!({"switching": title}));
        }
        if let Some(failure) = self.model_setup.failure_message() {
            status = merged(status, json!({"switchFailure": failure}));
        }
        status
    }

    fn setup_plan(
        &self,
        params: &Map<String, Value>,
        cx: &Context<Self>,
    ) -> Result<Value, ControlError> {
        let (suggestion, reason) = self.memory_suggestion(cx);
        let chosen = match params.get("preset") {
            Some(value) => preset_named(Some(value))?,
            None => suggestion,
        };
        let data = self.data.read(cx);
        let current = encoded(&data.settings);
        let mut settings = Map::new();
        for key in SetupPlan::KEYS {
            if let (Some(spec), Some(value)) = (registry::spec(key), current.get(key)) {
                settings.insert(key.to_string(), spec.presented(value));
            }
        }
        let plan = SetupPlan {
            settings,
            models: Some(preset_token(chosen).to_string()),
            launch_at_login: Some(data.settings.launch_at_login),
        };
        let needs_approval: Vec<&str> = SetupPlan::KEYS
            .iter()
            .copied()
            .filter(|key| registry::spec(key).is_some_and(|spec| spec.tier == SettingTier::Consent))
            .collect();
        Ok(merged(
            plan.json(),
            json!({"notes": {
                "suggestedModels": preset_token(suggestion),
                "modelsReason": reason,
                "needsApproval": needs_approval,
                "describe": "Run `lokalbot-cli config describe <key>` for each setting's choices.",
            }}),
        ))
    }

    fn permissions_json(&self, cx: &Context<Self>) -> Value {
        let needs = permissions::needs(self.data.read(cx), cx);
        let entries: Vec<Value> = needs
            .iter()
            .map(|need| {
                json!({
                    "name": need.name,
                    "title": need.title,
                    "granted": need.granted,
                    "checked": need.checked,
                    "neededBy": need.needed_by,
                    "detail": need.detail,
                })
            })
            .collect();
        json!(entries)
    }

    fn status(&mut self, cx: &Context<Self>) -> Value {
        self.approvals.expire_stale(Utc::now());
        let data = self.data.read(cx);
        let mut granted = Map::new();
        for need in permissions::needs(data, cx) {
            granted.insert(
                need.title,
                if need.checked {
                    json!(need.granted)
                } else {
                    Value::Null
                },
            );
        }
        json!({
            "app": hello(),
            "library": {"root": self.paths.root().display().to_string()},
            "onboarding": {"completed": data.settings.onboarding_completed},
            "recording": {"active": data.recording.is_active()},
            "models": models_json(data),
            "access": {
                "meetingLibrary": access::meetings_access_enabled(&self.paths),
                "screenMemory": access::screen_access_scope(&self.paths).is_some(),
                "personalContext": access::personal_context_enabled(&self.paths),
                "settings": access::settings_control_enabled(&self.paths),
            },
            "permissions": granted,
            "approvals": {"pending": self.approvals.pending.len()},
        })
    }

    fn doctor(&self, cx: &Context<Self>) -> Value {
        let data = self.data.read(cx);
        let mut checks: Vec<Value> = Vec::new();
        let mut steps: Vec<String> = Vec::new();
        let mut ready = true;
        let mut check = |name: &str, ok: bool, detail: String, blocking: bool| {
            checks.push(json!({"name": name, "ok": ok, "detail": detail}));
            if !ok && blocking {
                ready = false;
            }
        };

        let meeting_ready = data.models.transcription_ready && data.models.think_ready;
        check(
            "models",
            meeting_ready,
            if meeting_ready {
                "Meeting models are ready."
            } else {
                "Meeting models are not ready yet."
            }
            .to_string(),
            true,
        );
        if !meeting_ready {
            steps.push(if self.model_setup.is_switching() {
                "Models are downloading. Run `lokalbot-cli models status` until meetingReady is true.".to_string()
            } else {
                "Run `lokalbot-cli models download`, then `lokalbot-cli models status` until meetingReady is true.".to_string()
            });
        }
        if data.downloads.values().any(|d| d.error.is_some()) {
            steps.push(
                "A model needs attention. Show the person: `lokalbot-cli open settings models`."
                    .to_string(),
            );
        }

        let missing: Vec<permissions::PermissionNeed> = permissions::needs(data, cx)
            .into_iter()
            .filter(permissions::PermissionNeed::missing)
            .collect();
        let missing_text = missing
            .iter()
            .map(|need| format!("{} (for {})", need.title, need.needed_by.join(", ")))
            .collect::<Vec<_>>()
            .join("; ");
        check(
            "permissions",
            missing.is_empty(),
            if missing.is_empty() {
                "Every permission the enabled features need is granted.".to_string()
            } else {
                format!("Missing: {missing_text}")
            },
            true,
        );
        for need in &missing {
            steps.push(format!(
                "Ask the person to allow {}: `lokalbot-cli permissions request {}`.",
                need.title, need.name
            ));
        }

        let onboarded = data.settings.onboarding_completed;
        check(
            "onboarding",
            onboarded,
            if onboarded {
                "Setup is finished."
            } else {
                "Setup is not finished."
            }
            .to_string(),
            true,
        );
        if !onboarded {
            steps.push("When setup is done, run `lokalbot-cli setup finish`.".to_string());
        }

        let waiting = self.approvals.pending.len();
        check(
            "approvals",
            waiting == 0,
            if waiting == 0 {
                "Nothing is waiting for the person.".to_string()
            } else {
                format!("{waiting} request(s) are waiting for the person in LokalBot.")
            },
            false,
        );
        if waiting > 0 {
            steps.push("Tell the person a request is waiting for them in LokalBot.".to_string());
        }

        let launch_at_login = data.settings.launch_at_login;
        check(
            "launchAtLogin",
            launch_at_login,
            if launch_at_login {
                "LokalBot starts at login."
            } else {
                "LokalBot does not start at login."
            }
            .to_string(),
            false,
        );

        json!({"ready": ready, "checks": checks, "nextSteps": steps})
    }

    fn restart(&mut self, cx: &mut Context<Self>) -> Result<Value, ControlError> {
        let data = self.data.read(cx);
        let dictating = matches!(
            data.dictation,
            DictationHud::Starting | DictationHud::Listening { .. }
        );
        if data.recording.is_active() || dictating {
            return Err(ControlError::other(
                "busy",
                "LokalBot is recording. Restart it after the recording stops.",
            ));
        }
        cx.spawn(async move |_, cx| {
            smol::Timer::after(Duration::from_millis(500)).await;
            cx.update(crate::updates::restart);
        })
        .detach();
        Ok(json!({"restarting": true}))
    }

    fn open_settings(
        &mut self,
        params: &Map<String, Value>,
        cx: &mut Context<Self>,
    ) -> Result<Value, ControlError> {
        if params.get("target").and_then(Value::as_str) != Some("settings") {
            return Err(ControlError::invalid_request(
                "open supports the \"settings\" target.",
            ));
        }
        let Some(key) = params.get("key").and_then(Value::as_str) else {
            self.data.update(cx, |data, cx| {
                data.open_settings(SettingsCategory::Overview, cx)
            });
            return Ok(json!({"opened": true}));
        };
        let id = format!("settings.{key}");
        let entry = catalog::ENTRIES.iter().find(|entry| entry.id == id);
        let spec = registry::spec(key);
        if spec.is_none() && !(entry.is_some() && SETTINGS_DESTINATIONS.contains(&key)) {
            return Err(ControlError::unknown_key(key));
        }
        let category = entry
            .map(|entry| entry.category)
            .or_else(|| spec.map(|spec| settings_page_for(spec.category)))
            .unwrap_or(SettingsCategory::Overview);
        self.data.update(cx, |data, cx| {
            data.open_settings(category, cx);
            if entry.is_some() {
                data.settings_focus = Some(id.clone());
                cx.notify();
            }
        });
        Ok(json!({"opened": true}))
    }
}

fn settings_page_for(category: SettingCategory) -> SettingsCategory {
    match category {
        SettingCategory::General => SettingsCategory::General,
        SettingCategory::Ask => SettingsCategory::Ask,
        SettingCategory::Recording => SettingsCategory::Meetings,
        SettingCategory::DayMemory => SettingsCategory::DayMemory,
        SettingCategory::Daily => SettingsCategory::DailyReview,
        SettingCategory::Writing => SettingsCategory::Writing,
        SettingCategory::Dictation => SettingsCategory::Dictation,
        SettingCategory::Models => SettingsCategory::Models,
        SettingCategory::Files => SettingsCategory::Files,
        SettingCategory::PersonalContext => SettingsCategory::PersonalContext,
        SettingCategory::Devices => SettingsCategory::Devices,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_suggested_preset_follows_memory() {
        let settings = Settings::default();
        const GIB: u64 = 1_073_741_824;
        let (preset, reason) = suggested_preset(64 * GIB, &settings);
        assert!(preset == Preset::Balanced, "{reason}");
        assert!(reason.contains("64 GB"));
        let (preset, reason) = suggested_preset(4 * GIB, &settings);
        assert!(preset == Preset::Lightweight, "{reason}");
    }

    #[test]
    fn processing_stages_report_the_mac_states() {
        let cases = [
            (ProcessingStage::Queued, "queued", "Queued…"),
            (
                ProcessingStage::PreparingModel("speech model".into()),
                "preparing",
                "Preparing speech model…",
            ),
            (
                ProcessingStage::Transcribing,
                "transcribing",
                "Transcribing…",
            ),
            (
                ProcessingStage::IdentifyingSpeakers,
                "identifyingSpeakers",
                "Identifying speakers…",
            ),
            (ProcessingStage::Summarizing, "summarizing", "Summarizing…"),
            (
                ProcessingStage::Failed("no model".into()),
                "failed",
                "Failed: no model",
            ),
        ];
        for (stage, state, message) in cases {
            assert_eq!(stage_state(&stage), state);
            assert_eq!(stage_message(&stage), message);
        }
        assert_eq!(
            stage_state(&ProcessingStage::WaitingForModels),
            "waitingForModels"
        );
        let meeting = lokalbot_core::Meeting::new("Pricing review", "Zoom", Utc::now(), "m");
        let dir = tempfile::tempdir().unwrap();
        let idle = processing_status(&meeting, None, dir.path());
        assert_eq!(idle["state"], "idle");
        assert!(idle.get("message").is_none());
        let failed = processing_status(
            &meeting,
            Some(&ProcessingStage::Failed("no model".into())),
            dir.path(),
        );
        assert_eq!(failed["state"], "failed");
        assert_eq!(failed["message"], "Failed: no model");
        assert!(reprocess::is_settled(failed["state"].as_str()));
    }

    #[test]
    fn every_open_destination_is_a_settings_section() {
        for key in SETTINGS_DESTINATIONS {
            let id = format!("settings.{key}");
            assert!(
                catalog::ENTRIES.iter().any(|entry| entry.id == id),
                "{key} is not in the catalog"
            );
        }
    }
}
