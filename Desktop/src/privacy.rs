use crate::{
    domain::*,
    storage::{Library, atomic_write},
};
use aes_gcm::{
    Aes256Gcm, KeyInit,
    aead::{Aead, OsRng, rand_core::RngCore},
};
use anyhow::{Context, Result, ensure};
use regex::Regex;
use std::{path::Path, sync::OnceLock};

pub fn origin(endpoint: &str) -> Result<String> {
    let url = url::Url::parse(endpoint).context("Invalid inference endpoint")?;
    ensure!(
        url.username().is_empty()
            && url.password().is_none()
            && url.fragment().is_none()
            && url.query().is_none(),
        "Endpoint must not contain credentials, a query, or a fragment"
    );
    let local = match url.host() {
        Some(url::Host::Domain("localhost")) => true,
        Some(url::Host::Ipv4(ip)) => ip.is_loopback(),
        Some(url::Host::Ipv6(ip)) => ip.is_loopback(),
        _ => false,
    };
    ensure!(
        url.scheme() == "https" || (url.scheme() == "http" && local),
        "Remote inference requires HTTPS"
    );
    Ok(url.origin().ascii_serialization())
}
pub fn check_inference(settings: &Settings) -> Result<String> {
    let origin = origin(&settings.endpoint)?;
    let url = url::Url::parse(&settings.endpoint)?;
    let local = match url.host() {
        Some(url::Host::Domain("localhost")) => true,
        Some(url::Host::Ipv4(ip)) => ip.is_loopback(),
        Some(url::Host::Ipv6(ip)) => ip.is_loopback(),
        _ => false,
    };
    if settings.backend == Backend::OpenRouter {
        ensure!(
            origin == "https://openrouter.ai",
            "OpenRouter uses the fixed https://openrouter.ai origin"
        );
    }
    ensure!(
        local || settings.approved_origins.contains(&origin),
        "Approve the displayed inference origin in Settings before sending context"
    );
    Ok(origin)
}
#[derive(Clone)]
pub struct EgressGrant {
    pub revision: u64,
    pub origin: String,
}
impl EgressGrant {
    pub fn acquire(library: &Library) -> Result<Self> {
        let settings = library.settings()?;
        Ok(Self {
            revision: settings.revision,
            origin: check_inference(&settings)?,
        })
    }
    pub fn verify(&self, library: &Library) -> Result<()> {
        let settings = library.settings()?;
        ensure!(
            settings.revision == self.revision && check_inference(&settings)? == self.origin,
            "Settings changed while the request ran; its result was discarded"
        );
        Ok(())
    }
}
pub fn redact(text: &str) -> String {
    static PATTERNS: OnceLock<Vec<Regex>> = OnceLock::new();
    let patterns = PATTERNS.get_or_init(|| {
        [
        r"(?i)\b(?:sk-[a-z0-9_-]{12,}|gh[pousr]_[a-z0-9]{12,}|AKIA[A-Z0-9]{16})\b",
        r"(?i)\b(?:bearer\s+|(?:api[_ -]?key|password|token|secret)\s*[:=]\s*)[a-z0-9_./+\-=]{8,}",
        r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b",
        r"(?i)\b[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}\b",
    ].into_iter().map(|s|Regex::new(s).expect("static redaction expression")).collect()
    });
    let mut result = text.to_owned();
    for pattern in patterns {
        result = pattern.replace_all(&result, "[redacted]").into_owned();
    }
    result
}
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq)]
pub struct Observation {
    pub app: String,
    pub title: String,
    pub window: String,
    pub pid: u32,
    #[serde(default)]
    pub field: Option<String>,
    pub focus_verified: bool,
    pub secure: Option<bool>,
    pub domain: Option<String>,
    pub browser: bool,
}
pub fn excluded(o: &Observation, s: &Settings) -> bool {
    s.excluded_apps
        .iter()
        .any(|app| o.app.to_lowercase().contains(&app.to_lowercase()))
        || (o.browser
            && !s.excluded_domains.is_empty()
            && (o.domain.is_none()
                || s.excluded_domains.iter().any(|domain| {
                    o.domain.as_ref().is_some_and(|d| {
                        d.eq_ignore_ascii_case(domain)
                            || d.to_lowercase()
                                .ends_with(&format!(".{}", domain.to_lowercase()))
                    })
                })))
}
pub fn allow_screen(o: &Observation, s: &Settings) -> bool {
    !s.paused
        && s.screen_text_enabled
        && o.focus_verified
        && o.field.as_ref().is_some_and(|f| !f.is_empty())
        && o.secure == Some(false)
        && !excluded(o, s)
}
pub fn capture_still_valid(
    before: &Observation,
    after: &Observation,
    settings: &Settings,
    revision: u64,
) -> bool {
    before == after && settings.revision == revision && allow_screen(after, settings)
}

fn encryption_key(root: &Path) -> Result<[u8; 32]> {
    let lock_file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(root.join(".screen-key.lock"))?;
    fs2::FileExt::lock_exclusive(&lock_file)?;
    let path = root.join(".screen-key");
    if path.exists() {
        let bytes = std::fs::read(path)?;
        return bytes
            .try_into()
            .map_err(|_| anyhow::anyhow!("Invalid screen encryption key"));
    }
    let mut key = [0u8; 32];
    OsRng.fill_bytes(&mut key);
    atomic_write(&path, &key)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    }
    Ok(key)
}
pub fn encrypt_pixels(root: &Path, pixels: &[u8]) -> Result<Vec<u8>> {
    let cipher = Aes256Gcm::new_from_slice(&encryption_key(root)?)
        .map_err(|_| anyhow::anyhow!("Invalid encryption key"))?;
    let mut nonce = [0; 12];
    OsRng.fill_bytes(&mut nonce);
    let mut output = nonce.to_vec();
    output.extend(
        cipher
            .encrypt((&nonce).into(), pixels)
            .map_err(|_| anyhow::anyhow!("Screen encryption failed"))?,
    );
    Ok(output)
}
pub fn decrypt_pixels(root: &Path, encrypted: &[u8]) -> Result<Vec<u8>> {
    ensure!(encrypted.len() > 12, "Invalid encrypted screen capture");
    let cipher = Aes256Gcm::new_from_slice(&encryption_key(root)?)
        .map_err(|_| anyhow::anyhow!("Invalid encryption key"))?;
    cipher
        .decrypt(encrypted[..12].into(), &encrypted[12..])
        .map_err(|_| anyhow::anyhow!("Screen capture authentication failed"))
}
