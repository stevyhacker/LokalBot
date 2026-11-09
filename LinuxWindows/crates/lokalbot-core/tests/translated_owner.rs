//! Action owners under a non-English interface. The interface language is
//! process-wide, so this file stays one test in its own test binary.

use chrono::Utc;
use lokalbot_core::{ActionCorrection, Library, LibraryPaths, demo};

#[test]
fn owners_stay_canonical_under_a_german_interface() {
    let dir = tempfile::tempdir().unwrap();
    let paths = LibraryPaths::new(dir.path().join("library"));
    demo::seed(&paths, Utc::now()).unwrap();
    let library = Library::open(paths).unwrap();
    let meeting = library
        .list_meetings()
        .unwrap()
        .into_iter()
        .find(|m| m.title == "Holiday shoot planning")
        .unwrap();
    let action_id = library
        .meeting_actions(&meeting)
        .unwrap()
        .into_iter()
        .find(|a| a.text.starts_with("Book the photo studio"))
        .unwrap()
        .action_id;
    let set_owner = |owner: &str| {
        library
            .correct_action(
                &meeting,
                &action_id,
                ActionCorrection {
                    owner: Some(Some(owner.into())),
                    ..ActionCorrection::default()
                },
            )
            .unwrap();
        library
            .meeting_actions(&meeting)
            .unwrap()
            .into_iter()
            .find(|a| a.action_id == action_id)
            .unwrap()
    };

    assert_eq!(lokalbot_i18n::set_language("de").code, "de");
    assert_eq!(lokalbot_i18n::tr("You"), "Du");

    // What the correction sheet's "You" stores now.
    let mine = set_owner("Me");
    assert_eq!(mine.owner.as_deref(), Some("Me"));
    assert!(mine.is_for_user);

    // What v0.11.0–v0.11.5 stored for "You" under German.
    let legacy = set_owner("Ich");
    assert_eq!(legacy.owner.as_deref(), Some("Me"));
    assert!(legacy.is_for_user);

    let unresolved = set_owner("Unresolved speaker");
    assert_eq!(unresolved.owner.as_deref(), Some("Unresolved speaker"));
    assert!(!unresolved.is_for_user);

    // Another interface language reads the German word as a name.
    lokalbot_i18n::set_language("fr");
    let elsewhere = set_owner("Ich");
    assert_eq!(elsewhere.owner.as_deref(), Some("Ich"));
    assert!(!elsewhere.is_for_user);
}
