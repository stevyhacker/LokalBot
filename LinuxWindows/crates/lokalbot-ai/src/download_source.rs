//! Routes pinned Hugging Face file downloads through the source chosen in
//! Settings → Models (`ModelDownloadSource`, `ModelDownloadRouting`).
//!
//! huggingface.co is blocked in mainland China, so two opt-in sources serve the
//! same files there. Only `https://huggingface.co/<owner>/<repo>/resolve/<revision>/<path>`
//! URLs are rerouted; GitHub archives, the Hugging Face API and every other host
//! are untouched, and catalogs keep their Hugging Face URLs, so the pinning
//! policy still applies to them. The chosen mirror is tried first and each later
//! source is a fallback. Every file is checked against its pinned size and
//! SHA-256, so a source can make a download fail but cannot change a model.

use std::collections::HashMap;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicU8, Ordering};
use std::time::Duration;

use anyhow::{Result, anyhow};
use lokalbot_core::settings::ModelDownloadSource;
use parking_lot::Mutex;
use serde::Deserialize;

use crate::error::check_cancelled;

const HF_MIRROR_ORIGIN: &str = "https://hf-mirror.com";
const MODEL_SCOPE_ORIGIN: &str = "https://www.modelscope.cn";
const HUGGING_FACE_PREFIX: &str = "https://huggingface.co/";

static SOURCE: AtomicU8 = AtomicU8::new(0);

/// The source chosen in settings; the engine passes every change here.
pub fn set_source(source: ModelDownloadSource) {
    SOURCE.store(
        match source {
            ModelDownloadSource::HuggingFace => 0,
            ModelDownloadSource::HfMirror => 1,
            ModelDownloadSource::ModelScope => 2,
        },
        Ordering::Relaxed,
    );
}

pub(crate) fn current() -> ModelDownloadSource {
    match SOURCE.load(Ordering::Relaxed) {
        1 => ModelDownloadSource::HfMirror,
        2 => ModelDownloadSource::ModelScope,
        _ => ModelDownloadSource::HuggingFace,
    }
}

/// A Hugging Face `resolve` URL split into its parts. `path` stays
/// percent-encoded, as it appears in the URL.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ResolvedFile {
    repository: String,
    path: String,
}

fn resolved_file(url: &str) -> Option<ResolvedFile> {
    let (scheme, rest) = url.split_once("://")?;
    if !scheme.eq_ignore_ascii_case("https") {
        return None;
    }
    let rest = rest.split(['?', '#']).next()?;
    let mut parts = rest.split('/').filter(|part| !part.is_empty());
    if !parts.next()?.eq_ignore_ascii_case("huggingface.co") {
        return None;
    }
    let owner = parts.next()?;
    let repo = parts.next()?;
    if parts.next()? != "resolve" {
        return None;
    }
    let _revision = parts.next()?;
    let path = parts.collect::<Vec<_>>().join("/");
    (!path.is_empty()).then(|| ResolvedFile {
        repository: format!("{owner}/{repo}"),
        path,
    })
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Candidate {
    Original(String),
    HfMirror(String),
    ModelScope(String, ResolvedFile),
}

impl Candidate {
    pub(crate) fn url(&self) -> &str {
        match self {
            Self::Original(url) | Self::HfMirror(url) | Self::ModelScope(url, _) => url,
        }
    }

    fn label(&self) -> &'static str {
        match self {
            Self::Original(_) => "Hugging Face",
            Self::HfMirror(_) => "HF-Mirror",
            Self::ModelScope(..) => "ModelScope",
        }
    }
}

/// The sources to try for `url`, in order.
pub(crate) fn candidates(url: &str, source: ModelDownloadSource) -> Vec<Candidate> {
    let original = Candidate::Original(url.to_string());
    if source == ModelDownloadSource::HuggingFace {
        return vec![original];
    }
    let Some(file) = resolved_file(url) else {
        return vec![original];
    };
    let mut result = Vec::new();
    // ModelScope follows branches, not Hugging Face revisions; the listing
    // check in `model_scope_serves` keeps it to files that match the pin.
    if source == ModelDownloadSource::ModelScope {
        result.push(Candidate::ModelScope(
            format!(
                "{MODEL_SCOPE_ORIGIN}/models/{}/resolve/master/{}",
                file.repository, file.path
            ),
            file,
        ));
    }
    if let Some(rest) = url.get(HUGGING_FACE_PREFIX.len()..) {
        let rest = rest.split('#').next().unwrap_or(rest);
        result.push(Candidate::HfMirror(format!("{HF_MIRROR_ORIGIN}/{rest}")));
    }
    result.push(original);
    result
}

/// One file in a ModelScope repository listing.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub(crate) struct ModelScopeFile {
    #[serde(rename = "Path")]
    path: String,
    #[serde(rename = "Size")]
    size: Option<u64>,
    #[serde(rename = "Sha256")]
    sha256: Option<String>,
}

pub(crate) type Listing = HashMap<String, ModelScopeFile>;

fn percent_decoded(path: &str) -> String {
    let bytes = path.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let hex = (bytes[i] == b'%')
            .then(|| path.get(i + 1..i + 3))
            .flatten()
            .and_then(|digits| u8::from_str_radix(digits, 16).ok());
        if let Some(byte) = hex {
            out.push(byte);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).unwrap_or_else(|_| path.to_string())
}

/// Whether ModelScope serves exactly the pinned file: its listing has the same
/// path with the pinned SHA-256 (and size, when known).
fn model_scope_serves(file: &ResolvedFile, sha256: &str, size: u64, listing: &Listing) -> bool {
    let Some(entry) = listing.get(&percent_decoded(&file.path)) else {
        return false;
    };
    if entry.size.is_some_and(|listed| listed != size) {
        return false;
    }
    entry
        .sha256
        .as_deref()
        .is_some_and(|listed| listed.eq_ignore_ascii_case(sha256))
}

/// Tries each source in turn. `attempt` downloads one URL and checks it against
/// the pin, so a file that fails moves on to the next source. Cancelling stops.
pub(crate) fn try_candidates(
    url: &str,
    sha256: &str,
    size: u64,
    source: ModelDownloadSource,
    cancel: &std::sync::atomic::AtomicBool,
    listing: &mut dyn FnMut(&str) -> Option<Listing>,
    attempt: &mut dyn FnMut(&str) -> Result<()>,
) -> Result<()> {
    let mut first_error: Option<anyhow::Error> = None;
    for candidate in candidates(url, source) {
        check_cancelled(cancel)?;
        if let Candidate::ModelScope(_, file) = &candidate {
            let serves = listing(&file.repository)
                .is_some_and(|files| model_scope_serves(file, sha256, size, &files));
            if !serves {
                continue;
            }
        }
        match attempt(candidate.url()) {
            Ok(()) => {
                if !matches!(candidate, Candidate::Original(_)) {
                    log::info!(
                        "model download from {} matched its pin: {}",
                        candidate.label(),
                        candidate.url().rsplit('/').next().unwrap_or_default()
                    );
                }
                return Ok(());
            }
            Err(error) if crate::error::is_cancelled(&error) => return Err(error),
            Err(error) => {
                log::warn!(
                    "model download from {} failed: {error:#}",
                    candidate.label()
                );
                first_error.get_or_insert(error);
            }
        }
    }
    Err(first_error.unwrap_or_else(|| anyhow!("No download source has this file.")))
}

#[derive(Deserialize)]
struct ListingReply {
    #[serde(rename = "Data")]
    data: ListingData,
}

#[derive(Deserialize)]
struct ListingData {
    #[serde(rename = "Files")]
    files: Vec<ModelScopeFile>,
}

/// A ModelScope repository's files by path, fetched once per repository per
/// launch. A failed fetch isn't cached, so a later download can try again.
pub(crate) fn model_scope_listing(repository: &str) -> Option<Listing> {
    static CACHE: OnceLock<Mutex<HashMap<String, Listing>>> = OnceLock::new();
    let cache = CACHE.get_or_init(Default::default);
    if let Some(cached) = cache.lock().get(repository) {
        return Some(cached.clone());
    }
    let url = format!(
        "{MODEL_SCOPE_ORIGIN}/api/v1/models/{repository}/repo/files?Revision=master&Recursive=true"
    );
    let agent = crate::http::agent(&url, Duration::from_secs(15));
    let reply = crate::http::get(&agent, &url, None).ok()?;
    if reply.status != 200 {
        return None;
    }
    let listing = parse_listing(&reply.body)?;
    cache.lock().insert(repository.to_string(), listing.clone());
    Some(listing)
}

fn parse_listing(body: &[u8]) -> Option<Listing> {
    let reply: ListingReply = serde_json::from_slice(body).ok()?;
    let mut files = Listing::new();
    for file in reply.data.files {
        files.entry(file.path.clone()).or_insert(file);
    }
    Some(files)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicBool;

    const URL: &str = "https://huggingface.co/owner/repo/resolve/0123456789abcdef0123456789abcdef01234567/sub/My%20File.gguf";
    const SHA: &str = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abcd";

    #[test]
    fn only_hugging_face_files_are_rerouted() {
        for source in [
            ModelDownloadSource::HfMirror,
            ModelDownloadSource::ModelScope,
        ] {
            for url in [
                "https://github.com/k2-fsa/sherpa-onnx/releases/download/x/y.tar.bz2",
                "https://huggingface.co/api/models/owner/repo",
                "http://huggingface.co/owner/repo/resolve/main/file",
                "https://huggingface.co.evil.example/owner/repo/resolve/main/file",
            ] {
                assert_eq!(
                    candidates(url, source),
                    vec![Candidate::Original(url.to_string())],
                    "{url}"
                );
            }
        }
        assert_eq!(
            candidates(URL, ModelDownloadSource::HuggingFace),
            vec![Candidate::Original(URL.to_string())]
        );
    }

    #[test]
    fn sources_come_in_the_macs_order() {
        let mirror = "https://hf-mirror.com/owner/repo/resolve/0123456789abcdef0123456789abcdef01234567/sub/My%20File.gguf";
        let urls = |source| {
            candidates(URL, source)
                .iter()
                .map(|c| c.url().to_string())
                .collect::<Vec<_>>()
        };
        assert_eq!(urls(ModelDownloadSource::HfMirror), [mirror, URL]);
        assert_eq!(
            urls(ModelDownloadSource::ModelScope),
            [
                "https://www.modelscope.cn/models/owner/repo/resolve/master/sub/My%20File.gguf",
                mirror,
                URL
            ]
        );
    }

    fn listing(path: &str, size: Option<u64>, sha: Option<&str>) -> Listing {
        Listing::from([(
            path.to_string(),
            ModelScopeFile {
                path: path.to_string(),
                size,
                sha256: sha.map(str::to_string),
            },
        )])
    }

    #[test]
    fn model_scope_needs_a_matching_listing() {
        let file = resolved_file(URL).unwrap();
        assert_eq!(file.repository, "owner/repo");
        let path = "sub/My File.gguf";
        assert!(model_scope_serves(
            &file,
            SHA,
            7,
            &listing(path, Some(7), Some(&SHA.to_uppercase()))
        ));
        assert!(model_scope_serves(
            &file,
            SHA,
            7,
            &listing(path, None, Some(SHA))
        ));
        assert!(!model_scope_serves(
            &file,
            SHA,
            7,
            &listing(path, Some(8), Some(SHA))
        ));
        assert!(!model_scope_serves(
            &file,
            SHA,
            7,
            &listing(path, Some(7), Some("ff"))
        ));
        assert!(!model_scope_serves(
            &file,
            SHA,
            7,
            &listing(path, Some(7), None)
        ));
        assert!(!model_scope_serves(
            &file,
            SHA,
            7,
            &listing("other", Some(7), Some(SHA))
        ));
    }

    #[test]
    fn a_failed_source_falls_back_and_cancelling_stops() {
        let cancel = AtomicBool::new(false);
        let mut tried = Vec::new();
        try_candidates(
            URL,
            SHA,
            7,
            ModelDownloadSource::ModelScope,
            &cancel,
            // No listing, so ModelScope is skipped without a request.
            &mut |_| None,
            &mut |url| {
                tried.push(url.to_string());
                if url.contains("hf-mirror") {
                    Err(anyhow!("blocked"))
                } else {
                    Ok(())
                }
            },
        )
        .unwrap();
        assert_eq!(tried.len(), 2);
        assert!(tried[0].contains("hf-mirror.com"));
        assert_eq!(tried[1], URL);

        let mut tried = 0;
        let error = try_candidates(
            URL,
            SHA,
            7,
            ModelDownloadSource::HfMirror,
            &cancel,
            &mut |_| None,
            &mut |_| {
                tried += 1;
                Err(crate::AiError::Cancelled.into())
            },
        )
        .unwrap_err();
        assert!(crate::error::is_cancelled(&error));
        assert_eq!(tried, 1);

        let error = try_candidates(
            URL,
            SHA,
            7,
            ModelDownloadSource::HfMirror,
            &cancel,
            &mut |_| None,
            &mut |url| {
                if url.contains("hf-mirror") {
                    Err(anyhow!("first"))
                } else {
                    Err(anyhow!("second"))
                }
            },
        )
        .unwrap_err();
        assert_eq!(error.to_string(), "first");
    }

    #[test]
    fn a_model_scope_listing_decodes() {
        let body = br#"{"Code":200,"Data":{"Files":[{"Path":"a.gguf","Size":7,"Sha256":"AB","Name":"a.gguf"},{"Path":"dir","Type":"tree"}]}}"#;
        let files = parse_listing(body).unwrap();
        assert_eq!(files["a.gguf"].size, Some(7));
        assert_eq!(files["a.gguf"].sha256.as_deref(), Some("AB"));
        assert_eq!(files["dir"].sha256, None);
        assert_eq!(parse_listing(b"{}"), None);
    }
}
