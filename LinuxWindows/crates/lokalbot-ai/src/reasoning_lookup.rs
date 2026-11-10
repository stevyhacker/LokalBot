//! What a server publishes about a model's reasoning levels
//! (`ReasoningSupport.resolve`, `OpenRouterModelCatalog.reasoningSupport`,
//! `OllamaEngine.reasoningSupport`): OpenRouter's model list and Ollama's
//! capabilities. Both are read only from origins already allowed for inference, and
//! carry no key and no content. Callers check that the origin is allowed.

use std::collections::HashMap;
use std::sync::LazyLock;
use std::time::{Duration, Instant};

use lokalbot_core::settings::ReasoningLevel;
use parking_lot::Mutex;
use serde_json::{Map, Value, json};

use crate::http;
use crate::think::ReasoningSupport;

/// `OpenRouterModelCatalog.refreshInterval`: a running app looks again once a day.
const REFRESH_INTERVAL: Duration = Duration::from_secs(86_400);
/// A failed list read waits this long, so an offline computer doesn't add a timeout
/// to every Think request.
const RETRY_INTERVAL: Duration = Duration::from_secs(600);
const LIST_TIMEOUT: Duration = Duration::from_secs(10);
const SHOW_TIMEOUT: Duration = Duration::from_secs(3);

/// `reasoning_effort` and OpenRouter `effort` spell Off as "none".
fn level_for_effort(effort: &str) -> Option<ReasoningLevel> {
    use ReasoningLevel::*;
    Some(match effort {
        "none" | "off" => Off,
        "minimal" => Minimal,
        "low" => Low,
        "medium" => Medium,
        "high" => High,
        "xhigh" => Xhigh,
        "max" => Max,
        _ => return None,
    })
}

/// A model's `reasoning` object: `supported_efforts`, whether reasoning is
/// `mandatory` (no Off), and its defaults. No object: the model doesn't reason.
/// Without listed efforts, reasoning can only be switched off.
fn support_of(reasoning: Option<&Map<String, Value>>) -> ReasoningSupport {
    let Some(reasoning) = reasoning else {
        return ReasoningSupport::new(&[], None);
    };
    let mandatory = reasoning
        .get("mandatory")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let mut levels: Vec<ReasoningLevel> = reasoning
        .get("supported_efforts")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .filter_map(level_for_effort)
        .collect();
    levels.retain(|level| *level != ReasoningLevel::Off);
    if !mandatory {
        levels.push(ReasoningLevel::Off);
    }
    let default_level =
        if !mandatory && reasoning.get("default_enabled").and_then(Value::as_bool) == Some(false) {
            Some(ReasoningLevel::Off)
        } else {
            reasoning
                .get("default_effort")
                .and_then(Value::as_str)
                .and_then(level_for_effort)
        };
    ReasoningSupport::sorted(levels, default_level)
}

/// Every listed model's levels, by lowercase id. `None` for a body that isn't a list.
fn support_in_models(json: &Value) -> Option<HashMap<String, ReasoningSupport>> {
    let models = json.get("data")?.as_array()?;
    let mut out = HashMap::new();
    for model in models {
        let Some(id) = model.get("id").and_then(Value::as_str) else {
            continue;
        };
        out.insert(
            id.to_lowercase(),
            support_of(model.get("reasoning").and_then(Value::as_object)),
        );
    }
    Some(out)
}

#[derive(Default)]
struct ModelList {
    by_model: HashMap<String, ReasoningSupport>,
    fetched_at: Option<Instant>,
    attempted_at: Option<Instant>,
}

impl ModelList {
    /// Whether to read the list now: it's a day old, or missing and not just
    /// tried. Saying yes counts as the try.
    fn due(&mut self, now: Instant) -> bool {
        let stale = self
            .fetched_at
            .is_none_or(|at| now.duration_since(at) >= REFRESH_INTERVAL);
        let waiting = self
            .attempted_at
            .is_some_and(|at| now.duration_since(at) < RETRY_INTERVAL);
        if !stale || waiting {
            return false;
        }
        self.attempted_at = Some(now);
        true
    }

    /// Keeps what a read that began at `now` returned.
    fn store(&mut self, now: Instant, parsed: HashMap<String, ReasoningSupport>) {
        self.by_model = parsed;
        self.fetched_at = Some(now);
    }

    /// Reads the list when it is [`due`](Self::due).
    #[cfg(test)]
    fn refresh(
        &mut self,
        now: Instant,
        fetch: impl FnOnce() -> Option<HashMap<String, ReasoningSupport>>,
    ) {
        if self.due(now)
            && let Some(parsed) = fetch()
        {
            self.store(now, parsed);
        }
    }
}

static OPENROUTER: LazyLock<Mutex<ModelList>> = LazyLock::new(Default::default);
/// Held for a read of OpenRouter's list, so callers that arrive during one wait
/// for it. The list has its own lock, held only to look at it: the interface
/// asks [`openrouter_cached`] while drawing and must never wait for the network.
static OPENROUTER_READ: Mutex<()> = Mutex::new(());
/// Ollama's last answers, by server and model. A server that stops answering loses
/// its entry, and what LokalBot knows without asking applies again.
static OLLAMA: LazyLock<Mutex<HashMap<String, ReasoningSupport>>> = LazyLock::new(Default::default);

/// The selected model's levels from OpenRouter's list, read at most daily (`GET
/// <base>/models`). `None` when the model isn't listed.
pub(crate) fn openrouter(base: &str, model: &str) -> Option<ReasoningSupport> {
    let reading = OPENROUTER_READ.lock();
    let now = Instant::now();
    let due = OPENROUTER.lock().due(now);
    if due {
        let agent = http::agent(base, LIST_TIMEOUT);
        let headers = [("Accept", "application/json".to_string())];
        let parsed = http::get_with(&agent, &format!("{base}/models"), &headers)
            .ok()
            .filter(|reply| reply.status == 200)
            .and_then(|reply| reply.json().ok())
            .and_then(|json| support_in_models(&json));
        if let Some(parsed) = parsed {
            OPENROUTER.lock().store(now, parsed);
        }
    }
    drop(reading);
    openrouter_cached(model)
}

/// What the list said, without reading it.
pub(crate) fn openrouter_cached(model: &str) -> Option<ReasoningSupport> {
    OPENROUTER
        .lock()
        .by_model
        .get(&model.to_lowercase())
        .cloned()
}

fn ollama_key(base: &str, model: &str) -> String {
    format!("{base}|{model}")
}

/// Whether Ollama says the model thinks: no capability means nothing to set.
fn support_of_capabilities(capabilities: &[Value], known: ReasoningSupport) -> ReasoningSupport {
    if capabilities
        .iter()
        .any(|capability| capability.as_str() == Some("thinking"))
    {
        known
    } else {
        ReasoningSupport::new(&[], None)
    }
}

/// The model's levels from `POST /api/show` capabilities. `None` if the server
/// doesn't answer. The request carries only the model name.
pub(crate) fn ollama(base: &str, model: &str, known: ReasoningSupport) -> Option<ReasoningSupport> {
    let agent = http::agent(base, SHOW_TIMEOUT);
    let answer = http::post_json(
        &agent,
        &format!("{base}/api/show"),
        None,
        &json!({"model": model}),
    )
    .ok()
    .filter(|reply| reply.status == 200)
    .and_then(|reply| reply.json().ok())
    .and_then(|json| {
        json.get("capabilities")
            .and_then(Value::as_array)
            .map(|capabilities| support_of_capabilities(capabilities, known))
    });
    let mut known_answers = OLLAMA.lock();
    match &answer {
        Some(support) => {
            known_answers.insert(ollama_key(base, model), support.clone());
        }
        None => {
            known_answers.remove(&ollama_key(base, model));
        }
    }
    answer
}

/// What the server last said, without asking.
pub(crate) fn ollama_cached(base: &str, model: &str) -> Option<ReasoningSupport> {
    OLLAMA.lock().get(&ollama_key(base, model)).cloned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::http::testing::{Reply, StubServer};
    use ReasoningLevel::*;
    use std::cell::Cell;

    fn support(reasoning: Value) -> ReasoningSupport {
        support_of(reasoning.as_object())
    }

    #[test]
    fn a_models_object_gives_its_levels_in_order() {
        let found = support(json!({
            "supported_efforts": ["max", "low", "none", "high", "minimal", "xhigh", "medium"],
            "default_effort": "high",
        }));
        assert_eq!(found.levels, [Off, Minimal, Low, Medium, High, Xhigh, Max]);
        assert_eq!(found.default_level, Some(High));
    }

    #[test]
    fn mandatory_reasoning_has_no_off_and_optional_reasoning_always_does() {
        let mandatory = support(json!({
            "mandatory": true,
            "supported_efforts": ["none", "low", "high"],
            "default_enabled": false,
        }));
        assert_eq!(mandatory.levels, [Low, High]);
        assert_eq!(mandatory.default_level, None);
        let optional = support(json!({"supported_efforts": ["high"]}));
        assert_eq!(optional.levels, [Off, High]);
    }

    #[test]
    fn defaults_follow_default_enabled_then_default_effort() {
        let off = support(json!({
            "default_enabled": false,
            "default_effort": "high",
            "supported_efforts": ["high"],
        }));
        assert_eq!(off.default_level, Some(Off));
    }

    #[test]
    fn no_listed_efforts_can_only_switch_off_and_no_object_means_no_control() {
        assert_eq!(support(json!({})).levels, [Off]);
        assert_eq!(support_of(None).levels, []);
    }

    #[test]
    fn unknown_efforts_are_ignored() {
        let found = support(json!({"supported_efforts": ["turbo", "automatic", "low"]}));
        assert_eq!(found.levels, [Off, Low]);
    }

    #[test]
    fn reads_the_model_list() {
        let list = support_in_models(&json!({"data": [
            {"id": "Vendor/Thinker", "reasoning": {"supported_efforts": ["max"]}},
            {"id": "vendor/plain"},
            {"name": "no id"},
        ]}))
        .unwrap();
        assert_eq!(list.len(), 2);
        assert_eq!(list["vendor/thinker"].levels, [Off, Max]);
        assert!(list["vendor/plain"].levels.is_empty());
        assert!(support_in_models(&json!({"error": "nope"})).is_none());
    }

    #[test]
    fn the_list_is_read_daily_and_a_failed_read_waits() {
        let mut list = ModelList::default();
        let start = Instant::now();
        let calls = Cell::new(0);
        let fails = || {
            calls.set(calls.get() + 1);
            None
        };
        let answers = || {
            calls.set(calls.get() + 1);
            Some(HashMap::from([(
                "m".to_string(),
                ReasoningSupport::new(&[Off], None),
            )]))
        };
        list.refresh(start, fails);
        assert_eq!(calls.get(), 1);
        // A failed read isn't tried again for ten minutes.
        list.refresh(start + Duration::from_secs(599), fails);
        assert_eq!(calls.get(), 1);
        list.refresh(start + RETRY_INTERVAL, answers);
        assert_eq!(calls.get(), 2);
        assert!(list.by_model.contains_key("m"));
        // A good read lasts a day, and a later failure keeps what it knew.
        list.refresh(start + RETRY_INTERVAL + Duration::from_secs(60), answers);
        assert_eq!(calls.get(), 2);
        let later = start + RETRY_INTERVAL + REFRESH_INTERVAL;
        list.refresh(later, fails);
        assert_eq!(calls.get(), 3);
        assert!(list.by_model.contains_key("m"));
    }

    /// The interface reads the cached list while drawing, and a read of the
    /// list can take ten seconds on a bad network.
    #[test]
    fn a_read_of_the_list_leaves_the_cached_answers_free() {
        let (release, held) = std::sync::mpsc::channel::<()>();
        let held = Mutex::new(held);
        let server = StubServer::start(move |_| {
            let _ = held.lock().recv_timeout(Duration::from_secs(10));
            Reply::Json(
                200,
                json!({"data": [
                    {"id": "audit/reader", "reasoning": {"supported_efforts": ["low"]}},
                ]}),
            )
        });
        *OPENROUTER.lock() = ModelList::default();
        let base = server.url("");
        let reading = std::thread::spawn(move || openrouter(&base, "Audit/Reader"));
        let asked = Instant::now();
        while server.requests().is_empty() {
            assert!(asked.elapsed() < Duration::from_secs(10), "never asked");
            std::thread::sleep(Duration::from_millis(5));
        }
        // The request is out and unanswered.
        let free = OPENROUTER.try_lock().is_some();
        release.send(()).unwrap();
        let found = reading.join().unwrap();
        assert!(free, "the cached list was locked for the whole read");
        assert_eq!(found.unwrap().levels, [Off, Low]);
        assert_eq!(
            openrouter_cached("audit/reader").unwrap().levels,
            [Off, Low]
        );
    }

    #[test]
    fn ollama_asks_only_with_the_model_name_and_no_key() {
        let server = StubServer::start(|request| {
            assert_eq!(request.path, "/api/show");
            Reply::Json(200, json!({"capabilities": ["completion", "thinking"]}))
        });
        let base = server.url("");
        let known = ReasoningSupport::new(&[Low, High], Some(High));
        let found = ollama(&base, "gpt-oss", known.clone()).unwrap();
        assert_eq!(found, known);
        assert_eq!(ollama_cached(&base, "gpt-oss"), Some(known));
        let sent = server.requests().pop().unwrap();
        assert_eq!(sent.json(), json!({"model": "gpt-oss"}));
        assert_eq!(sent.header("authorization"), None);
    }

    #[test]
    fn an_ollama_model_that_doesnt_think_has_no_control() {
        let server = StubServer::start(|_| {
            Reply::Json(200, json!({"capabilities": ["completion", "vision"]}))
        });
        let known = ReasoningSupport::new(&[Off], None);
        let found = ollama(&server.url(""), "llama", known).unwrap();
        assert!(found.levels.is_empty());
    }

    #[test]
    fn an_ollama_server_that_stops_answering_goes_back_to_what_is_known() {
        let down = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let is_down = down.clone();
        let server = StubServer::start(move |_| {
            if is_down.load(std::sync::atomic::Ordering::SeqCst) {
                Reply::Text(500, "no".into())
            } else {
                Reply::Json(200, json!({"capabilities": ["thinking"]}))
            }
        });
        let base = server.url("");
        let known = ReasoningSupport::new(&[Off], None);
        assert!(ollama(&base, "m", known.clone()).is_some());
        assert!(ollama_cached(&base, "m").is_some());
        down.store(true, std::sync::atomic::Ordering::SeqCst);
        assert!(ollama(&base, "m", known).is_none());
        assert!(ollama_cached(&base, "m").is_none());
    }
}
