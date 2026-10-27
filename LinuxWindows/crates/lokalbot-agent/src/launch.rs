//! The exact pi launch contract (`PiLaunchPlanner.swift`).
//!
//! pi is isolated from the user's `~/.pi` and any folder-local pi
//! configuration (`--no-extensions -e`, `--no-skills --skill`,
//! `--no-prompt-templates`, `--no-approve`) and offline (`--offline` and
//! `PI_SKIP_VERSION_CHECK`, since pi ships update checks and install
//! telemetry on by default). Context files are disabled because pi's upward
//! discovery is not confined to the working folder; workspace files stay
//! readable through the read tool, which the extension gates. LokalBot's own
//! system prompt replaces pi's coding-agent prompt; the extension appends the
//! per-run environment.
//!
//! Additions on Linux and Windows: Bun runs with `--no-install` so a missing
//! import can never be fetched from npm at run time; Bun's transpiler cache
//! and jiti's extension cache are off, since they would keep compiled copies
//! of pi and of the approval extension in `~/.bun` and the shared temporary
//! folder, outside the audited runtime; `LOKALBOT_STORAGE_ROOT`
//! points the bundled `lokalbot-cli` at this library; on Windows without Bash
//! the model gets pi's PowerShell tool instead (see [`crate::shell`]).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::endpoint::LlmEndpoint;

/// Everything needed to spawn one pi RPC subprocess.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LaunchPlan {
    pub executable: PathBuf,
    pub arguments: Vec<String>,
    pub environment: BTreeMap<String, String>,
    pub working_directory: PathBuf,
}

/// How a launch picks its conversation.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub enum SessionChoice {
    /// A new session file.
    #[default]
    Fresh,
    /// pi's `--continue`: the most recent session for this working folder.
    ContinueRecent,
    /// One exact saved session file.
    Saved(PathBuf),
}

/// What the working folder is, for the extension's environment prompt section
/// (`AgentWorkspaceKind` in `PiLaunchPlanner.swift`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WorkspaceKind {
    /// The app's own Agent Workspace.
    AgentWorkspace,
    /// A folder the user picked.
    ChosenFolder,
}

impl WorkspaceKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::AgentWorkspace => "agent-workspace",
            Self::ChosenFolder => "chosen-folder",
        }
    }
}

pub struct PlanInputs<'a> {
    pub bun: &'a Path,
    pub pi_cli: &'a Path,
    pub extension_dir: &'a Path,
    pub skill_dir: Option<&'a Path>,
    /// Replaces pi's default system prompt (`--system-prompt`).
    pub system_prompt: Option<&'a Path>,
    pub session_dir: &'a Path,
    pub pi_config_dir: &'a Path,
    pub workspace: &'a Path,
    pub workspace_kind: Option<WorkspaceKind>,
    pub library_root: &'a Path,
    pub endpoint: &'a LlmEndpoint,
    pub reasoning_level_file: Option<&'a Path>,
    /// Holds `lokalbot-cli`, which the skill calls by name.
    pub helpers_dir: Option<&'a Path>,
    pub private_roots: &'a [PathBuf],
    pub agent_capability: Option<&'a str>,
    pub session: &'a SessionChoice,
    /// `--tools`, when the default tool set must change (Windows without Bash).
    pub tools: Option<&'a [&'a str]>,
    pub base_environment: BTreeMap<String, String>,
}

pub const ENV_BASE_URL: &str = "LOKALBOT_LLM_BASE_URL";
pub const ENV_MODEL: &str = "LOKALBOT_LLM_MODEL";
pub const ENV_CONTEXT: &str = "LOKALBOT_LLM_CTX";
pub const ENV_DIALECT: &str = "LOKALBOT_LLM_REASONING_DIALECT";
pub const ENV_API: &str = "LOKALBOT_LLM_API";
pub const ENV_SERVED_BY: &str = "LOKALBOT_LLM_SERVED_BY";
pub const ENV_REASONING_FILE: &str = "LOKALBOT_LLM_REASONING_FILE";
pub const ENV_PRIVATE_ROOTS: &str = "LOKALBOT_AGENT_PRIVATE_ROOTS";
pub const ENV_API_KEY: &str = "LOKALBOT_LLM_API_KEY";
pub const ENV_WORKSPACE_KIND: &str = "LOKALBOT_AGENT_WORKSPACE_KIND";

pub fn plan(inputs: PlanInputs<'_>) -> LaunchPlan {
    let mut arguments = vec![
        "--no-install".to_string(),
        path_string(inputs.pi_cli),
        "--mode".into(),
        "rpc".into(),
        "--provider".into(),
        "lokalbot".into(),
        "--model".into(),
        inputs.endpoint.model.clone(),
        "--no-extensions".into(),
        "-e".into(),
        path_string(inputs.extension_dir),
        "--no-skills".into(),
    ];
    match inputs.session {
        SessionChoice::Saved(file) => {
            arguments.push("--session".into());
            arguments.push(path_string(file));
        }
        SessionChoice::ContinueRecent => arguments.push("--continue".into()),
        SessionChoice::Fresh => {}
    }
    if let Some(skill) = inputs.skill_dir {
        arguments.push("--skill".into());
        arguments.push(path_string(skill));
    }
    if let Some(prompt) = inputs.system_prompt {
        arguments.push("--system-prompt".into());
        arguments.push(path_string(prompt));
    }
    arguments.extend([
        "--no-prompt-templates".into(),
        "--no-context-files".into(),
        "--no-approve".into(),
        "--session-dir".into(),
        path_string(inputs.session_dir),
        "--offline".into(),
    ]);
    if let Some(tools) = inputs.tools {
        arguments.push("--tools".into());
        arguments.push(tools.join(","));
    }

    let endpoint = inputs.endpoint;
    let mut env = inputs.base_environment;
    set(&mut env, ENV_BASE_URL, Some(endpoint.base_url.clone()));
    set(&mut env, ENV_MODEL, Some(endpoint.model.clone()));
    set(
        &mut env,
        ENV_CONTEXT,
        Some(endpoint.context_tokens.to_string()),
    );
    set(
        &mut env,
        ENV_DIALECT,
        Some(endpoint.reasoning_dialect.as_str().into()),
    );
    set(&mut env, ENV_API, Some(endpoint.api.as_str().into()));
    // A plan relay is on this computer; the model is not. The extension's
    // environment section says who serves it.
    set(
        &mut env,
        ENV_SERVED_BY,
        endpoint
            .plan
            .map(|plan| format!("{} on the user's {}", plan.provider_name(), plan.title())),
    );
    // The host rewrites this file when the reasoning level changes; the
    // extension reads it before every model request. Absent: Automatic.
    set(
        &mut env,
        ENV_REASONING_FILE,
        inputs.reasoning_level_file.map(path_string),
    );
    set(
        &mut env,
        ENV_WORKSPACE_KIND,
        inputs.workspace_kind.map(|kind| kind.as_str().into()),
    );
    let roots: Vec<String> = inputs
        .private_roots
        .iter()
        .map(|p| path_string(p))
        .collect();
    // An encoding failure must stop the extension at startup, never omit the
    // protected roots: `null` fails its launch validation.
    set(
        &mut env,
        ENV_PRIVATE_ROOTS,
        Some(serde_json::to_string(&roots).unwrap_or_else(|_| "null".into())),
    );
    // A credential-free endpoint must not inherit a key for another service.
    // The extension takes the key at startup and removes it from the
    // environment the agent's shell commands inherit.
    set(&mut env, ENV_API_KEY, endpoint.api_key.clone());
    set(
        &mut env,
        lokalbot_core::access::CAPABILITY_ENV,
        inputs.agent_capability.map(str::to_string),
    );
    set(
        &mut env,
        lokalbot_core::paths::STORAGE_ROOT_ENV,
        Some(path_string(inputs.library_root)),
    );
    set(&mut env, "PI_SKIP_VERSION_CHECK", Some("1".into()));
    set(&mut env, "PI_TELEMETRY", Some("0".into()));
    set(
        &mut env,
        "BUN_RUNTIME_TRANSPILER_CACHE_PATH",
        Some("0".into()),
    );
    set(&mut env, "JITI_FS_CACHE", Some("false".into()));
    set(
        &mut env,
        "PI_CODING_AGENT_DIR",
        Some(path_string(inputs.pi_config_dir)),
    );
    if let Some(helpers) = inputs.helpers_dir {
        let existing = get(&env, "PATH").unwrap_or_default();
        let separator = if cfg!(windows) { ";" } else { ":" };
        let value = if existing.is_empty() {
            path_string(helpers)
        } else {
            format!("{}{separator}{existing}", path_string(helpers))
        };
        set(&mut env, "PATH", Some(value));
    }
    LaunchPlan {
        executable: inputs.bun.to_path_buf(),
        arguments,
        environment: env,
        working_directory: inputs.workspace.to_path_buf(),
    }
}

fn path_string(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

/// Environment names are case-insensitive on Windows ("Path"); keep one entry.
fn same_name(a: &str, b: &str) -> bool {
    if cfg!(windows) {
        a.eq_ignore_ascii_case(b)
    } else {
        a == b
    }
}

fn get(env: &BTreeMap<String, String>, key: &str) -> Option<String> {
    env.iter()
        .find(|(name, _)| same_name(name, key))
        .map(|(_, value)| value.clone())
}

fn set(env: &mut BTreeMap<String, String>, key: &str, value: Option<String>) {
    env.retain(|name, _| !same_name(name, key));
    if let Some(value) = value {
        env.insert(key.to_string(), value);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::endpoint::{ProviderApi, ReasoningDialect};
    use lokalbot_core::settings::SubscriptionPlan;

    struct Options {
        api_key: Option<String>,
        inherited_key: Option<&'static str>,
        skill: bool,
        helpers: bool,
        capability: Option<&'static str>,
        session: SessionChoice,
        reasoning_file: Option<PathBuf>,
        tools: Option<Vec<&'static str>>,
        plan: Option<SubscriptionPlan>,
        inherited_served_by: bool,
    }

    impl Default for Options {
        fn default() -> Self {
            Self {
                api_key: None,
                inherited_key: None,
                skill: true,
                helpers: true,
                capability: None,
                session: SessionChoice::Fresh,
                reasoning_file: None,
                tools: None,
                plan: None,
                inherited_served_by: false,
            }
        }
    }

    fn make(options: Options) -> LaunchPlan {
        let mut base = BTreeMap::new();
        base.insert("PATH".to_string(), "/usr/bin:/bin".to_string());
        base.insert("HOME".to_string(), "/home/x".to_string());
        if let Some(key) = options.inherited_key {
            base.insert(ENV_API_KEY.to_string(), key.to_string());
        }
        if options.inherited_served_by {
            base.insert(ENV_SERVED_BY.to_string(), "someone else".into());
        }
        base.insert(
            lokalbot_core::access::CAPABILITY_ENV.to_string(),
            "inherited".into(),
        );
        let endpoint = LlmEndpoint {
            base_url: "http://127.0.0.1:17872/v1".into(),
            model: "qwen2.5-7b-instruct".into(),
            context_tokens: 16_384,
            api_key: options.api_key.clone(),
            reasoning_dialect: ReasoningDialect::LlamaServer,
            api: if options.plan.is_some() {
                ProviderApi::Responses
            } else {
                ProviderApi::ChatCompletions
            },
            plan: options.plan,
        };
        let private_roots = vec![PathBuf::from("/store"), PathBuf::from("/rt")];
        let tools = options.tools.clone();
        plan(PlanInputs {
            bun: Path::new("/rt/bun/bun"),
            pi_cli: Path::new(
                "/rt/pi/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js",
            ),
            extension_dir: Path::new("/rt/lokalbot-extension"),
            skill_dir: options.skill.then_some(Path::new("/rt/lokalbot-cli-skill")),
            system_prompt: Some(Path::new("/rt/lokalbot-system-prompt.md")),
            session_dir: Path::new("/store/agent/sessions"),
            pi_config_dir: Path::new("/store/agent/pi-config"),
            workspace: Path::new("/work"),
            workspace_kind: Some(WorkspaceKind::AgentWorkspace),
            library_root: Path::new("/store"),
            endpoint: &endpoint,
            reasoning_level_file: options.reasoning_file.as_deref(),
            helpers_dir: options.helpers.then_some(Path::new("/opt/lokalbot")),
            private_roots: &private_roots,
            agent_capability: options.capability,
            session: &options.session,
            tools: tools.as_deref(),
            base_environment: base,
        })
    }

    #[test]
    fn arguments_match_the_contract() {
        assert_eq!(
            make(Options::default()).arguments,
            vec![
                "--no-install",
                "/rt/pi/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js",
                "--mode",
                "rpc",
                "--provider",
                "lokalbot",
                "--model",
                "qwen2.5-7b-instruct",
                "--no-extensions",
                "-e",
                "/rt/lokalbot-extension",
                "--no-skills",
                "--skill",
                "/rt/lokalbot-cli-skill",
                "--system-prompt",
                "/rt/lokalbot-system-prompt.md",
                "--no-prompt-templates",
                "--no-context-files",
                "--no-approve",
                "--session-dir",
                "/store/agent/sessions",
                "--offline",
            ]
        );
    }

    #[test]
    fn environment_carries_endpoint_and_privacy_guards() {
        let env = make(Options::default()).environment;
        assert_eq!(env[ENV_BASE_URL], "http://127.0.0.1:17872/v1");
        assert_eq!(env[ENV_MODEL], "qwen2.5-7b-instruct");
        assert_eq!(env[ENV_CONTEXT], "16384");
        assert!(!env.contains_key(ENV_API_KEY));
        assert_eq!(env["PI_SKIP_VERSION_CHECK"], "1");
        assert_eq!(env["PI_TELEMETRY"], "0");
        assert_eq!(env["BUN_RUNTIME_TRANSPILER_CACHE_PATH"], "0");
        assert_eq!(env["JITI_FS_CACHE"], "false");
        assert_eq!(env[ENV_WORKSPACE_KIND], "agent-workspace");
        assert_eq!(env["PI_CODING_AGENT_DIR"], "/store/agent/pi-config");
        assert_eq!(env[lokalbot_core::paths::STORAGE_ROOT_ENV], "/store");
        let separator = if cfg!(windows) { ";" } else { ":" };
        assert_eq!(
            env["PATH"],
            format!("/opt/lokalbot{separator}/usr/bin:/bin")
        );
        assert_eq!(env["HOME"], "/home/x", "the base environment is preserved");
    }

    #[test]
    fn environment_names_the_reasoning_fields_and_level_file() {
        let file = PathBuf::from("/tmp/lokalbot-agent-reasoning-x.json");
        let with_file = make(Options {
            reasoning_file: Some(file.clone()),
            ..Options::default()
        });
        assert_eq!(
            with_file.environment[ENV_REASONING_FILE],
            file.to_string_lossy()
        );
        let plain = make(Options::default()).environment;
        assert_eq!(plain[ENV_DIALECT], "llama-server");
        assert!(!plain.contains_key(ENV_REASONING_FILE));
    }

    #[test]
    fn a_plan_relay_selects_the_responses_api_and_names_who_serves_it() {
        let plain = make(Options {
            inherited_served_by: true,
            ..Options::default()
        })
        .environment;
        assert_eq!(plain[ENV_API], "openai-completions");
        assert!(
            !plain.contains_key(ENV_SERVED_BY),
            "a local model is never described as served by a plan"
        );
        let relayed = make(Options {
            plan: Some(SubscriptionPlan::ChatGpt),
            api_key: Some("relay-fixture-key".into()),
            ..Options::default()
        })
        .environment;
        assert_eq!(relayed[ENV_API], "openai-responses");
        assert_eq!(relayed[ENV_SERVED_BY], "OpenAI on the user's ChatGPT plan");
        assert_eq!(relayed[ENV_API_KEY], "relay-fixture-key");
    }

    #[test]
    fn credential_free_endpoint_cannot_inherit_another_key() {
        let env = make(Options {
            inherited_key: Some("unrelated-fixture-key"),
            ..Options::default()
        })
        .environment;
        assert!(!env.contains_key(ENV_API_KEY));
        let env = make(Options {
            api_key: Some("selected-fixture-key".into()),
            inherited_key: Some("unrelated-fixture-key"),
            ..Options::default()
        })
        .environment;
        assert_eq!(env[ENV_API_KEY], "selected-fixture-key");
    }

    #[test]
    fn private_roots_are_passed_separately_from_the_working_folder() {
        let plan = make(Options::default());
        let roots: Vec<String> =
            serde_json::from_str(&plan.environment[ENV_PRIVATE_ROOTS]).unwrap();
        assert_eq!(roots, vec!["/store", "/rt"]);
        assert_eq!(plan.working_directory, Path::new("/work"));
        assert_eq!(plan.executable, Path::new("/rt/bun/bun"));
    }

    #[test]
    fn no_skill_directory_omits_skill_flag_but_keeps_no_skills() {
        let arguments = make(Options {
            skill: false,
            ..Options::default()
        })
        .arguments;
        assert!(arguments.contains(&"--no-skills".to_string()));
        assert!(!arguments.contains(&"--skill".to_string()));
    }

    #[test]
    fn capability_is_passed_only_when_issued() {
        let key = lokalbot_core::access::CAPABILITY_ENV;
        assert!(!make(Options::default()).environment.contains_key(key));
        assert_eq!(
            make(Options {
                capability: Some("id.secret"),
                ..Options::default()
            })
            .environment[key],
            "id.secret"
        );
    }

    #[test]
    fn continue_and_exact_session() {
        assert!(
            !make(Options::default())
                .arguments
                .contains(&"--continue".into())
        );
        assert!(
            make(Options {
                session: SessionChoice::ContinueRecent,
                ..Options::default()
            })
            .arguments
            .contains(&"--continue".into())
        );
        let saved = PathBuf::from("/store/agent/sessions/saved.jsonl");
        let arguments = make(Options {
            session: SessionChoice::Saved(saved.clone()),
            ..Options::default()
        })
        .arguments;
        assert!(!arguments.contains(&"--continue".into()));
        let at = arguments.iter().position(|a| a == "--session").unwrap();
        assert_eq!(arguments[at + 1], saved.to_string_lossy());
    }

    #[test]
    fn tools_override_is_explicit() {
        let arguments = make(Options {
            tools: Some(vec!["read", "powershell", "edit", "write"]),
            ..Options::default()
        })
        .arguments;
        let at = arguments.iter().position(|a| a == "--tools").unwrap();
        assert_eq!(arguments[at + 1], "read,powershell,edit,write");
        assert!(
            !make(Options::default())
                .arguments
                .contains(&"--tools".into())
        );
    }
}
