//! Reading a typed value, mapping it to what `Settings` stores, and deciding how
//! a change is authorized (`SettingChange.swift`, `SettingsSnapshot.swift`,
//! `SettingsChangeApplier.swift`). Pure, so the app and the tests share it.

use chrono::{DateTime, Local, Utc};
use serde_json::{Map, Value, json};

use super::protocol::ControlError;
use super::registry::{self, SettingCategory, SettingKind, SettingSpec, SettingTier, TextFormat};
use super::{encoded, json_eq, optional_json_eq, redact_url};
use crate::model::activity::ScreenContextMode;
use crate::settings::{Settings, split_list};

/// How one requested change is authorized. Only `Preference` and `Narrowing`
/// changes apply directly; `Widening` needs the person's approval in the app.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChangeClass {
    Unchanged,
    Preference,
    Narrowing,
    Widening,
    ReadOnly,
}

impl ChangeClass {
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Unchanged => "unchanged",
            Self::Preference => "preference",
            Self::Narrowing => "narrowing",
            Self::Widening => "widening",
            Self::ReadOnly => "readOnly",
        }
    }
}

impl SettingSpec {
    fn invalid(&self, message: &str) -> ControlError {
        ControlError::invalid_value(self.key, message)
    }

    /// Reads a value typed on the command line into the form `config get`
    /// prints: tokens for choices, numbers, booleans, lists. Lists and
    /// structured values also accept JSON.
    pub fn parse(&self, text: &str) -> Result<Value, ControlError> {
        let trimmed = text.trim();
        match self.kind {
            SettingKind::Bool => match trimmed.to_lowercase().as_str() {
                "true" | "on" | "yes" | "1" => Ok(json!(true)),
                "false" | "off" | "no" | "0" => Ok(json!(false)),
                _ => Err(self.invalid("expects true or false")),
            },
            SettingKind::Integer(_) => trimmed
                .parse::<i64>()
                .map(|value| json!(value))
                .map_err(|_| self.invalid("expects a whole number")),
            SettingKind::Number(_) => match trimmed.parse::<f64>() {
                Ok(value) if value.is_finite() => Ok(json!(value)),
                _ => Err(self.invalid("expects a number")),
            },
            SettingKind::Text(format) => Ok(json!(if format == TextFormat::Plain {
                text
            } else {
                trimmed
            })),
            SettingKind::Choice(_) => Ok(json!(trimmed)),
            SettingKind::TextList | SettingKind::ChoiceList(_) => {
                if trimmed.starts_with('[') {
                    return self.json_value(trimmed);
                }
                let items: Vec<&str> = trimmed
                    .split(',')
                    .map(str::trim)
                    .filter(|item| !item.is_empty())
                    .collect();
                Ok(json!(items))
            }
            SettingKind::Structured => self.json_value(trimmed),
        }
    }

    fn json_value(&self, text: &str) -> Result<Value, ControlError> {
        serde_json::from_str(text).map_err(|_| self.invalid("is not valid JSON"))
    }

    /// The value `Settings` stores for a presented value, after type, range,
    /// and choice checks. The app's decoder still has the last word.
    pub fn stored_from_presented(&self, value: &Value) -> Result<Value, ControlError> {
        match self.kind {
            SettingKind::Bool => {
                if value.is_boolean() {
                    Ok(value.clone())
                } else {
                    Err(self.invalid("expects true or false"))
                }
            }
            SettingKind::Integer(range) => {
                let Some(number) = whole_number(value) else {
                    return Err(self.invalid("expects a whole number"));
                };
                if let Some((low, high)) = range
                    && !(low..=high).contains(&number)
                {
                    return Err(self.invalid(&format!("must be between {low} and {high}")));
                }
                Ok(json!(number))
            }
            SettingKind::Number(range) => {
                let Some(number) = value.as_f64().filter(|n| n.is_finite()) else {
                    return Err(self.invalid("expects a number"));
                };
                if let Some((low, high)) = range
                    && !(low..=high).contains(&number)
                {
                    return Err(self.invalid(&format!(
                        "must be between {} and {}",
                        format_number(low),
                        format_number(high)
                    )));
                }
                Ok(value.clone())
            }
            SettingKind::Text(_) => {
                if value.is_string() {
                    Ok(value.clone())
                } else {
                    Err(self.invalid("expects text"))
                }
            }
            SettingKind::TextList => match value {
                Value::Array(items) if items.iter().all(Value::is_string) => Ok(value.clone()),
                _ => Err(self.invalid("expects a list of text")),
            },
            SettingKind::Choice(choices) => {
                let token = value.as_str();
                choices
                    .iter()
                    .find(|choice| Some(choice.token) == token)
                    .map(|choice| choice.stored.json())
                    .ok_or_else(|| self.invalid(&format!("expects one of: {}", tokens(choices))))
            }
            SettingKind::ChoiceList(choices) => {
                let complaint = || self.invalid(&format!("expects a list of: {}", tokens(choices)));
                let Value::Array(items) = value else {
                    return Err(complaint());
                };
                let mut stored: Vec<Value> = Vec::new();
                for item in items {
                    let token = item.as_str();
                    let Some(choice) = choices.iter().find(|c| Some(c.token) == token) else {
                        return Err(complaint());
                    };
                    let value = choice.stored.json();
                    if !stored.contains(&value) {
                        stored.push(value);
                    }
                }
                Ok(Value::Array(stored))
            }
            SettingKind::Structured => match value {
                Value::Object(_) | Value::Array(_) => Ok(value.clone()),
                _ => Err(self.invalid("expects a JSON object, as `config get` prints it")),
            },
        }
    }

    /// Whether a change from `old` to `new` (both stored values) can apply
    /// directly. A consent setting widens when it captures, reads, records,
    /// keeps, or sends more; narrowing it is always allowed.
    pub fn classify(&self, old: Option<&Value>, new: &Value) -> ChangeClass {
        if old.is_some_and(|old| json_eq(old, new)) {
            return ChangeClass::Unchanged;
        }
        match self.tier {
            SettingTier::ReadOnly => ChangeClass::ReadOnly,
            SettingTier::Preference => ChangeClass::Preference,
            SettingTier::Consent => {
                if self.widens(old, new) {
                    ChangeClass::Widening
                } else {
                    ChangeClass::Narrowing
                }
            }
        }
    }

    fn widens(&self, old: Option<&Value>, new: &Value) -> bool {
        match self.key {
            // Requiring a calendar match narrows auto-recording; dropping it widens.
            "requireCalendarForBrowser" => return *new == json!(false),
            // Longer retention keeps more; shorter deletes, which goes through
            // the reviewed cleanup. Either way the person decides.
            "retentionDays" | "keepOCRTextForever" => return true,
            "autoRecordMode" => return self.choice_stored("automatic").as_ref() == Some(new),
            "screenContextCaptureMode" => {
                return self.choice_rank(Some(new)) > self.choice_rank(old);
            }
            "openRouterDataPolicy" => {
                return self.choice_stored("accountPolicy").as_ref() == Some(new);
            }
            // Each later source puts another third-party host ahead of the
            // earlier ones (ModelScope, then HF-Mirror, then Hugging Face), so
            // only moving back toward Hugging Face narrows.
            "modelDownloadSource" => return self.choice_rank(Some(new)) > self.choice_rank(old),
            // Choices run from the shortest window to all history, so a later
            // choice shares more with paired devices.
            "companionHistory" => return self.choice_rank(Some(new)) > self.choice_rank(old),
            _ => {}
        }
        match self.kind {
            SettingKind::Bool => *new == json!(true),
            SettingKind::Text(TextFormat::CommaSeparated) => {
                // Exclusions: removing an entry captures or suggests in more places.
                let before = list_entries(old.and_then(Value::as_str).unwrap_or(""));
                let after = list_entries(new.as_str().unwrap_or(""));
                !before.is_subset(&after)
            }
            // A new export or routine folder writes outside the library.
            SettingKind::Text(TextFormat::Path) => !new.as_str().unwrap_or("").is_empty(),
            SettingKind::TextList => {
                // Approved origins: adding one sends data to a new place.
                let before = lowered_strings(old);
                let after = lowered_strings(Some(new));
                !after.is_subset(&before)
            }
            _ => true,
        }
    }

    fn choice_stored(&self, token: &str) -> Option<Value> {
        self.kind
            .choices()?
            .iter()
            .find(|choice| choice.token == token)
            .map(|choice| choice.stored.json())
    }

    fn choice_rank(&self, value: Option<&Value>) -> usize {
        let Some(value) = value else {
            return 0;
        };
        self.kind
            .choices()
            .and_then(|choices| {
                choices
                    .iter()
                    .position(|choice| json_eq(&choice.stored.json(), value))
            })
            .unwrap_or(0)
    }

    /// A stored value as `config list` and approval replies show it.
    pub fn presented_redacted(&self, stored: Option<&Value>) -> Value {
        let Some(stored) = stored else {
            return Value::Null;
        };
        if matches!(self.kind, SettingKind::Text(TextFormat::Url))
            && let Some(url) = stored.as_str()
        {
            return json!(redact_url(url));
        }
        self.presented(stored)
    }
}

fn whole_number(value: &Value) -> Option<i64> {
    if let Some(number) = value.as_i64() {
        return Some(number);
    }
    value
        .as_f64()
        .filter(|n| n.fract() == 0.0 && n.abs() < 1e15)
        .map(|n| n as i64)
}

fn tokens(choices: &[registry::SettingChoice]) -> String {
    choices
        .iter()
        .map(|choice| choice.token)
        .collect::<Vec<_>>()
        .join(", ")
}

fn format_number(number: f64) -> String {
    if number.fract() == 0.0 {
        format!("{}", number as i64)
    } else {
        number.to_string()
    }
}

fn list_entries(text: &str) -> std::collections::HashSet<String> {
    split_list(text)
        .into_iter()
        .map(|entry| entry.to_lowercase())
        .collect()
}

fn lowered_strings(value: Option<&Value>) -> std::collections::HashSet<String> {
    value
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_lowercase)
                .collect()
        })
        .unwrap_or_default()
}

/// A `settings.set` request: values as `config get` prints them, keys to reset
/// to their defaults, and whether to only report what would happen.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ChangeRequest {
    pub changes: Map<String, Value>,
    pub reset: Vec<String>,
    pub dry_run: bool,
}

impl ChangeRequest {
    pub fn from_params(params: Option<&Map<String, Value>>) -> Result<Self, ControlError> {
        let mut request = Self::default();
        if let Some(value) = params.and_then(|p| p.get("changes")) {
            let Some(object) = value.as_object() else {
                return Err(ControlError::invalid_request(
                    "\"changes\" must be an object of setting keys and values.",
                ));
            };
            request.changes = object.clone();
        }
        if let Some(value) = params.and_then(|p| p.get("reset")) {
            let keys = value
                .as_array()
                .filter(|items| items.iter().all(Value::is_string))
                .ok_or_else(|| {
                    ControlError::invalid_request("\"reset\" must be a list of setting keys.")
                })?;
            request.reset = keys
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect();
        }
        if request.changes.is_empty() && request.reset.is_empty() {
            return Err(ControlError::invalid_request(
                "Name at least one setting to change or reset.",
            ));
        }
        if let Some(overlap) = request
            .reset
            .iter()
            .find(|key| request.changes.contains_key(*key))
        {
            return Err(ControlError::invalid_request(format!(
                "{overlap} is both changed and reset."
            )));
        }
        if let Some(Value::Bool(value)) = params.and_then(|p| p.get("dryRun")) {
            request.dry_run = *value;
        }
        Ok(request)
    }

    pub fn params(&self) -> Map<String, Value> {
        let mut params = Map::new();
        params.insert("dryRun".into(), json!(self.dry_run));
        if !self.changes.is_empty() {
            params.insert("changes".into(), Value::Object(self.changes.clone()));
        }
        if !self.reset.is_empty() {
            params.insert("reset".into(), json!(self.reset));
        }
        params
    }
}

/// One change in a plan. `stored: None` removes the key, for an optional
/// setting reset to its default.
#[derive(Clone, Debug, PartialEq)]
pub struct PlanItem {
    pub spec: SettingSpec,
    pub previous: Option<Value>,
    pub stored: Option<Value>,
    pub change: ChangeClass,
}

/// What a `settings.set` request would do to the current settings: the stored
/// value each key gets and how each change is authorized.
#[derive(Clone, Debug, PartialEq)]
pub struct ChangePlan {
    pub items: Vec<PlanItem>,
}

impl ChangePlan {
    pub fn read_only(&self) -> Vec<&PlanItem> {
        self.of(ChangeClass::ReadOnly)
    }

    pub fn widening(&self) -> Vec<&PlanItem> {
        self.of(ChangeClass::Widening)
    }

    fn of(&self, class: ChangeClass) -> Vec<&PlanItem> {
        self.items.iter().filter(|i| i.change == class).collect()
    }

    pub fn applicable(&self) -> Vec<&PlanItem> {
        self.items
            .iter()
            .filter(|i| matches!(i.change, ChangeClass::Preference | ChangeClass::Narrowing))
            .collect()
    }

    /// Applicable and widening items together, in order: everything the
    /// person is asked about or that applies with it.
    pub fn changed(&self) -> Vec<PlanItem> {
        self.items
            .iter()
            .filter(|i| {
                matches!(
                    i.change,
                    ChangeClass::Preference | ChangeClass::Narrowing | ChangeClass::Widening
                )
            })
            .cloned()
            .collect()
    }

    pub fn make(
        request: &ChangeRequest,
        current: &Map<String, Value>,
        defaults: &Map<String, Value>,
    ) -> Result<Self, ControlError> {
        let mut items: Vec<PlanItem> = Vec::new();
        for (key, value) in &request.changes {
            let Some(spec) = registry::spec(key) else {
                return Err(ControlError::unknown_key(key));
            };
            let mut stored = spec.stored_from_presented(value)?;
            // `config list` and `export` show URLs without user info or query.
            // Writing that form back must not strip them from the real value.
            if matches!(spec.kind, SettingKind::Text(TextFormat::Url))
                && let Some(existing) = current.get(key).and_then(Value::as_str)
                && stored.as_str() == Some(redact_url(existing).as_str())
            {
                stored = json!(existing);
            }
            items.push(PlanItem {
                spec: *spec,
                previous: current.get(key).cloned(),
                change: spec.classify(current.get(key), &stored),
                stored: Some(stored),
            });
        }
        for key in &request.reset {
            let Some(spec) = registry::spec(key) else {
                return Err(ControlError::unknown_key(key));
            };
            let stored = defaults.get(key).cloned();
            let change = if optional_json_eq(stored.as_ref(), current.get(key)) {
                ChangeClass::Unchanged
            } else {
                spec.classify(current.get(key), stored.as_ref().unwrap_or(&Value::Null))
            };
            items.push(PlanItem {
                spec: *spec,
                previous: current.get(key).cloned(),
                stored,
                change,
            });
        }
        let order = |key: &str| {
            registry::all()
                .iter()
                .position(|spec| spec.key == key)
                .unwrap_or(0)
        };
        items.sort_by_key(|item| order(item.spec.key));
        Ok(Self { items })
    }

    /// Reviewed items again, from the settings as they are now: the same keys
    /// and values, each classified from its current value.
    pub fn rebasing(items: &[PlanItem], current: &Map<String, Value>) -> Self {
        Self {
            items: items
                .iter()
                .map(|item| {
                    let previous = current.get(item.spec.key).cloned();
                    let change = if optional_json_eq(item.stored.as_ref(), previous.as_ref()) {
                        ChangeClass::Unchanged
                    } else {
                        item.spec.classify(
                            previous.as_ref(),
                            item.stored.as_ref().unwrap_or(&Value::Null),
                        )
                    };
                    PlanItem {
                        spec: item.spec,
                        previous,
                        stored: item.stored.clone(),
                        change,
                    }
                })
                .collect(),
        }
    }

    /// Whether this plan widens something `reviewed` did not show: a widening
    /// change that was not on it, or one that now starts from another value.
    pub fn widens_beyond(&self, reviewed: &[PlanItem]) -> bool {
        self.widening().iter().any(|item| {
            let Some(shown) = reviewed.iter().find(|r| r.spec.key == item.spec.key) else {
                return true;
            };
            shown.change != ChangeClass::Widening
                || !optional_json_eq(shown.previous.as_ref(), item.previous.as_ref())
        })
    }

    /// The report each item gets in a `settings.set` reply.
    pub fn entries(&self) -> Vec<Value> {
        self.items.iter().map(plan_entry).collect()
    }
}

pub fn plan_entry(item: &PlanItem) -> Value {
    json!({
        "key": item.spec.key,
        "title": item.spec.title,
        "tier": item.spec.tier.raw_value(),
        "change": item.change.raw_value(),
        "previous": item.spec.presented_redacted(item.previous.as_ref()),
        "value": item.spec.presented_redacted(item.stored.as_ref()),
    })
}

/// What the approval card says a change does, in full. Lists name every entry
/// added and removed; other values show before and after.
pub fn change_lines(spec: &SettingSpec, old: Option<&Value>, new: Option<&Value>) -> Vec<String> {
    use lokalbot_i18n::tr;
    if let (Some(before), Some(after)) =
        (card_list_entries(spec, old), card_list_entries(spec, new))
    {
        let keys = |list: &[String]| -> std::collections::HashSet<String> {
            list.iter().map(|entry| entry.to_lowercase()).collect()
        };
        let (before_keys, after_keys) = (keys(&before), keys(&after));
        let added: Vec<&str> = after
            .iter()
            .filter(|entry| !before_keys.contains(&entry.to_lowercase()))
            .map(String::as_str)
            .collect();
        let removed: Vec<&str> = before
            .iter()
            .filter(|entry| !after_keys.contains(&entry.to_lowercase()))
            .map(String::as_str)
            .collect();
        let mut lines = Vec::new();
        if !added.is_empty() {
            lines.push(lokalbot_i18n::format(
                "Adds: {0}",
                &[("0", added.join(", "))],
            ));
        }
        if !removed.is_empty() {
            lines.push(lokalbot_i18n::format(
                "Removes: {0}",
                &[("0", removed.join(", "))],
            ));
        }
        if !lines.is_empty() {
            return lines;
        }
    }
    let before = display_text(spec, old);
    let after = display_text(spec, new);
    let line = format!("{before} → {after}");
    if before == after && !optional_json_eq(old, new) {
        // A URL's user info or query, or a structured value, changed.
        return vec![
            line,
            tr("Changes details that are hidden here, such as a URL's password or query.")
                .to_string(),
        ];
    }
    vec![line]
}

/// A setting's whole value as the person reads it. URLs leave out user info and
/// query.
pub fn display_text(spec: &SettingSpec, value: Option<&Value>) -> String {
    use lokalbot_i18n::tr;
    let Some(value) = value else {
        return tr("Default").to_string();
    };
    match value {
        Value::Bool(flag) => tr(if *flag { "On" } else { "Off" }).to_string(),
        Value::Number(number) => match spec.presented(value) {
            Value::String(token) => token,
            _ => number.to_string(),
        },
        Value::String(text) => {
            if matches!(spec.kind, SettingKind::Text(TextFormat::Url)) {
                return redact_url(text);
            }
            if text.is_empty() {
                return tr("Not set").to_string();
            }
            // Choices stored as display names read better than tokens.
            if matches!(spec.kind, SettingKind::Choice(_)) {
                return tr(text).to_string();
            }
            text.clone()
        }
        Value::Array(items) => {
            let names: Vec<String> = items
                .iter()
                .map(|item| spec.presented(item).as_str().unwrap_or("?").to_string())
                .collect();
            if names.is_empty() {
                tr("None").to_string()
            } else {
                names.join(", ")
            }
        }
        Value::Null | Value::Object(_) => tr("Configured").to_string(),
    }
}

/// The entries of a list setting, or `None` for other settings.
fn card_list_entries(spec: &SettingSpec, value: Option<&Value>) -> Option<Vec<String>> {
    match spec.kind {
        SettingKind::TextList | SettingKind::ChoiceList(_) => match value {
            Some(Value::Array(items)) => Some(
                items
                    .iter()
                    .map(|item| spec.presented(item).as_str().unwrap_or("?").to_string())
                    .collect(),
            ),
            None => Some(Vec::new()),
            _ => None,
        },
        SettingKind::Text(TextFormat::CommaSeparated) => {
            Some(split_list(value.and_then(Value::as_str).unwrap_or("")))
        }
        _ => None,
    }
}

/// What `config list` and `config get` report: registry keys only, choice
/// values as tokens, URLs without user info or query.
pub fn snapshot_entries(settings: &Settings, specs: &[&SettingSpec]) -> Vec<Value> {
    let current = encoded(settings);
    let defaults = encoded(&Settings::default());
    specs
        .iter()
        .map(|spec| {
            let value = spec.presented_redacted(current.get(spec.key));
            let default = spec.presented_redacted(defaults.get(spec.key));
            let changed = !json_eq(&value, &default);
            json!({
                "key": spec.key,
                "title": spec.title,
                "category": spec.category.raw_value(),
                "tier": spec.tier.raw_value(),
                "type": spec.kind.type_name(),
                "value": value,
                "default": default,
                "changed": changed,
            })
        })
        .collect()
}

/// The specs a `settings.list` request asks for, in registry order.
pub fn specs_for_category(
    category: Option<&str>,
) -> Result<Vec<&'static SettingSpec>, ControlError> {
    let Some(category) = category else {
        return Ok(registry::all().iter().collect());
    };
    let Some(wanted) = SettingCategory::parse(category) else {
        let names: Vec<&str> = SettingCategory::ALL.iter().map(|c| c.raw_value()).collect();
        return Err(ControlError::invalid_request(format!(
            "Unknown category {category}. Categories: {}.",
            names.join(", ")
        )));
    };
    Ok(registry::all()
        .iter()
        .filter(|spec| spec.category == wanted)
        .collect())
}

/// The rules the Settings controls apply alongside a change, so a change made
/// anywhere leaves the same settings (`AppState.coupledSettings`).
pub fn coupled_settings(mut new: Settings, old: &Settings, now: DateTime<Utc>) -> Settings {
    if old.tracking_enabled && !new.tracking_enabled {
        new.screen_context_capture_mode = ScreenContextMode::ActivityOnly;
    }
    if new.screen_context_capture_mode != old.screen_context_capture_mode
        && new.screen_context_capture_mode != ScreenContextMode::ActivityOnly
    {
        new.tracking_enabled = true;
    }
    if new.dreaming_enabled != old.dreaming_enabled {
        const KEY: &str = "dreamingFirstEligibleDayKey";
        if new.dreaming_enabled {
            // The Mac's key: the overnight review starts from the day before.
            let yesterday = now.with_timezone(&Local).date_naive() - chrono::Duration::days(1);
            new.other
                .insert(KEY.into(), json!(yesterday.format("%Y-%m-%d").to_string()));
        } else {
            new.other.remove(KEY);
        }
    }
    new
}

/// Applies checked plan items through the real decoder, so a value the app
/// would reject or adjust is reported instead of silently stored as something
/// else, then applies the couplings Settings enforces.
pub fn apply_items(
    items: &[PlanItem],
    settings: &Settings,
    now: DateTime<Utc>,
) -> Result<Settings, ControlError> {
    let Value::Object(mut object) = serde_json::to_value(settings).unwrap_or(Value::Null) else {
        return Err(ControlError::invalid_request(
            "LokalBot could not read its settings.",
        ));
    };
    for item in items {
        match &item.stored {
            Some(value) => {
                object.insert(item.spec.key.to_string(), value.clone());
                // Turning this on from an approved card or Undo is the person's
                // own choice, which is what reading depends on.
                if item.spec.key == "codingAgentEvidenceEnabled" && *value == json!(true) {
                    object.insert("codingAgentEvidenceConfirmed".into(), json!(true));
                }
            }
            None => {
                object.remove(item.spec.key);
            }
        }
    }
    let decoded: Settings = match serde_json::from_value(Value::Object(object)) {
        Ok(decoded) => decoded,
        Err(err) => {
            // Name the value at fault when one can be singled out.
            for item in items {
                if !accepted_alone(item, settings) {
                    return Err(ControlError::invalid_value(
                        item.spec.key,
                        "isn't a value LokalBot accepts",
                    ));
                }
            }
            return Err(ControlError::invalid_request(format!(
                "LokalBot could not read the changed settings: {err}"
            )));
        }
    };
    let result = encoded(&decoded);
    for item in items {
        if !optional_json_eq(result.get(item.spec.key), item.stored.as_ref()) {
            return Err(ControlError::invalid_value(
                item.spec.key,
                "isn't a value LokalBot accepts",
            ));
        }
    }
    Ok(coupled_settings(decoded, settings, now))
}

fn accepted_alone(item: &PlanItem, settings: &Settings) -> bool {
    let Value::Object(mut object) = serde_json::to_value(settings).unwrap_or(Value::Null) else {
        return true;
    };
    if let Some(value) = &item.stored {
        object.insert(item.spec.key.to_string(), value.clone());
    }
    serde_json::from_value::<Settings>(Value::Object(object)).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(key: &str) -> &'static SettingSpec {
        registry::spec(key).unwrap_or_else(|| panic!("{key}"))
    }

    fn code(result: Result<impl Sized, ControlError>) -> Option<String> {
        result.err().map(|err| err.code)
    }

    #[test]
    fn parses_command_line_values_by_kind() {
        assert_eq!(spec("menuBarOnly").parse("off").unwrap(), json!(false));
        assert_eq!(spec("menuBarOnly").parse("YES").unwrap(), json!(true));
        assert_eq!(
            code(spec("menuBarOnly").parse("maybe")).as_deref(),
            Some("invalid_value")
        );
        assert_eq!(spec("dayDigestHour").parse("19").unwrap(), json!(19));
        assert_eq!(spec("speechSpeed").parse("1.5").unwrap(), json!(1.5));
        assert_eq!(
            spec("enabledMemoryRoutines")
                .parse("dailyStandup, localJournal")
                .unwrap(),
            json!(["dailyStandup", "localJournal"])
        );
        assert_eq!(
            spec("approvedRemoteInferenceOrigins")
                .parse("[\"https://a.example\"]")
                .unwrap(),
            json!(["https://a.example"])
        );
        assert_eq!(
            spec("openAIBaseURL").parse("  http://host/v1 ").unwrap(),
            json!("http://host/v1")
        );
        assert_eq!(
            spec("dayDigestCustomPrompt")
                .parse(" keep spaces ")
                .unwrap(),
            json!(" keep spaces ")
        );
        assert_eq!(
            spec("dictationShortcut").parse(" Alt+Space ").unwrap(),
            json!("Alt+Space")
        );
    }

    #[test]
    fn maps_tokens_to_stored_values_and_checks_ranges() {
        assert_eq!(
            spec("autoRecordMode")
                .stored_from_presented(&json!("manual"))
                .unwrap(),
            json!("Never auto-record")
        );
        assert_eq!(
            code(spec("autoRecordMode").stored_from_presented(&json!("Never auto-record")))
                .as_deref(),
            Some("invalid_value")
        );
        assert_eq!(
            spec("cotypingAcceptKey")
                .stored_from_presented(&json!("rightArrow"))
                .unwrap(),
            json!(124)
        );
        assert_eq!(
            code(spec("dayDigestHour").stored_from_presented(&json!(24))).as_deref(),
            Some("invalid_value")
        );
        assert_eq!(
            code(spec("speechSpeed").stored_from_presented(&json!(3.0))).as_deref(),
            Some("invalid_value")
        );
        assert_eq!(
            spec("enabledMemoryRoutines")
                .stored_from_presented(&json!(["dailyStandup", "dailyStandup"]))
                .unwrap(),
            json!(["dailyStandup"])
        );
        assert_eq!(
            code(spec("noteTemplate").stored_from_presented(&json!(true))).as_deref(),
            Some("invalid_value")
        );
    }

    #[test]
    fn classifies_widening_and_narrowing() {
        let class = |key: &str, from: Value, to: Value| spec(key).classify(Some(&from), &to);
        use ChangeClass::*;
        assert_eq!(
            class("appTheme", json!("system"), json!("dark")),
            Preference
        );
        assert_eq!(class("appTheme", json!("dark"), json!("dark")), Unchanged);
        assert_eq!(
            class("customBuiltInModels", json!([]), json!([{"id": "x"}])),
            ReadOnly
        );
        assert_eq!(
            class("trackingEnabled", json!(false), json!(true)),
            Widening
        );
        assert_eq!(
            class("trackingEnabled", json!(true), json!(false)),
            Narrowing
        );
        assert_eq!(
            class("requireCalendarForBrowser", json!(true), json!(false)),
            Widening
        );
        assert_eq!(
            class("requireCalendarForBrowser", json!(false), json!(true)),
            Narrowing
        );
        assert_eq!(
            class(
                "autoRecordMode",
                json!("Ask via notification"),
                json!("Record automatically")
            ),
            Widening
        );
        assert_eq!(
            class(
                "autoRecordMode",
                json!("Record automatically"),
                json!("Never auto-record")
            ),
            Narrowing
        );
        assert_eq!(
            class(
                "screenContextCaptureMode",
                json!("Activity only"),
                json!("Text context")
            ),
            Widening
        );
        assert_eq!(
            class(
                "screenContextCaptureMode",
                json!("Text + visual context"),
                json!("Text context")
            ),
            Narrowing
        );
        assert_eq!(
            class(
                "excludedApps",
                json!("1Password, Bitwarden"),
                json!("1Password, Bitwarden, Slack")
            ),
            Narrowing
        );
        assert_eq!(
            class(
                "excludedApps",
                json!("1Password, Bitwarden"),
                json!("bitwarden")
            ),
            Widening
        );
        // Lists here may also be separated by newlines.
        assert_eq!(
            class(
                "excludedApps",
                json!("1Password\nBitwarden"),
                json!("1Password, Bitwarden, Slack")
            ),
            Narrowing
        );
        assert_eq!(
            class(
                "approvedRemoteInferenceOrigins",
                json!(["https://a"]),
                json!(["https://a", "https://b"])
            ),
            Widening
        );
        assert_eq!(
            class(
                "approvedRemoteInferenceOrigins",
                json!(["https://a", "https://b"]),
                json!(["https://A"])
            ),
            Narrowing
        );
        assert_eq!(
            class(
                "dailyMemoryExportFolder",
                json!(""),
                json!("/home/me/Notes")
            ),
            Widening
        );
        assert_eq!(
            class("dailyMemoryExportFolder", json!("/x"), json!("")),
            Narrowing
        );
        assert_eq!(class("retentionDays", json!(14), json!(7)), Widening);
        assert_eq!(class("retentionDays", json!(14), json!(30)), Widening);
        assert_eq!(
            class(
                "openRouterDataPolicy",
                json!("privateOnly"),
                json!("accountPolicy")
            ),
            Widening
        );
        assert_eq!(
            class(
                "openRouterDataPolicy",
                json!("accountPolicy"),
                json!("privateOnly")
            ),
            Narrowing
        );
        assert_eq!(
            class(
                "modelDownloadSource",
                json!("huggingFace"),
                json!("hfMirror")
            ),
            Widening
        );
        assert_eq!(
            class(
                "modelDownloadSource",
                json!("hfMirror"),
                json!("modelScope")
            ),
            Widening
        );
        assert_eq!(
            class(
                "modelDownloadSource",
                json!("modelScope"),
                json!("hfMirror")
            ),
            Narrowing
        );
        assert_eq!(
            class(
                "modelDownloadSource",
                json!("hfMirror"),
                json!("huggingFace")
            ),
            Narrowing
        );
        assert_eq!(class("companionHistory", json!(30), json!(90)), Widening);
        assert_eq!(class("companionHistory", json!(30), json!(0)), Widening);
        assert_eq!(class("companionHistory", json!(0), json!(365)), Narrowing);
        assert_eq!(
            class("recordSystemAudio", json!(false), json!(true)),
            Widening
        );
        assert_eq!(
            class("recordSystemAudio", json!(true), json!(false)),
            Narrowing
        );
    }

    #[test]
    fn every_consent_setting_has_a_direction() {
        // A consent setting with no rule would treat every change as widening,
        // including turning it off. Check each one can be narrowed.
        let defaults = encoded(&Settings::default());
        for spec in registry::all() {
            if spec.tier != SettingTier::Consent {
                continue;
            }
            let narrowed: Value = match (spec.key, spec.kind) {
                ("retentionDays" | "keepOCRTextForever", _) => continue,
                ("requireCalendarForBrowser", _) => json!(true),
                ("autoRecordMode", _) => json!("Never auto-record"),
                ("screenContextCaptureMode", _) => json!("Activity only"),
                ("openRouterDataPolicy", _) => json!("privateOnly"),
                ("modelDownloadSource", _) => json!("huggingFace"),
                ("companionHistory", _) => json!(30),
                (_, SettingKind::Bool) => json!(false),
                (_, SettingKind::Text(TextFormat::CommaSeparated)) => json!(format!(
                    "{}, Example App",
                    defaults[spec.key].as_str().unwrap_or("")
                )),
                (_, SettingKind::Text(_)) => json!(""),
                (_, SettingKind::TextList) => json!([]),
                _ => panic!("{} has no narrowing rule", spec.key),
            };
            let change = spec.classify(defaults.get(spec.key), &narrowed);
            assert!(
                matches!(change, ChangeClass::Narrowing | ChangeClass::Unchanged),
                "{}: {change:?}",
                spec.key
            );
        }
    }

    #[test]
    fn request_params_round_trip() {
        let params = |value: Value| value.as_object().unwrap().clone();
        assert_eq!(
            code(ChangeRequest::from_params(Some(&Map::new()))).as_deref(),
            Some("invalid_request")
        );
        assert_eq!(
            code(ChangeRequest::from_params(Some(&params(
                json!({"changes": {"a": 1}, "reset": ["a"]})
            ))))
            .as_deref(),
            Some("invalid_request")
        );
        let request = ChangeRequest::from_params(Some(&params(json!({
            "changes": {"appTheme": "dark"}, "reset": ["dayDigestHour"], "dryRun": true,
        }))))
        .unwrap();
        assert!(request.dry_run);
        assert_eq!(
            ChangeRequest::from_params(Some(&request.params())).unwrap(),
            request
        );
    }

    #[test]
    fn plans_reset_to_defaults_and_keep_hidden_url_parts() {
        let map = |value: Value| value.as_object().unwrap().clone();
        let current = map(json!({
            "appTheme": "system", "trackingEnabled": true, "dayDigestHour": 20,
            "openAIBaseURL": "https://user:secret@host.example/v1?key=1",
        }));
        let defaults =
            map(json!({"appTheme": "system", "trackingEnabled": true, "dayDigestHour": 18}));
        let plan = ChangePlan::make(
            &ChangeRequest {
                changes: map(json!({"appTheme": "dark", "trackingEnabled": false})),
                reset: vec!["dayDigestHour".into()],
                dry_run: false,
            },
            &current,
            &defaults,
        )
        .unwrap();
        let keys: Vec<&str> = plan.items.iter().map(|i| i.spec.key).collect();
        assert_eq!(keys, ["appTheme", "trackingEnabled", "dayDigestHour"]);
        assert_eq!(plan.items[2].stored, Some(json!(18)));
        assert_eq!(plan.applicable().len(), 3);

        // `config export` shows the URL redacted; importing it back is a no-op.
        let url = ChangePlan::make(
            &ChangeRequest {
                changes: map(json!({"openAIBaseURL": "https://host.example/v1"})),
                ..Default::default()
            },
            &current,
            &defaults,
        )
        .unwrap();
        assert_eq!(url.items[0].change, ChangeClass::Unchanged);
        assert_eq!(
            url.items[0].stored,
            Some(json!("https://user:secret@host.example/v1?key=1"))
        );
        // The URL in a reply never shows its secret parts.
        assert_eq!(url.entries()[0]["value"], "https://host.example/v1");

        for key in [
            "languageHint",
            "onboardingCompleted",
            "codingAgentEvidenceConfirmed",
        ] {
            let mut changes = Map::new();
            changes.insert(key.into(), json!(true));
            assert_eq!(
                code(ChangePlan::make(
                    &ChangeRequest {
                        changes,
                        ..Default::default()
                    },
                    &current,
                    &defaults
                ))
                .as_deref(),
                Some("unknown_key"),
                "{key}"
            );
        }
    }

    #[test]
    fn a_widening_that_grew_while_waiting_shows_again() {
        let map = |value: Value| value.as_object().unwrap().clone();
        let before = map(json!({"trackingEnabled": false}));
        let plan = ChangePlan::make(
            &ChangeRequest {
                changes: map(json!({"trackingEnabled": true})),
                ..Default::default()
            },
            &before,
            &before,
        )
        .unwrap();
        // Unchanged: the person already turned it on, so it is not widening.
        let same = ChangePlan::rebasing(&plan.items, &map(json!({"trackingEnabled": true})));
        assert_eq!(same.items[0].change, ChangeClass::Unchanged);
        assert!(!same.widens_beyond(&plan.items));
        // An origin list that gained an entry the card did not show.
        let list = spec("approvedRemoteInferenceOrigins");
        let shown = vec![PlanItem {
            spec: *list,
            previous: Some(json!(["https://a"])),
            stored: Some(json!(["https://a", "https://b"])),
            change: ChangeClass::Widening,
        }];
        let now = map(json!({"approvedRemoteInferenceOrigins": ["https://c"]}));
        assert!(ChangePlan::rebasing(&shown, &now).widens_beyond(&shown));
    }

    #[test]
    fn applying_uses_the_real_decoder_and_the_couplings_settings_use() {
        let settings = Settings {
            screen_context_capture_mode: ScreenContextMode::Text,
            ..Default::default()
        };
        let item = |key: &str, stored: Value, change: ChangeClass| PlanItem {
            spec: *spec(key),
            previous: None,
            stored: Some(stored),
            change,
        };
        // Turning tracking off drops screen context too.
        let off = apply_items(
            &[item(
                "trackingEnabled",
                json!(false),
                ChangeClass::Narrowing,
            )],
            &settings,
            Utc::now(),
        )
        .unwrap();
        assert_eq!(
            off.screen_context_capture_mode,
            ScreenContextMode::ActivityOnly
        );
        // Screen context turns tracking back on.
        let on = apply_items(
            &[item(
                "screenContextCaptureMode",
                json!("Text + visual context"),
                ChangeClass::Widening,
            )],
            &off,
            Utc::now(),
        )
        .unwrap();
        assert!(on.tracking_enabled);
        // A decoder that rejects the value names it.
        let rejected = apply_items(
            &[item("retentionDays", json!(-3), ChangeClass::Widening)],
            &settings,
            Utc::now(),
        )
        .unwrap_err();
        assert_eq!(rejected.code, "invalid_value");
        // Dreaming keeps its first day in step, under the Mac's key.
        let dreaming = apply_items(
            &[item(
                "dreamingEnabled",
                json!(false),
                ChangeClass::Preference,
            )],
            &settings,
            Utc::now(),
        )
        .unwrap();
        assert!(!dreaming.other.contains_key("dreamingFirstEligibleDayKey"));
        let back = apply_items(
            &[item(
                "dreamingEnabled",
                json!(true),
                ChangeClass::Preference,
            )],
            &dreaming,
            Utc::now(),
        )
        .unwrap();
        assert!(back.other.contains_key("dreamingFirstEligibleDayKey"));
        // The person approving this is what lets sessions be read.
        let reading = apply_items(
            &[item(
                "codingAgentEvidenceEnabled",
                json!(true),
                ChangeClass::Widening,
            )],
            &Settings::default(),
            Utc::now(),
        )
        .unwrap();
        assert!(reading.coding_agent_evidence_confirmed);
        // Other changes leave an install that never chose exactly as it was.
        let unrelated = apply_items(
            &[item("appTheme", json!("dark"), ChangeClass::Preference)],
            &Settings::default(),
            Utc::now(),
        )
        .unwrap();
        assert!(unrelated.coding_agent_evidence_enabled);
        assert!(!unrelated.coding_agent_evidence_confirmed);
    }

    #[test]
    fn the_card_shows_every_entry_a_list_gains_or_loses() {
        let lines = change_lines(
            spec("approvedRemoteInferenceOrigins"),
            Some(&json!(["https://a"])),
            Some(&json!(["https://b", "https://A"])),
        );
        assert_eq!(lines, ["Adds: https://b"]);
        let lines = change_lines(
            spec("excludedApps"),
            Some(&json!("1Password, Bitwarden")),
            Some(&json!("bitwarden, Slack")),
        );
        assert_eq!(lines, ["Adds: Slack", "Removes: 1Password"]);
        assert_eq!(
            change_lines(
                spec("trackingEnabled"),
                Some(&json!(false)),
                Some(&json!(true))
            ),
            ["Off → On"]
        );
        // Hidden parts of a URL don't pass unnoticed.
        let lines = change_lines(
            spec("openAIBaseURL"),
            Some(&json!("https://host/v1")),
            Some(&json!("https://user:pw@host/v1")),
        );
        assert_eq!(lines.len(), 2);
        assert!(!lines.join(" ").contains("pw"));
    }

    #[test]
    fn snapshot_presents_tokens_and_redacts_urls() {
        let settings = Settings {
            openai_base_url: "https://user:secret@host.example/v1?key=1".into(),
            ..Default::default()
        };
        let specs = [
            spec("autoRecordMode"),
            spec("openAIBaseURL"),
            spec("cotypingAcceptKey"),
        ];
        let entries = snapshot_entries(&settings, &specs);
        assert_eq!(entries[0]["value"], "ask");
        assert_eq!(entries[0]["changed"], false);
        assert_eq!(entries[1]["value"], "https://host.example/v1");
        assert_eq!(entries[1]["changed"], true);
        assert_eq!(entries[2]["value"], "tab");
        assert!(!entries.iter().any(|e| e.to_string().contains("secret")));
    }
}
