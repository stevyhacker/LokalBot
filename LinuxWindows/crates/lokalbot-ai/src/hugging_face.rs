//! Browse Hugging Face (`HuggingFaceAPIClient`, `HuggingFaceSearchService`):
//! search GGUF repositories, then list one repository's `.gguf` files with the
//! immutable commit and LFS digest a download needs.

use std::cmp::Ordering;
use std::time::Duration;

use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);
pub const RESULT_LIMIT: usize = 20;

#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum ApiError {
    #[error("Couldn't build the HuggingFace request URL.")]
    InvalidUrl,
    #[error("HuggingFace is rate-limiting requests — wait a moment and try again.")]
    RateLimited,
    #[error("HuggingFace returned an unexpected response (HTTP {0}).")]
    Http(u16),
    #[error("Couldn't read HuggingFace's response.")]
    Decoding,
    #[error("{0}")]
    Transport(String),
}

/// One repository from the search, most downloaded first.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct ModelSummary {
    pub id: String,
    #[serde(default)]
    pub downloads: u64,
    #[serde(default)]
    pub likes: u64,
}

/// One downloadable `.gguf` file inside a repository.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HfFile {
    /// Repo-relative path, such as `gguf/model-Q4_K_M.gguf`.
    pub id: String,
    /// `owner/repo`.
    pub model_id: String,
    pub size_bytes: Option<u64>,
    /// The repository's commit.
    pub revision: String,
    pub sha256: Option<String>,
}

impl HfFile {
    /// The `resolve` URL, percent-encoded, with the digest in its fragment the
    /// way the Mac stores it.
    pub fn download_url(&self) -> String {
        let path: Vec<String> = self.id.split('/').map(encoded).collect();
        let mut url = format!(
            "https://huggingface.co/{}/resolve/{}/{}",
            self.model_id,
            self.revision,
            path.join("/")
        );
        if let Some(sha256) = &self.sha256 {
            url.push_str("#sha256=");
            url.push_str(sha256);
        }
        url
    }

    /// Repos sometimes nest files, and downloads land flat under `models/`.
    pub fn file_name(&self) -> String {
        let leaf: String = self
            .id
            .rsplit('/')
            .next()
            .unwrap_or(&self.id)
            .chars()
            .map(|c| {
                if c.is_alphanumeric() || "-_.".contains(c) {
                    c
                } else {
                    '_'
                }
            })
            .collect();
        let digest = Sha256::digest(format!("{}/{}", self.model_id, self.id).as_bytes());
        let tail: Vec<char> = leaf.chars().collect();
        let tail: String = tail[tail.len().saturating_sub(180)..].iter().collect();
        format!("hf-{}-{tail}", hex::encode(&digest[..6]))
    }

    /// The `customBuiltInModels` record both apps read (`ModelCatalog.Entry`).
    pub fn catalog_record(&self) -> Value {
        let mut record = json!({
            "id": format!("hf:{}/{}", self.model_id, self.id),
            "displayName": self.file_name(),
            "fileName": self.file_name(),
            "url": self.download_url(),
            "sizeGB": self.size_bytes.map_or(0.0, |size| size as f64 / 1_000_000_000.0),
            "blurb": format!("Downloaded from {}.", self.model_id),
            "disablesThinking": false,
        });
        if let Some(sha256) = &self.sha256 {
            record["sha256"] = json!(sha256);
        }
        if let Some(size) = self.size_bytes {
            record["sizeBytes"] = json!(size);
        }
        record
    }
}

fn encoded(segment: &str) -> String {
    let mut out = String::with_capacity(segment.len());
    for byte in segment.bytes() {
        if byte.is_ascii_alphanumeric() || b"-._~".contains(&byte) {
            out.push(byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

fn fetch(url: &str) -> Result<Vec<u8>, ApiError> {
    let agent = crate::http::agent(url, REQUEST_TIMEOUT);
    let reply = crate::http::get(&agent, url, None)
        .map_err(|error| ApiError::Transport(format!("{error:#}")))?;
    match reply.status {
        429 => Err(ApiError::RateLimited),
        200..=299 => Ok(reply.body),
        status => Err(ApiError::Http(status)),
    }
}

/// `direction=-1` is required: `sort=downloads` alone returns least popular first.
pub fn search_url(query: &str, limit: usize) -> String {
    format!(
        "https://huggingface.co/api/models?search={}&filter=gguf&sort=downloads&direction=-1&limit={}",
        crate::http::form_escaped(query),
        limit.max(1)
    )
}

/// Matching GGUF repositories, most downloaded first.
pub fn search_models(query: &str) -> Result<Vec<ModelSummary>, ApiError> {
    let query = query.trim();
    if query.is_empty() {
        return Ok(Vec::new());
    }
    let body = fetch(&search_url(query, RESULT_LIMIT))?;
    serde_json::from_slice(&body).map_err(|_| ApiError::Decoding)
}

/// A repository's `.gguf` files in natural filename order, so quantization
/// variants group sensibly.
pub fn files(model_id: &str) -> Result<Vec<HfFile>, ApiError> {
    if !valid_model_id(model_id) {
        return Err(ApiError::InvalidUrl);
    }
    let body = fetch(&format!(
        "https://huggingface.co/api/models/{model_id}?blobs=true"
    ))?;
    parse_files(model_id, &body)
}

#[derive(Deserialize)]
struct ModelRecord {
    sha: Option<String>,
    siblings: Vec<Sibling>,
}

#[derive(Deserialize)]
struct Sibling {
    rfilename: String,
    size: Option<u64>,
    lfs: Option<Lfs>,
}

#[derive(Deserialize)]
struct Lfs {
    sha256: Option<String>,
    oid: Option<String>,
    size: Option<u64>,
}

fn parse_files(model_id: &str, body: &[u8]) -> Result<Vec<HfFile>, ApiError> {
    let record: ModelRecord = serde_json::from_slice(body).map_err(|_| ApiError::Decoding)?;
    let revision = record.sha.unwrap_or_else(|| "main".to_string());
    let mut files: Vec<HfFile> = record
        .siblings
        .into_iter()
        .filter(|sibling| sibling.rfilename.to_lowercase().ends_with(".gguf"))
        .map(|sibling| {
            let lfs = sibling.lfs.as_ref();
            HfFile {
                model_id: model_id.to_string(),
                size_bytes: lfs.and_then(|l| l.size).or(sibling.size),
                revision: revision.clone(),
                sha256: normalized_sha256(
                    lfs.and_then(|l| l.sha256.as_deref().or(l.oid.as_deref())),
                ),
                id: sibling.rfilename,
            }
        })
        .collect();
    files.sort_by(|a, b| natural_order(&a.id, &b.id));
    Ok(files)
}

fn valid_model_id(id: &str) -> bool {
    let parts: Vec<&str> = id.split('/').collect();
    parts.len() == 2
        && parts.iter().all(|part| {
            !part.is_empty()
                && *part != "."
                && *part != ".."
                && part
                    .chars()
                    .all(|c| c.is_alphanumeric() || "-_.".contains(c))
        })
}

fn normalized_sha256(oid: Option<&str>) -> Option<String> {
    let oid = oid?.to_lowercase();
    let oid = oid.strip_prefix("sha256:").unwrap_or(&oid);
    (oid.len() == 64 && oid.chars().all(|c| c.is_ascii_hexdigit())).then(|| oid.to_string())
}

/// `localizedStandardCompare`: ignores case, and digit runs compare as numbers.
fn natural_order(a: &str, b: &str) -> Ordering {
    let (mut a, mut b) = (a.chars().peekable(), b.chars().peekable());
    loop {
        match (a.peek().copied(), b.peek().copied()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(x), Some(y)) if x.is_ascii_digit() && y.is_ascii_digit() => {
                let number = |chars: &mut std::iter::Peekable<std::str::Chars>| {
                    let mut value = String::new();
                    while let Some(digit) = chars.peek().filter(|c| c.is_ascii_digit()) {
                        value.push(*digit);
                        chars.next();
                    }
                    value.trim_start_matches('0').to_string()
                };
                let (left, right) = (number(&mut a), number(&mut b));
                let order = left.len().cmp(&right.len()).then(left.cmp(&right));
                if order != Ordering::Equal {
                    return order;
                }
            }
            (Some(x), Some(y)) => {
                let order = x.to_lowercase().cmp(y.to_lowercase());
                if order != Ordering::Equal {
                    return order;
                }
                a.next();
                b.next();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DIGEST: &str = "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899";

    fn file() -> HfFile {
        HfFile {
            id: "gguf/My Model-Q4.gguf".to_string(),
            model_id: "owner/repo".to_string(),
            size_bytes: Some(2_500_000_000),
            revision: "0123456789abcdef0123456789abcdef01234567".to_string(),
            sha256: Some(DIGEST.to_string()),
        }
    }

    #[test]
    fn the_search_asks_for_popular_gguf_repositories() {
        assert_eq!(
            search_url("qwen 3", 20),
            "https://huggingface.co/api/models?search=qwen%203&filter=gguf&sort=downloads&direction=-1&limit=20"
        );
        let found: Vec<ModelSummary> =
            serde_json::from_str(r#"[{"id":"a/b","downloads":5},{"id":"c/d","likes":2}]"#).unwrap();
        assert_eq!(found[0].downloads, 5);
        assert_eq!(found[0].likes, 0);
        assert_eq!(found[1].likes, 2);
    }

    #[test]
    fn files_carry_the_commit_and_digest() {
        let body = format!(
            r#"{{"sha":"abc","siblings":[
                {{"rfilename":"README.md"}},
                {{"rfilename":"m-Q10.gguf","lfs":{{"oid":"{DIGEST}","size":9}}}},
                {{"rfilename":"m-q2.GGUF","size":4,"lfs":{{"sha256":"sha256:{DIGEST}"}}}},
                {{"rfilename":"small.gguf","size":3,"lfs":{{"oid":"tooshort"}}}}
            ]}}"#
        );
        let files = parse_files("owner/repo", body.as_bytes()).unwrap();
        let names: Vec<&str> = files.iter().map(|f| f.id.as_str()).collect();
        assert_eq!(names, ["m-q2.GGUF", "m-Q10.gguf", "small.gguf"]);
        assert_eq!(files[0].size_bytes, Some(4));
        assert_eq!(files[1].size_bytes, Some(9));
        assert_eq!(files[0].sha256.as_deref(), Some(DIGEST));
        assert_eq!(files[2].sha256, None);
        assert_eq!(files[1].revision, "abc");
        assert_eq!(parse_files("owner/repo", b"{}"), Err(ApiError::Decoding));
    }

    #[test]
    fn ids_cant_leave_the_models_api() {
        assert!(valid_model_id("unsloth/Qwen3.5-0.8B-GGUF"));
        for id in ["a", "a/b/c", "../b", "a/..", "a/b?x", "a/", "/b"] {
            assert!(!valid_model_id(id), "{id}");
        }
        assert_eq!(files("../secrets"), Err(ApiError::InvalidUrl));
    }

    /// Needs the network: `cargo test -p lokalbot-ai hugging_face -- --ignored`.
    #[test]
    #[ignore]
    fn the_live_api_lists_pinned_files() {
        let found = search_models("qwen").unwrap();
        assert!(!found.is_empty());
        assert!(found.len() <= RESULT_LIMIT);
        let listed = found
            .iter()
            .take(5)
            .flat_map(|model| files(&model.id).unwrap())
            .next()
            .unwrap();
        assert_eq!(listed.revision.len(), 40);
        assert!(listed.sha256.is_some());
        assert!(listed.size_bytes.is_some());
        assert_eq!(
            crate::download::source_refusal(
                listed.download_url().split('#').next().unwrap(),
                listed.sha256.as_deref().unwrap(),
                false,
            ),
            None
        );
    }

    #[test]
    fn the_record_matches_the_macs_entry() {
        let record = file().catalog_record();
        assert_eq!(record["id"], "hf:owner/repo/gguf/My Model-Q4.gguf");
        assert_eq!(
            record["url"],
            format!(
                "https://huggingface.co/owner/repo/resolve/0123456789abcdef0123456789abcdef01234567/gguf/My%20Model-Q4.gguf#sha256={DIGEST}"
            )
        );
        let name = record["fileName"].as_str().unwrap();
        assert!(name.starts_with("hf-"));
        assert!(name.ends_with("-My_Model-Q4.gguf"));
        assert_eq!(record["displayName"], record["fileName"]);
        assert_eq!(record["sha256"], DIGEST);
        assert_eq!(record["sizeBytes"], 2_500_000_000u64);
        assert_eq!(record["sizeGB"], 2.5);
        assert_eq!(record["blurb"], "Downloaded from owner/repo.");
        assert_eq!(record["disablesThinking"], false);
    }
}
