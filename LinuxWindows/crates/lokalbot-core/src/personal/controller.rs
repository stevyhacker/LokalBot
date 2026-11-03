//! The one owner of the personal model (`PersonalModelController`,
//! `PersonalModelStore`). Ask reads and adds claims through it; Settings →
//! Personal Context edits them; the overnight review adds learned ones. Nothing
//! touches the credential store until first use. If the saved file can't be read,
//! every edit is refused instead of overwriting it. Learned claims are checked
//! against the evidence revisions on every use: a deleted or corrected source
//! retracts them, and while a revocation is pending they are withheld.
//!
//! `memory/personal-model.json.enc` is sealed under the `chat-key`. A plaintext
//! `memory/personal-model.json` (demo seeds, upgrade fixtures) is accepted and
//! re-sealed on the next save; a sealed copy wins over a plaintext one.

use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;

use anyhow::Result;
use chrono::{NaiveDate, Utc};
use uuid::Uuid;

use super::{
    Authority, Claim, ClaimEdit, ClaimKind, EditError, LearningCandidate, LearningOutcome, Origin,
    PersonalModel, Status, TypedSource, access, duplicate_key, learning, promotion,
};
use crate::dream::{DreamMemory, DreamStore, day_from_key};
use crate::evidence::EvidenceState;
use crate::library::{Library, write_atomic};
use crate::sealed;

pub const FILE_NAME: &str = "personal-model.json";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LoadError {
    KeyUnavailable,
    Unreadable,
    NewerVersion,
}

impl LoadError {
    pub fn message(self) -> &'static str {
        match self {
            Self::KeyUnavailable => lokalbot_i18n::tr(
                "LokalBot couldn't unlock what it remembers about you. It's kept as is and nothing new is saved until it can.",
            ),
            Self::NewerVersion => lokalbot_i18n::tr(
                "What LokalBot remembers about you was saved by a newer version. Update LokalBot to change it.",
            ),
            Self::Unreadable => lokalbot_i18n::tr(
                "LokalBot couldn't read what it remembers about you. The file is kept as is and nothing new is saved.",
            ),
        }
    }
}

/// Held by the library, behind one lock.
#[derive(Debug, Default)]
pub struct State {
    model: PersonalModel,
    loaded: bool,
    load_error: Option<LoadError>,
    /// The last projection failure, for Settings.
    access_error: Option<String>,
}

/// A borrowed view of the library's personal model.
pub struct Personal<'a> {
    library: &'a Library,
}

impl Library {
    pub fn personal(&self) -> Personal<'_> {
        Personal { library: self }
    }
}

impl Personal<'_> {
    fn directory(&self) -> PathBuf {
        self.library.paths().root().join("memory")
    }

    fn sealed_path(&self) -> PathBuf {
        self.directory().join(format!("{FILE_NAME}.enc"))
    }

    fn plaintext_path(&self) -> PathBuf {
        self.directory().join(FILE_NAME)
    }

    /// The saved model; empty when nothing was ever saved. Errors instead of
    /// returning empty for anything unreadable, so nothing is saved over it.
    fn read_file(&self) -> Result<PersonalModel, LoadError> {
        let sealed_path = self.sealed_path();
        let plaintext_path = self.plaintext_path();
        let data = if sealed_path.exists() {
            let key = self
                .library
                .chat_key(false)
                .map_err(|_| LoadError::KeyUnavailable)?;
            let bytes = fs::read(&sealed_path).map_err(|_| LoadError::Unreadable)?;
            sealed::open(&key, &bytes).ok_or(LoadError::Unreadable)?
        } else if plaintext_path.exists() {
            fs::read(&plaintext_path).map_err(|_| LoadError::Unreadable)?
        } else {
            return Ok(PersonalModel::default());
        };
        let model: PersonalModel =
            serde_json::from_slice(&data).map_err(|_| LoadError::Unreadable)?;
        if model.version > super::MODEL_VERSION {
            return Err(LoadError::NewerVersion);
        }
        Ok(model)
    }

    fn write_file(&self, model: &PersonalModel) -> Result<()> {
        let key = self.library.chat_key(true)?;
        let value = crate::library::sort_keys(serde_json::to_value(model)?);
        let bytes = serde_json::to_vec_pretty(&value)?;
        write_atomic(&self.sealed_path(), &sealed::seal(&key, &bytes)?)?;
        match fs::remove_file(self.plaintext_path()) {
            Err(err) if err.kind() != std::io::ErrorKind::NotFound => Err(err.into()),
            _ => Ok(()),
        }
    }

    fn load_if_needed(&self, state: &mut State) {
        if !state.loaded {
            self.reload_locked(state);
        }
    }

    fn reload_locked(&self, state: &mut State) {
        state.loaded = true;
        match self.read_file() {
            Ok(model) => {
                state.model = model;
                state.load_error = None;
            }
            Err(err) => {
                log::warn!("personal model load failed: {err:?}");
                state.model = PersonalModel::default();
                state.load_error = Some(err);
            }
        }
        self.refresh_access(state);
    }

    /// Reads the file again, for when the key has only just become available.
    pub fn reload(&self) {
        let mut state = self.library.personal_state().lock();
        self.reload_locked(&mut state);
    }

    /// Why the saved items couldn't be opened, for Settings.
    pub fn load_error(&self) -> Option<LoadError> {
        let mut state = self.library.personal_state().lock();
        self.load_if_needed(&mut state);
        state.load_error
    }

    /// Everything stored, suggestions included.
    pub fn claims(&self) -> Vec<Claim> {
        let mut state = self.library.personal_state().lock();
        self.load_if_needed(&mut state);
        state.model.claims.clone()
    }

    pub fn claim(&self, id: Uuid) -> Option<Claim> {
        self.claims().into_iter().find(|c| c.id == id)
    }

    /// Learned suggestions waiting for review, newest first.
    pub fn suggestions(&self) -> Vec<Claim> {
        let mut claims: Vec<Claim> = self
            .claims()
            .into_iter()
            .filter(|c| c.status == Status::Proposed)
            .collect();
        claims.sort_by_key(|c| std::cmp::Reverse(c.created_at));
        claims
    }

    /// Kept items, newest first, the order Settings shows.
    pub fn kept(&self) -> Vec<Claim> {
        let mut claims: Vec<Claim> = self
            .claims()
            .into_iter()
            .filter(|c| c.status == Status::Confirmed)
            .collect();
        claims.sort_by_key(|c| std::cmp::Reverse(c.updated_at));
        claims
    }

    /// Confirmed claims safe to put in a prompt now. Scoped Ask questions pass
    /// `include_evidence_backed: false`: like work memory, learned claims would
    /// carry meeting content past the question's source boundary.
    pub fn usable_claims(&self, include_evidence_backed: bool) -> Vec<Claim> {
        let usable = include_evidence_backed && self.retract_invalidated();
        let mut state = self.library.personal_state().lock();
        self.load_if_needed(&mut state);
        state
            .model
            .claims
            .iter()
            .filter(|c| c.status == Status::Confirmed && (c.evidence.is_none() || usable))
            .cloned()
            .collect()
    }

    fn evidence_store(&self) -> DreamStore {
        DreamStore::new(self.library.paths().root())
    }

    /// Learned claims whose source changed keep their place while that source
    /// still has the line they quote, and are retracted once it doesn't. False
    /// when evidence can't be checked (a revocation is pending), so callers
    /// withhold evidence-backed claims meanwhile.
    pub fn retract_invalidated(&self) -> bool {
        let claims = {
            let mut state = self.library.personal_state().lock();
            self.load_if_needed(&mut state);
            state.model.claims.clone()
        };
        if !claims.iter().any(|c| c.evidence.is_some()) {
            return true;
        }
        let store = self.evidence_store();
        let Some(check) = store.evidence_check() else {
            return false;
        };
        let changed: Vec<&Claim> = claims
            .iter()
            .filter(|c| c.evidence.is_some() && check.invalidates(c.evidence.as_ref()))
            .collect();
        if changed.is_empty() {
            return true;
        }
        let revision = store.evidence_revision().ok();
        let mut kept: HashSet<Uuid> = HashSet::new();
        let mut stale: HashSet<Uuid> = HashSet::new();
        for claim in changed {
            if revision.is_some() && self.source_still_quotes(claim) {
                kept.insert(claim.id);
            } else {
                stale.insert(claim.id);
            }
        }
        self.mutate(|model, _| {
            if let Some(revision) = revision {
                model.refresh_evidence(&kept, revision);
            }
            model.retract(&stale);
            Ok(())
        })
        .is_ok()
    }

    /// After a meeting is deleted or corrected. Every read checks evidence
    /// anyway, so an unloaded model has nothing to clean yet.
    pub fn retract_if_loaded(&self) {
        if self.library.personal_state().lock().loaded {
            self.retract_invalidated();
        }
    }

    /// Does the source still have the line the claim quotes, as the person's own
    /// words? Reads only that meeting's transcript, that day's agent requests, or
    /// work memory.
    fn source_still_quotes(&self, claim: &Claim) -> bool {
        match &claim.origin {
            Origin::Learned { meeting_id, .. } => {
                let Ok(Some(meeting)) = self.library.meeting(*meeting_id) else {
                    return false;
                };
                let Ok(Some(transcript)) = self.library.transcript(&meeting) else {
                    return false;
                };
                learning::quote_still_said(
                    claim.quote.as_deref(),
                    &learning::own_turns(&transcript.segments),
                )
            }
            Origin::Typed {
                source: TypedSource::CodingAgent { .. },
                day_key,
            } => {
                let settings = crate::Settings::load(&self.library.paths().settings_file());
                let Some(day) = day_from_key(day_key) else {
                    return false;
                };
                if !settings.coding_agent_evidence_active() {
                    return false;
                }
                let Ok(bursts) = self.library.coding_agent_bursts_on(day) else {
                    return false;
                };
                let requests: Vec<String> = bursts
                    .into_iter()
                    .filter(|b| !b.is_scheduled_run())
                    .flat_map(|b| b.prompts)
                    .collect();
                learning::quote_still_said(claim.quote.as_deref(), &requests)
            }
            Origin::WorkMemory { .. } => {
                let Ok(Some(memory)) = self.evidence_store().load_memory() else {
                    return false;
                };
                let key = duplicate_key(&claim.text);
                memory
                    .work_goals
                    .iter()
                    .map(|g| g.text.clone())
                    .chain(
                        memory
                            .active_projects
                            .iter()
                            .map(|p| promotion::project_claim(&p.name)),
                    )
                    .any(|text| duplicate_key(&text) == key)
            }
            _ => false,
        }
    }

    pub fn remember(
        &self,
        text: &str,
        kind: Option<ClaimKind>,
        origin: Origin,
    ) -> Result<Claim, EditError> {
        self.mutate(|model, now| {
            model.add(
                text,
                kind.unwrap_or_else(|| ClaimKind::suggested(text)),
                origin,
                now,
            )
        })
    }

    pub fn update(&self, id: Uuid, edit: ClaimEdit) -> Result<Claim, EditError> {
        self.mutate(|model, now| model.update(id, edit, now))
    }

    pub fn forget(&self, ids: &HashSet<Uuid>) -> Result<(), EditError> {
        self.mutate(|model, now| {
            model.remove(ids, now);
            Ok(())
        })
    }

    /// The review's findings: facts and goals are saved, preferences become
    /// suggestions. Expired suggestions and tombstones are pruned.
    pub fn learn(
        &self,
        candidates: &[LearningCandidate],
        day: Option<(&str, &str)>,
    ) -> LearningOutcome {
        let mut outcome = LearningOutcome::default();
        let _ = self.mutate(|model, now| {
            model.prune(now);
            outcome = model.learn(candidates, now);
            if let Some((day_key, fingerprint)) = day {
                model.record_learned(day_key, fingerprint, now);
            }
            Ok(())
        });
        outcome
    }

    /// True when the pass already read exactly these lines for this day.
    pub fn has_learned(&self, day_key: &str, fingerprint: &str) -> bool {
        let mut state = self.library.personal_state().lock();
        self.load_if_needed(&mut state);
        state.model.has_learned(day_key, fingerprint)
    }

    /// Suggests goals and projects the review has kept for weeks.
    pub fn promote_work_memory(&self, memory: &DreamMemory, day_key: &str) -> LearningOutcome {
        let mut outcome = LearningOutcome::default();
        let _ = self.mutate(|model, now| {
            let result = promotion::evaluate(memory, &model.work_sightings, day_key);
            model.work_sightings = result.sightings;
            outcome = model.learn(&result.candidates, now);
            Ok(())
        });
        outcome
    }

    /// Deleting an Ask conversation takes back what was learned from it. Only
    /// reads the file when there may be something to take back.
    pub fn retract_learned_from_conversation(&self, conversation_id: Uuid) {
        if !self.sealed_path().exists() && !self.plaintext_path().exists() {
            return;
        }
        let _ = self.mutate(|model, _| {
            model.retract_learned_from_conversation(conversation_id);
            Ok(())
        });
    }

    pub fn confirm(&self, ids: &HashSet<Uuid>) -> Result<(), EditError> {
        self.mutate(|model, now| {
            for id in ids {
                model.confirm(*id, now)?;
            }
            Ok(())
        })
    }

    pub fn keep_as_statement(&self, id: Uuid) -> Result<Claim, EditError> {
        self.mutate(|model, now| model.keep_as_statement(id, now))
    }

    /// Forget everything: both copies, even when they can't be opened.
    pub fn forget_all(&self) -> Result<(), EditError> {
        let mut state = self.library.personal_state().lock();
        for path in [self.sealed_path(), self.plaintext_path()] {
            match fs::remove_file(&path) {
                Err(err) if err.kind() != std::io::ErrorKind::NotFound => {
                    log::warn!("personal model delete failed: {err}");
                    return Err(EditError::Unavailable);
                }
                _ => {}
            }
        }
        state.loaded = true;
        state.model = PersonalModel::default();
        state.load_error = None;
        self.refresh_access(&mut state);
        Ok(())
    }

    /// Stamps claims that went into an answer. Best effort.
    pub fn mark_used(&self, ids: &[Uuid]) {
        if ids.is_empty() {
            return;
        }
        let ids: HashSet<Uuid> = ids.iter().copied().collect();
        let _ = self.mutate(|model, now| {
            model.mark_used(&ids, now);
            Ok(())
        });
    }

    fn mutate<T>(
        &self,
        body: impl FnOnce(&mut PersonalModel, chrono::DateTime<Utc>) -> Result<T, EditError>,
    ) -> Result<T, EditError> {
        let mut state = self.library.personal_state().lock();
        self.load_if_needed(&mut state);
        if state.load_error.is_some() {
            return Err(EditError::Unavailable);
        }
        let mut updated = state.model.clone();
        let result = body(&mut updated, Utc::now())?;
        if updated == state.model {
            return Ok(result);
        }
        if let Err(err) = self.write_file(&updated) {
            log::warn!("personal model save failed: {err:#}");
            return Err(EditError::Unavailable);
        }
        state.model = updated;
        self.refresh_access(&mut state);
        Ok(result)
    }

    // ----------------------------------------------------------- agent access

    /// The claims agents may be offered: confirmed, with evidence still valid.
    fn agent_eligible(&self, state: &State) -> Option<Vec<Claim>> {
        if state.load_error.is_some() {
            return None;
        }
        let needs_check = state.model.claims.iter().any(|c| c.evidence.is_some());
        let check: Option<EvidenceState> = if needs_check {
            self.evidence_store().evidence_check()
        } else {
            None
        };
        Some(
            state
                .model
                .claims
                .iter()
                .filter(|claim| {
                    claim.status == Status::Confirmed
                        && match &claim.evidence {
                            None => true,
                            Some(evidence) => check
                                .as_ref()
                                .is_some_and(|check| !check.invalidates(Some(evidence))),
                        }
                })
                .cloned()
                .collect(),
        )
    }

    fn refresh_access(&self, state: &mut State) {
        let eligible = self.agent_eligible(state);
        state.access_error = access::refresh(self.library.paths(), eligible.as_deref());
    }

    /// Keeps the shared copy in step at launch: on writes it, off removes it.
    pub fn start_access(&self) {
        let paths = self.library.paths();
        if crate::access::personal_context_enabled(paths) {
            self.retract_invalidated();
            let mut state = self.library.personal_state().lock();
            self.load_if_needed(&mut state);
            self.refresh_access(&mut state);
        } else {
            access::remove_projection(paths);
        }
    }

    pub fn set_access(&self, enabled: bool) -> Result<(), String> {
        if let Err(err) = access::set_enabled(self.library.paths(), enabled) {
            return Err(lokalbot_i18n::format(
                "LokalBot couldn't turn on personal context access: {0}",
                &[("0", err.to_string())],
            ));
        }
        let mut state = self.library.personal_state().lock();
        self.load_if_needed(&mut state);
        self.refresh_access(&mut state);
        Ok(())
    }

    pub fn access_error(&self) -> Option<String> {
        self.library.personal_state().lock().access_error.clone()
    }
}

/// `PersonalContextSettings.metaLine`: where an item came from and the day.
pub fn meta_source(claim: &Claim, meeting_title: Option<&str>) -> String {
    match &claim.origin {
        Origin::Said { .. } => lokalbot_i18n::tr("Said in Ask").into(),
        Origin::Added {} => lokalbot_i18n::tr("Added by you").into(),
        Origin::Learned { .. } => match meeting_title {
            Some(title) => lokalbot_i18n::format("From {0}", &[("0", title.to_string())]),
            None => lokalbot_i18n::tr("From a meeting").into(),
        },
        Origin::Typed { source, .. } => match source {
            TypedSource::CodingAgent { name } => {
                lokalbot_i18n::format("From {0}", &[("0", name.clone())])
            }
            TypedSource::Ask { .. } => lokalbot_i18n::tr("From a question in Ask").into(),
            TypedSource::Dictation { app } if app.is_empty() => {
                lokalbot_i18n::tr("From your dictation").into()
            }
            TypedSource::Dictation { app } => {
                lokalbot_i18n::format("Dictated in {0}", &[("0", app.clone())])
            }
        },
        Origin::WorkMemory { day_key } => {
            let since = day_from_key(day_key)
                .map(|day: NaiveDate| day.format("%b %-d, %Y").to_string())
                .unwrap_or_else(|| day_key.clone());
            lokalbot_i18n::format("In work memory since {0}", &[("0", since)])
        }
    }
}

/// Saved automatically, rather than reviewed or stated.
pub fn saved_automatically(claim: &Claim) -> bool {
    claim.status == Status::Confirmed && claim.authority == Authority::Learned
}
