use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use super::{Candidate, FileKind, IndexOptions};

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Costs {
    pub image: f64,
    pub screenshot: f64,
    pub pdf_page: f64,
    pub doc_chunk: f64,
    pub audio_second: f64,
    pub video_second: f64,
}

impl Default for Costs {
    fn default() -> Self {
        Self {
            image: 0.12,
            screenshot: 0.32,
            pdf_page: 0.09,
            doc_chunk: 0.045,
            audio_second: 0.0089,
            video_second: 0.019,
        }
    }
}

impl Costs {
    fn get_mut(&mut self, name: &str) -> Option<&mut f64> {
        match name {
            "image" => Some(&mut self.image),
            "screenshot" => Some(&mut self.screenshot),
            "pdfPage" => Some(&mut self.pdf_page),
            "docChunk" => Some(&mut self.doc_chunk),
            "audioSecond" => Some(&mut self.audio_second),
            "videoSecond" => Some(&mut self.video_second),
            _ => None,
        }
    }
}

const FIELDS: [&str; 6] = [
    "image",
    "screenshot",
    "pdfPage",
    "docChunk",
    "audioSecond",
    "videoSecond",
];

fn enough(name: &str) -> f64 {
    match name {
        "image" | "screenshot" => 20.0,
        "pdfPage" | "docChunk" => 30.0,
        "audioSecond" | "videoSecond" => 600.0,
        _ => f64::INFINITY,
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Tally {
    pub seconds: f64,
    pub units: f64,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct MeasuredCosts {
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub speed: Option<serde_json::Value>,
    #[serde(default)]
    pub tallies: BTreeMap<String, Tally>,
}

impl MeasuredCosts {
    pub fn add(&mut self, name: &str, units: f64, seconds: f64) {
        if units <= 0.0 || seconds <= 0.0 {
            return;
        }
        let threshold = if enough(name).is_finite() {
            enough(name)
        } else {
            20.0
        };
        let tally = self.tallies.entry(name.to_string()).or_default();
        if tally.units > 10.0 * threshold {
            tally.seconds /= 2.0;
            tally.units /= 2.0;
        }
        tally.seconds += seconds;
        tally.units += units;
    }

    pub fn costs(&self) -> Costs {
        let mut costs = Costs::default();
        let pace = self.pace().unwrap_or(1.0).clamp(0.02, 50.0);
        for name in FIELDS {
            let Some(cost) = costs.get_mut(name) else {
                continue;
            };
            match self.tallies.get(name) {
                Some(tally) if tally.units >= enough(name) => *cost = tally.seconds / tally.units,
                _ => *cost *= pace,
            }
        }
        costs
    }

    pub fn pace(&self) -> Option<f64> {
        let mut expected = Costs::default();
        let (mut sum, mut weights) = (0.0, 0.0);
        for name in FIELDS {
            let Some(tally) = self.tallies.get(name) else {
                continue;
            };
            let cost = expected.get_mut(name).map_or(0.0, |c| *c);
            if tally.units >= enough(name) && tally.seconds > 0.0 && cost > 0.0 {
                sum += tally.seconds * (tally.seconds / tally.units / cost).ln();
                weights += tally.seconds;
            }
        }
        (weights > 0.0).then(|| (sum / weights).exp())
    }

    pub fn is_unmeasured(&self) -> bool {
        self.tallies.is_empty()
    }

    pub fn file(folder: &Path) -> PathBuf {
        folder.join("costs.json")
    }

    pub fn load(folder: &Path) -> Self {
        std::fs::read(Self::file(folder))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    pub fn merge(new: &MeasuredCosts, folder: &Path) {
        let mut saved = Self::load(folder);
        for (name, tally) in &new.tallies {
            saved.add(name, tally.units, tally.seconds);
        }
        match serde_json::to_vec_pretty(&saved) {
            Ok(json) => {
                let _ = crate::library::write_atomic(&Self::file(folder), &json);
            }
            Err(err) => log::debug!("file search: costs not saved: {err}"),
        }
    }
}

pub mod index_size {
    pub const PICTURE: f64 = 2_700.0;
    pub const SCREENSHOT: f64 = 6_700.0;
    pub const PDF_PAGE: f64 = 7_700.0;
    pub const DOC_CHUNK: f64 = 8_700.0;
    pub const SOUND_WINDOW: f64 = 2_000.0;
    pub const VIDEO_FRAME: f64 = 2_000.0;
    pub const FRAMES_PER_VIDEO: f64 = 1_200.0;
}

pub trait Measures {
    fn pages(&self, path: &str) -> usize;
    fn duration(&self, path: &str) -> f64;
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct FolderEstimate {
    pub files: usize,
    pub pictures: usize,
    pub documents: usize,
    pub recordings: usize,
    pub playing_seconds: f64,
    pub seconds: f64,
    pub later_seconds: f64,
    pub index_bytes: f64,
    pub download_bytes: u64,
    pub unreadable: Vec<String>,
    pub rough: bool,
}

impl FolderEstimate {
    pub fn of(
        candidates: &[Candidate],
        options: &IndexOptions,
        costs: &Costs,
        measures: &dyn Measures,
    ) -> Self {
        let mut estimate = Self::default();
        for file in candidates {
            estimate.files += 1;
            match file.kind {
                FileKind::Image => {
                    estimate.pictures += 1;
                    estimate.seconds += costs.image;
                    estimate.index_bytes += index_size::PICTURE;
                }
                FileKind::Screenshot => {
                    estimate.pictures += 1;
                    estimate.seconds += costs.screenshot;
                    estimate.index_bytes += index_size::SCREENSHOT;
                }
                FileKind::Pdf => {
                    estimate.documents += 1;
                    let total = measures.pages(&file.path);
                    let all = total.min(options.max_pages);
                    let first = if total > options.big_pdf_pages {
                        options.pdf_step.min(all)
                    } else {
                        all
                    };
                    estimate.seconds += first as f64 * costs.pdf_page;
                    if all > first {
                        estimate.later_seconds += (all - first) as f64 * costs.pdf_page;
                    }
                    estimate.index_bytes += all as f64 * index_size::PDF_PAGE;
                }
                FileKind::Doc => {
                    estimate.documents += 1;
                    let all = ((file.size / 2000) as usize).clamp(1, options.max_chunks);
                    let first = all.min(options.doc_step);
                    estimate.seconds += first as f64 * costs.doc_chunk;
                    if all > first {
                        estimate.later_seconds += (all - first) as f64 * costs.doc_chunk;
                    }
                    estimate.index_bytes += all as f64 * index_size::DOC_CHUNK;
                }
                FileKind::Audio => {
                    estimate.recordings += 1;
                    let seconds = measures.duration(&file.path);
                    estimate.playing_seconds += seconds;
                    estimate.seconds += seconds * costs.audio_second;
                    estimate.index_bytes += sound_bytes(seconds, options);
                }
                FileKind::Video => {
                    estimate.recordings += 1;
                    let seconds = measures.duration(&file.path);
                    estimate.playing_seconds += seconds;
                    estimate.seconds += seconds * costs.video_second;
                    estimate.index_bytes += (seconds / options.frame_interval)
                        .min(index_size::FRAMES_PER_VIDEO)
                        * index_size::VIDEO_FRAME
                        + sound_bytes(seconds, options);
                }
                FileKind::Code => {}
            }
        }
        estimate
    }
}

fn sound_bytes(seconds: f64, options: &IndexOptions) -> f64 {
    (seconds / options.audio_hop).ceil() * index_size::SOUND_WINDOW
}

pub fn estimate_duration(seconds: f64) -> (u64, u64) {
    let rounded = if seconds < 3600.0 {
        (seconds / 60.0).round().max(1.0) * 60.0
    } else {
        (seconds / 600.0).round() * 600.0
    };
    let minutes = (rounded / 60.0).round() as u64;
    (minutes / 60, minutes % 60)
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixed;
    impl Measures for Fixed {
        fn pages(&self, _: &str) -> usize {
            100
        }
        fn duration(&self, _: &str) -> f64 {
            250.0
        }
    }

    fn file(kind: FileKind, size: i64) -> Candidate {
        Candidate {
            path: "x".into(),
            kind,
            size,
            mtime: 0.0,
            inode: 0,
            device: 0,
        }
    }

    #[test]
    fn estimates_read_long_files_in_two_parts() {
        let options = IndexOptions::default();
        let estimate = FolderEstimate::of(
            &[
                file(FileKind::Image, 1),
                file(FileKind::Screenshot, 1),
                file(FileKind::Pdf, 1),
                file(FileKind::Doc, 200_000),
                file(FileKind::Audio, 1),
                file(FileKind::Video, 1),
            ],
            &options,
            &Costs::default(),
            &Fixed,
        );
        assert_eq!(estimate.files, 6);
        assert_eq!(estimate.pictures, 2);
        assert_eq!(estimate.documents, 2);
        assert_eq!(estimate.recordings, 2);
        assert_eq!(estimate.playing_seconds, 500.0);
        let first = 0.12 + 0.32 + 30.0 * 0.09 + 40.0 * 0.045 + 250.0 * 0.0089 + 250.0 * 0.019;
        assert!((estimate.seconds - first).abs() < 1e-9);
        assert!((estimate.later_seconds - (70.0 * 0.09 + 60.0 * 0.045)).abs() < 1e-9);
        let room = 2_700.0
            + 6_700.0
            + 100.0 * 7_700.0
            + 100.0 * 8_700.0
            + 10.0 * 2_000.0
            + (250.0 / 3.0) * 2_000.0
            + 10.0 * 2_000.0;
        assert!((estimate.index_bytes - room).abs() < 1.0);
    }

    #[test]
    fn measured_costs_take_over_with_enough_of_them() {
        let mut measured = MeasuredCosts::default();
        assert!(measured.is_unmeasured());
        assert_eq!(measured.costs(), Costs::default());
        measured.add("image", 10.0, 10.0);
        assert_eq!(measured.pace(), None, "not enough yet");
        measured.add("image", 10.0, 10.0);
        assert!((measured.costs().image - 1.0).abs() < 1e-9);
        let pace = measured.pace().unwrap();
        assert!((pace - 1.0 / 0.12).abs() < 1e-6);
        assert!((measured.costs().doc_chunk - 0.045 * pace).abs() < 1e-9);
        measured.add("image", 200.0, 200.0);
        measured.add("image", 1.0, 1.0);
        assert!(measured.tallies["image"].units < 200.0);
    }

    #[test]
    fn saving_keeps_the_macs_speed() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            MeasuredCosts::file(dir.path()),
            r#"{"speed":{"embedding":1.5,"ocr":2},"tallies":{"image":{"seconds":3,"units":4}}}"#,
        )
        .unwrap();
        let mut new = MeasuredCosts::default();
        new.add("image", 2.0, 1.0);
        MeasuredCosts::merge(&new, dir.path());
        let saved = MeasuredCosts::load(dir.path());
        assert_eq!(
            saved.tallies["image"],
            Tally {
                seconds: 4.0,
                units: 6.0
            }
        );
        assert_eq!(saved.speed.unwrap()["embedding"], 1.5);
    }

    #[test]
    fn durations_round_to_what_an_estimate_deserves() {
        assert_eq!(estimate_duration(30.0), (0, 1));
        assert_eq!(estimate_duration(1500.0), (0, 25));
        assert_eq!(estimate_duration(3700.0), (1, 0));
        assert_eq!(estimate_duration(7800.0), (2, 10));
    }
}
