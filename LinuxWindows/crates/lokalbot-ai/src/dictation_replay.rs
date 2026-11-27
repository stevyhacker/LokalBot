use std::collections::HashSet;
use std::io::Write;
use std::path::Path;
use std::time::Instant;

use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use lokalbot_core::Settings;
use lokalbot_core::settings::DictationIntent;

use crate::dictation::{
    ComposeProviders, Profile, SavedFacts, ScreenContext, cleanup_system, cleanup_user_prompt,
    compose_user_prompt, prepare_checked_with_lock,
};
use crate::dictation_word_lock::WordLock;
use crate::prompts::DICTATION_COMPOSE_SYSTEM;
use crate::think::ThinkClient;

const MAX_INPUT_BYTES: usize = 4_194_304;
const MAX_CASES: usize = 500;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Input {
    pub cases: Vec<Case>,
    #[serde(default)]
    pub memory_items: Vec<Value>,
    #[serde(default)]
    pub use_visible_context: bool,
    #[serde(default)]
    pub use_meeting_memory: bool,
    #[serde(default)]
    pub use_screen_memory: bool,
    pub use_screen_context: Option<bool>,
    pub window_text_policy: Option<WindowTextPolicy>,
    pub routing: Option<String>,
    pub cleanup_prompt: Option<String>,
    pub word_lock: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowTextPolicy {
    pub limit: u32,
    pub keeps_end: bool,
}

#[derive(Debug, Deserialize)]
pub struct Case {
    pub id: String,
    pub speech: String,
    pub transcribe: Option<bool>,
    pub visible: Option<Value>,
    pub screen: Option<ScreenFixture>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScreenFixture {
    pub app_name: String,
    pub window_title: String,
    pub text: String,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct Observation {
    pub id: String,
    pub text: String,
    pub prompt: String,
    pub system: String,
    #[serde(rename = "memoryIDs")]
    pub memory_ids: Vec<String>,
    #[serde(rename = "visibleIDs")]
    pub visible_ids: Vec<String>,
    #[serde(rename = "textReadIDs")]
    pub text_read_ids: Vec<String>,
    #[serde(rename = "modelCalls")]
    pub model_calls: u32,
    #[serde(rename = "screenReads")]
    pub screen_reads: u32,
    #[serde(rename = "routedAsRequest", skip_serializing_if = "Option::is_none")]
    pub routed_as_request: Option<bool>,
    #[serde(rename = "latencyMs")]
    pub latency_ms: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    pub unsupported: Vec<String>,
}

pub fn parse_input(bytes: &[u8]) -> Result<Input> {
    if bytes.len() > MAX_INPUT_BYTES {
        bail!("fixture is larger than {MAX_INPUT_BYTES} bytes");
    }
    let input: Input = serde_json::from_slice(bytes)?;
    let unique: HashSet<&str> = input.cases.iter().map(|c| c.id.as_str()).collect();
    if input.cases.is_empty() || input.cases.len() > MAX_CASES || unique.len() != input.cases.len()
    {
        bail!("fixture needs 1 to {MAX_CASES} cases with distinct ids");
    }
    Ok(input)
}

pub fn is_loopback_http(url: &str) -> bool {
    let Some(rest) = url.strip_prefix("http://") else {
        return false;
    };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    if authority.contains('@') {
        return false;
    }
    let host = match authority.strip_prefix('[') {
        Some(v6) => v6.split(']').next().unwrap_or_default(),
        None => authority.split(':').next().unwrap_or_default(),
    };
    host.eq_ignore_ascii_case("localhost") || host == "127.0.0.1" || host == "::1"
}

pub fn word_lock_named(name: &str) -> Option<WordLock> {
    match name {
        "off" => Some(WordLock::Off),
        "digitsNamesNegation" => Some(WordLock::DigitsNamesNegation),
        _ => None,
    }
}

pub fn unsupported_for(input: &Input, case: &Case) -> Vec<String> {
    let mut gaps = Vec::new();
    if input.routing.is_some() {
        gaps.push("routing".to_string());
    }
    if input.cleanup_prompt.is_some() {
        gaps.push("cleanupPrompt".to_string());
    }
    if input
        .window_text_policy
        .as_ref()
        .is_some_and(|p| !p.keeps_end || p.limit != 2_000)
    {
        gaps.push("windowTextPolicy".to_string());
    }
    if input
        .word_lock
        .as_deref()
        .is_some_and(|name| word_lock_named(name).is_none())
    {
        gaps.push("wordLock".to_string());
    }
    if case.visible.is_some() && input.use_visible_context {
        gaps.push("visibleContext".to_string());
    }
    let memory_granted = input.use_meeting_memory || input.use_screen_memory;
    if memory_granted && !input.memory_items.is_empty() {
        gaps.push("savedFacts".to_string());
    }
    gaps
}

struct Replayer<'a> {
    think: &'a ThinkClient,
    settings: &'a Settings,
    screen: Option<ScreenContext>,
    screen_reads: u32,
}

impl ComposeProviders for Replayer<'_> {
    fn cancelled(&self) -> bool {
        false
    }
    fn current_settings(&self) -> Settings {
        self.settings.clone()
    }
    fn screen(&mut self) -> Option<ScreenContext> {
        self.screen_reads += 1;
        self.screen.clone()
    }
    fn visible(&mut self) -> Option<String> {
        None
    }
    fn memory(
        &mut self,
        _speech: &str,
        _screen: Option<&ScreenContext>,
        _visible: Option<&str>,
        _settings: &Settings,
    ) -> SavedFacts {
        SavedFacts::default()
    }
    fn memory_is_current(&mut self, _facts: &SavedFacts, _current: &Settings) -> bool {
        true
    }
    fn visible_is_current(&mut self, _text: &str, _current: &Settings) -> bool {
        true
    }
    fn screen_is_current(&mut self, _context: &ScreenContext, _current: &Settings) -> bool {
        true
    }
    fn make_think(&mut self, _settings: &Settings) -> Result<ThinkClient> {
        Ok(self.think.clone())
    }
}

pub fn replay_settings(input: &Input, case: &Case) -> Settings {
    Settings {
        dictation_intent: if case.transcribe == Some(true) {
            DictationIntent::Transcribe
        } else {
            DictationIntent::Compose
        },
        dictation_use_screen_context: input.use_screen_context.unwrap_or(false),
        dictation_use_visible_context: input.use_visible_context,
        dictation_use_meeting_memory: input.use_meeting_memory,
        dictation_use_screen_memory: input.use_screen_memory,
        ..Settings::default()
    }
}

pub fn replay_case(input: &Input, case: &Case, think: &ThinkClient) -> Observation {
    let settings = replay_settings(input, case);
    let screen = case.screen.as_ref().map(|s| ScreenContext {
        app_name: s.app_name.clone(),
        bundle_id: None,
        window_title: s.window_title.clone(),
        visible_text: s.text.clone(),
    });
    let mut replayer = Replayer {
        think,
        settings: &settings,
        screen: screen
            .clone()
            .filter(|_| settings.dictation_use_screen_context),
        screen_reads: 0,
    };
    let started = Instant::now();
    let lock = input
        .word_lock
        .as_deref()
        .and_then(word_lock_named)
        .unwrap_or_default();
    let result = prepare_checked_with_lock(&case.speech, &settings, &mut replayer, lock);
    let latency_ms = started.elapsed().as_secs_f64() * 1000.0;
    let mut observation = Observation {
        id: case.id.clone(),
        text: String::new(),
        prompt: String::new(),
        system: String::new(),
        memory_ids: Vec::new(),
        visible_ids: Vec::new(),
        text_read_ids: Vec::new(),
        model_calls: 0,
        screen_reads: replayer.screen_reads,
        routed_as_request: None,
        latency_ms,
        error: None,
        unsupported: unsupported_for(input, case),
    };
    match result {
        Ok(checked) => {
            let prepared = checked.prepared;
            observation.model_calls = u32::from(prepared.composition_model.is_some());
            observation.routed_as_request = prepared.context_use.map(|u| u.was_writing_request);
            if observation.model_calls == 1 {
                let profile = Profile::from_settings(&settings);
                let spoken = crate::notes::view::normalized_text(&case.speech);
                if prepared.was_writing_request {
                    observation.system = DICTATION_COMPOSE_SYSTEM.to_string();
                    observation.prompt = compose_user_prompt(
                        &spoken,
                        screen.as_ref().filter(|_| prepared.used_screen_context),
                        &profile,
                        None,
                        None,
                    );
                } else {
                    observation.system = cleanup_system(&profile);
                    observation.prompt = cleanup_user_prompt(&spoken);
                }
            }
            observation.text = prepared.text;
        }
        Err(error) => observation.error = Some(error.to_string()),
    }
    observation
}

pub fn run(
    input_path: &Path,
    endpoint: &str,
    token: &str,
    model: &str,
    out: &mut dyn Write,
) -> Result<bool> {
    if !is_loopback_http(endpoint) {
        bail!("the server URL must be plain http on a loopback address");
    }
    let input = parse_input(&std::fs::read(input_path)?)?;
    let think = ThinkClient::llama_server(endpoint, token, model);
    let mut failed = false;
    for case in &input.cases {
        let observation = replay_case(&input, case, &think);
        failed |= observation.error.is_some();
        serde_json::to_writer(&mut *out, &observation)?;
        out.write_all(b"\n")?;
        out.flush()?;
    }
    Ok(failed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::http::testing::{Reply, StubServer};
    use serde_json::json;

    fn fixture(extra: Value) -> Vec<u8> {
        let mut base = json!({
            "cases": [
                {"id": "a", "speech": "we need 3 more testers by 9", "transcribe": false},
                {"id": "b", "speech": "reply that friday works", "screen": {"appName": "Mail", "windowTitle": "Re: review", "text": "Can we move it?"}},
                {"id": "c", "speech": "keep this exactly", "transcribe": true}
            ],
            "memoryItems": [],
            "now": "2026-10-08T12:00:00Z",
            "useVisibleContext": false,
            "useMeetingMemory": false,
            "useScreenMemory": false
        });
        base.as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        serde_json::to_vec(&base).unwrap()
    }

    fn chat(content: &str) -> Reply {
        Reply::Json(
            200,
            json!({"choices": [{"message": {"content": content}, "finish_reason": "stop"}]}),
        )
    }

    #[test]
    fn dictation_replay_parses_the_mac_fixture() {
        let input = parse_input(&fixture(json!({
            "useScreenContext": true,
            "windowTextPolicy": {"limit": 2000, "keepsEnd": true},
            "routing": "commands"
        })))
        .unwrap();
        assert_eq!(input.cases.len(), 3);
        assert_eq!(input.use_screen_context, Some(true));
        assert_eq!(input.cases[1].screen.as_ref().unwrap().app_name, "Mail");
        assert_eq!(input.cases[2].transcribe, Some(true));
        assert_eq!(input.routing.as_deref(), Some("commands"));
    }

    #[test]
    fn dictation_replay_rejects_empty_duplicate_and_oversized_fixtures() {
        assert!(parse_input(br#"{"cases": []}"#).is_err());
        assert!(
            parse_input(br#"{"cases": [{"id": "x", "speech": "a"}, {"id": "x", "speech": "b"}]}"#)
                .is_err()
        );
        assert!(parse_input(&vec![b' '; MAX_INPUT_BYTES + 1]).is_err());
    }

    #[test]
    fn dictation_replay_accepts_only_plain_loopback_http() {
        assert!(is_loopback_http("http://127.0.0.1:8080/v1"));
        assert!(is_loopback_http("http://localhost:8080/v1"));
        assert!(is_loopback_http("http://[::1]:8080/v1"));
        assert!(!is_loopback_http("https://127.0.0.1/v1"));
        assert!(!is_loopback_http("http://example.com/v1"));
        assert!(!is_loopback_http("http://user:pw@127.0.0.1/v1"));
        assert!(!is_loopback_http("http://127.0.0.1.example.com/v1"));
    }

    #[test]
    fn dictation_replay_names_every_condition_the_port_cannot_honour() {
        let plain = parse_input(&fixture(json!({}))).unwrap();
        assert!(unsupported_for(&plain, &plain.cases[0]).is_empty());
        let demanding = parse_input(&fixture(json!({
            "routing": "relays",
            "cleanupPrompt": "composeDecides",
            "windowTextPolicy": {"limit": 12000, "keepsEnd": false},
            "wordLock": "strict",
            "useVisibleContext": true,
            "useMeetingMemory": true,
            "memoryItems": [{"id": "m"}]
        })))
        .unwrap();
        let mut case = Case {
            id: "v".into(),
            speech: "x".into(),
            transcribe: None,
            visible: Some(json!({})),
            screen: None,
        };
        let gaps = unsupported_for(&demanding, &case);
        for name in [
            "routing",
            "cleanupPrompt",
            "windowTextPolicy",
            "wordLock",
            "visibleContext",
            "savedFacts",
        ] {
            assert!(gaps.iter().any(|g| g == name), "{name} in {gaps:?}");
        }
        case.visible = None;
        assert!(
            !unsupported_for(&demanding, &case)
                .iter()
                .any(|g| g == "visibleContext")
        );
    }

    #[test]
    fn dictation_replay_observation_has_the_mac_jsonl_fields() {
        let observation = Observation {
            id: "a".into(),
            text: "t".into(),
            prompt: "p".into(),
            system: "s".into(),
            memory_ids: vec![],
            visible_ids: vec![],
            text_read_ids: vec![],
            model_calls: 1,
            screen_reads: 0,
            routed_as_request: None,
            latency_ms: 1.5,
            error: None,
            unsupported: vec![],
        };
        let value = serde_json::to_value(&observation).unwrap();
        let keys: std::collections::BTreeSet<&str> = value
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        let expected: std::collections::BTreeSet<&str> = [
            "id",
            "text",
            "prompt",
            "system",
            "memoryIDs",
            "visibleIDs",
            "textReadIDs",
            "modelCalls",
            "screenReads",
            "latencyMs",
            "unsupported",
        ]
        .into_iter()
        .collect();
        assert_eq!(keys, expected);
        let routed = Observation {
            routed_as_request: Some(false),
            error: Some("e".into()),
            ..observation
        };
        let value = serde_json::to_value(&routed).unwrap();
        assert_eq!(value["routedAsRequest"], json!(false));
        assert_eq!(value["error"], json!("e"));
    }

    #[test]
    fn dictation_replay_runs_each_case_through_real_preparation() {
        let server =
            StubServer::start(|_| chat("{\"transcript\": \"We need 3 more testers by 9.\"}"));
        let endpoint = server.url("/v1");
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("in.json");
        std::fs::write(&path, fixture(json!({"useScreenContext": true}))).unwrap();
        let mut out = Vec::new();
        let failed = run(&path, &endpoint, "", "m", &mut out).unwrap();
        assert!(!failed);
        let lines: Vec<Value> = String::from_utf8(out)
            .unwrap()
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        assert_eq!(lines.len(), 3);
        assert_eq!(lines[0]["text"], "We need 3 more testers by 9.");
        assert_eq!(lines[0]["modelCalls"], 1);
        assert_eq!(lines[0]["routedAsRequest"], false);
        assert_eq!(lines[0]["screenReads"], 0);
        assert_eq!(lines[1]["routedAsRequest"], true);
        assert_eq!(lines[1]["screenReads"], 1);
        assert!(
            lines[1]["prompt"]
                .as_str()
                .unwrap()
                .contains("Application: Mail")
        );
        assert_eq!(lines[2]["text"], "keep this exactly");
        assert_eq!(lines[2]["modelCalls"], 0);
        assert!(lines[2].get("routedAsRequest").is_none());
    }

    #[test]
    fn dictation_replay_honours_the_word_lock_field() {
        let server = StubServer::start(|_| chat("We need four more testers by nine."));
        let endpoint = server.url("/v1");
        let dir = tempfile::tempdir().unwrap();
        let mut texts = Vec::new();
        for lock in ["off", "digitsNamesNegation"] {
            let path = dir.path().join(format!("{lock}.json"));
            std::fs::write(&path, fixture(json!({"wordLock": lock}))).unwrap();
            let mut out = Vec::new();
            assert!(!run(&path, &endpoint, "", "m", &mut out).unwrap());
            let first: Value =
                serde_json::from_str(String::from_utf8(out).unwrap().lines().next().unwrap())
                    .unwrap();
            assert_eq!(first["unsupported"], json!([]));
            texts.push(first["text"].as_str().unwrap().to_string());
        }
        assert_eq!(texts[0], "We need four more testers by nine.");
        assert_eq!(texts[1], "we need 3 more testers by 9");
    }

    #[test]
    fn dictation_replay_refuses_a_remote_endpoint() {
        let mut out = Vec::new();
        assert!(
            run(
                Path::new("/nonexistent"),
                "https://example.com/v1",
                "",
                "m",
                &mut out
            )
            .is_err()
        );
    }
}
