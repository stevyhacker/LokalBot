use std::collections::HashSet;
use std::sync::Arc;

use anyhow::{Result, anyhow};
use lokalbot_ai::project_status;
use lokalbot_ai::remote_gate::Priority;
use lokalbot_ai::think::allows_automatic_main_inference;
use lokalbot_core::ProjectProfile;
use parking_lot::Mutex;

use crate::models::Models;
use crate::{EngineEvent, Shared};

#[derive(Clone)]
pub struct ProjectNotes {
    shared: Arc<Shared>,
    models: Models,
    writing: Arc<Mutex<HashSet<String>>>,
    attempts: Arc<Mutex<HashSet<String>>>,
}

fn due_automatically(
    project: &ProjectProfile,
    writing: &HashSet<String>,
    attempts: &HashSet<String>,
) -> bool {
    if !project.is_tracked() || writing.contains(&project.id) {
        return false;
    }
    let evidence = project_status::evidence(project);
    if evidence.is_empty() {
        return false;
    }
    let fingerprint = project_status::fingerprint(&evidence);
    let saved = project.summary.as_ref();
    saved.is_none_or(|summary| summary.evidence_fingerprint != fingerprint)
        && !attempts.contains(&attempt_key(&project.id, &fingerprint))
}

fn attempt_key(project_id: &str, fingerprint: &str) -> String {
    format!("{project_id}{fingerprint}")
}

impl ProjectNotes {
    pub fn new(shared: Arc<Shared>, models: Models) -> Self {
        Self {
            shared,
            models,
            writing: Default::default(),
            attempts: Default::default(),
        }
    }

    pub fn write(&self, project_id: String) {
        let notes = self.clone();
        std::thread::spawn(move || {
            if !notes.writing.lock().insert(project_id.clone()) {
                return;
            }
            let result = notes.write_now(&project_id, Priority::Interactive, false);
            if let Err(err) = result {
                notes
                    .shared
                    .error(format!("Could not write the project note: {err:#}"));
            }
            notes.finished(project_id);
        });
    }

    pub fn opened(&self, project_id: String) {
        let notes = self.clone();
        std::thread::spawn(move || {
            let settings = notes.shared.settings();
            if !allows_automatic_main_inference(&settings)
                || !notes
                    .models
                    .missing(&notes.models.think_requirements())
                    .is_empty()
            {
                return;
            }
            let library = &notes.shared.library;
            let Ok(projects) = library.projects() else {
                return;
            };
            let Some(project) = projects.iter().find(|p| p.id == project_id) else {
                return;
            };
            {
                let mut writing = notes.writing.lock();
                let mut attempts = notes.attempts.lock();
                if !due_automatically(project, &writing, &attempts) {
                    return;
                }
                let evidence = project_status::evidence(project);
                attempts.insert(attempt_key(
                    &project.id,
                    &project_status::fingerprint(&evidence),
                ));
                writing.insert(project_id.clone());
            }
            if let Err(err) = notes.write_now(&project_id, Priority::Background, true) {
                log::warn!("the automatic note for {project_id} was not written: {err:#}");
            }
            notes.finished(project_id);
        });
    }

    fn write_now(&self, project_id: &str, priority: Priority, automatic: bool) -> Result<()> {
        let shared = &self.shared;
        shared.emit(EngineEvent::ProjectNote {
            project_id: project_id.to_string(),
            running: true,
        });
        if !self
            .models
            .missing(&self.models.think_requirements())
            .is_empty()
        {
            return Err(anyhow!(
                "Download the Think model in Settings → Models first."
            ));
        }
        let settings = shared.settings();
        let think = shared
            .think(&settings)?
            .with_priority(priority, "project summary");
        let project = shared
            .library
            .projects()?
            .into_iter()
            .find(|p| p.id == project_id)
            .ok_or_else(|| anyhow!("That project no longer exists."))?;
        let summary = project_status::generate(&think, &shared.library, &project)?;
        if automatic && !allows_automatic_main_inference(&shared.settings()) {
            return Ok(());
        }
        if !shared
            .library
            .projects()?
            .iter()
            .any(|p| p.id == project_id)
        {
            return Ok(());
        }
        shared.library.save_project_summary(summary)?;
        Ok(())
    }

    fn finished(&self, project_id: String) {
        self.writing.lock().remove(&project_id);
        self.shared.emit(EngineEvent::ProjectNote {
            project_id,
            running: false,
        });
        self.shared.emit(EngineEvent::LibraryChanged);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;
    use lokalbot_core::model::ProjectKind;
    use lokalbot_core::{MeetingRef, ProjectSummary};

    fn project(kind: ProjectKind) -> ProjectProfile {
        ProjectProfile {
            id: "tracked:7D4A1C6E-5B2F-4C3A-9E8D-1F2A3B4C5D6E".into(),
            kind,
            name: "Atlas".into(),
            other_names: Vec::new(),
            meetings: vec![MeetingRef {
                id: uuid::Uuid::new_v4(),
                title: "Atlas review".into(),
                started_at: Utc::now(),
                ended_at: None,
                calendar_event_id: None,
                participant_count: 0,
            }],
            mentions: Vec::new(),
            my_actions: Vec::new(),
            others_actions: Vec::new(),
            older_others_actions: Vec::new(),
            decisions: Vec::new(),
            people: Vec::new(),
            week_seconds: 0.0,
            days: Vec::new(),
            windows: Vec::new(),
            window_count: 0,
            last_active: None,
            summary: None,
            review_notes: Vec::new(),
        }
    }

    fn summary(project: &ProjectProfile, fingerprint: &str) -> ProjectSummary {
        ProjectSummary {
            project_id: project.id.clone(),
            overview: "Where it stands.".into(),
            points: Vec::new(),
            open_questions: Vec::new(),
            meeting_ids: Vec::new(),
            evidence_fingerprint: fingerprint.into(),
            generated_at: Utc::now(),
            engine_name: "test".into(),
            location: "on this PC".into(),
        }
    }

    #[test]
    fn a_note_is_due_only_when_its_evidence_changed_and_once_for_that_evidence() {
        let mut atlas = project(ProjectKind::Tracked);
        let fingerprint = project_status::fingerprint(&project_status::evidence(&atlas));
        let none = HashSet::new();

        assert!(due_automatically(&atlas, &none, &none));
        atlas.summary = Some(summary(&atlas, "older evidence"));
        assert!(due_automatically(&atlas, &none, &none));
        atlas.summary = Some(summary(&atlas, &fingerprint));
        assert!(!due_automatically(&atlas, &none, &none));
        atlas.summary = None;
        let writing = HashSet::from([atlas.id.clone()]);
        assert!(!due_automatically(&atlas, &writing, &none));
        let attempts = HashSet::from([attempt_key(&atlas.id, &fingerprint)]);
        assert!(!due_automatically(&atlas, &none, &attempts));
    }

    #[test]
    fn only_a_tracked_project_with_evidence_gets_a_note_by_itself() {
        let none = HashSet::new();
        assert!(!due_automatically(
            &project(ProjectKind::Suggested),
            &none,
            &none
        ));
        let mut empty = project(ProjectKind::Tracked);
        empty.meetings.clear();
        assert!(!due_automatically(&empty, &none, &none));
    }
}
