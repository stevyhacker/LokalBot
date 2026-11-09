use serde_json::json;

use super::{DESIGN_REVIEW, Phone, meeting_field};
use crate::client::search_cjk as cjk;

#[test]
fn transcript_hits_carry_the_segment_start() {
    let phone = Phone::sample();
    let hits = phone.client.search("revised deck".into(), 20).unwrap();
    let segment = hits
        .iter()
        .find(|hit| hit.kind == "transcript")
        .expect("a transcript hit");
    assert_eq!(segment.key, DESIGN_REVIEW);
    assert_eq!(segment.meeting_id.as_deref(), Some(DESIGN_REVIEW));
    assert_eq!(segment.at, Some(721.4));
    assert_eq!(segment.title, "Design review — onboarding");
    let review_day = meeting_field(DESIGN_REVIEW, "day");
    assert_eq!(segment.date.as_deref(), Some(review_day.as_str()));
    assert!(
        segment.snippet.contains("«revised»") && segment.snippet.contains("«deck»"),
        "{}",
        segment.snippet
    );

    // The action, the summary and the day digest match too.
    assert!(
        hits.iter()
            .any(|hit| hit.kind == "meeting" && hit.key == DESIGN_REVIEW && hit.at.is_none())
    );
    let digest = hits
        .iter()
        .find(|hit| hit.kind == "day")
        .expect("a digest hit");
    // That day's digest lists the task.
    assert_eq!(digest.key, review_day);
    assert_eq!(digest.date.as_deref(), Some(review_day.as_str()));
    assert_eq!(digest.title, review_day);
    assert!(digest.meeting_id.is_none());
}

#[test]
fn search_covers_titles_notes_decisions_and_questions() {
    let phone = Phone::sample();
    let kinds = |query: &str| -> Vec<(String, String)> {
        phone
            .client
            .search(query.into(), 50)
            .unwrap()
            .into_iter()
            .map(|hit| (hit.kind, hit.key))
            .collect()
    };
    // Title (and other fields) of the Northwind call.
    assert!(kinds("Northwind").contains(&(
        "meeting".into(),
        "3f6c2a10-8a4e-4d2b-9b1e-0a1b2c3d4e03".into()
    )));
    // Notes only.
    assert_eq!(
        kinds("legal about"),
        [("meeting".to_owned(), DESIGN_REVIEW.to_owned())]
    );
    // An open question.
    assert!(kinds("customers go first").contains(&("meeting".into(), DESIGN_REVIEW.into())));
    // Prefix matching of the last term.
    assert!(!kinds("onboa").is_empty());
    // Natural-language questions fall back to any content word.
    assert!(!kinds("what about the flag").is_empty());
    assert!(kinds("zebra").is_empty());
    // Punctuation cannot break the query.
    assert!(!kinds("\"deck)").is_empty());
    assert!(kinds("").is_empty());
    // Limits.
    assert_eq!(phone.client.search("the".into(), 2).unwrap().len(), 2);
}

#[test]
fn cjk_text_is_found_by_substring() {
    let phone = Phone::sample();
    let meeting = json!([{
        "kind": "meeting", "key": "cjk-1", "version": 1, "seq": 50, "deleted": false,
        "sortKey": "2026-10-28T09:00:00.000Z",
        "body": {
            "id": "cjk-1", "title": "设计评审", "startedAt": "2026-10-28T09:00:00.000Z", "day": "2026-10-28",
            "summaryMarkdown": "我们讨论了深色模式下设置页面的对比度问题。比如logo再大一点。下周四发布。",
            "actions": [], "decisions": [], "openQuestions": [], "people": [], "projects": []
        }
    }]);
    phone.client.import_records(meeting.to_string()).unwrap();

    let hits = phone.client.search("对比度".into(), 10).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].key, "cjk-1");
    assert_eq!(hits[0].title, "设计评审");
    assert!(hits[0].snippet.contains("«对比度»"), "{}", hits[0].snippet);

    // A Latin word glued to CJK text.
    let hits = phone.client.search("logo".into(), 10).unwrap();
    assert_eq!(
        hits.iter().map(|h| h.key.as_str()).collect::<Vec<_>>(),
        ["cjk-1"]
    );
    assert!(hits[0].snippet.contains("«logo»"));

    // A longer spaceless question matches by two-character pieces.
    let hits = phone.client.search("下周四发布之前".into(), 10).unwrap();
    assert_eq!(hits.len(), 1);
}

#[test]
fn cjk_helpers_match_the_mac() {
    assert!(cjk::contains_cjk("深色"));
    assert!(cjk::contains_cjk("カタカナ"));
    assert!(cjk::contains_cjk("한국어"));
    assert!(!cjk::contains_cjk("Ünïcödé"));
    assert_eq!(cjk::terms("深色，模式 深色"), ["深色", "模式"]);
    assert_eq!(
        cjk::relaxed_terms("下周四发布"),
        ["下周", "周四", "四发", "发布"]
    );
    assert_eq!(cjk::relaxed_terms("a 下"), ["a", "下"]);
    assert_eq!(cjk::like_pattern("50%_a\\b"), "%50\\%\\_a\\\\b%");
    assert_eq!(
        cjk::snippet("Hello World, hello again", &["hello".into()]).unwrap(),
        "«Hello» World, «hello» again"
    );
    let long = format!("{}target{}", "x".repeat(40), "y".repeat(80));
    let snippet = cjk::snippet(&long, &["target".into()]).unwrap();
    assert!(snippet.starts_with('…') && snippet.ends_with('…'));
    assert_eq!(snippet.chars().filter(|c| *c == 'x').count(), 18);
    assert_eq!(snippet.chars().filter(|c| *c == 'y').count(), 54);
    assert!(cjk::snippet("nothing here", &["zebra".into()]).is_none());
}
