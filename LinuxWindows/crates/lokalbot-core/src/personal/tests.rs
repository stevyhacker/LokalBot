use std::collections::HashSet;
use std::fs;
use std::sync::Arc;

use chrono::{Duration, TimeZone as _, Utc};
use uuid::Uuid;

use super::access::{self, Projection};
use super::controller::LoadError;
use super::learning::{self, Utterance, UtteranceSource};
use super::promotion;
use super::*;
use crate::dream::{DreamMemory, MemoryGoal, MemoryProject};
use crate::evidence::{self, Provenance, Source};
use crate::model::Segment;
use crate::sealed;
use crate::{Library, LibraryPaths, Meeting};

const KEY: sealed::SealingKey = [5u8; sealed::KEY_BYTES];
const OTHER: sealed::SealingKey = [6u8; sealed::KEY_BYTES];

fn now() -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 10, 20, 8, 0, 0).unwrap()
}

fn library() -> (tempfile::TempDir, Library) {
    let dir = tempfile::tempdir().unwrap();
    let library = Library::open(LibraryPaths::new(dir.path())).unwrap();
    library.set_chat_key_source(Arc::new(|_| Ok(KEY)));
    (dir, library)
}

/// `memory/personal-model.json` as the Mac's `JSONEncoder` writes it.
const MAC_MODEL: &str = r#"{
  "claims" : [ {
    "alwaysUse" : true,
    "authority" : "stated",
    "createdAt" : "2026-10-14T09:00:00Z",
    "id" : "11111111-1111-4111-8111-111111111111",
    "kind" : "fact",
    "origin" : { "said" : {
      "conversationID" : "22222222-2222-4222-8222-222222222222",
      "messageID" : "33333333-3333-4333-8333-333333333333"
    } },
    "sharing" : "agents",
    "status" : "confirmed",
    "text" : "Maya is my manager.",
    "updatedAt" : "2026-10-14T09:00:00Z"
  }, {
    "alwaysUse" : false,
    "authority" : "learned",
    "createdAt" : "2026-10-15T04:00:00Z",
    "evidence" : {
      "includesUnattributedContext" : false,
      "revision" : 3,
      "sources" : [ { "dayKey" : "2026-10-14", "id" : "44444444-4444-4444-8444-444444444444", "kind" : "meeting" } ]
    },
    "id" : "55555555-5555-4555-8555-555555555555",
    "kind" : "goal",
    "lastUsedAt" : "2026-10-16T10:00:00Z",
    "origin" : { "learned" : {
      "dayKey" : "2026-10-14",
      "meetingID" : "44444444-4444-4444-8444-444444444444"
    } },
    "quote" : "I want to run a marathon next year",
    "sharing" : "lokalBotOnly",
    "status" : "confirmed",
    "text" : "I want to run a marathon in 2027.",
    "updatedAt" : "2026-10-15T04:00:00Z"
  }, {
    "alwaysUse" : false,
    "authority" : "learned",
    "createdAt" : "2026-10-15T04:00:00Z",
    "id" : "66666666-6666-4666-8666-666666666666",
    "kind" : "preference",
    "origin" : { "typed" : {
      "dayKey" : "2026-10-14",
      "source" : { "codingAgent" : { "name" : "Claude Code" } }
    } },
    "sharing" : "lokalBotOnly",
    "status" : "proposed",
    "text" : "I prefer short replies.",
    "updatedAt" : "2026-10-15T04:00:00Z"
  }, {
    "alwaysUse" : false,
    "authority" : "stated",
    "createdAt" : "2026-10-15T04:00:00Z",
    "id" : "77777777-7777-4777-8777-777777777777",
    "kind" : "principle",
    "origin" : { "added" : { } },
    "sharing" : "lokalBotOnly",
    "status" : "confirmed",
    "text" : "Family first.",
    "updatedAt" : "2026-10-15T04:00:00Z"
  } ],
  "learnedDays" : [ { "dayKey" : "2026-10-14", "fingerprint" : "abc", "learnedAt" : "2026-10-15T04:00:00Z" } ],
  "tombstones" : [ { "createdAt" : "2026-10-15T04:00:00Z", "key" : "deadbeef" } ],
  "version" : 1,
  "workSightings" : [ { "firstDayKey" : "2026-10-01", "key" : "goal:abc" } ]
}"#;

#[test]
fn it_reads_and_rewrites_the_macs_model_with_the_same_shape() {
    let model: PersonalModel = serde_json::from_str(MAC_MODEL).unwrap();
    assert_eq!(model.claims.len(), 4);
    assert!(matches!(model.claims[0].origin, Origin::Said { .. }));
    assert!(matches!(model.claims[3].origin, Origin::Added {}));
    assert_eq!(model.claims[0].sharing, Sharing::Agents);
    assert_eq!(model.claims[2].status, Status::Proposed);
    let written = serde_json::to_value(&model).unwrap();
    let original: serde_json::Value = serde_json::from_str(MAC_MODEL).unwrap();
    assert_eq!(written, original);
}

#[test]
fn claims_written_before_later_fields_get_the_old_behaviour() {
    let claim: Claim = serde_json::from_value(serde_json::json!({
        "id": "11111111-1111-4111-8111-111111111111",
        "kind": "fact", "text": "x",
        "origin": {"added": {}},
        "createdAt": "2026-10-14T09:00:00Z", "updatedAt": "2026-10-14T09:00:00Z"
    }))
    .unwrap();
    assert_eq!(claim.sharing, Sharing::LokalBotOnly);
    assert_eq!(claim.status, Status::Confirmed);
    assert_eq!(claim.authority, Authority::Stated);
}

// ----------------------------------------------------------------- the store

#[test]
fn a_plaintext_model_is_accepted_then_sealed_on_the_next_save() {
    let (dir, library) = library();
    fs::create_dir_all(dir.path().join("memory")).unwrap();
    let plain = dir.path().join("memory/personal-model.json");
    fs::write(&plain, MAC_MODEL).unwrap();
    assert_eq!(library.personal().claims().len(), 4);
    assert!(plain.exists());

    library
        .personal()
        .remember("I live in Belgrade.", None, Origin::Added {})
        .unwrap();
    assert!(!plain.exists());
    let sealed_path = dir.path().join("memory/personal-model.json.enc");
    let bytes = fs::read(&sealed_path).unwrap();
    assert!(!String::from_utf8_lossy(&bytes).contains("Belgrade"));
    let clear = sealed::open(&KEY, &bytes).unwrap();
    let model: PersonalModel = serde_json::from_slice(&clear).unwrap();
    assert_eq!(model.claims.len(), 5);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let mode = fs::metadata(&sealed_path).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
    }
}

#[test]
fn a_model_that_cant_be_opened_is_reported_and_never_overwritten() {
    let (dir, library) = library();
    fs::create_dir_all(dir.path().join("memory")).unwrap();
    let path = dir.path().join("memory/personal-model.json.enc");
    let foreign = sealed::seal(&OTHER, MAC_MODEL.as_bytes()).unwrap();
    fs::write(&path, &foreign).unwrap();

    assert_eq!(library.personal().load_error(), Some(LoadError::Unreadable));
    assert_eq!(
        library
            .personal()
            .remember("Something new.", None, Origin::Added {})
            .unwrap_err(),
        EditError::Unavailable
    );
    assert_eq!(fs::read(&path).unwrap(), foreign);

    // Without any key it says so instead.
    let library2 = Library::open(LibraryPaths::new(dir.path())).unwrap();
    assert_eq!(
        library2.personal().load_error(),
        Some(LoadError::KeyUnavailable)
    );
    assert_eq!(fs::read(&path).unwrap(), foreign);

    // Forget everything is the person's explicit choice.
    library.personal().forget_all().unwrap();
    assert!(!path.exists());
    assert_eq!(library.personal().load_error(), None);
}

#[test]
fn a_newer_version_is_kept_as_is() {
    let (dir, library) = library();
    fs::create_dir_all(dir.path().join("memory")).unwrap();
    let path = dir.path().join("memory/personal-model.json");
    fs::write(&path, r#"{"version": 99, "claims": []}"#).unwrap();
    assert_eq!(
        library.personal().load_error(),
        Some(LoadError::NewerVersion)
    );
    assert!(
        library
            .personal()
            .remember("Something.", None, Origin::Added {})
            .is_err()
    );
    assert!(path.exists());
}

// ----------------------------------------------------------------- the rules

#[test]
fn text_is_validated_not_truncated() {
    assert_eq!(validated_text("  ").unwrap_err(), EditError::Empty);
    assert_eq!(
        validated_text(&"x".repeat(281)).unwrap_err(),
        EditError::TooLong(281)
    );
    assert_eq!(
        validated_text("My key is sk-abcdefghijklmnopqrstuvwx").unwrap_err(),
        EditError::LooksSecret
    );
    assert_eq!(
        validated_text("card 4242 4242 4242 4242").unwrap_err(),
        EditError::LooksSecret
    );
    assert_eq!(validated_text(" a   b ").unwrap(), "a b");
}

#[test]
fn duplicates_merge_across_case_width_accents_and_full_stops() {
    assert_eq!(duplicate_key("Živim u  Beogradu."), "zivim u beogradu");
    assert_eq!(duplicate_key("ＡＢＣ"), duplicate_key("abc"));
    let mut model = PersonalModel::default();
    let first = model
        .add(
            "I live in Belgrade.",
            ClaimKind::Fact,
            Origin::Added {},
            now(),
        )
        .unwrap();
    let later = now() + Duration::hours(1);
    let second = model
        .add(
            "i live in belgrade",
            ClaimKind::Goal,
            Origin::Added {},
            later,
        )
        .unwrap();
    assert_eq!(first.id, second.id);
    assert_eq!(model.claims.len(), 1);
    assert_eq!(model.claims[0].updated_at, later);
}

#[test]
fn saying_what_was_learned_makes_it_the_persons_statement() {
    let mut model = PersonalModel::default();
    let outcome = model.learn(
        &[candidate(ClaimKind::Fact, "I live in Belgrade.", false)],
        now(),
    );
    assert_eq!(outcome.saved.len(), 1);
    assert!(model.claims[0].evidence.is_some());
    model
        .add(
            "I live in Belgrade.",
            ClaimKind::Fact,
            Origin::Added {},
            now(),
        )
        .unwrap();
    assert_eq!(model.claims[0].authority, Authority::Stated);
    assert!(model.claims[0].evidence.is_none());
}

#[test]
fn the_limit_refuses_rather_than_evicts() {
    let mut model = PersonalModel::default();
    for index in 0..MAX_CLAIMS {
        model
            .add(
                &format!("Item {index}"),
                ClaimKind::Fact,
                Origin::Added {},
                now(),
            )
            .unwrap();
    }
    assert_eq!(
        model
            .add("One more", ClaimKind::Fact, Origin::Added {}, now())
            .unwrap_err(),
        EditError::Full
    );
    assert_eq!(model.claims.len(), MAX_CLAIMS);
}

fn candidate(kind: ClaimKind, text: &str, needs_review: bool) -> LearningCandidate {
    LearningCandidate {
        kind,
        text: text.into(),
        quote: Some("I said so".into()),
        origin: Origin::Learned {
            meeting_id: Uuid::nil(),
            day_key: "2026-10-19".into(),
        },
        evidence: Some(Provenance {
            sources: vec![Source {
                kind: "meeting".into(),
                id: Uuid::nil().to_string(),
                day_key: "2026-10-19".into(),
            }],
            revision: 1,
            includes_unattributed_context: false,
        }),
        needs_review,
    }
}

#[test]
fn principles_are_never_learned_and_preferences_wait_for_review() {
    let mut model = PersonalModel::default();
    let outcome = model.learn(
        &[
            candidate(ClaimKind::Principle, "I never lie.", false),
            candidate(ClaimKind::Preference, "I prefer written updates.", false),
            candidate(ClaimKind::Fact, "I lead the platform team.", false),
            candidate(ClaimKind::Goal, "I want a marathon medal soon.", true),
        ],
        now(),
    );
    assert_eq!(outcome.skipped, 1);
    assert_eq!(outcome.saved.len(), 1);
    assert_eq!(outcome.proposed.len(), 2);
    assert!(model.claims.iter().all(|c| c.kind != ClaimKind::Principle));
    assert_eq!(
        model
            .claims
            .iter()
            .find(|c| c.kind == ClaimKind::Preference)
            .unwrap()
            .status,
        Status::Proposed
    );
}

#[test]
fn forgetting_leaves_a_180_day_hash_so_it_isnt_learned_again() {
    let mut model = PersonalModel::default();
    model.learn(
        &[candidate(
            ClaimKind::Fact,
            "I lead the platform team.",
            false,
        )],
        now(),
    );
    let id = model.claims[0].id;
    model.remove(&HashSet::from([id]), now());
    assert_eq!(model.tombstones.len(), 1);
    assert!(!model.tombstones[0].key.contains("platform"));
    let again = model.learn(
        &[candidate(
            ClaimKind::Fact,
            "I lead the platform team.",
            false,
        )],
        now(),
    );
    assert_eq!(again.skipped, 1);

    // Stated claims leave nothing behind.
    let stated = model
        .add(
            "Something I said.",
            ClaimKind::Fact,
            Origin::Added {},
            now(),
        )
        .unwrap();
    model.remove(&HashSet::from([stated.id]), now());
    assert_eq!(model.tombstones.len(), 1);

    // Tombstones last 180 days; unreviewed suggestions 14.
    model.learn(
        &[candidate(
            ClaimKind::Preference,
            "I prefer tea every day.",
            false,
        )],
        now(),
    );
    model.prune(now() + Duration::days(13));
    assert_eq!(model.tombstones.len(), 1);
    assert_eq!(model.claims.len(), 1);
    model.prune(now() + Duration::days(15));
    assert_eq!(model.tombstones.len(), 1);
    assert!(model.claims.is_empty());
    model.prune(now() + Duration::days(181));
    assert!(model.tombstones.is_empty());
}

#[test]
fn retracting_from_a_source_leaves_no_tombstone() {
    let mut model = PersonalModel::default();
    model.learn(
        &[candidate(
            ClaimKind::Fact,
            "I lead the platform team.",
            false,
        )],
        now(),
    );
    model.retract(&HashSet::from([model.claims[0].id]));
    assert!(model.tombstones.is_empty());
    assert_eq!(
        model
            .learn(
                &[candidate(
                    ClaimKind::Fact,
                    "I lead the platform team.",
                    false
                )],
                now()
            )
            .saved
            .len(),
        1
    );
}

#[test]
fn a_reworded_item_is_skipped() {
    assert!(is_near_duplicate(
        "I live in Belgrade with family",
        "I live in Belgrade"
    ));
    assert!(!is_near_duplicate("I live in Belgrade", "I run marathons"));
}

#[test]
fn deleting_a_conversation_takes_back_what_was_learned_from_it() {
    let conversation = Uuid::new_v4();
    let mut model = PersonalModel::default();
    model.learn(
        &[LearningCandidate {
            kind: ClaimKind::Fact,
            text: "I have two kids.".into(),
            quote: Some("I have two kids".into()),
            origin: Origin::Typed {
                source: TypedSource::Ask {
                    conversation_id: conversation,
                },
                day_key: "2026-10-19".into(),
            },
            evidence: None,
            needs_review: true,
        }],
        now(),
    );
    assert_eq!(model.claims.len(), 1);
    let mut kept = model.clone();
    kept.keep_as_statement(kept.claims[0].id, now()).unwrap();
    model.retract_learned_from_conversation(conversation);
    assert!(model.claims.is_empty());
    kept.retract_learned_from_conversation(conversation);
    assert_eq!(kept.claims.len(), 1);
}

#[test]
fn remember_is_recognized_in_english_and_serbian_but_not_for_questions() {
    assert_eq!(
        remember_statement("Remember that Maya is my manager"),
        Some("Maya is my manager".into())
    );
    assert_eq!(
        remember_statement("please remember: answer in bullets"),
        Some("Answer in bullets".into())
    );
    assert_eq!(
        remember_statement("zapamti da imam dvoje dece"),
        Some("Imam dvoje dece".into())
    );
    assert_eq!(
        remember_statement("запамти да живим у Београду"),
        Some("Живим у Београду".into())
    );
    assert_eq!(remember_statement("remember when we met?"), None);
    assert_eq!(remember_statement("remember what she said"), None);
    assert_eq!(remember_statement("zapamti da li si video"), None);
    assert_eq!(remember_statement("What did we decide?"), None);
    assert_eq!(remember_statement("remember"), None);
}

#[test]
fn kinds_are_guessed_only_from_obvious_openings() {
    assert_eq!(ClaimKind::suggested("I prefer tea"), ClaimKind::Preference);
    assert_eq!(ClaimKind::suggested("I want to run"), ClaimKind::Goal);
    assert_eq!(ClaimKind::suggested("Maya is my manager"), ClaimKind::Fact);
}

// ------------------------------------------------------------ what Ask reads

fn claim(kind: ClaimKind, text: &str, age: i64) -> Claim {
    let mut claim = Claim::new(
        kind,
        text.into(),
        Origin::Added {},
        now() - Duration::hours(age),
    );
    claim.updated_at = claim.created_at;
    claim
}

#[test]
fn selection_orders_as_the_mac_does() {
    let mut always = claim(ClaimKind::Fact, "An old pinned note", 100);
    always.always_use = true;
    let items = vec![
        claim(ClaimKind::Fact, "Unrelated newest", 0),
        claim(ClaimKind::Goal, "Ship the beta launch", 5),
        claim(ClaimKind::Preference, "Answer briefly", 10),
        always.clone(),
    ];
    let ranked = ordered(&items, "How is the beta launch going?", &[]);
    let texts: Vec<&str> = ranked.iter().map(|c| c.text.as_str()).collect();
    assert_eq!(
        texts,
        vec![
            "An old pinned note",
            "Answer briefly",
            "Ship the beta launch",
            "Unrelated newest",
        ]
    );
}

#[test]
fn the_prompt_block_skips_what_doesnt_fit_and_labels_learned_items() {
    let mut learned = claim(ClaimKind::Fact, "I lead the platform team.", 1);
    learned.authority = Authority::Learned;
    let big = claim(ClaimKind::Fact, &"x".repeat(280), 2);
    let selection = select_context(&[learned, big], "platform", &[], 700);
    assert_eq!(selection.claim_ids.len(), 1);
    assert!(
        selection
            .block
            .starts_with("What LokalBot knows about the user.")
    );
    assert!(selection.block.contains("- [fact · learned "));
    assert!(selection.block.ends_with("point out the conflict."));
    assert!(select_context(&[], "q", &[], 2_000).block.is_empty());
}

#[test]
fn scoped_questions_get_only_what_the_person_stated() {
    let (dir, library) = library();
    library
        .personal()
        .remember("I said this.", None, Origin::Added {})
        .unwrap();
    library.personal().learn(
        &[candidate(
            ClaimKind::Fact,
            "I lead the platform team.",
            false,
        )],
        None,
    );
    assert_eq!(library.personal().usable_claims(true).len(), 2);
    assert_eq!(library.personal().usable_claims(false).len(), 1);

    // While a revocation is pending, learned items are withheld.
    fs::write(dir.path().join(evidence::PENDING_FILE), "[]").unwrap();
    let usable = library.personal().usable_claims(true);
    assert_eq!(usable.len(), 1);
    assert_eq!(usable[0].text, "I said this.");
}

fn meeting(id: Uuid) -> Meeting {
    serde_json::from_value(serde_json::json!({
        "id": id.to_string().to_uppercase(), "title": "Review", "appName": "Zoom",
        "startedAt": "2026-10-19T09:00:00Z", "endedAt": "2026-10-19T09:30:00Z",
        "relativePath": format!("meetings/{}", id.simple())
    }))
    .unwrap()
}

#[test]
fn a_learned_item_goes_when_its_meeting_is_deleted_unless_kept() {
    let (dir, library) = library();
    let id = Uuid::new_v4();
    let source = meeting(id);
    let learned = |text: &str| LearningCandidate {
        kind: ClaimKind::Fact,
        text: text.into(),
        quote: Some("I lead the platform team".into()),
        origin: Origin::Learned {
            meeting_id: id,
            day_key: "2026-10-19".into(),
        },
        evidence: Some(Provenance {
            sources: vec![Source {
                kind: "meeting".into(),
                id: crate::ids::uuid_upper(&id),
                day_key: "2026-10-19".into(),
            }],
            revision: 0,
            includes_unattributed_context: false,
        }),
        needs_review: false,
    };
    library
        .personal()
        .learn(&[learned("I lead the platform team.")], None);
    library
        .personal()
        .learn(&[learned("I manage twelve brilliant engineers.")], None);
    let keep = library.personal().kept()[0].clone();
    library.personal().keep_as_statement(keep.id).unwrap();

    evidence::with_meeting_removal(dir.path(), &[&source], || Ok(())).unwrap();
    library.personal().retract_if_loaded();
    let left = library.personal().claims();
    assert_eq!(left.len(), 1);
    assert_eq!(left[0].id, keep.id);
    // No tombstone: it can be learned again from evidence that still exists.
    assert_eq!(library.personal().usable_claims(true).len(), 1);
}

// ------------------------------------------------------------- agent sharing

#[test]
fn agents_see_only_shared_items_and_only_while_the_grant_is_on() {
    let (dir, library) = library();
    let paths = library.paths().clone();
    let claim = library
        .personal()
        .remember("Maya is my manager.", None, Origin::Added {})
        .unwrap();
    library
        .personal()
        .remember("A private note.", None, Origin::Added {})
        .unwrap();
    library
        .personal()
        .update(
            claim.id,
            ClaimEdit {
                sharing: Some(Sharing::Agents),
                ..Default::default()
            },
        )
        .unwrap();
    // Marked, but the grant is off.
    assert!(access::read_projection(&paths).is_none());
    let projection_path = dir.path().join("control/personal-context.json");
    assert!(!projection_path.exists());

    library.personal().set_access(true).unwrap();
    let shared = access::read_projection(&paths).unwrap();
    assert_eq!(shared.claims.len(), 1);
    assert_eq!(shared.claims[0].text, "Maya is my manager.");
    assert_eq!(shared.claims[0].source, "added_in_settings");
    // What the Mac's decoder needs.
    let json: serde_json::Value =
        serde_json::from_slice(&fs::read(&projection_path).unwrap()).unwrap();
    assert!(json["generatedAt"].is_string());
    assert_eq!(json["version"], 1);
    assert_eq!(json["claims"][0]["kind"], "fact");
    assert_eq!(json["claims"][0]["alwaysUse"], false);

    // An edit reaches agents; turning the grant off removes the copy.
    library
        .personal()
        .update(
            claim.id,
            ClaimEdit {
                text: Some("Maya Chen is my manager.".into()),
                ..Default::default()
            },
        )
        .unwrap();
    let shared: Projection = access::read_projection(&paths).unwrap();
    assert_eq!(shared.claims[0].text, "Maya Chen is my manager.");
    library.personal().set_access(false).unwrap();
    assert!(!projection_path.exists());
    assert!(
        !dir.path()
            .join("control/personal-context-access-enabled")
            .exists()
    );
}

#[test]
fn when_the_model_cant_be_read_agents_get_nothing() {
    let (dir, library) = library();
    let paths = library.paths().clone();
    library.personal().set_access(true).unwrap();
    assert!(dir.path().join("control/personal-context.json").exists());
    fs::create_dir_all(dir.path().join("memory")).unwrap();
    fs::write(
        dir.path().join("memory/personal-model.json.enc"),
        sealed::seal(&OTHER, b"{}").unwrap(),
    )
    .unwrap();
    library.personal().reload();
    assert!(!dir.path().join("control/personal-context.json").exists());
    assert!(access::read_projection(&paths).is_none());
    assert!(
        library
            .personal()
            .access_error()
            .unwrap()
            .contains("agents get nothing")
    );
}

#[test]
fn proposed_and_invalidated_items_are_never_shared() {
    let (dir, library) = library();
    library.personal().set_access(true).unwrap();
    library.personal().learn(
        &[candidate(
            ClaimKind::Preference,
            "I prefer written updates.",
            false,
        )],
        None,
    );
    let proposed = library.personal().suggestions()[0].clone();
    library
        .personal()
        .update(
            proposed.id,
            ClaimEdit {
                sharing: Some(Sharing::Agents),
                ..Default::default()
            },
        )
        .unwrap();
    assert!(
        access::read_projection(library.paths())
            .unwrap()
            .claims
            .is_empty()
    );

    library
        .personal()
        .confirm(&HashSet::from([proposed.id]))
        .unwrap();
    assert_eq!(
        access::read_projection(library.paths())
            .unwrap()
            .claims
            .len(),
        1
    );
    fs::write(dir.path().join(evidence::PENDING_FILE), "[]").unwrap();
    library.personal().reload();
    assert!(
        access::read_projection(library.paths())
            .unwrap()
            .claims
            .is_empty()
    );
}

// ----------------------------------------------------------- the person's lines

fn segment(speaker: &str, text: &str) -> Segment {
    Segment {
        start: 0.0,
        end: 1.0,
        speaker: speaker.into(),
        text: text.into(),
        confidence: None,
        timing_precision: None,
        attribution: None,
    }
}

#[test]
fn own_turns_join_the_microphone_and_skip_other_speakers() {
    let segments = vec![
        segment("local", "I live in Belgrade"),
        segment("local", "and I lead the team here"),
        segment("them", "That is what someone else said to me here"),
        segment("local", "too short"),
    ];
    assert_eq!(
        learning::own_turns(&segments),
        vec!["I live in Belgrade and I lead the team here"]
    );
}

#[test]
fn a_shared_microphone_is_skipped_unless_one_voice_dominates() {
    let shared = vec![
        segment("local 1", "I live in Belgrade with my family"),
        segment("them", "ok"),
        segment("local 2", "I live in Novi Sad with my family"),
    ];
    assert!(learning::own_turns(&shared).is_empty());
    let mut dominant = Vec::new();
    for _ in 0..4 {
        dominant.push(segment("local 1", "I live in Belgrade with my family"));
        dominant.push(segment("them", "ok"));
    }
    dominant.push(segment("local 2", "I live in Novi Sad with my family"));
    let turns = learning::own_turns(&dominant);
    assert_eq!(turns.len(), 4);
    assert!(turns.iter().all(|t| t.contains("Belgrade")));
}

#[test]
fn only_first_person_lines_count() {
    assert_eq!(learning::self_reference_score("I live in my town"), 2);
    assert_eq!(learning::self_reference_score("Živim u Beogradu"), 1);
    assert_eq!(learning::self_reference_score("Живим у Београду"), 1);
    assert_eq!(learning::self_reference_score("The deploy failed again"), 0);
}

#[test]
fn at_most_forty_lines_six_thousand_characters_fifteen_typed() {
    let (_dir, library) = library();
    let day = chrono::NaiveDate::from_ymd_opt(2026, 10, 19).unwrap();
    let typed: Vec<learning::TypedLine> = (0..60)
        .map(|i| learning::TypedLine {
            source: TypedSource::CodingAgent {
                name: "Codex".into(),
            },
            text: format!("I want to do my thing number {i} today"),
        })
        .collect();
    let lines = learning::utterances(&library, day, &typed).unwrap();
    assert_eq!(lines.len(), learning::MAX_TYPED_UTTERANCES);
    assert_eq!(lines[0].handle, "U1");

    let no_self: Vec<learning::TypedLine> = vec![learning::TypedLine {
        source: TypedSource::Ask {
            conversation_id: Uuid::nil(),
        },
        text: "the deploy failed again last night".into(),
    }];
    assert!(
        learning::utterances(&library, day, &no_self)
            .unwrap()
            .is_empty()
    );
}

#[test]
fn the_fingerprint_ignores_order_and_dictation() {
    let line = |text: &str, source: UtteranceSource| Utterance {
        handle: "U1".into(),
        source,
        label: "L".into(),
        day_key: "d".into(),
        text: text.into(),
    };
    let a = line("one", UtteranceSource::Meeting(Uuid::nil()));
    let b = line("two", UtteranceSource::Meeting(Uuid::nil()));
    let dictated = line(
        "three",
        UtteranceSource::Typed(TypedSource::Dictation { app: "x".into() }),
    );
    assert_eq!(
        learning::fingerprint(&[a.clone(), b.clone()]),
        learning::fingerprint(&[b, dictated, a])
    );
}

#[test]
fn a_quote_is_found_despite_case_accents_and_cut_ends() {
    let lines = vec!["Živim u Beogradu sa porodicom, i radim od kuće.".to_string()];
    assert!(learning::quote_still_said(
        Some("zivim u beogradu sa porodicom…"),
        &lines
    ));
    assert!(!learning::quote_still_said(
        Some("zivim u novom sadu"),
        &lines
    ));
    assert!(!learning::quote_still_said(Some("short"), &lines));
    assert!(!learning::quote_still_said(None, &lines));
}

#[test]
fn remember_messages_are_not_read_again_and_a_dictated_request_counts_once() {
    let day = chrono::NaiveDate::from_ymd_opt(2026, 10, 19).unwrap();
    let at = Utc.with_ymd_and_hms(2026, 10, 19, 12, 0, 0).unwrap();
    let conversation: crate::model::Conversation = serde_json::from_value(serde_json::json!({
        "id": "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
        "title": "t", "createdAt": "2026-10-19T09:00:00Z", "updatedAt": "2026-10-19T09:00:00Z",
        "messages": [
            {"id": "11111111-1111-4111-8111-111111111111", "role": "user", "text": "Remember that I like tea",
             "createdAt": "2026-10-19T12:00:00Z"},
            {"id": "22222222-2222-4222-8222-222222222222", "role": "assistant", "text": "I like tea",
             "rememberReceipt": {"claimID": "33333333-3333-4333-8333-333333333333"}},
            {"id": "33333333-3333-4333-8333-333333333334", "role": "user", "text": "I wonder what my week looks like",
             "createdAt": "2026-10-19T12:01:00Z"}
        ]
    }))
    .unwrap();
    let dictated = |text: &str| dictation_log::Entry {
        id: Uuid::new_v4(),
        text: text.into(),
        app_name: "Editor".into(),
        dictated_at: at,
    };
    let lines = learning::typed_lines(
        &[],
        &[conversation],
        &[
            dictated("I wonder what my week looks like!"),
            dictated("I live in Belgrade"),
        ],
        day,
    );
    assert_eq!(lines.len(), 2);
    assert_eq!(lines[0].text, "I wonder what my week looks like");
    assert_eq!(lines[0].label(), "typed in Ask");
    assert_eq!(lines[1].label(), "dictated in Editor");
}

// ------------------------------------------------------- the dictation buffer

#[test]
fn dictation_is_sealed_redacted_and_gone_after_two_days_or_its_pass() {
    let (dir, library) = library();
    let at = now();
    let log = library.dictation_log().at(at);
    log.append("My card is 4242 4242 4242 4242, I live here", "Editor")
        .unwrap();
    let path = dir.path().join("memory/dictation-for-learning.json.enc");
    let bytes = fs::read(&path).unwrap();
    assert!(!String::from_utf8_lossy(&bytes).contains("live here"));
    let day = crate::time::local_day(at);
    let entries = log.entries_on(day);
    assert_eq!(entries.len(), 1);
    assert!(entries[0].text.contains("[REDACTED_CARD]"));
    assert!(!entries[0].text.contains("4242"));
    assert_eq!(entries[0].app_name, "Editor");

    // Past two days it no longer reads, and pruning removes the file.
    let later = library.dictation_log().at(at + Duration::days(3));
    assert!(later.entries_on(day).is_empty());
    later.prune().unwrap();
    assert!(!path.exists());

    log.append("I live here now", "Editor").unwrap();
    log.remove_through(day).unwrap();
    assert!(!path.exists());
    log.append("I live here again", "Editor").unwrap();
    log.delete_all().unwrap();
    assert!(!path.exists());
}

#[test]
fn dictation_keeps_at_most_two_hundred_entries() {
    let (_dir, library) = library();
    let log = library.dictation_log().at(now());
    for index in 0..205 {
        log.append(&format!("Entry {index}"), "App").unwrap();
    }
    let entries = log.entries_on(crate::time::local_day(now()));
    assert_eq!(entries.len(), 200);
    assert_eq!(entries[0].text, "Entry 5");
}

// --------------------------------------------------------- work memory, weeks on

fn memory_with(last: &str, attributed: bool) -> DreamMemory {
    let mut memory = DreamMemory::empty(now());
    let provenance = attributed.then(|| Provenance {
        sources: vec![Source {
            kind: "digest".into(),
            id: "2026-10-19".into(),
            day_key: "2026-10-19".into(),
        }],
        revision: 1,
        includes_unattributed_context: false,
    });
    memory.work_goals.push(MemoryGoal {
        text: "Ship the beta".into(),
        horizon: "this month".into(),
        last_reinforced_day: last.into(),
        pinned: false,
        provenance: provenance.clone(),
    });
    memory.active_projects.push(MemoryProject {
        name: "Atlas".into(),
        status: "moving".into(),
        last_active_day: last.into(),
        evidence: vec![],
        pinned: false,
        provenance,
    });
    memory
}

#[test]
fn work_memory_is_suggested_after_two_weeks_and_a_recent_sighting() {
    let memory = memory_with("2026-10-19", true);
    let fresh = promotion::evaluate(&memory, &[], "2026-10-19");
    assert!(fresh.candidates.is_empty());
    assert_eq!(fresh.sightings.len(), 2);

    let sightings: Vec<WorkSighting> = fresh
        .sightings
        .iter()
        .map(|s| WorkSighting {
            key: s.key.clone(),
            first_day_key: "2026-10-05".into(),
        })
        .collect();
    let due = promotion::evaluate(&memory, &sightings, "2026-10-19");
    assert_eq!(due.candidates.len(), 2);
    assert!(due.candidates.iter().all(|c| c.needs_review));
    assert_eq!(due.candidates[1].text, "I work on Atlas.");
    assert_eq!(due.candidates[0].kind, ClaimKind::Goal);
    assert_eq!(due.candidates[1].kind, ClaimKind::Fact);

    // Not seen in the last week, or without attribution: nothing.
    let stale = memory_with("2026-10-05", true);
    assert!(
        promotion::evaluate(&stale, &sightings, "2026-10-19")
            .candidates
            .is_empty()
    );
    let unattributed = memory_with("2026-10-19", false);
    assert!(
        promotion::evaluate(&unattributed, &sightings, "2026-10-19")
            .candidates
            .is_empty()
    );
    // Sightings of what memory no longer holds are forgotten.
    let gone = promotion::evaluate(&DreamMemory::empty(now()), &sightings, "2026-10-19");
    assert!(gone.sightings.is_empty());
}
