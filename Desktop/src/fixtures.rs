//! Deliberately fictional fixtures. Seeding is explicit and refuses an existing library.
use crate::{
    domain::*,
    storage::{Library, atomic_write},
};
use anyhow::{Result, ensure};

pub fn seed(library: &mut Library) -> Result<Vec<String>> {
    ensure!(
        library.meetings()?.is_empty(),
        "Synthetic seeding requires an empty library"
    );
    let today = chrono::Local::now().date_naive();
    use chrono::TimeZone;
    let definitions = [
        (
            "LokalBot product sync",
            "Google Meet",
            9,
            30,
            vec![
                (
                    "You",
                    "We will ship the Linux and Windows workspace beside the existing macOS app. The macOS app stays intact.",
                ),
                (
                    "Maya Chen",
                    "The first release needs meetings, transcripts, notes, local search, and answers that link to evidence. We should test permissions and retention before release.",
                ),
                (
                    "Alex Morgan",
                    "I will test microphone recording and imported audio on Ubuntu by Monday. The server has no GPU, so we can use CPU Whisper for transcription and OpenRouter for text inference.",
                ),
                (
                    "Maya Chen",
                    "I will compare keyboard navigation and transcript reading on Windows by Tuesday.",
                ),
                (
                    "You",
                    "I will review the GPUI pull request today. We must validate Hyprland separately and never assume system-wide typing is available on every compositor.",
                ),
                (
                    "Alex Morgan",
                    "We have not approved a Windows release date. Signing and publication remain a later decision.",
                ),
            ],
        ),
        (
            "Engineering standup",
            "Slack",
            10,
            30,
            vec![
                (
                    "Alex Morgan",
                    "The local library now persists meeting notes and action corrections in SQLite. Search must remove deleted sources.",
                ),
                (
                    "Sam Rivera",
                    "I will add a restart and source-deletion regression test by Wednesday. I will also test that a revoked remote origin discards pending results.",
                ),
                (
                    "You",
                    "Let's retain screen text and encrypted pixels for fourteen days by default. Saved moments stay until explicitly removed.",
                ),
                (
                    "Sam Rivera",
                    "The synthetic fixture contact is maya.chen@example.test. The synthetic canary is secret=SYNTHETIC-CREDENTIAL-NEVER-SEND. Both must be redacted before remote inference.",
                ),
            ],
        ),
        (
            "Design review",
            "Zoom",
            11,
            15,
            vec![
                (
                    "Maya Chen",
                    "Keep Today, Timeline, Meetings, Ask, Type, and Agent close to the current workspace. Add People and Projects from actual library evidence.",
                ),
                (
                    "You",
                    "Use a calm dark palette with a restrained teal accent. Transcript text should wrap and remain comfortable to read.",
                ),
                (
                    "Maya Chen",
                    "I will review the screenshots and empty states on Thursday. The interface must say when a feature needs configuration or a platform adapter.",
                ),
            ],
        ),
    ];
    let mut ids = vec![];
    for (index, (title, app, hour, minute, lines)) in definitions.into_iter().enumerate() {
        let mut m = Meeting::empty(title);
        m.app = app.into();
        m.started_at = chrono::Local
            .from_local_datetime(&today.and_hms_opt(hour, minute, 0).unwrap())
            .earliest()
            .unwrap()
            .timestamp();
        m.people = lines
            .iter()
            .map(|(speaker, _)| speaker.to_string())
            .collect::<std::collections::BTreeSet<_>>()
            .into_iter()
            .collect();
        m.duration = (lines.len() * 22) as f64;
        m.segments = lines
            .into_iter()
            .enumerate()
            .map(|(i, (speaker, text))| Segment {
                id: format!("fixture-{index}-{i}"),
                start: (i * 22) as f64,
                end: ((i + 1) * 22) as f64,
                speaker: speaker.into(),
                text: text.into(),
            })
            .collect();
        m.notes = "Synthetic test meeting. No private recording or work history was used.".into();
        ids.push(m.id.clone());
        library.save_meeting(&m)?;
    }
    for (app, title, text, start, duration) in [
        (
            "VS Code",
            "LokalBot Desktop — storage.rs",
            "Implemented SQLite persistence and source deletion checks.",
            9 * 3600,
            2800,
        ),
        (
            "Firefox",
            "GPUI documentation",
            "Reviewed Linux and Windows platform requirements.",
            10 * 3600 + 120,
            1700,
        ),
        (
            "Terminal",
            "Synthetic fixture validation",
            "Prepared the GPU-free test run.",
            11 * 3600,
            1200,
        ),
    ] {
        let midnight = chrono::Local
            .from_local_datetime(&today.and_hms_opt(0, 0, 0).unwrap())
            .earliest()
            .unwrap()
            .timestamp();
        let at = midnight + start;
        library.save_activity(&Activity {
            id: new_id(),
            app: app.into(),
            title: title.into(),
            start: at,
            end: at + duration,
            private: false,
        })?;
        library.save_moment(&Moment {
            id: new_id(),
            app: app.into(),
            title: title.into(),
            text: text.into(),
            created_at: at,
            saved: false,
            pixels: None,
        })?;
    }
    atomic_write(
        &library.root.join(".synthetic-fixture"),
        b"Fictional LokalBot desktop integration fixtures\n",
    )?;
    Ok(ids)
}
