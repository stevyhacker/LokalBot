//! The real [`Launcher`]: resolves the Think endpoint (leasing the built-in
//! llama-server when that is the model, or starting a ChatGPT plan relay),
//! audits the runtime, issues a scoped `lokalbot-cli` grant, writes the
//! extension and starts pi (`AgentSessionController.start`,
//! `ThinkExecution.prepareAgentConnection`).

use std::path::PathBuf;
use std::sync::{Arc, Weak};

use lokalbot_ai::RuntimeManager;
use lokalbot_ai::plans::PlanError;
use lokalbot_ai::plans::chatgpt::{self, relay::Relay};
use lokalbot_core::LibraryPaths;
use lokalbot_core::settings::{SubscriptionPlan, SummarizerBackend};

use crate::endpoint::{self, LlmEndpoint, ProviderApi, ReasoningDialect, Resolution};
use crate::launch::{self, PlanInputs, WorkspaceKind};
use crate::layout::{AgentDirectories, RuntimeLayout};
use crate::manifest::RuntimeManifest;
use crate::process::PiProcess;
use crate::rpc::{LineTransport, REQUEST_TIMEOUT, RpcClient, Sink};
use crate::session::{LaunchError, LaunchRequest, Launched, Launcher, RequestTag};
use crate::shell::ShellChoice;

/// A scoped grant lasts at most a day; revoking it on stop is the norm.
const CAPABILITY_LIFETIME_HOURS: i64 = 24;

pub type ApiKeySource = Arc<dyn Fn() -> Option<String> + Send + Sync>;

#[derive(Clone)]
pub struct PiLauncher {
    pub paths: LibraryPaths,
    pub dirs: AgentDirectories,
    pub layout: RuntimeLayout,
    pub manifest: RuntimeManifest,
    /// The app's llama.cpp runtime (the engine's), for the built-in model.
    pub runtime: Option<RuntimeManager>,
    /// The stored OpenAI-compatible key, read at launch only.
    pub api_key: ApiKeySource,
    /// The ChatGPT plan sign-in a plan task's relay draws its tokens from.
    pub chatgpt_account: Arc<chatgpt::Account>,
    /// The folder holding `lokalbot-cli`, put first on the agent's PATH.
    pub helpers_dir: Option<PathBuf>,
    /// The command shell; `None` detects it ([`ShellChoice::detect`]).
    pub shell: Option<ShellChoice>,
}

impl PiLauncher {
    /// `lokalbot-cli` next to the running executable, when it is there.
    pub fn bundled_helpers_dir() -> Option<PathBuf> {
        let dir = std::env::current_exe().ok()?.parent()?.to_path_buf();
        let name = if cfg!(windows) {
            "lokalbot-cli.exe"
        } else {
            "lokalbot-cli"
        };
        dir.join(name).is_file().then_some(dir)
    }

    fn launch_blocking(
        &self,
        request: LaunchRequest,
        sink: Sink<RequestTag>,
    ) -> Result<Launched, LaunchError> {
        let connection = self.connect(&request)?;
        let endpoint = connection.endpoint.clone();

        if !self.layout.is_integrity_valid(&self.manifest) {
            return Err(LaunchError::Other(
                "The Agent runtime changed since installation. Repair it under Tasks → Verify Agent runtime before starting this task.".into(),
            ));
        }
        remove_expired_capabilities(&self.paths);
        let capability = lokalbot_core::access::issue_agent_capability(
            &self.paths,
            chrono::Duration::hours(CAPABILITY_LIFETIME_HOURS),
        )
        .map_err(|err| LaunchError::Other(format!("Couldn't grant library access: {err}")))?;
        let revoke = |capability: &str| {
            let _ = lokalbot_core::access::revoke_agent_capability(&self.paths, capability);
        };

        let spawned = (|| -> Result<Launched, LaunchError> {
            let files = crate::resources::materialize(&self.layout)
                .map_err(|err| LaunchError::Other(format!("{err:#}")))?;
            let shell = self.shell.clone().unwrap_or_else(ShellChoice::detect);
            shell
                .apply(&self.dirs.pi_config())
                .map_err(|err| LaunchError::Other(format!("{err:#}")))?;
            let sessions = self.dirs.sessions();
            crate::fsutil::create_private_dir(&sessions)
                .map_err(|err| LaunchError::Other(err.to_string()))?;
            crate::fsutil::create_private_dir(&self.dirs.pi_config())
                .map_err(|err| LaunchError::Other(err.to_string()))?;
            let in_agent_workspace =
                crate::policy::same_path(&request.workspace, &self.dirs.default_workspace());
            let workspace_kind = if in_agent_workspace {
                WorkspaceKind::AgentWorkspace
            } else {
                WorkspaceKind::ChosenFolder
            };
            let plan = launch::plan(PlanInputs {
                bun: &self.layout.bun(),
                pi_cli: &self.layout.pi_cli(),
                extension_dir: &files.extension_dir,
                skill_dir: Some(&files.skill_dir),
                system_prompt: Some(&files.system_prompt),
                session_dir: &sessions,
                pi_config_dir: &self.dirs.pi_config(),
                workspace: &request.workspace,
                workspace_kind: Some(workspace_kind),
                library_root: self.paths.root(),
                endpoint: &endpoint,
                reasoning_level_file: Some(&request.reasoning_level_file),
                helpers_dir: self.helpers_dir.as_deref(),
                private_roots: &request.private_roots,
                agent_capability: Some(&capability),
                session: &request.session,
                tools: shell.tools(),
                base_environment: std::env::vars().collect(),
            });
            let client = RpcClient::new(sink, REQUEST_TIMEOUT);
            let reader = client.clone();
            let closer = client.clone();
            let process = PiProcess::spawn(
                &plan,
                Some(&self.dirs.process_markers()),
                move |line| reader.handle_line(&line),
                move |report| closer.handle_close(report.stderr_tail),
            )
            .map_err(|err| LaunchError::Other(format!("Couldn't start the agent: {err:#}")))?;
            let process = Arc::new(process);
            client.attach(Arc::new(ProcessTransport(Arc::downgrade(&process))));
            Ok(Launched {
                client,
                process: Some(process),
                lease: None,
                relay: None,
                capability: Some(capability.clone()),
                endpoint: endpoint.clone(),
                reports_session_file: true,
            })
        })();
        match spawned {
            Ok(mut launched) => {
                launched.lease = connection.lease;
                launched.relay = connection.relay;
                Ok(launched)
            }
            Err(error) => {
                revoke(&capability);
                Err(error)
            }
        }
    }

    /// The endpoint, with what must stay alive while the task runs.
    fn connect(&self, request: &LaunchRequest) -> Result<Connection, LaunchError> {
        // Only an OpenAI-compatible server takes a key; reading the system
        // keyring can block for a long time when no secret service answers.
        let api_key = match request.settings.summarizer_backend {
            SummarizerBackend::OpenAICompatible => (self.api_key)(),
            SummarizerBackend::BuiltIn
            | SummarizerBackend::Ollama
            | SummarizerBackend::ChatGptPlan
            | SummarizerBackend::ClaudePlan => None,
        };
        match endpoint::resolve(&request.settings, api_key) {
            Resolution::Unsupported(reason) => Err(LaunchError::Configuration(reason)),
            Resolution::Ready(endpoint) => Ok(Connection {
                endpoint,
                lease: None,
                relay: None,
            }),
            Resolution::ChatGptPlan { model } => self.connect_chatgpt_plan(model),
            Resolution::BuiltIn { model_id } => {
                let not_downloaded = || {
                    LaunchError::Configuration(
                        "The built-in model isn't downloaded yet. Download it under Settings → Models."
                            .into(),
                    )
                };
                let entry = lokalbot_ai::catalog::entry(&model_id).ok_or_else(not_downloaded)?;
                let runtime = self.runtime.as_ref().ok_or_else(|| {
                    LaunchError::Other("The built-in model runtime isn't available.".into())
                })?;
                if !lokalbot_ai::catalog::is_downloaded(runtime.paths(), entry) {
                    return Err(not_downloaded());
                }
                let lease = runtime.main_server(entry).map_err(|err| {
                    LaunchError::Other(format!("Couldn't start {}: {err:#}", entry.display_name))
                })?;
                let endpoint = LlmEndpoint {
                    base_url: lease.base_url(),
                    model: entry.id.to_string(),
                    context_tokens: lokalbot_ai::Role::Main.context_tokens(),
                    api_key: Some(lease.token().to_string()),
                    reasoning_dialect: ReasoningDialect::LlamaServer,
                    api: ProviderApi::ChatCompletions,
                    plan: None,
                };
                Ok(Connection {
                    endpoint,
                    lease: Some(lease),
                    relay: None,
                })
            }
        }
    }

    /// A relay for this task on 127.0.0.1. pi gets its random key; only the
    /// relay holds the plan's tokens.
    fn connect_chatgpt_plan(&self, model: String) -> Result<Connection, LaunchError> {
        // A missing sign-in opens Models now instead of failing the first turn.
        let status = self
            .chatgpt_account
            .status()
            .map_err(|err| LaunchError::Configuration(err.to_string()))?;
        if !status.is_signed_in() {
            return Err(LaunchError::Configuration(PlanError::SignedOut.to_string()));
        }
        if !status.allows_plan_usage() {
            return Err(LaunchError::Configuration(
                PlanError::PlanUsageNotGranted.to_string(),
            ));
        }
        let relay = Relay::start(self.chatgpt_account.clone())
            .map_err(|err| LaunchError::Other(format!("{err:#}")))?;
        let endpoint = LlmEndpoint {
            base_url: relay.base_url(),
            context_tokens: chatgpt::context_tokens(&model),
            model,
            api_key: Some(relay.key().to_string()),
            reasoning_dialect: ReasoningDialect::OpenAi,
            api: ProviderApi::Responses,
            plan: Some(SubscriptionPlan::ChatGpt),
        };
        Ok(Connection {
            endpoint,
            lease: None,
            relay: Some(relay),
        })
    }
}

/// A task's model connection. The lease keeps the built-in model loaded; the
/// relay serves the ChatGPT plan. Both last until the task stops.
struct Connection {
    endpoint: LlmEndpoint,
    lease: Option<lokalbot_ai::Lease>,
    relay: Option<Relay>,
}

impl Launcher for PiLauncher {
    fn launch(
        &self,
        request: LaunchRequest,
        sink: Sink<RequestTag>,
        done: Box<dyn FnOnce(Result<Launched, LaunchError>) + Send>,
    ) {
        let launcher = self.clone();
        let spawned = std::thread::Builder::new()
            .name("lokalbot-agent-launch".into())
            .spawn(move || done(launcher.launch_blocking(request, sink)));
        if let Err(err) = spawned {
            log::error!("could not start the agent launch thread: {err}");
        }
    }
}

/// The client writes through a weak handle: dropping the session's process
/// ends pi even while the reader thread still holds the client.
struct ProcessTransport(Weak<PiProcess>);

impl LineTransport for ProcessTransport {
    fn send_line(&self, line: &str) -> Result<(), String> {
        match self.0.upgrade() {
            Some(process) => process.send_line(line).map_err(|err| err.to_string()),
            None => Err("The agent process is not running.".into()),
        }
    }
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct CapabilityRecord {
    #[serde(with = "lokalbot_core::time::swift_date")]
    expires_at: chrono::DateTime<chrono::Utc>,
}

/// Deletes expired grants (`AgentAccessGate.removeExpiredCapabilities`).
pub fn remove_expired_capabilities(paths: &LibraryPaths) {
    let dir = paths.control_dir().join("agent-capabilities");
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return;
    };
    let now = chrono::Utc::now();
    for entry in entries.flatten() {
        let path = entry.path();
        let live = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<CapabilityRecord>(&bytes).ok())
            .is_some_and(|record| record.expires_at > now);
        if !live {
            let _ = std::fs::remove_file(&path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::launch::SessionChoice;
    use chatgpt::{Credentials, Endpoints, MemoryStore, PLAN_SCOPE};
    use lokalbot_core::Settings;

    fn launcher(root: &std::path::Path, store: MemoryStore) -> PiLauncher {
        let paths = LibraryPaths::new(root);
        PiLauncher {
            dirs: AgentDirectories::new(&paths),
            layout: RuntimeLayout::for_library(&paths),
            manifest: RuntimeManifest::current(),
            paths,
            runtime: None,
            api_key: Arc::new(|| Some("sk-unrelated-fixture".into())),
            chatgpt_account: Arc::new(chatgpt::Account::new(Arc::new(store), Endpoints::default())),
            helpers_dir: None,
            shell: None,
        }
    }

    fn plan_request(root: &std::path::Path) -> LaunchRequest {
        let mut settings = Settings {
            summarizer_backend: SummarizerBackend::ChatGptPlan,
            chatgpt_plan_model: "gpt-6.1-sol".into(),
            ..Settings::default()
        };
        SubscriptionPlan::ChatGpt.set_approved(&mut settings, true);
        LaunchRequest {
            settings,
            workspace: root.to_path_buf(),
            session: SessionChoice::Fresh,
            reasoning_level_file: root.join("level.json"),
            private_roots: Vec::new(),
        }
    }

    fn credentials(scopes: &[&str]) -> Credentials {
        Credentials {
            client_id: "app_issued".into(),
            subject: "user-1".into(),
            email: None,
            id_token: "id".into(),
            access_token: "access-fixture".into(),
            refresh_token: Some("refresh-fixture".into()),
            expires_at: chrono::Utc::now().timestamp() + 3_600,
            scopes: scopes.iter().map(|scope| scope.to_string()).collect(),
        }
    }

    fn configuration_error(result: Result<Connection, LaunchError>) -> String {
        match result {
            Err(LaunchError::Configuration(reason)) => reason,
            Err(other) => panic!("{other:?}"),
            Ok(_) => panic!("the plan must not connect"),
        }
    }

    #[test]
    fn a_plan_task_asks_for_sign_in_before_starting() {
        let dir = tempfile::tempdir().unwrap();
        let signed_out = launcher(dir.path(), MemoryStore::default());
        assert_eq!(
            configuration_error(signed_out.connect(&plan_request(dir.path()))),
            PlanError::SignedOut.to_string()
        );
        let no_grant = launcher(
            dir.path(),
            MemoryStore::signed_in(&credentials(&["openid"])),
        );
        assert_eq!(
            configuration_error(no_grant.connect(&plan_request(dir.path()))),
            PlanError::PlanUsageNotGranted.to_string()
        );
    }

    #[test]
    fn a_plan_task_points_pi_at_a_relay_on_this_computer() {
        let dir = tempfile::tempdir().unwrap();
        let signed_in = launcher(
            dir.path(),
            MemoryStore::signed_in(&credentials(&[PLAN_SCOPE])),
        );
        let connection = signed_in.connect(&plan_request(dir.path())).unwrap();
        let relay = connection.relay.as_ref().expect("a relay");
        let endpoint = &connection.endpoint;
        assert_eq!(endpoint.base_url, relay.base_url());
        assert!(lokalbot_core::access::is_loopback_url(&endpoint.base_url));
        // pi holds the relay's key, never the plan token or a stored API key.
        assert_eq!(endpoint.api_key.as_deref(), Some(relay.key()));
        assert_eq!(endpoint.model, "gpt-6.1-sol");
        assert_eq!(endpoint.api, ProviderApi::Responses);
        assert_eq!(endpoint.plan, Some(SubscriptionPlan::ChatGpt));
        assert_eq!(endpoint.reasoning_dialect, ReasoningDialect::OpenAi);
        assert_eq!(endpoint.context_tokens, 922_000);
        assert!(connection.lease.is_none());
        let port = relay.port();
        drop(connection);
        // The relay stops with the connection.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while std::net::TcpStream::connect(("127.0.0.1", port)).is_ok() {
            assert!(
                std::time::Instant::now() < deadline,
                "the relay kept listening"
            );
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }

    #[test]
    fn expired_capabilities_are_removed_and_live_ones_kept() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LibraryPaths::new(dir.path());
        let live =
            lokalbot_core::access::issue_agent_capability(&paths, chrono::Duration::hours(1))
                .unwrap();
        let folder = paths.control_dir().join("agent-capabilities");
        std::fs::write(folder.join("old.json"), r#"{"digest":"x","expiresAt":0}"#).unwrap();
        std::fs::write(folder.join("junk.json"), "junk").unwrap();
        remove_expired_capabilities(&paths);
        assert!(!folder.join("old.json").exists());
        assert!(!folder.join("junk.json").exists());
        assert!(lokalbot_core::access::meetings_authorization(&paths, Some(&live)).is_some());
    }
}
