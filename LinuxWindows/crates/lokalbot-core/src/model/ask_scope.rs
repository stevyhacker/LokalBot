//! What one Ask question may draw on, as saved with its turns (`AskSourceScope`,
//! `AskDateScope`, `ChatViewModel.QuestionScope`), and what that means for the
//! turns around it: earlier, wider answers stay out of a narrower question's
//! model context, and a reopened conversation never widens.

use std::collections::BTreeSet;

use chrono::{Datelike as _, NaiveDate};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::chat::{ChatMessage, ChatRole};

/// A source a question may read. The raw values are the Mac's; `Today` is the
/// Activity source, a name kept so saved conversations still decode.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub enum AskSourceScope {
    Meetings,
    Today,
    Screen,
    Files,
}

impl AskSourceScope {
    /// In the order questions save them.
    pub const ALL: [AskSourceScope; 4] = [
        AskSourceScope::Meetings,
        AskSourceScope::Today,
        AskSourceScope::Screen,
        AskSourceScope::Files,
    ];

    /// Every source. Files is part of "All sources" whether or not it is on, so
    /// turning it on or off never makes an earlier question look narrowed.
    pub fn defaults() -> BTreeSet<AskSourceScope> {
        Self::ALL.into_iter().collect()
    }
}

/// `YYYY-MM-DD` with zero padding, naming a real day.
pub fn is_canonical_day_key(key: &str) -> bool {
    key.len() == 10
        && NaiveDate::parse_from_str(key, "%Y-%m-%d").is_ok_and(|day| day_key(day) == key)
}

/// `AskDayScope.key`: a civil day, so a change of time zone can't move it.
pub fn day_key(day: NaiveDate) -> String {
    format!("{:04}-{:02}-{:02}", day.year(), day.month(), day.day())
}

/// The key as a question saves it, or `None` if it is not one.
pub(super) fn canonical_scope_key(key: &str) -> Option<String> {
    AskDateScope::from_storage_key(key).map(|_| key.to_string())
}

/// `AskDateScope`: one civil-day range shared by search, answers and saved
/// questions. Single days are `YYYY-MM-DD`; ranges include both ends and are
/// `YYYY-MM-DD...YYYY-MM-DD`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AskDateScope {
    pub first_day: NaiveDate,
    pub last_day: NaiveDate,
}

impl AskDateScope {
    pub fn day(day: NaiveDate) -> Self {
        Self {
            first_day: day,
            last_day: day,
        }
    }

    pub fn from_storage_key(key: &str) -> Option<Self> {
        let parts: Vec<&str> = key.split("...").collect();
        if !(1..=2).contains(&parts.len()) {
            return None;
        }
        let (first, last) = (parts[0], parts[parts.len() - 1]);
        if !is_canonical_day_key(first) || !is_canonical_day_key(last) || first > last {
            return None;
        }
        Some(Self {
            first_day: NaiveDate::parse_from_str(first, "%Y-%m-%d").ok()?,
            last_day: NaiveDate::parse_from_str(last, "%Y-%m-%d").ok()?,
        })
    }

    pub fn storage_key(&self) -> String {
        if self.first_day == self.last_day {
            day_key(self.first_day)
        } else {
            format!("{}...{}", day_key(self.first_day), day_key(self.last_day))
        }
    }

    pub fn contains_day_key(&self, key: &str) -> bool {
        is_canonical_day_key(key)
            && key >= day_key(self.first_day).as_str()
            && key <= day_key(self.last_day).as_str()
    }
}

/// `ChatViewModel.QuestionScope`, plus the days of its attached screens: what is
/// saved on both turns of a question.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct QuestionScope {
    /// In `AskSourceScope::ALL` order.
    pub sources: Vec<AskSourceScope>,
    pub day_scope_key: Option<String>,
    pub attached_screen_day_keys: Vec<String>,
    pub meeting_ids: Option<Vec<Uuid>>,
    pub screen_snapshot_ids: Option<Vec<i64>>,
    /// Here the screen-app filter also limits the model's screen search, so it
    /// is part of the boundary. The Mac ignores the key.
    pub screen_app: Option<String>,
}

impl QuestionScope {
    /// The sources as a question sends them: all of them when none were named.
    pub fn allowed_sources(&self) -> BTreeSet<AskSourceScope> {
        if self.sources.is_empty() {
            AskSourceScope::defaults()
        } else {
            self.sources.iter().copied().collect()
        }
    }

    /// `ChatViewModel.currentQuestionScope`: what the latest question asked
    /// within. A conversation with no question has none.
    pub fn current(messages: &[ChatMessage]) -> Option<Self> {
        let question = messages.iter().rev().find(|m| m.role == ChatRole::User)?;
        Some(Self {
            sources: if question.source_scopes.is_empty() {
                AskSourceScope::ALL.to_vec()
            } else {
                question.source_scopes.clone()
            },
            day_scope_key: question.day_scope_key.clone(),
            attached_screen_day_keys: Vec::new(),
            meeting_ids: question.meeting_ids.clone(),
            screen_snapshot_ids: question.screen_snapshot_ids.clone(),
            screen_app: question.screen_app.clone(),
        })
    }
}

fn is_subset<T: PartialEq>(saved: &Option<Vec<T>>, allowed: &[T]) -> bool {
    saved
        .as_ref()
        .is_some_and(|saved| saved.iter().all(|item| allowed.contains(item)))
}

/// `ChatViewModel.finalizedHistoryForKey` with its evidence filter: the
/// question/answer pairs that may reach the model for a question within `scope`.
/// A pair whose question reached further than `scope` stays out, as does one
/// that failed, was stopped, or only saved a "Remember …" statement.
pub fn finalized_history(messages: &[ChatMessage], scope: &QuestionScope) -> Vec<ChatMessage> {
    let allowed = scope.allowed_sources();
    let within_evidence = |message: &&ChatMessage| {
        scope
            .meeting_ids
            .as_ref()
            .is_none_or(|ids| is_subset(&message.meeting_ids, ids))
            && scope
                .screen_snapshot_ids
                .as_ref()
                .is_none_or(|ids| is_subset(&message.screen_snapshot_ids, ids))
    };
    let mut history = Vec::new();
    let mut pending_user: Option<&ChatMessage> = None;
    for message in messages.iter().filter(within_evidence) {
        match message.role {
            ChatRole::User => pending_user = Some(message),
            ChatRole::Assistant => {
                let Some(user) = pending_user.take() else {
                    continue;
                };
                if !message.is_error
                    && message.remember_receipt.is_none()
                    && history_pair_allowed(user, &allowed, scope.day_scope_key.as_deref())
                    && within_screen_app(user, scope.screen_app.as_deref())
                {
                    history.push(user.clone());
                    history.push(message.clone());
                }
            }
        }
    }
    history
}

/// A question limited to one app's screens doesn't hear answers from others'.
fn within_screen_app(user: &ChatMessage, screen_app: Option<&str>) -> bool {
    let read_screens =
        user.source_scopes.is_empty() || user.source_scopes.contains(&AskSourceScope::Screen);
    screen_app.is_none() || !read_screens || user.screen_app.as_deref() == screen_app
}

/// `ChatViewModel.historyPairAllowed`.
fn history_pair_allowed(
    user: &ChatMessage,
    allowed: &BTreeSet<AskSourceScope>,
    day_scope_key: Option<&str>,
) -> bool {
    let everything = *allowed == AskSourceScope::defaults();
    if user.legacy_scope_is_ambiguous {
        return everything && day_scope_key.is_none();
    }
    if let Some(key) = day_scope_key {
        let range = AskDateScope::from_storage_key(key);
        let outside = |day: &String| !range.is_some_and(|range| range.contains_day_key(day));
        if user.attached_screen_day_keys.iter().any(outside) {
            return false;
        }
    }
    if user.source_scopes.is_empty() {
        if !everything || day_scope_key.is_some() {
            return false;
        }
    } else if !user.source_scopes.iter().all(|s| allowed.contains(s)) {
        return false;
    }
    match (user.day_scope_key.as_deref(), day_scope_key) {
        (None, None) | (Some(_), None) => true,
        (Some(saved), Some(key)) => saved == key,
        (None, Some(_)) => false,
    }
}

/// `ChatViewModel.canRetry`. Only the failed last turn can be asked again, and a
/// question with attached screens only while their ids are still in memory
/// (`has_live_attachments`): the captured text never reaches disk.
pub fn can_retry(messages: &[ChatMessage], assistant_id: Uuid, has_live_attachments: bool) -> bool {
    let Some((index, message)) = messages
        .iter()
        .enumerate()
        .find(|(_, m)| m.id == assistant_id)
    else {
        return false;
    };
    if message.role != ChatRole::Assistant
        || !message.is_error
        || messages.last().map(|m| m.id) != Some(assistant_id)
    {
        return false;
    }
    let Some(user) = messages[..index]
        .iter()
        .rev()
        .find(|m| m.role == ChatRole::User)
    else {
        return false;
    };
    !user.legacy_scope_is_ambiguous
        && (user.attached_screen_day_keys.is_empty() || has_live_attachments)
}

/// `ChatViewModel.retry`: the question behind a failed turn, and the scope it
/// was asked within. Sources default to all only for a legacy turn with none.
pub fn retry_question(
    messages: &[ChatMessage],
    assistant_id: Uuid,
) -> Option<(String, QuestionScope)> {
    let index = messages.iter().position(|m| m.id == assistant_id)?;
    let user = messages[..index]
        .iter()
        .rev()
        .find(|m| m.role == ChatRole::User)?;
    Some((
        user.text.clone(),
        QuestionScope {
            sources: if user.source_scopes.is_empty() {
                AskSourceScope::ALL.to_vec()
            } else {
                user.source_scopes.clone()
            },
            day_scope_key: user.day_scope_key.clone(),
            attached_screen_day_keys: user.attached_screen_day_keys.clone(),
            meeting_ids: user.meeting_ids.clone(),
            screen_snapshot_ids: user.screen_snapshot_ids.clone(),
            screen_app: user.screen_app.clone(),
        },
    ))
}

/// Takes a failed turn and its question out of the conversation, so asking it
/// again doesn't repeat them. `false` if it isn't the failed last turn.
pub fn remove_failed_turn(messages: &mut Vec<ChatMessage>, assistant_id: Uuid) -> bool {
    let is_failed_last = messages
        .last()
        .is_some_and(|m| m.id == assistant_id && m.role == ChatRole::Assistant && m.is_error);
    if !is_failed_last {
        return false;
    }
    messages.pop();
    if let Some(user) = messages.iter().rposition(|m| m.role == ChatRole::User) {
        messages.remove(user);
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Conversation;
    use serde_json::json;

    const CONVERSATION: &str = "11111111-1111-4111-8111-111111111111";
    const USER: &str = "22222222-2222-4222-8222-222222222222";
    const ASSISTANT: &str = "33333333-3333-4333-8333-333333333333";
    const MEETING: &str = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA";

    fn scope(sources: &[AskSourceScope]) -> QuestionScope {
        QuestionScope {
            sources: sources.to_vec(),
            ..Default::default()
        }
    }

    fn pair(user_scope: &QuestionScope, user: &str, answer: &str) -> Vec<ChatMessage> {
        vec![
            ChatMessage::new(ChatRole::User, user).with_scope(user_scope),
            ChatMessage::new(ChatRole::Assistant, answer).with_scope(user_scope),
        ]
    }

    fn texts(messages: &[ChatMessage]) -> Vec<&str> {
        messages.iter().map(|m| m.text.as_str()).collect()
    }

    /// What `JSONEncoder` writes for a current Mac turn, with sorted keys.
    fn mac_conversation() -> serde_json::Value {
        json!({
            "createdAt": "2026-10-01T09:00:00Z",
            "id": CONVERSATION,
            "messages": [
                {
                    "attachedScreenDayKeys": ["2026-10-01"],
                    "createdAt": "2026-10-01T09:00:00Z",
                    "dayScope": "2026-09-25...2026-10-01",
                    "id": USER,
                    "meetingIDs": [MEETING],
                    "role": "user",
                    "screenSnapshotIDs": [42, 7],
                    "sourceScopeSchemaVersion": 2,
                    "sourceScopes": ["Meetings", "Today", "Screen"],
                    "text": "What did we decide?",
                },
                {
                    "createdAt": "2026-10-01T09:00:05Z",
                    "dayScope": "2026-09-25...2026-10-01",
                    "id": ASSISTANT,
                    "isError": true,
                    "role": "assistant",
                    "sourceScopeSchemaVersion": 2,
                    "sourceScopes": ["Meetings", "Today", "Screen"],
                    "text": "The selected assistant could not be reached.",
                },
            ],
            "title": "What did we decide?",
            "updatedAt": "2026-10-01T09:00:05Z",
        })
    }

    #[test]
    fn a_mac_conversation_reads_and_writes_back_the_same_keys() {
        let chat: Conversation = serde_json::from_value(mac_conversation()).unwrap();
        let user = &chat.messages[0];
        assert_eq!(
            user.source_scopes,
            [
                AskSourceScope::Meetings,
                AskSourceScope::Today,
                AskSourceScope::Screen
            ]
        );
        assert_eq!(
            user.day_scope_key.as_deref(),
            Some("2026-09-25...2026-10-01")
        );
        assert_eq!(user.attached_screen_day_keys, ["2026-10-01"]);
        assert_eq!(
            user.meeting_ids,
            Some(vec![Uuid::parse_str(MEETING).unwrap()])
        );
        assert_eq!(user.screen_snapshot_ids, Some(vec![42, 7]));
        assert!(!user.legacy_scope_is_ambiguous);
        assert!(chat.messages[1].is_error);
        assert_eq!(serde_json::to_value(&chat).unwrap(), mac_conversation());
    }

    #[test]
    fn a_new_turn_writes_the_mac_keys_and_leaves_out_empty_ones() {
        let turn = ChatMessage::new(ChatRole::User, "Hello").with_scope(&QuestionScope {
            sources: vec![AskSourceScope::Files],
            day_scope_key: Some("2026-10-01".into()),
            meeting_ids: Some(Vec::new()),
            ..Default::default()
        });
        let json = serde_json::to_value(&turn).unwrap();
        assert_eq!(json["sourceScopes"], json!(["Files"]));
        assert_eq!(json["dayScope"], "2026-10-01");
        assert_eq!(json["meetingIDs"], json!([]));
        assert_eq!(json["sourceScopeSchemaVersion"], 2);
        for absent in [
            "attachedScreenDayKeys",
            "screenSnapshotIDs",
            "isError",
            "legacyScopeIsAmbiguous",
            "createdAtIsEstimated",
        ] {
            assert!(json.get(absent).is_none(), "{absent}");
        }
    }

    #[test]
    fn version_one_turns_are_never_reused_under_a_narrower_question() {
        let chat: Conversation = serde_json::from_value(json!({
            "id": CONVERSATION,
            "title": "Old",
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-01T00:00:00Z",
            "messages": [
                {"id": USER, "role": "user", "text": "Q", "sourceScopes": ["Meetings"]},
                {"id": ASSISTANT, "role": "assistant", "text": "A"},
            ],
        }))
        .unwrap();
        let [user, answer] = chat.messages.as_slice() else {
            panic!("two turns");
        };
        assert!(user.legacy_scope_is_ambiguous);
        assert!(user.created_at_is_estimated);
        assert_eq!(user.created_at, Some(chat.created_at));
        let narrowed = scope(&[AskSourceScope::Meetings]);
        assert!(finalized_history(&chat.messages, &narrowed).is_empty());
        assert_eq!(
            texts(&finalized_history(
                &chat.messages,
                &scope(&AskSourceScope::ALL)
            )),
            ["Q", "A"]
        );
        // Nor retried: its real scope is unknown.
        let failed = {
            let mut failed = answer.clone();
            failed.is_error = true;
            vec![user.clone(), failed]
        };
        assert!(!can_retry(
            &failed,
            Uuid::parse_str(ASSISTANT).unwrap(),
            true
        ));
    }

    #[test]
    fn a_version_one_today_scope_widens_the_label_and_drops_its_day() {
        let chat: Conversation = serde_json::from_value(json!({
            "id": CONVERSATION,
            "title": "Old",
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-01T00:00:00Z",
            "messages": [{
                "id": USER, "role": "user", "text": "Q",
                "sourceScopes": ["Today", "Meetings"], "dayScope": "2026-01-01",
            }],
        }))
        .unwrap();
        assert_eq!(chat.messages[0].source_scopes, AskSourceScope::ALL);
        assert_eq!(chat.messages[0].day_scope_key, None);
        assert!(chat.messages[0].legacy_scope_is_ambiguous);
    }

    #[test]
    fn an_absolute_day_scope_is_dropped_and_marks_the_turn() {
        for day_scope in [
            json!("2026-01-01T00:00:00Z"),
            json!(787_000_000),
            json!(null),
        ] {
            let message: ChatMessage = serde_json::from_value(json!({
                "id": USER, "role": "user", "text": "Q",
                "sourceScopes": ["Meetings"], "sourceScopeSchemaVersion": 2,
                "dayScope": day_scope,
            }))
            .unwrap();
            assert_eq!(message.day_scope_key, None);
            assert!(message.legacy_scope_is_ambiguous, "{day_scope}");
        }
    }

    #[test]
    fn a_date_key_is_canonical_or_nothing() {
        assert!(AskDateScope::from_storage_key("2026-10-01").is_some());
        assert_eq!(
            AskDateScope::from_storage_key("2026-09-25...2026-10-01")
                .unwrap()
                .storage_key(),
            "2026-09-25...2026-10-01"
        );
        for bad in [
            "",
            "2026-1-1",
            "2026-13-01",
            "2026-02-30",
            "2026-10-02...2026-10-01",
            "2026-10-01...2026-10-02...2026-10-03",
            "2026-10-01...",
        ] {
            assert_eq!(AskDateScope::from_storage_key(bad), None, "{bad}");
        }
        let range = AskDateScope::from_storage_key("2026-09-25...2026-10-01").unwrap();
        assert!(range.contains_day_key("2026-09-25"));
        assert!(range.contains_day_key("2026-10-01"));
        assert!(!range.contains_day_key("2026-10-02"));
        assert!(!range.contains_day_key("not a day"));
    }

    #[test]
    fn earlier_wider_answers_stay_out_of_a_narrower_question() {
        let mut messages = pair(&scope(&AskSourceScope::ALL), "Everything?", "Secret");
        messages.extend(pair(
            &scope(&[AskSourceScope::Meetings]),
            "Meetings?",
            "From meetings",
        ));
        // Narrow: only the pair asked within it.
        assert_eq!(
            texts(&finalized_history(
                &messages,
                &scope(&[AskSourceScope::Meetings])
            )),
            ["Meetings?", "From meetings"]
        );
        // Wider still sees narrower answers.
        assert_eq!(
            texts(&finalized_history(&messages, &scope(&AskSourceScope::ALL))),
            ["Everything?", "Secret", "Meetings?", "From meetings"]
        );
    }

    #[test]
    fn a_date_scoped_question_reads_only_that_range() {
        let on = |key: Option<&str>| QuestionScope {
            sources: AskSourceScope::ALL.to_vec(),
            day_scope_key: key.map(str::to_string),
            ..Default::default()
        };
        let mut messages = pair(&on(None), "Any time?", "A");
        messages.extend(pair(&on(Some("2026-10-01")), "That day?", "B"));
        messages.extend(pair(&on(Some("2026-10-02")), "Next day?", "C"));
        assert_eq!(
            texts(&finalized_history(&messages, &on(Some("2026-10-01")))),
            ["That day?", "B"]
        );
        // An unscoped question may reuse dated answers, as on the Mac.
        assert_eq!(finalized_history(&messages, &on(None)).len(), 6);
    }

    #[test]
    fn attached_screens_from_another_day_stay_out() {
        let attached = QuestionScope {
            sources: AskSourceScope::ALL.to_vec(),
            attached_screen_day_keys: vec!["2026-10-05".into()],
            ..Default::default()
        };
        let messages = pair(&attached, "This screen?", "It shows mail");
        let within = |key: &str| QuestionScope {
            sources: AskSourceScope::ALL.to_vec(),
            day_scope_key: Some(key.into()),
            ..Default::default()
        };
        assert!(finalized_history(&messages, &within("2026-10-01")).is_empty());
    }

    #[test]
    fn a_meeting_boundary_keeps_out_what_it_does_not_contain() {
        let one = Uuid::from_u128(1);
        let two = Uuid::from_u128(2);
        let bound = |ids: &[Uuid]| QuestionScope {
            sources: vec![AskSourceScope::Meetings],
            meeting_ids: Some(ids.to_vec()),
            ..Default::default()
        };
        let mut messages = pair(&scope(&[AskSourceScope::Meetings]), "Unbound?", "A");
        messages.extend(pair(&bound(&[one]), "First?", "B"));
        messages.extend(pair(&bound(&[two]), "Second?", "C"));
        messages.extend(pair(&bound(&[one, two]), "Both?", "D"));
        assert_eq!(
            texts(&finalized_history(&messages, &bound(&[one]))),
            ["First?", "B"]
        );
        let screens = QuestionScope {
            sources: vec![AskSourceScope::Screen],
            screen_snapshot_ids: Some(vec![9]),
            ..Default::default()
        };
        assert!(finalized_history(&messages, &screens).is_empty());
    }

    #[test]
    fn a_screen_app_limit_keeps_other_apps_answers_out() {
        let limited = |app: Option<&str>| QuestionScope {
            sources: vec![AskSourceScope::Meetings, AskSourceScope::Screen],
            screen_app: app.map(str::to_string),
            ..Default::default()
        };
        let mut messages = pair(&limited(None), "Any app?", "A");
        messages.extend(pair(&limited(Some("Mail")), "In Mail?", "B"));
        messages.extend(pair(&scope(&[AskSourceScope::Meetings]), "Meetings?", "C"));
        assert_eq!(
            texts(&finalized_history(&messages, &limited(Some("Mail")))),
            ["In Mail?", "B", "Meetings?", "C"]
        );
        assert_eq!(finalized_history(&messages, &limited(None)).len(), 6);
        assert_eq!(
            QuestionScope::current(&pair(&limited(Some("Mail")), "Q", "A"))
                .unwrap()
                .screen_app
                .as_deref(),
            Some("Mail")
        );
    }

    #[test]
    fn failed_stopped_and_remembered_turns_stay_out_of_history() {
        let all = scope(&AskSourceScope::ALL);
        let mut messages = pair(&all, "Failed?", "Couldn't reach it");
        messages[1].is_error = true;
        messages.extend(pair(&all, "Remember that I like tea", "I like tea"));
        messages[3].remember_receipt = Some(crate::model::RememberReceipt { claim_id: None });
        messages.push(ChatMessage::new(ChatRole::User, "Unanswered").with_scope(&all));
        messages.extend(pair(&all, "Decided?", "Redis."));
        assert_eq!(
            texts(&finalized_history(&messages, &all)),
            ["Decided?", "Redis."]
        );
    }

    #[test]
    fn the_current_scope_is_the_latest_questions() {
        assert_eq!(QuestionScope::current(&[]), None);
        let bound = QuestionScope {
            sources: vec![AskSourceScope::Screen],
            day_scope_key: Some("2026-10-01".into()),
            attached_screen_day_keys: vec!["2026-10-01".into()],
            meeting_ids: None,
            screen_snapshot_ids: Some(vec![3]),
            screen_app: None,
        };
        let mut messages = pair(&scope(&AskSourceScope::ALL), "Wide?", "A");
        messages.extend(pair(&bound, "Narrow?", "B"));
        let current = QuestionScope::current(&messages).unwrap();
        assert_eq!(current.sources, [AskSourceScope::Screen]);
        assert_eq!(current.day_scope_key.as_deref(), Some("2026-10-01"));
        assert_eq!(current.screen_snapshot_ids, Some(vec![3]));
        // Attachments are for one question; the boundary carries on without them.
        assert!(current.attached_screen_day_keys.is_empty());
    }

    #[test]
    fn only_the_failed_last_turn_retries_within_its_own_scope() {
        let bound = QuestionScope {
            sources: vec![AskSourceScope::Meetings],
            day_scope_key: Some("2026-10-01".into()),
            meeting_ids: Some(vec![Uuid::from_u128(1)]),
            ..Default::default()
        };
        let mut messages = pair(&bound, "Q", "It failed");
        let failed = messages[1].id;
        assert!(!can_retry(&messages, failed, false), "not an error yet");
        messages[1].is_error = true;
        assert!(can_retry(&messages, failed, false));
        assert!(!can_retry(&messages, messages[0].id, false));
        let (question, scope) = retry_question(&messages, failed).unwrap();
        assert_eq!(question, "Q");
        assert_eq!(scope, bound);
        // A later turn supersedes it.
        messages.extend(pair(&bound, "Next", "Fine"));
        assert!(!can_retry(&messages, failed, false));
    }

    #[test]
    fn a_question_with_attached_screens_retries_only_while_they_are_in_memory() {
        let attached = QuestionScope {
            sources: AskSourceScope::ALL.to_vec(),
            attached_screen_day_keys: vec!["2026-10-01".into()],
            ..Default::default()
        };
        let mut messages = pair(&attached, "Q", "It failed");
        messages[1].is_error = true;
        let failed = messages[1].id;
        assert!(can_retry(&messages, failed, true));
        assert!(!can_retry(&messages, failed, false));
    }

    #[test]
    fn retrying_removes_the_failed_pair_and_nothing_else() {
        let all = scope(&AskSourceScope::ALL);
        let mut messages = pair(&all, "Earlier", "Answer");
        messages.extend(pair(&all, "Q", "It failed"));
        let failed = messages[3].id;
        assert!(!remove_failed_turn(&mut messages, failed), "not an error");
        assert_eq!(messages.len(), 4);
        messages[3].is_error = true;
        let first = messages[0].id;
        assert!(!remove_failed_turn(&mut messages, first));
        assert!(remove_failed_turn(&mut messages, failed));
        assert_eq!(texts(&messages), ["Earlier", "Answer"]);
    }
}
