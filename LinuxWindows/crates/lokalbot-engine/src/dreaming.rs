use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Result, anyhow};
use chrono::{DateTime, Local, NaiveDate, Timelike as _, Utc};
use parking_lot::{Condvar, Mutex};

use lokalbot_ai::dream::{self, DreamError, DreamRequest};
use lokalbot_ai::personal_learning;
use lokalbot_ai::think::{SIMILARITY_PREFIX, allows_automatic_main_inference};
use lokalbot_core::Settings;
use lokalbot_core::dream::{CATCH_UP_DAYS, DreamStore, InferenceProvenance, day_from_key, day_key};
use lokalbot_core::personal::learning;

use crate::models::Models;
use crate::{BackgroundItem, BackgroundKind, EngineEvent, Shared};

const TICK: Duration = Duration::from_secs(60);
const FAILURE_BACKOFF: Duration = Duration::from_secs(15 * 60);

#[derive(Clone, Debug, Default, PartialEq)]
pub struct DreamStatus {
    pub is_dreaming: bool,
    pub active_day: Option<String>,
    pub remaining_days: usize,
    pub last_dreamed_at: Option<DateTime<Utc>>,
    pub last_error: Option<String>,
}

#[derive(Default)]
struct State {
    status: DreamStatus,
    last_failure: Option<Instant>,
    transient_failures: HashMap<String, u32>,
    complete_through: Option<NaiveDate>,
    review_now: bool,
    wake: bool,
}

#[derive(Default)]
pub(crate) struct Dreams {
    state: Mutex<State>,
    wake: Condvar,
    generation: AtomicU64,
}

impl Dreams {
    fn wake(&self) {
        self.state.lock().wake = true;
        self.wake.notify_all();
    }

    pub fn review_now(&self) {
        {
            let mut state = self.state.lock();
            if state.status.is_dreaming {
                return;
            }
            state.review_now = true;
            state.wake = true;
        }
        self.wake.notify_all();
    }

    pub fn reconsider(&self, days: &[NaiveDate]) {
        {
            let mut state = self.state.lock();
            state.last_failure = None;
            state.complete_through = None;
            let active = state.status.active_day.as_deref().and_then(day_from_key);
            if active.is_some_and(|day| days.contains(&day)) {
                self.generation.fetch_add(1, Ordering::SeqCst);
            }
            state.wake = true;
        }
        self.wake.notify_all();
    }

    pub fn settings_changed(&self) {
        {
            let mut state = self.state.lock();
            state.last_failure = None;
            state.complete_through = None;
            state.wake = true;
        }
        self.wake.notify_all();
    }

    fn abandon(&self) {
        self.generation.fetch_add(1, Ordering::SeqCst);
    }

    fn sleep(&self) {
        let mut state = self.state.lock();
        if !state.wake {
            let _ = self.wake.wait_for(&mut state, TICK);
        }
        state.wake = false;
    }
}

fn publish(shared: &Shared, change: impl FnOnce(&mut State)) {
    let status = {
        let mut state = shared.dreams.state.lock();
        change(&mut state);
        state.status.clone()
    };
    shared.emit(EngineEvent::Dream(Box::new(status)));
}

pub fn oldest_missing_target(
    first_eligible: Option<&str>,
    yesterday: NaiveDate,
    has_report: &dyn Fn(&str) -> bool,
) -> Option<NaiveDate> {
    let window_start = yesterday - chrono::Duration::days(CATCH_UP_DAYS - 1);
    let start = match first_eligible.filter(|key| lokalbot_core::dream::is_canonical_day_key(key)) {
        Some(key) => {
            let day = day_from_key(key)?;
            if day > yesterday {
                return None;
            }
            day
        }
        None => yesterday,
    };
    let mut day = start.max(window_start);
    while day <= yesterday {
        if !has_report(&day_key(day)) {
            return Some(day);
        }
        day = day.succ_opt()?;
    }
    None
}

fn missing_after(day: NaiveDate, yesterday: NaiveDate, has_report: &dyn Fn(&str) -> bool) -> usize {
    let mut count = 0;
    let mut current = day;
    while let Some(next) = current.succ_opt().filter(|next| *next <= yesterday) {
        if !has_report(&day_key(next)) {
            count += 1;
        }
        current = next;
    }
    count
}

pub fn past_the_hour(now_hour: u32, hour: u32) -> bool {
    now_hour >= hour.min(23)
}

fn can_run(shared: &Shared, models: &Models, settings: &Settings) -> bool {
    allows_automatic_main_inference(settings)
        && models.missing(&models.think_requirements()).is_empty()
        && !shared.capture_active.load(Ordering::Relaxed)
        && !shared.recording_active.load(Ordering::Relaxed)
        && !shared.dictation_working.load(Ordering::Relaxed)
        && !shared.autocomplete_generating.load(Ordering::Relaxed)
        && !shared.pipeline_busy.load(Ordering::Relaxed)
        && !lokalbot_platform::power::on_battery()
}

fn tick(shared: &Arc<Shared>, models: &Models) {
    let manual = std::mem::take(&mut shared.dreams.state.lock().review_now);
    let today = Local::now().date_naive();
    let yesterday = today - chrono::Duration::days(1);
    if manual {
        run(shared, models, yesterday, false, 0);
        return;
    }
    loop {
        let settings = shared.settings();
        if !settings.dreaming_enabled || shared.is_shutting_down() {
            return;
        }
        if !past_the_hour(Local::now().hour(), settings.dreaming_hour) {
            return;
        }
        {
            let state = shared.dreams.state.lock();
            if state.complete_through == Some(yesterday) {
                return;
            }
            if state
                .last_failure
                .is_some_and(|at| at.elapsed() < FAILURE_BACKOFF)
            {
                return;
            }
        }
        if !can_run(shared, models, &settings) {
            return;
        }
        let store = DreamStore::new(shared.library.paths().root());
        let has_report = |key: &str| store.has_report(key);
        let Some(day) = oldest_missing_target(
            settings.dreaming_first_eligible_day_key(),
            yesterday,
            &has_report,
        ) else {
            shared.dreams.state.lock().complete_through = Some(yesterday);
            return;
        };
        let remaining = missing_after(day, yesterday, &has_report);
        if !run(shared, models, day, true, remaining) {
            return;
        }
    }
}

fn day_label(day: NaiveDate) -> String {
    day.format("%b %-d").to_string()
}

fn run(
    shared: &Arc<Shared>,
    models: &Models,
    day: NaiveDate,
    is_automatic: bool,
    remaining: usize,
) -> bool {
    let key = day_key(day);
    let generation = shared.dreams.generation.load(Ordering::SeqCst);
    let transient_failures = {
        let state = shared.dreams.state.lock();
        state.transient_failures.get(&key).copied().unwrap_or(0)
    };
    publish(shared, |state| {
        state.status.is_dreaming = true;
        state.status.active_day = Some(key.clone());
        state.status.remaining_days = remaining;
        state.status.last_error = None;
    });
    let background_id = "overnight-review".to_string();
    let detail = if remaining == 0 {
        day_label(day)
    } else {
        lokalbot_i18n::format(
            "{0}, {1} more",
            &[("0", day_label(day)), ("1", remaining.to_string())],
        )
    };
    shared.set_background(BackgroundItem {
        id: background_id.clone(),
        kind: BackgroundKind::Digest,
        title: lokalbot_i18n::tr("Overnight review").to_string(),
        detail,
        progress: None,
    });
    let cancelled = || {
        shared.is_shutting_down() || shared.dreams.generation.load(Ordering::SeqCst) != generation
    };
    let make_engine = || -> Result<(lokalbot_ai::think::ThinkClient, InferenceProvenance)> {
        let settings = shared.settings();
        if is_automatic && !allows_automatic_main_inference(&settings) {
            return Err(lokalbot_ai::AiError::Unavailable(
                "Approve scheduled context sharing for this remote Think server in Models settings."
                    .into(),
            )
            .into());
        }
        let think = shared.think(&settings)?;
        if is_automatic && !allows_automatic_main_inference(&shared.settings()) {
            return Err(lokalbot_ai::AiError::Cancelled.into());
        }
        let provenance = dream::inference_provenance(&think, &settings);
        Ok((think, provenance))
    };
    let result = dream::dream(
        &shared.library,
        &DreamRequest {
            day,
            language: lokalbot_ai::language::DailySummaryLanguage::from_settings(
                &shared.settings(),
            ),
            is_automatic,
            transient_failures,
            make_engine: &make_engine,
            cancelled: &cancelled,
        },
    );
    let mut advance = false;
    match result {
        Ok(_) if cancelled() => {}
        Ok(_) => {
            publish(shared, |state| {
                state.status.last_dreamed_at = Some(Utc::now());
                state.last_failure = None;
                state.transient_failures.remove(&key);
            });
            learn_about_person(shared, models, day, is_automatic);
            roll_up_reviews(shared, is_automatic);
            advance = is_automatic;
        }
        Err(DreamError::Cancelled) => {}
        Err(DreamError::Deferred(_)) => {
            let mut state = shared.dreams.state.lock();
            state.last_failure = Some(Instant::now());
            *state.transient_failures.entry(key.clone()).or_default() += 1;
        }
        Err(err) => {
            let message =
                lokalbot_i18n::format("Dreaming failed: {0}", &[("0", format!("{err:#}"))]);
            shared.error(message.clone());
            publish(shared, |state| {
                state.last_failure = Some(Instant::now());
                state.status.last_error = Some(message);
            });
        }
    }
    shared.clear_background(&background_id);
    publish(shared, |state| {
        state.status.is_dreaming = false;
        state.status.active_day = None;
        state.status.remaining_days = 0;
    });
    shared.emit(EngineEvent::LibraryChanged);
    advance
}

fn learn_about_person(shared: &Arc<Shared>, models: &Models, day: NaiveDate, is_automatic: bool) {
    let settings = shared.settings();
    if !settings.ask_memory_enabled || !settings.personal_learning_enabled {
        return;
    }
    let library = &shared.library;
    let store = DreamStore::new(library.paths().root());
    let key = day_key(day);
    if let Ok(Some(memory)) = store.load_memory() {
        let promoted = library.personal().promote_work_memory(&memory, &key);
        if !promoted.proposed.is_empty() {
            log::info!(
                "personal learning: day={key} work-memory suggestions={}",
                promoted.proposed.len()
            );
        }
    }
    if is_automatic && !allows_automatic_main_inference(&settings) {
        return;
    }
    let result = (|| -> Result<()> {
        let bursts = if settings.coding_agent_evidence_active() {
            library.coding_agent_bursts_on(day).unwrap_or_default()
        } else {
            Vec::new()
        };
        let log = library.dictation_log();
        let dictated = if settings.learns_from_dictation() {
            log.entries_on(day)
        } else {
            Vec::new()
        };
        let conversations = library.conversations().unwrap_or_default();
        let typed = learning::typed_lines(&bursts, &conversations, &dictated, day);
        let lines = learning::utterances(library, day, &typed)?;
        let fingerprint = learning::fingerprint(&lines);
        let counts = learning::line_counts(&lines);
        if lines.is_empty()
            || (dictated.is_empty() && library.personal().has_learned(&key, &fingerprint))
        {
            log::info!("personal learning: day={key} {counts} unchanged or empty, not read again");
            return Ok(());
        }
        let revision = store.evidence_revision().map_err(anyhow::Error::from)?;
        let think = shared.think(&settings)?;
        let mut known = library.personal().usable_claims(true);
        known.extend(library.personal().suggestions());
        let embedder = (settings.semantic_search_enabled
            && models.missing(&models.embedding_requirements()).is_empty())
        .then(|| lokalbot_ai::think::EmbeddingClient::new(&shared.runtime));
        let embed = |texts: &[String]| {
            let embedder = embedder.as_ref()?;
            embedder.embed(texts, SIMILARITY_PREFIX).ok()
        };
        let candidates = personal_learning::run(&think, &lines, &known, revision, Some(&embed))?;
        if !dictated.is_empty()
            && let Err(err) = log.remove_through(day)
        {
            log::warn!("dictation for learning not removed: {err:#}");
        }
        let outcome = library
            .personal()
            .learn(&candidates, Some((&key, &fingerprint)));
        log::info!(
            "personal learning: day={key} {counts} saved={} suggested={} skipped={}",
            outcome.saved.len(),
            outcome.proposed.len(),
            outcome.skipped
        );
        Ok(())
    })();
    if let Err(err) = result {
        log::info!("personal learning skipped: {err:#}");
    }
}

fn roll_up_reviews(shared: &Arc<Shared>, is_automatic: bool) {
    let settings = shared.settings();
    let showable = lokalbot_core::access::screen_access_scope(shared.library.paths())
        == Some(lokalbot_core::access::ScreenScope::RetainedHistory);
    let result = lokalbot_ai::dream_rollup::run(
        &shared.library,
        Utc::now(),
        lokalbot_ai::dream_rollup::nightly_limit(showable),
        &|| {
            if is_automatic && !allows_automatic_main_inference(&settings) {
                return Err(anyhow!("scheduled sharing is not approved"));
            }
            shared.think(&settings)
        },
    );
    match result {
        Ok(outcome) if !outcome.written.is_empty() || !outcome.removed.is_empty() => {
            log::info!(
                "dream rollups: written={:?} removed={:?}",
                outcome.written,
                outcome.removed
            );
        }
        Ok(_) => {}
        Err(err) => log::info!("dream rollups skipped: {err:#}"),
    }
}

pub(crate) fn clear_work_memory(shared: &Shared) {
    shared.dreams.abandon();
    if let Err(err) = DreamStore::new(shared.library.paths().root()).clear_all() {
        shared.error(lokalbot_i18n::format(
            "Could not clear dream memory: {0}",
            &[("0", format!("{err:#}"))],
        ));
    }
    shared.dreams.settings_changed();
    shared.emit(EngineEvent::LibraryChanged);
}

pub(crate) fn digest_changed(shared: &Shared, day: NaiveDate) {
    if day >= Local::now().date_naive() {
        return;
    }
    let key = day_key(day);
    let revocation = lokalbot_core::dream::store::Revocation {
        days: [key.clone()].into(),
        meetings: Default::default(),
        reports: [key].into(),
        activity_only: true,
    };
    let store = DreamStore::new(shared.library.paths().root());
    if let Err(err) = store.invalidate_evidence(&revocation, Utc::now()) {
        shared.error(lokalbot_i18n::format(
            "Could not retract changed evidence from Dream memory: {0}",
            &[("0", format!("{err:#}"))],
        ));
    }
    shared.dreams.reconsider(&[day]);
}

pub fn review_once(
    library: &lokalbot_core::Library,
    settings: &Settings,
    day: NaiveDate,
) -> Result<lokalbot_core::dream::DreamReport> {
    let runtime = lokalbot_ai::runtime::RuntimeManager::new(library.paths().clone(), settings);
    let make_engine = || -> Result<(lokalbot_ai::think::ThinkClient, InferenceProvenance)> {
        let client = lokalbot_ai::think::ThinkClient::new(&runtime, settings)?;
        let think = match settings.summarizer_backend {
            lokalbot_core::settings::SummarizerBackend::OpenAICompatible => {
                client.with_api_key(crate::secrets::openai_api_key())
            }
            _ => client,
        };
        let provenance = dream::inference_provenance(&think, settings);
        Ok((think, provenance))
    };
    let result = dream::dream(
        library,
        &DreamRequest {
            day,
            language: lokalbot_ai::language::DailySummaryLanguage::from_settings(settings),
            is_automatic: false,
            transient_failures: 0,
            make_engine: &make_engine,
            cancelled: &|| false,
        },
    );
    runtime.shutdown();
    result.map_err(|err| anyhow!("{err:#}"))
}

pub fn validated_day(key: Option<&str>, today: NaiveDate) -> Result<NaiveDate, String> {
    let yesterday = today - chrono::Duration::days(1);
    let day = match key {
        Some(key) => day_from_key(key)
            .filter(|_| lokalbot_core::dream::is_canonical_day_key(key))
            .ok_or_else(|| format!("invalid day {key} (expected yyyy-MM-dd)"))?,
        None => yesterday,
    };
    if day > yesterday {
        return Err(format!("day {} must be yesterday or earlier", day_key(day)));
    }
    Ok(day)
}

pub(crate) fn start(shared: Arc<Shared>, models: Models) {
    let spawned = std::thread::Builder::new()
        .name("lokalbot-dreams".into())
        .spawn(move || {
            publish(&shared, |_| {});
            shared.library.personal().start_access();
            while !shared.is_shutting_down() {
                shared.dreams.sleep();
                if shared.is_shutting_down() {
                    return;
                }
                tick(&shared, &models);
            }
        });
    if let Err(err) = spawned {
        log::warn!("could not start the overnight review: {err}");
    }
}

pub(crate) fn stop(shared: &Shared) {
    shared.dreams.abandon();
    shared.dreams.wake();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn day(key: &str) -> NaiveDate {
        day_from_key(key).unwrap()
    }

    #[test]
    fn it_walks_forward_from_the_boundary_and_stops_at_seven_days() {
        let yesterday = day("2026-10-19");
        let none = |_: &str| false;
        assert_eq!(
            oldest_missing_target(Some("2026-10-18"), yesterday, &none),
            Some(day("2026-10-18"))
        );
        assert_eq!(
            oldest_missing_target(Some("2026-01-01"), yesterday, &none),
            Some(day("2026-10-13"))
        );
        let some = |key: &str| key == "2026-10-13" || key == "2026-10-14";
        assert_eq!(
            oldest_missing_target(Some("2026-01-01"), yesterday, &some),
            Some(day("2026-10-15"))
        );
        assert_eq!(
            oldest_missing_target(Some("2026-10-18"), yesterday, &|_: &str| true),
            None
        );
    }

    #[test]
    fn a_future_boundary_waits_and_a_malformed_one_narrows_to_yesterday() {
        let yesterday = day("2026-10-19");
        let none = |_: &str| false;
        assert_eq!(
            oldest_missing_target(Some("2026-10-20"), yesterday, &none),
            None
        );
        assert_eq!(
            oldest_missing_target(Some("not a day"), yesterday, &none),
            Some(yesterday)
        );
        assert_eq!(
            oldest_missing_target(None, yesterday, &none),
            Some(yesterday)
        );
        assert_eq!(
            oldest_missing_target(Some("2026-1-1"), yesterday, &none),
            Some(yesterday)
        );
    }

    #[test]
    fn it_counts_whats_queued_behind_a_run() {
        let yesterday = day("2026-10-19");
        let has = |key: &str| key == "2026-10-18";
        assert_eq!(missing_after(day("2026-10-16"), yesterday, &has), 2);
        assert_eq!(missing_after(yesterday, yesterday, &has), 0);
    }

    #[test]
    fn a_headless_day_must_be_valid_and_in_the_past() {
        let today = day("2026-10-20");
        assert_eq!(validated_day(None, today), Ok(day("2026-10-19")));
        assert_eq!(
            validated_day(Some("2026-10-01"), today),
            Ok(day("2026-10-01"))
        );
        assert!(
            validated_day(Some("2026-10-20"), today)
                .unwrap_err()
                .contains("yesterday")
        );
        assert!(
            validated_day(Some("oct 1"), today)
                .unwrap_err()
                .contains("expected")
        );
        assert!(
            validated_day(Some("2026-1-1"), today)
                .unwrap_err()
                .contains("expected")
        );
    }

    #[test]
    fn it_runs_once_the_hour_has_passed() {
        assert!(!past_the_hour(3, 4));
        assert!(past_the_hour(4, 4));
        assert!(past_the_hour(23, 40));
    }
}
