//! The GGUF models LokalBot can download (`Engines/ModelCatalog.swift`,
//! `Services/EmbeddingIndex.swift`). Files, revisions, sizes and SHA-256
//! digests are the macOS pins, so a library moved between platforms reuses
//! its `models/` folder.

use std::io::Read as _;
use std::path::{Path, PathBuf};

use lokalbot_core::LibraryPaths;

use crate::download::{self, DownloadSpec};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ModelKind {
    /// Chat/completion models for Think and Autocomplete.
    Text,
    /// The embedder for "Search by meaning".
    Embedding,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ModelEntry {
    pub id: &'static str,
    pub display_name: &'static str,
    /// Hugging Face `owner/repo`.
    pub repo: &'static str,
    /// Immutable 40-hex commit the file is pinned to.
    pub revision: &'static str,
    pub file: &'static str,
    pub quant: &'static str,
    pub size_bytes: u64,
    pub sha256: &'static str,
    pub blurb: &'static str,
    pub kind: ModelKind,
    /// Offered for Think (summaries, Ask, digests).
    pub think: bool,
    /// Offered in the Autocomplete picker (`keystrokeScaleEntries`).
    pub autocomplete: bool,
    pub license: Option<&'static str>,
    /// Sampling the vendor requires, merged last into built-in chat requests
    /// (`MainLLMRuntimePolicy.requestOverrides`).
    pub request_overrides: &'static [(&'static str, f64)],
    /// The model has no thinking-budget control on llama-server.
    pub no_reasoning_control: bool,
}

impl ModelEntry {
    pub fn url(&self) -> String {
        format!(
            "https://huggingface.co/{}/resolve/{}/{}",
            self.repo, self.revision, self.file
        )
    }

    /// Decimal gigabytes, as the pickers show them.
    pub fn size_gb(&self) -> f64 {
        self.size_bytes as f64 / 1e9
    }

    pub fn download_spec(&self, paths: &LibraryPaths) -> DownloadSpec {
        DownloadSpec {
            url: self.url(),
            sha256: self.sha256.to_string(),
            size: self.size_bytes,
            dest: model_path(paths, self),
        }
    }
}

pub const COMPACT_FALLBACK_ID: &str = "qwen3.5-0.8b";
pub const DEFAULT_THINK_ID: &str = "qwen3.5-4b";
pub const RECOMMENDED_SUMMARIZATION_ID: &str = "qwen3.6-35b-a3b";
pub const QUALITY_AUTOCOMPLETE_ID: &str = "gemma4-e2b-base-q6";
pub const LIGHTWEIGHT_AUTOCOMPLETE_ID: &str = "lfm2.5-1.2b-instruct";
pub const EMBEDDING_ID: &str = "embeddinggemma-2-q8";
/// Alias the engine uses.
pub const EMBEDDING_MODEL_ID: &str = EMBEDDING_ID;
/// Persisted with every vector (`EmbeddingIndex.indexVersion`); vectors made
/// under another value are stale.
pub const EMBEDDING_INDEX_VERSION: &str = "embeddinggemma-2-q8-mean-768-v1";
pub const EMBEDDING_DIMENSIONS: usize = 768;

/// Models above this size are too slow for keystroke-latency completion.
const KEYSTROKE_SCALE_MAX_GB: f64 = 7.0;

#[allow(clippy::too_many_arguments)] // a table row constructor
const fn text(
    id: &'static str,
    display_name: &'static str,
    repo: &'static str,
    revision: &'static str,
    file: &'static str,
    quant: &'static str,
    size_bytes: u64,
    sha256: &'static str,
    blurb: &'static str,
    think: bool,
    autocomplete: bool,
) -> ModelEntry {
    ModelEntry {
        id,
        display_name,
        repo,
        revision,
        file,
        quant,
        size_bytes,
        sha256,
        blurb,
        kind: ModelKind::Text,
        think,
        autocomplete,
        license: None,
        request_overrides: &[],
        no_reasoning_control: false,
    }
}

static CATALOG: [ModelEntry; 15] = [
    text(
        COMPACT_FALLBACK_ID,
        "Qwen3.5 0.8B",
        "unsloth/Qwen3.5-0.8B-GGUF",
        "6ab461498e2023f6e3c1baea90a8f0fe38ab64d0",
        "Qwen3.5-0.8B-Q4_K_M.gguf",
        "Q4_K_M",
        532_517_120,
        "bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517",
        "Tiny downloadable fallback for short meetings and autocomplete.",
        true,
        true,
    ),
    ModelEntry {
        license: Some("LFM Open License v1.0"),
        ..text(
            LIGHTWEIGHT_AUTOCOMPLETE_ID,
            "LFM2.5 1.2B Instruct",
            "unsloth/LFM2.5-1.2B-Instruct-GGUF",
            "bf1ebe055f24ddd24f3622d933a63b42606773f3",
            "LFM2.5-1.2B-Instruct-Q4_K_M.gguf",
            "Q4_K_M",
            730_895_584,
            "856aeee6d85ac684b1db8dee48795b44fc06731ecda03aee36ece682413a9b9a",
            "Lightweight, English-first autocomplete alternative. Under 1 GB.",
            true,
            true,
        )
    },
    ModelEntry {
        license: Some("Apache 2.0"),
        ..text(
            QUALITY_AUTOCOMPLETE_ID,
            "Gemma 4 E2B Base (Autocomplete)",
            "mradermacher/gemma-4-E2B-i1-GGUF",
            "a9bf638e53783fc93778f357cc5c672eab5393b1",
            "gemma-4-E2B.i1-Q6_K.gguf",
            "i1-Q6_K",
            3_845_328_608,
            "20f49b221691c71d955e1d5a840b6e26329db4a5e1626f702fa4226e80a9c629",
            "Default autocomplete model for higher-quality suggestions. 16 GB+ RAM.",
            false,
            true,
        )
    },
    text(
        "qwen3.5-2b",
        "Qwen3.5 2B",
        "unsloth/Qwen3.5-2B-GGUF",
        "f6d5376be1edb4d416d56da11e5397a961aca8ae",
        "Qwen3.5-2B-Q4_K_M.gguf",
        "Q4_K_M",
        1_280_835_840,
        "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223",
        "Lightweight multilingual autocomplete option. Any PC.",
        true,
        true,
    ),
    text(
        DEFAULT_THINK_ID,
        "Qwen3.5 4B",
        "unsloth/Qwen3.5-4B-GGUF",
        "e87f176479d0855a907a41277aca2f8ee7a09523",
        "Qwen3.5-4B-Q4_K_M.gguf",
        "Q4_K_M",
        2_740_937_888,
        "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4",
        "Default Think model with balanced local summaries and long context. 16 GB RAM.",
        true,
        true,
    ),
    ModelEntry {
        request_overrides: &[
            ("temperature", 0.1),
            ("top_k", 50.0),
            ("repeat_penalty", 1.1),
        ],
        ..text(
            "lfm2.5-2.6b",
            "LFM2.5 2.6B Reasoning",
            "LiquidAI/LFM2.5-2.6B-GGUF",
            "b22e29ebf6249a8c9fcdda36914743e9980595c4",
            "LFM2.5-2.6B-Q4_K_M.gguf",
            "Q4_K_M",
            1_674_454_848,
            "79fdf00351b46cf26f020aead28d01889886be87c55fa0eb907e6f9b00bfee14",
            "Experimental compact reasoning model for summaries and extraction. 16 GB RAM.",
            true,
            false,
        )
    },
    text(
        "granite-4.1-3b",
        "Granite 4.1 3B (Experimental)",
        "ibm-granite/granite-4.1-3b-GGUF",
        "ab4701481089b58a082ef63cc1cee738887293ff",
        "granite-4.1-3b-Q4_K_M.gguf",
        "Q4_K_M",
        2_099_501_664,
        "662b0626cd58f443baea23559b469df6576a81d349649c59413b36a9fb32eb29",
        "Experimental 3B Think model for summaries, extraction, and JSON. 16 GB RAM.",
        true,
        false,
    ),
    ModelEntry {
        request_overrides: &[("temperature", 0.05)],
        no_reasoning_control: true,
        ..text(
            "ministral-3-3b-instruct-2512",
            "Ministral 3 3B Instruct (Experimental)",
            "mistralai/Ministral-3-3B-Instruct-2512-GGUF",
            "eb599d408350ea2bb60452cb86be7c7b2fc28227",
            "Ministral-3-3B-Instruct-2512-Q4_K_M.gguf",
            "Q4_K_M",
            2_147_023_008,
            "9ed150d4367e68df0ac8e1540f6ddc65b42d0ee26378329d1ecbca60f93fc5f8",
            "Experimental 3B Think model with native JSON and long context. 16 GB RAM.",
            true,
            false,
        )
    },
    text(
        "gemma4-e4b",
        "Gemma 4 E4B (Legacy)",
        "unsloth/gemma-4-E4B-it-GGUF",
        "0720adb23527c2cd5ea01d1db067cd960327fdac",
        "gemma-4-E4B-it-Q4_K_M.gguf",
        "Q4_K_M",
        4_977_169_568,
        "519b9793ed6ce0ff530f1b7c96e848e08e49e7af4d57bb97f76215963a54146d",
        "Legacy edge-optimized option. 16 GB RAM.",
        true,
        false,
    ),
    text(
        "gemma4-e4b-q5-xl",
        "Gemma 4 · E4B",
        "unsloth/gemma-4-E4B-it-GGUF",
        "0720adb23527c2cd5ea01d1db067cd960327fdac",
        "gemma-4-E4B-it-UD-Q5_K_XL.gguf",
        "UD-Q5_K_XL",
        6_656_152_736,
        "5fb55145c335edd0c2e0cdd7505ed1557cd346787449479be65094c6f5b016c6",
        "Higher-capacity autocomplete option (Q5 XL quant). 16 GB+ RAM.",
        true,
        true,
    ),
    text(
        "lfm2.5-8b-a1b",
        "LFM2.5 8B (MoE)",
        "LiquidAI/LFM2.5-8B-A1B-GGUF",
        "dfd5fdcad7a1c0d31473fb4ca443b8befbacddf0",
        "LFM2.5-8B-A1B-Q4_K_M.gguf",
        "Q4_K_M",
        5_155_564_768,
        "4923ec14f06b968b74d663e5949867d2d9c3bf13a20b8be1a9f9af39989b2bb0",
        "Fast meeting summaries; ~1B active. 16 GB RAM.",
        true,
        true,
    ),
    text(
        RECOMMENDED_SUMMARIZATION_ID,
        "Qwen 3.6 · 35B-A3B",
        "unsloth/Qwen3.6-35B-A3B-GGUF",
        "a483e9e6cbd595906af30beda3187c2663a1118c",
        "Qwen3.6-35B-A3B-UD-IQ4_XS.gguf",
        "UD-IQ4_XS",
        17_730_509_792,
        "649d7508507b84638732c4f52c24c8b15843c6dca2f3ff793ae07c14a67ebbb3",
        "Higher-quality long-meeting option; ~3B active. 32 GB+ RAM.",
        true,
        false,
    ),
    text(
        "qwen3.6-27b",
        "Qwen3.6 27B",
        "unsloth/Qwen3.6-27B-GGUF",
        "82d411acf4a06cfb8d9b073a5211bf410bfc29bf",
        "Qwen3.6-27B-Q4_K_M.gguf",
        "Q4_K_M",
        16_817_244_384,
        "5ed60d0af4650a854b1755bd392f9aef4872643dc25a254bc68043fa638392a0",
        "Maximum-quality dense summaries. Best on 32 GB+ RAM.",
        true,
        false,
    ),
    text(
        "gemma4-12b",
        "Gemma 4 12B",
        "unsloth/gemma-4-12B-it-GGUF",
        "d997c805aafe035a8024f961c6e1afd6b30d79a5",
        "gemma-4-12b-it-Q4_K_M.gguf",
        "Q4_K_M",
        7_121_860_000,
        "43fec98c5102b1c446b4ddd0a9439f1db3a2e1f2e0b8cd143ce1ea619a9403d6",
        "Multimodal-family summary option for screenshot and slide workflows.",
        true,
        false,
    ),
    ModelEntry {
        kind: ModelKind::Embedding,
        ..text(
            EMBEDDING_ID,
            "EmbeddingGemma 2",
            "ggml-org/embeddinggemma-2-GGUF",
            "bfcd298762cc34d0357ece5ebdd31791a3a374d8",
            "embeddinggemma-2-Q8_0.gguf",
            "Q8_0",
            309_855_456,
            "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135",
            "Search by meaning across your meetings.",
            false,
            false,
        )
    },
];

/// Every downloadable model, text models roughly smallest first, then the embedder.
pub fn catalog() -> &'static [ModelEntry] {
    &CATALOG
}

pub fn entry(id: &str) -> Option<&'static ModelEntry> {
    CATALOG.iter().find(|e| e.id == id)
}

pub fn embedding_entry() -> &'static ModelEntry {
    entry(EMBEDDING_ID).expect("the embedder is in the catalog")
}

/// Think picker entries (`mainLLMEntries`).
pub fn think_entries() -> impl Iterator<Item = &'static ModelEntry> {
    CATALOG
        .iter()
        .filter(|e| e.kind == ModelKind::Text && e.think)
}

/// Autocomplete picker entries (`keystrokeScaleEntries`): under 7 GB and not
/// an always-reasoning or legacy model. A stored choice stays visible.
pub fn autocomplete_entries(keeping: Option<&str>) -> impl Iterator<Item = &'static ModelEntry> {
    let keeping = keeping.map(str::to_string);
    CATALOG.iter().filter(move |e| {
        e.kind == ModelKind::Text
            && (keeping.as_deref() == Some(e.id)
                || (e.autocomplete && e.size_gb() < KEYSTROKE_SCALE_MAX_GB))
    })
}

/// The pinned download of `entry` into `<root>/models/`.
pub fn download_spec(paths: &LibraryPaths, entry: &ModelEntry) -> DownloadSpec {
    entry.download_spec(paths)
}

/// `<root>/models/<file>`.
pub fn model_path(paths: &LibraryPaths, entry: &ModelEntry) -> PathBuf {
    paths.models_dir().join(entry.file)
}

/// Cheap check for the UI: the exact size and GGUF magic, plus a matching
/// `.sha256` sidecar when one exists. [`verify_downloaded`] hashes a file that
/// has no sidecar yet.
pub fn is_downloaded(paths: &LibraryPaths, entry: &ModelEntry) -> bool {
    let path = model_path(paths, entry);
    if !has_size_and_magic(&path, entry.size_bytes) {
        return false;
    }
    match download::read_sidecar(&path) {
        Some(digest) => digest.eq_ignore_ascii_case(entry.sha256),
        None => true,
    }
}

/// Full integrity check before a model is loaded. A file without a sidecar
/// (copied in by hand, or written by an older build) is hashed once and the
/// sidecar recorded. A file that fails is left in place; the caller decides
/// whether to delete it.
pub fn verify_downloaded(paths: &LibraryPaths, entry: &ModelEntry) -> anyhow::Result<bool> {
    let path = model_path(paths, entry);
    if !has_size_and_magic(&path, entry.size_bytes) {
        return Ok(false);
    }
    if let Some(digest) = download::read_sidecar(&path) {
        return Ok(digest.eq_ignore_ascii_case(entry.sha256));
    }
    let digest = download::sha256_file(&path, None)?;
    if !digest.eq_ignore_ascii_case(entry.sha256) {
        return Ok(false);
    }
    download::write_sidecar(&path, &digest)?;
    Ok(true)
}

/// Removes a downloaded model and its sidecar.
pub fn delete_model(paths: &LibraryPaths, entry: &ModelEntry) -> std::io::Result<()> {
    let path = model_path(paths, entry);
    for file in [path.clone(), download::sidecar_path(&path)] {
        match std::fs::remove_file(&file) {
            Err(err) if err.kind() != std::io::ErrorKind::NotFound => return Err(err),
            _ => {}
        }
    }
    Ok(())
}

fn has_size_and_magic(path: &Path, size: u64) -> bool {
    let Ok(meta) = std::fs::metadata(path) else {
        return false;
    };
    meta.len() == size && looks_like_gguf(path)
}

/// `ModelFileValidator.looksLikeGGUF`: the first four bytes are `GGUF`.
pub fn looks_like_gguf(path: &Path) -> bool {
    let mut magic = [0u8; 4];
    std::fs::File::open(path)
        .and_then(|mut f| f.read_exact(&mut magic))
        .is_ok()
        && &magic == b"GGUF"
}

/// A one-click local setup (`ModelStackPreset`).
#[derive(Clone, Debug, PartialEq)]
pub struct Preset {
    pub id: &'static str,
    pub name: &'static str,
    pub description: &'static str,
    pub think: &'static str,
    pub autocomplete: &'static str,
}

pub const PRESETS: [Preset; 2] = [
    Preset {
        id: "balanced",
        name: "Balanced local",
        description: "Balanced local models for everyday work.",
        think: DEFAULT_THINK_ID,
        autocomplete: QUALITY_AUTOCOMPLETE_ID,
    },
    Preset {
        id: "lightweight",
        name: "Lightweight local",
        description: "Smaller downloads and a lighter memory footprint.",
        think: COMPACT_FALLBACK_ID,
        autocomplete: LIGHTWEIGHT_AUTOCOMPLETE_ID,
    },
];

impl Preset {
    /// Bytes still to download to apply this preset.
    pub fn missing_bytes(&self, paths: &LibraryPaths) -> u64 {
        let mut ids = vec![self.think, self.autocomplete];
        ids.dedup();
        ids.iter()
            .filter_map(|id| entry(id))
            .filter(|e| !is_downloaded(paths, e))
            .map(|e| e.size_bytes)
            .sum()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pins_are_well_formed() {
        for e in catalog() {
            assert_eq!(e.revision.len(), 40, "{}", e.id);
            assert!(
                e.revision.chars().all(|c| c.is_ascii_hexdigit()),
                "{}",
                e.id
            );
            assert_eq!(e.sha256.len(), 64, "{}", e.id);
            assert!(e.url().starts_with("https://huggingface.co/"));
            assert!(e.file.ends_with(".gguf"));
        }
        let ids: std::collections::HashSet<_> = catalog().iter().map(|e| e.id).collect();
        assert_eq!(ids.len(), catalog().len());
    }

    #[test]
    fn presets_and_pickers_follow_macos() {
        assert_eq!(entry("qwen3.5-4b").unwrap().size_bytes, 2_740_937_888);
        assert_eq!(
            embedding_entry().url(),
            "https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/bfcd298762cc34d0357ece5ebdd31791a3a374d8/embeddinggemma-2-Q8_0.gguf"
        );
        for preset in PRESETS {
            assert!(entry(preset.think).unwrap().think);
            assert!(entry(preset.autocomplete).unwrap().autocomplete);
        }
        assert!(!think_entries().any(|e| e.id == QUALITY_AUTOCOMPLETE_ID || e.id == EMBEDDING_ID));
        let autocomplete: Vec<_> = autocomplete_entries(None).map(|e| e.id).collect();
        assert!(autocomplete.contains(&"gemma4-e2b-base-q6"));
        assert!(autocomplete.contains(&"gemma4-e4b-q5-xl"));
        for excluded in [
            "gemma4-e4b",
            "granite-4.1-3b",
            "lfm2.5-2.6b",
            "ministral-3-3b-instruct-2512",
            "gemma4-12b",
        ] {
            assert!(!autocomplete.contains(&excluded), "{excluded}");
        }
        assert!(autocomplete_entries(Some("gemma4-12b")).any(|e| e.id == "gemma4-12b"));
    }

    #[test]
    fn downloaded_status_checks_size_magic_and_sidecar() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LibraryPaths::new(dir.path());
        let entry = ModelEntry {
            size_bytes: 8,
            ..entry(COMPACT_FALLBACK_ID).unwrap().clone()
        };
        let path = model_path(&paths, &entry);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        assert!(!is_downloaded(&paths, &entry));
        std::fs::write(&path, b"GGUFxxxx").unwrap();
        assert!(is_downloaded(&paths, &entry));
        // A sidecar that disagrees with the pinned digest means another file.
        download::write_sidecar(&path, &"0".repeat(64)).unwrap();
        assert!(!is_downloaded(&paths, &entry));
        assert!(!verify_downloaded(&paths, &entry).unwrap());
        std::fs::write(&path, b"NOPExxxx").unwrap();
        assert!(!is_downloaded(&paths, &entry));
        delete_model(&paths, &entry).unwrap();
        assert!(!path.exists());
    }
}
