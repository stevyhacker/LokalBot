//! What LokalBot and its helpers use right now, and which models are in memory
//! (`ResourceMonitorSection`, `ModelResidency`, `ModelRuntimeRegistry`). Local
//! figures only; nothing is stored or sent.

use std::collections::VecDeque;
use std::time::Instant;

use lokalbot_ai::runtime::Role;
use lokalbot_platform::process_usage::process_usage;
use parking_lot::Mutex;

use crate::Engine;

#[derive(Clone, Debug, PartialEq)]
pub struct LoadedModel {
    pub role: String,
    pub label: String,
    /// `None` for a model inside LokalBot's own process, whose share of the
    /// total can't be told apart.
    pub memory_bytes: Option<u64>,
    /// A request is using it.
    pub in_use: bool,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ResourceSnapshot {
    /// Across all cores, 0–100; unknown until a second reading.
    pub cpu_percent: Option<f64>,
    /// LokalBot and its helper processes.
    pub memory_bytes: Option<u64>,
    pub models: Vec<LoadedModel>,
    /// Newest first.
    pub generations: Vec<GenerationMetric>,
}

/// One summary's timing (`GenerationMetric`).
#[derive(Clone, Debug, PartialEq)]
pub struct GenerationMetric {
    pub label: String,
    pub seconds: f64,
    pub approx_tokens: usize,
}

impl GenerationMetric {
    /// Guards the divide, so a zero duration reads as 0.
    pub fn tokens_per_second(&self) -> f64 {
        if self.seconds > 0.0 {
            self.approx_tokens as f64 / self.seconds
        } else {
            0.0
        }
    }
}

/// The last generations, in memory only (`GenerationMetricsStore`): these
/// numbers matter only while someone is watching them.
#[derive(Default)]
pub struct GenerationMetrics {
    recent: Mutex<VecDeque<GenerationMetric>>,
}

const MAXIMUM_METRICS: usize = 20;

impl GenerationMetrics {
    pub fn record(&self, label: String, seconds: f64, text: &str) {
        let mut recent = self.recent.lock();
        recent.push_front(GenerationMetric {
            label,
            seconds,
            approx_tokens: estimated_tokens(text),
        });
        recent.truncate(MAXIMUM_METRICS);
    }

    pub fn recent(&self) -> Vec<GenerationMetric> {
        self.recent.lock().iter().cloned().collect()
    }
}

/// `TokenCountEstimator`: per word, characters / 4, at least 1.
fn estimated_tokens(text: &str) -> usize {
    text.split(|c: char| !c.is_alphanumeric())
        .filter(|word| !word.is_empty())
        .map(|word| ((word.chars().count() as f64 / 4.0).round() as usize).max(1))
        .sum()
}

impl ResourceSnapshot {
    /// The memory of the models whose share is known.
    pub fn model_memory_bytes(&self) -> u64 {
        self.models.iter().filter_map(|m| m.memory_bytes).sum()
    }
}

/// Keeps the last CPU reading, so each sample covers the time since the one before.
#[derive(Default)]
pub struct ResourceSampler {
    last: Option<(Instant, f64)>,
}

fn role_title(role: Role) -> &'static str {
    match role {
        Role::Main => "Think",
        Role::Embedder => "Embeddings",
        Role::Autocomplete => "Autocomplete",
        Role::MediaEmbedder => "Files and screen pictures",
    }
}

impl ResourceSampler {
    pub fn sample(&mut self, engine: &Engine) -> ResourceSnapshot {
        let mut cpu_seconds = 0.0;
        let mut memory = None;
        let mut add = |pid: u32| {
            let usage = process_usage(pid)?;
            cpu_seconds += usage.cpu_seconds;
            memory = Some(memory.unwrap_or(0) + usage.memory_bytes);
            Some(usage.memory_bytes)
        };
        add(std::process::id());
        let mut models = Vec::new();
        for status in engine.runtime().statuses() {
            let Some(pid) = status.pid.filter(|_| status.running) else {
                continue;
            };
            let label = status
                .model_id
                .as_deref()
                .and_then(lokalbot_ai::catalog::entry)
                .map(|entry| entry.display_name.to_string())
                .or(status.model_id.clone())
                .unwrap_or_default();
            models.push(LoadedModel {
                role: role_title(status.role).to_string(),
                label,
                memory_bytes: add(pid),
                in_use: status.leases > 0,
            });
        }
        for (role, label) in engine.loaded_speech_models() {
            models.push(LoadedModel {
                role: role.to_string(),
                label,
                memory_bytes: None,
                in_use: false,
            });
        }
        let now = Instant::now();
        let cores = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(1) as f64;
        let cpu_percent = self.last.and_then(|(at, before)| {
            cpu_percent(
                before,
                cpu_seconds,
                now.duration_since(at).as_secs_f64(),
                cores,
            )
        });
        self.last = Some((now, cpu_seconds));
        ResourceSnapshot {
            cpu_percent,
            memory_bytes: memory,
            models,
            generations: engine.recent_generations(),
        }
    }
}

/// A helper that exited makes the total fall; that reading says nothing.
fn cpu_percent(before: f64, after: f64, elapsed: f64, cores: f64) -> Option<f64> {
    if elapsed <= 0.0 || after < before {
        return None;
    }
    Some(((after - before) / (elapsed * cores) * 100.0).clamp(0.0, 100.0))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generations_keep_the_last_twenty_newest_first() {
        let metrics = GenerationMetrics::default();
        for index in 0..25 {
            metrics.record(format!("Summary {index}"), 2.0, "four five, sixteen");
        }
        let recent = metrics.recent();
        assert_eq!(recent.len(), MAXIMUM_METRICS);
        assert_eq!(recent[0].label, "Summary 24");
        assert_eq!(recent[0].approx_tokens, 4);
        assert_eq!(recent[0].tokens_per_second(), 2.0);
        let idle = GenerationMetric {
            label: String::new(),
            seconds: 0.0,
            approx_tokens: 5,
        };
        assert_eq!(idle.tokens_per_second(), 0.0);
        assert_eq!(estimated_tokens("  \n"), 0);
    }

    #[test]
    fn cpu_is_shared_across_cores() {
        assert_eq!(cpu_percent(1.0, 3.0, 2.0, 4.0), Some(25.0));
        assert_eq!(cpu_percent(0.0, 100.0, 1.0, 1.0), Some(100.0));
        assert_eq!(cpu_percent(5.0, 3.0, 2.0, 4.0), None);
        assert_eq!(cpu_percent(1.0, 3.0, 0.0, 4.0), None);
    }

    #[test]
    fn model_memory_adds_what_is_known() {
        let model = |memory_bytes| LoadedModel {
            role: "Think".into(),
            label: "m".into(),
            memory_bytes,
            in_use: false,
        };
        let snapshot = ResourceSnapshot {
            models: vec![model(Some(5)), model(None), model(Some(7))],
            ..Default::default()
        };
        assert_eq!(snapshot.model_memory_bytes(), 12);
    }
}
