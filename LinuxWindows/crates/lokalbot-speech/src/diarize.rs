//! Speaker separation within one track: pyannote segmentation 3.0 finds who
//! speaks when, speaker embeddings tell the voices apart, and clustering
//! numbers them. Replaces macOS's Nemotron/Pyannote CoreML diarizers.

use std::path::Path;

use anyhow::{Result, anyhow};
use sherpa_onnx::{
    FastClusteringConfig, OfflineSpeakerDiarization, OfflineSpeakerDiarizationConfig,
    OfflineSpeakerSegmentationModelConfig, OfflineSpeakerSegmentationPyannoteModelConfig,
    SpeakerEmbeddingExtractorConfig,
};

use crate::attribution::Turn;

/// Clustering threshold for TitaNet-small embeddings; lower keeps more voices
/// apart. 0.7–0.8 separated 2 and 4 synthetic voices correctly where 0.5
/// split one voice in two.
pub const CLUSTER_THRESHOLD: f32 = 0.75;
/// Tracks shorter than this are not worth separating.
const MIN_SECONDS: f64 = 2.0;

pub struct Diarizer {
    inner: OfflineSpeakerDiarization,
}

impl Diarizer {
    pub fn load(
        segmentation: &Path,
        embedding: &Path,
        threads: usize,
        threshold: f32,
    ) -> Result<Self> {
        let threads = threads.clamp(1, 16) as i32;
        let config = OfflineSpeakerDiarizationConfig {
            segmentation: OfflineSpeakerSegmentationModelConfig {
                pyannote: OfflineSpeakerSegmentationPyannoteModelConfig {
                    model: Some(segmentation.to_string_lossy().into_owned()),
                    ..Default::default()
                },
                num_threads: threads,
                debug: false,
                provider: Some("cpu".into()),
            },
            embedding: SpeakerEmbeddingExtractorConfig {
                model: Some(embedding.to_string_lossy().into_owned()),
                num_threads: threads,
                debug: false,
                provider: Some("cpu".into()),
            },
            clustering: FastClusteringConfig {
                num_clusters: -1,
                threshold,
                compute_confidence: false,
            },
            min_duration_on: 0.3,
            min_duration_off: 0.5,
        };
        let inner = OfflineSpeakerDiarization::create(&config)
            .ok_or_else(|| anyhow!("could not load the speaker models"))?;
        Ok(Self { inner })
    }

    /// Speaker turns of 16 kHz mono `samples`, sorted by start.
    pub fn turns(&self, samples: &[f32]) -> Result<Vec<Turn>> {
        if (samples.len() as f64) < MIN_SECONDS * 16_000.0 {
            return Ok(Vec::new());
        }
        let result = self
            .inner
            .process(samples)
            .ok_or_else(|| anyhow!("speaker separation failed"))?;
        Ok(result
            .sort_by_start_time()
            .into_iter()
            .filter(|s| s.end > s.start)
            .map(|s| Turn {
                start: s.start as f64,
                end: s.end as f64,
                speaker: s.speaker,
            })
            .collect())
    }
}
