use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use super::{Draft, Step};

const FILE: &str = "onboarding-resume.json";

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ResumeState {
    pub step: Step,
    pub draft: Draft,
    pub baseline: Draft,
    pub include_autocomplete: bool,
    pub opens_sample_meeting: bool,
}

fn path(root: &Path) -> PathBuf {
    root.join(FILE)
}

pub(super) fn load(root: &Path, current: &Draft) -> Option<ResumeState> {
    let text = std::fs::read_to_string(path(root)).ok()?;
    parse(&text, current)
}

fn parse(text: &str, current: &Draft) -> Option<ResumeState> {
    let state: ResumeState = serde_json::from_str(text).ok()?;
    (state.baseline == *current).then_some(state)
}

pub(super) fn save(root: &Path, state: &ResumeState) {
    let Ok(text) = serde_json::to_string(state) else {
        return;
    };
    if let Err(err) = lokalbot_core::library::write_atomic(&path(root), text.as_bytes()) {
        log::warn!("could not save where setup is: {err:#}");
    }
}

pub(super) fn clear(root: &Path) {
    let path = path(root);
    if path.exists()
        && let Err(err) = std::fs::remove_file(&path)
    {
        log::warn!("could not remove setup's saved state: {err:#}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_core::settings::{AutoRecordMode, Settings};

    fn state(baseline: Draft) -> ResumeState {
        let mut draft = baseline;
        draft.set_meeting_mode(AutoRecordMode::Automatic);
        ResumeState {
            step: Step::Access,
            draft,
            baseline,
            include_autocomplete: true,
            opens_sample_meeting: false,
        }
    }

    #[test]
    fn a_saved_setup_resumes_only_for_the_settings_it_began_with() {
        let settings = Settings::default();
        let baseline = Draft::new(&settings);
        let saved = state(baseline);
        let text = serde_json::to_string(&saved).unwrap();
        assert_eq!(parse(&text, &baseline), Some(saved));

        let changed = Draft::new(&Settings {
            tracking_enabled: false,
            ..settings
        });
        assert_eq!(parse(&text, &changed), None);
        assert_eq!(parse("{not json", &baseline), None);
    }

    #[test]
    fn saving_and_clearing_round_trips_in_the_library() {
        let dir = tempfile::tempdir().unwrap();
        let baseline = Draft::new(&Settings::default());
        save(dir.path(), &state(baseline));
        assert_eq!(load(dir.path(), &baseline), Some(state(baseline)));
        clear(dir.path());
        assert_eq!(load(dir.path(), &baseline), None);
        clear(dir.path());
    }
}
