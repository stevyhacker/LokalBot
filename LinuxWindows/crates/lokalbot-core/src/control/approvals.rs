//! Requests from the terminal that wait for the person (`SettingsApprovals.swift`):
//! settings changes that widen what LokalBot captures, reads, records, or sends,
//! and new API keys. Each request is one card in the approval window listing
//! every change it makes. It is answered once, expires after a few minutes, and
//! is never approved in bulk. Only the app's own window calls [`Approvals::approve`];
//! nothing on the control socket can reach it.

use chrono::{DateTime, Duration, Utc};
use serde_json::{Map, Value, json};
use uuid::Uuid;

use super::change::{ChangeRequest, PlanItem};
use super::iso8601;
use super::protocol::{AppSecret, ControlError, RequestState, SecretValue};
use crate::ids::uuid_upper;
use crate::retention::RetentionReview;

#[derive(Clone, Debug, PartialEq)]
pub enum Subject {
    Settings(ChangeRequest),
    Secret(AppSecret, SecretValue),
}

#[derive(Clone, Debug)]
pub struct ApprovalRequest {
    pub id: Uuid,
    /// Who asked, from the process tree: shown to the person, never trusted.
    pub caller: String,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    pub subject: Subject,
    /// What the request changes, as `settings.set` reports it.
    pub changes: Vec<Value>,
    pub items: Vec<PlanItem>,
    /// The cleanup a shorter retention policy deletes. Approving the card
    /// applies exactly this review.
    pub retention: Option<RetentionReview>,
    pub state: RequestState,
    pub answered_at: Option<DateTime<Utc>>,
    pub result: Option<Value>,
    /// Why the last Approve did not go through, shown on the card.
    pub problem: Option<String>,
}

impl ApprovalRequest {
    /// What `settings.request` reports. An API key never appears in it.
    pub fn json(&self) -> Value {
        let mut object = Map::new();
        object.insert("id".into(), json!(uuid_upper(&self.id)));
        object.insert("state".into(), json!(self.state.raw_value()));
        object.insert("caller".into(), json!(self.caller));
        object.insert("createdAt".into(), json!(iso8601::text(&self.created_at)));
        object.insert("expiresAt".into(), json!(iso8601::text(&self.expires_at)));
        object.insert("changes".into(), Value::Array(self.changes.clone()));
        if let Some(answered) = &self.answered_at {
            object.insert("answeredAt".into(), json!(iso8601::text(answered)));
        }
        if let Some(result) = &self.result {
            object.insert("result".into(), result.clone());
        }
        if let Some(review) = &self.retention {
            object.insert(
                "retentionReview".into(),
                json!({
                    "days": review.days,
                    "keepTextForever": review.keep_text_forever,
                    "imagesRemoved": review.pixel_count(),
                    "textRecordsRemoved": review.text_count(),
                    "activityTitlesCleared": review.activity_titles.len(),
                }),
            );
        }
        Value::Object(object)
    }

    /// What the request asks for, for the error message and notification.
    pub fn headline(&self) -> String {
        match &self.subject {
            Subject::Secret(secret, _) => format!("Setting the {}", secret.title()),
            Subject::Settings(_) => {
                let titles: Vec<&str> = self
                    .items
                    .iter()
                    .filter(|item| item.change == super::change::ChangeClass::Widening)
                    .map(|item| item.spec.title)
                    .collect();
                if titles.is_empty() {
                    "This change".to_string()
                } else {
                    titles.join(", ")
                }
            }
        }
    }

    pub fn is_secret(&self) -> bool {
        matches!(self.subject, Subject::Secret(..))
    }
}

/// Why an approval did not finish.
#[derive(Clone, Debug, PartialEq)]
pub enum ApprovalProblem {
    Control(ControlError),
    /// Keep the card waiting with this message.
    Retry(String),
}

impl std::fmt::Display for ApprovalProblem {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Control(error) => write!(f, "{}", error.message),
            Self::Retry(message) => f.write_str(message),
        }
    }
}

/// Approving would widen more than the card showed; it now shows the changes
/// as they would apply.
pub const CHANGED_WHILE_WAITING: &str = "Your settings changed while this request was waiting. Review the updated changes before approving.";

pub struct Approvals {
    pub pending: Vec<ApprovalRequest>,
    answered: Vec<ApprovalRequest>,
}

impl Default for Approvals {
    fn default() -> Self {
        Self::new()
    }
}

impl Approvals {
    pub const LIFETIME_SECONDS: i64 = 5 * 60;
    pub const MAXIMUM_PENDING: usize = 5;
    /// Answers stay readable for `config request` this long.
    pub const ANSWERED_LIFETIME_SECONDS: i64 = 30 * 60;

    pub fn new() -> Self {
        Self {
            pending: Vec::new(),
            answered: Vec::new(),
        }
    }

    /// Queues a request. An identical settings request from the same caller
    /// that is still waiting is returned instead of asking twice. The bool
    /// says whether the request is new, so the person is told only once.
    pub fn submit(
        &mut self,
        subject: Subject,
        caller: &str,
        items: Vec<PlanItem>,
        changes: Vec<Value>,
        retention: Option<RetentionReview>,
        now: DateTime<Utc>,
    ) -> Result<(ApprovalRequest, bool), ControlError> {
        self.expire_stale(now);
        if matches!(subject, Subject::Settings(_))
            && let Some(existing) = self
                .pending
                .iter()
                .find(|r| r.subject == subject && r.caller == caller)
        {
            return Ok((existing.clone(), false));
        }
        if self.pending.len() >= Self::MAXIMUM_PENDING {
            return Err(ControlError::too_many_requests());
        }
        let request = ApprovalRequest {
            id: Uuid::new_v4(),
            caller: caller.to_string(),
            created_at: now,
            expires_at: now + Duration::seconds(Self::LIFETIME_SECONDS),
            subject,
            changes,
            items,
            retention,
            state: RequestState::Pending,
            answered_at: None,
            result: None,
            problem: None,
        };
        self.pending.push(request.clone());
        Ok((request, true))
    }

    pub fn request(&mut self, id: Uuid, now: DateTime<Utc>) -> Option<&ApprovalRequest> {
        self.expire_stale(now);
        self.pending
            .iter()
            .chain(self.answered.iter())
            .find(|r| r.id == id)
    }

    /// The waiting request for `id`, or why it isn't waiting. An approved one
    /// answers `Ok(None)`: approving twice changes nothing.
    pub fn waiting(
        &mut self,
        id: Uuid,
        now: DateTime<Utc>,
    ) -> Result<Option<ApprovalRequest>, ControlError> {
        self.expire_stale(now);
        if let Some(found) = self.pending.iter().find(|r| r.id == id) {
            return Ok(Some(found.clone()));
        }
        match self.answered.iter().find(|r| r.id == id).map(|r| r.state) {
            Some(RequestState::Approved) => Ok(None),
            Some(RequestState::Denied) => Err(ControlError::denied()),
            Some(RequestState::Expired) => Err(ControlError::expired()),
            _ => Err(ControlError::unknown_request(&uuid_upper(&id))),
        }
    }

    /// The person approved and the change went through.
    pub fn finish_approved(&mut self, id: Uuid, result: Value, now: DateTime<Utc>) {
        if let Some(index) = self.pending.iter().position(|r| r.id == id) {
            self.finish(index, RequestState::Approved, Some(result), now);
        }
    }

    /// Leaves the card waiting, with why on it.
    pub fn set_problem(&mut self, id: Uuid, problem: String) {
        if let Some(found) = self.pending.iter_mut().find(|r| r.id == id) {
            found.problem = Some(problem);
        }
    }

    pub fn deny(&mut self, id: Uuid, now: DateTime<Utc>) {
        if let Some(index) = self.pending.iter().position(|r| r.id == id) {
            self.finish(index, RequestState::Denied, None, now);
        }
    }

    /// Turning the settings grant off answers everything still waiting.
    pub fn deny_all(&mut self, now: DateTime<Utc>) -> Vec<Uuid> {
        let ids: Vec<Uuid> = self.pending.iter().map(|r| r.id).collect();
        while !self.pending.is_empty() {
            self.finish(0, RequestState::Denied, None, now);
        }
        ids
    }

    /// Lets the approval path refresh a card it could not apply as shown.
    pub fn update(&mut self, id: Uuid, change: impl FnOnce(&mut ApprovalRequest)) {
        if let Some(found) = self.pending.iter_mut().find(|r| r.id == id) {
            change(found);
        }
    }

    /// Returns the requests that just expired.
    pub fn expire_stale(&mut self, now: DateTime<Utc>) -> Vec<Uuid> {
        let mut expired = Vec::new();
        while let Some(index) = self.pending.iter().position(|r| r.expires_at <= now) {
            expired.push(self.pending[index].id);
            self.finish(index, RequestState::Expired, None, now);
        }
        self.answered.retain(|r| {
            r.answered_at.unwrap_or(now) + Duration::seconds(Self::ANSWERED_LIFETIME_SECONDS) > now
        });
        expired
    }

    fn finish(
        &mut self,
        index: usize,
        state: RequestState,
        result: Option<Value>,
        now: DateTime<Utc>,
    ) {
        let mut request = self.pending.remove(index);
        request.state = state;
        request.answered_at = Some(now);
        request.result = result;
        request.problem = None;
        // An API key is kept only until the request is answered.
        if let Subject::Secret(secret, _) = request.subject {
            request.subject = Subject::Secret(secret, SecretValue::default());
        }
        self.answered.push(request);
        if self.answered.len() > 50 {
            let excess = self.answered.len() - 50;
            self.answered.drain(..excess);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(seconds: i64) -> DateTime<Utc> {
        DateTime::from_timestamp(1_800_000_000 + seconds, 0).unwrap()
    }

    fn settings_subject(key: &str, value: Value) -> Subject {
        let mut changes = Map::new();
        changes.insert(key.into(), value);
        Subject::Settings(ChangeRequest {
            changes,
            ..Default::default()
        })
    }

    fn secret_subject() -> Subject {
        Subject::Secret(
            AppSecret::OpenAICompatible,
            SecretValue::new("sk-very-secret-key"),
        )
    }

    #[test]
    fn identical_requests_are_asked_once() {
        let mut approvals = Approvals::new();
        let subject = settings_subject("trackingEnabled", json!(true));
        let (first, new) = approvals
            .submit(subject.clone(), "claude", vec![], vec![], None, at(0))
            .unwrap();
        assert!(new);
        let (second, new) = approvals
            .submit(subject.clone(), "claude", vec![], vec![], None, at(1))
            .unwrap();
        assert!(!new);
        assert_eq!(first.id, second.id);
        let (other, new) = approvals
            .submit(subject, "codex", vec![], vec![], None, at(2))
            .unwrap();
        assert!(new);
        assert_ne!(other.id, first.id);
    }

    #[test]
    fn only_a_few_requests_wait_at_once() {
        let mut approvals = Approvals::new();
        for index in 0..Approvals::MAXIMUM_PENDING {
            approvals
                .submit(
                    settings_subject("dayDigestHour", json!(index)),
                    "claude",
                    vec![],
                    vec![],
                    None,
                    at(0),
                )
                .unwrap();
        }
        let refused = approvals
            .submit(
                settings_subject("dayDigestHour", json!(99)),
                "claude",
                vec![],
                vec![],
                None,
                at(0),
            )
            .unwrap_err();
        assert_eq!(refused.code, "too_many_requests");
    }

    #[test]
    fn requests_expire_and_are_forgotten_later() {
        let mut approvals = Approvals::new();
        let (request, _) = approvals
            .submit(secret_subject(), "claude", vec![], vec![], None, at(0))
            .unwrap();
        assert_eq!(
            approvals.request(request.id, at(299)).unwrap().state,
            RequestState::Pending
        );
        assert_eq!(
            approvals.request(request.id, at(300)).unwrap().state,
            RequestState::Expired
        );
        assert_eq!(
            approvals.waiting(request.id, at(301)).unwrap_err().code,
            "expired"
        );
        assert!(approvals.request(request.id, at(300 + 1800)).is_none());
        assert_eq!(
            approvals
                .waiting(request.id, at(300 + 1801))
                .unwrap_err()
                .code,
            "unknown_request"
        );
    }

    #[test]
    fn an_api_key_goes_when_the_request_is_answered_and_never_shows() {
        let mut approvals = Approvals::new();
        let (request, _) = approvals
            .submit(secret_subject(), "claude", vec![], vec![], None, at(0))
            .unwrap();
        assert!(!request.json().to_string().contains("sk-very-secret-key"));
        assert!(!format!("{request:?}").contains("sk-very-secret-key"));
        approvals.deny(request.id, at(1));
        let answered = approvals.request(request.id, at(2)).unwrap();
        assert_eq!(answered.state, RequestState::Denied);
        let Subject::Secret(_, value) = &answered.subject else {
            panic!()
        };
        assert!(value.is_empty());
        assert_eq!(
            approvals.waiting(request.id, at(3)).unwrap_err().code,
            "denied"
        );
    }

    #[test]
    fn turning_the_grant_off_denies_what_waits() {
        let mut approvals = Approvals::new();
        let (request, _) = approvals
            .submit(
                settings_subject("trackingEnabled", json!(true)),
                "claude",
                vec![],
                vec![],
                None,
                at(0),
            )
            .unwrap();
        assert_eq!(approvals.deny_all(at(1)), vec![request.id]);
        assert!(approvals.pending.is_empty());
        assert_eq!(
            approvals.request(request.id, at(2)).unwrap().state,
            RequestState::Denied
        );
    }

    #[test]
    fn approving_twice_changes_nothing() {
        let mut approvals = Approvals::new();
        let (request, _) = approvals
            .submit(
                settings_subject("trackingEnabled", json!(true)),
                "claude",
                vec![],
                vec![],
                None,
                at(0),
            )
            .unwrap();
        assert!(approvals.waiting(request.id, at(1)).unwrap().is_some());
        approvals.finish_approved(request.id, json!({"applied": true}), at(1));
        assert!(approvals.waiting(request.id, at(2)).unwrap().is_none());
        let json = approvals.request(request.id, at(2)).unwrap().json();
        assert_eq!(json["state"], "approved");
        assert_eq!(json["result"]["applied"], true);
    }
}
