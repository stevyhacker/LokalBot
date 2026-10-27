//! Consent boundaries shared by the app, engine and CLI.
//!
//! External agents get read access only through marker files under
//! `<root>/control/`, exactly as on macOS (`AgentAccessGate.swift`,
//! `ScreenMemoryAccessGate.swift`). Remote model servers need an approved
//! origin (`RemoteInferenceGate.swift`).

use std::net::IpAddr;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::paths::LibraryPaths;

pub const MEETINGS_MARKER: &str = "agent-access-enabled";
pub const SCREEN_MARKER: &str = "screen-memory-access-enabled";

pub const PERSONAL_MARKER: &str = "personal-context-access-enabled";
pub const PERSONAL_PROJECTION: &str = "personal-context.json";
/// Environment variable carrying an Agent Mode capability token.
pub const CAPABILITY_ENV: &str = "LOKALBOT_AGENT_CAPABILITY";
const CAPABILITY_DIR: &str = "agent-capabilities";
const WAKE_FILE: &str = "agent-wake";
const WAKE_ERROR_FILE: &str = "agent-wake-error";

pub const MEETINGS_DISABLED_MESSAGE: &str = "External agent access is off. Enable it in LokalBot → Settings → Privacy & Data → \"Allow external agents to read your meeting library\".";
pub const SCREEN_DISABLED_MESSAGE: &str = "External screen-memory access is off. Enable it separately in LokalBot → Settings → Privacy & Data → \"Allow external agents to read screen memory\".";

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ScreenScope {
    Today,
    #[default]
    RecentWeek,
    RetainedHistory,
}

impl ScreenScope {
    pub fn label(self) -> &'static str {
        match self {
            ScreenScope::Today => "Today only",
            ScreenScope::RecentWeek => "Last 7 days",
            ScreenScope::RetainedHistory => "All retained history",
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
struct ScreenProfile {
    scope: ScreenScope,
}

pub fn meetings_access_enabled(paths: &LibraryPaths) -> bool {
    paths.control_dir().join(MEETINGS_MARKER).is_file()
}

pub fn set_meetings_access(paths: &LibraryPaths, enabled: bool) -> std::io::Result<()> {
    let marker = paths.control_dir().join(MEETINGS_MARKER);
    if enabled {
        ensure_private_dir(&paths.control_dir())?;
        crate::library::write_atomic(&marker, uuid::Uuid::new_v4().to_string().as_bytes())?;
        restrict_file(&marker);
        Ok(())
    } else {
        remove_if_exists(&marker)
    }
}

/// The grant behind meeting access: the marker's content, or a valid
/// capability token from `LOKALBOT_AGENT_CAPABILITY`. A long read keeps the
/// same grant identity from start to answer (`authorizationID`).
pub fn meetings_authorization(paths: &LibraryPaths, token: Option<&str>) -> Option<String> {
    use sha2::Digest as _;
    if let Ok(marker) = std::fs::read(paths.control_dir().join(MEETINGS_MARKER)) {
        return Some(format!("global:{}", hex::encode(marker)));
    }
    let token = token?;
    validate_capability(paths, token).then(|| {
        format!(
            "capability:{}",
            hex::encode(sha2::Sha256::digest(token.as_bytes()))
        )
    })
}

/// Meeting access for this process (marker or inherited capability).
pub fn meetings_access_authorized(paths: &LibraryPaths) -> bool {
    let token = std::env::var(CAPABILITY_ENV).ok();
    meetings_authorization(paths, token.as_deref()).is_some()
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CapabilityRecord {
    digest: String,
    #[serde(with = "crate::time::swift_date")]
    expires_at: chrono::DateTime<chrono::Utc>,
}

/// Issues a bearer capability (`<uuid>.<64 hex>`) for one embedded agent
/// process; only the secret's SHA-256 is stored.
pub fn issue_agent_capability(
    paths: &LibraryPaths,
    lifetime: chrono::Duration,
) -> std::io::Result<String> {
    use sha2::Digest as _;
    let id = uuid::Uuid::new_v4().hyphenated().to_string();
    let secret = format!(
        "{}{}",
        uuid::Uuid::new_v4().simple(),
        uuid::Uuid::new_v4().simple()
    );
    let record = CapabilityRecord {
        digest: hex::encode(sha2::Sha256::digest(secret.as_bytes())),
        expires_at: chrono::Utc::now() + lifetime.max(chrono::Duration::seconds(60)),
    };
    let dir = paths.control_dir().join(CAPABILITY_DIR);
    ensure_private_dir(&paths.control_dir())?;
    ensure_private_dir(&dir)?;
    let path = dir.join(format!("{id}.json"));
    let bytes = serde_json::to_vec(&record).map_err(std::io::Error::other)?;
    crate::library::write_atomic(&path, &bytes)?;
    restrict_file(&path);
    Ok(format!("{id}.{secret}"))
}

pub fn revoke_agent_capability(paths: &LibraryPaths, token: &str) -> std::io::Result<()> {
    let Some((id, _)) = token.split_once('.') else {
        return Ok(());
    };
    let path = paths
        .control_dir()
        .join(CAPABILITY_DIR)
        .join(format!("{}.json", id.to_lowercase()));
    remove_if_exists(&path)
}

fn validate_capability(paths: &LibraryPaths, token: &str) -> bool {
    use sha2::Digest as _;
    let Some((id, secret)) = token.split_once('.') else {
        return false;
    };
    if uuid::Uuid::parse_str(id).is_err()
        || secret.len() != 64
        || !secret.chars().all(|c| c.is_ascii_hexdigit())
    {
        return false;
    }
    let path = paths
        .control_dir()
        .join(CAPABILITY_DIR)
        .join(format!("{}.json", id.to_lowercase()));
    let Ok(bytes) = std::fs::read(path) else {
        return false;
    };
    let Ok(record) = serde_json::from_slice::<CapabilityRecord>(&bytes) else {
        return false;
    };
    record.expires_at > chrono::Utc::now()
        && record.digest == hex::encode(sha2::Sha256::digest(secret.as_bytes()))
}

/// Asks the app to start its model server (`ask_library` wake protocol).
pub fn touch_wake(paths: &LibraryPaths) -> std::io::Result<()> {
    std::fs::create_dir_all(paths.control_dir())?;
    std::fs::write(paths.control_dir().join(WAKE_FILE), b"")
}

/// True once when a wake request is pending; removes it.
pub fn consume_wake(paths: &LibraryPaths) -> bool {
    let path = paths.control_dir().join(WAKE_FILE);
    path.exists() && std::fs::remove_file(path).is_ok()
}

pub fn wake_pending(paths: &LibraryPaths) -> bool {
    paths.control_dir().join(WAKE_FILE).exists()
}

pub fn write_wake_error(paths: &LibraryPaths, message: &str) -> std::io::Result<()> {
    std::fs::create_dir_all(paths.control_dir())?;
    std::fs::write(
        paths.control_dir().join(WAKE_ERROR_FILE),
        message.as_bytes(),
    )
}

pub fn read_wake_error(paths: &LibraryPaths) -> Option<String> {
    let text = std::fs::read_to_string(paths.control_dir().join(WAKE_ERROR_FILE)).ok()?;
    let trimmed = text.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

pub fn clear_wake_error(paths: &LibraryPaths) {
    let _ = remove_if_exists(&paths.control_dir().join(WAKE_ERROR_FILE));
}

/// Whether the personal-context grant is on.
pub fn personal_context_enabled(paths: &LibraryPaths) -> bool {
    paths.control_dir().join(PERSONAL_MARKER).is_file()
}

/// `None` when screen access is off or the marker cannot be read. An empty
/// (legacy) marker means all retained history; one that does not parse,
/// including whitespace, means the last 7 days (`ScreenMemoryAccessGate.profile`).
pub fn screen_access_scope(paths: &LibraryPaths) -> Option<ScreenScope> {
    let marker = paths.control_dir().join(SCREEN_MARKER);
    let bytes = std::fs::read(marker).ok()?;
    if bytes.is_empty() {
        return Some(ScreenScope::RetainedHistory);
    }
    Some(
        serde_json::from_slice::<ScreenProfile>(&bytes)
            .map(|p| p.scope)
            .unwrap_or(ScreenScope::RecentWeek),
    )
}

pub fn set_screen_access(paths: &LibraryPaths, scope: Option<ScreenScope>) -> std::io::Result<()> {
    let marker = paths.control_dir().join(SCREEN_MARKER);
    match scope {
        Some(scope) => {
            ensure_private_dir(&paths.control_dir())?;
            let json =
                serde_json::to_vec(&ScreenProfile { scope }).map_err(std::io::Error::other)?;
            crate::library::write_atomic(&marker, &json)?;
            restrict_file(&marker);
            Ok(())
        }
        None => remove_if_exists(&marker),
    }
}

fn remove_if_exists(path: &Path) -> std::io::Result<()> {
    match std::fs::remove_file(path) {
        Err(err) if err.kind() != std::io::ErrorKind::NotFound => Err(err),
        _ => Ok(()),
    }
}

fn ensure_private_dir(dir: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
    }
    Ok(())
}

fn restrict_file(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    }
    #[cfg(not(unix))]
    let _ = path;
}

/// `scheme://host[:port]` of a URL, lowercased; `None` if it does not parse.
pub fn origin_of(url: &str) -> Option<String> {
    let (scheme, rest) = url.trim().split_once("://")?;
    let authority = rest.split(['/', '?', '#']).next()?;
    let authority = authority.rsplit('@').next()?;
    if authority.is_empty() {
        return None;
    }
    Some(format!(
        "{}://{}",
        scheme.to_lowercase(),
        authority.to_lowercase()
    ))
}

fn host_of(url: &str) -> Option<String> {
    let origin = origin_of(url)?;
    let authority = origin.split_once("://")?.1.to_string();
    if let Some(stripped) = authority.strip_prefix('[') {
        return stripped.split(']').next().map(str::to_string);
    }
    Some(
        authority
            .rsplit_once(':')
            .map(|(h, p)| {
                if p.chars().all(|c| c.is_ascii_digit()) {
                    h.to_string()
                } else {
                    authority.clone()
                }
            })
            .unwrap_or(authority),
    )
}

/// `localhost`, `*.localhost`, `::1` and `127.0.0.0/8`. `0.0.0.0` is not loopback.
pub fn is_loopback_url(url: &str) -> bool {
    let Some(host) = host_of(url) else {
        return false;
    };
    if host == "localhost" || host.ends_with(".localhost") {
        return true;
    }
    match host.parse::<IpAddr>() {
        Ok(IpAddr::V4(v4)) => v4.is_loopback(),
        Ok(IpAddr::V6(v6)) => v6.is_loopback(),
        Err(_) => false,
    }
}

/// RFC 1918, link-local, CGNAT (Tailscale), unique-local IPv6, `.local`,
/// `.home.arpa`, `.ts.net` and single-label names.
pub fn is_private_network_url(url: &str) -> bool {
    let Some(host) = host_of(url) else {
        return false;
    };
    match host.parse::<IpAddr>() {
        Ok(IpAddr::V4(v4)) => {
            let [a, b, ..] = v4.octets();
            v4.is_private() || v4.is_link_local() || (a == 100 && (64..=127).contains(&b))
        }
        Ok(IpAddr::V6(v6)) => {
            let first = v6.segments()[0];
            (first & 0xfe00) == 0xfc00 || (first & 0xffc0) == 0xfe80
        }
        Err(_) => {
            host.ends_with(".local")
                || host.ends_with(".home.arpa")
                || host.ends_with(".ts.net")
                || !host.contains('.')
        }
    }
}

/// Why a server cannot receive context yet, or `None` if it may.
pub fn remote_block_reason(url: &str, approved: &[String]) -> Option<String> {
    if is_loopback_url(url) {
        return None;
    }
    let Some(origin) = origin_of(url) else {
        return Some("The server URL is not valid.".into());
    };
    let https = origin.starts_with("https://");
    if !https && !is_private_network_url(url) {
        return Some(format!(
            "{origin} must use HTTPS before LokalBot can send it context."
        ));
    }
    if approved.iter().any(|a| a.eq_ignore_ascii_case(&origin)) {
        None
    } else {
        Some(format!(
            "Allow sending context to {origin} in Settings → Models first."
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loopback_and_private_detection() {
        assert!(is_loopback_url("http://127.0.0.1:17872/v1"));
        assert!(is_loopback_url("http://localhost:11434"));
        assert!(!is_loopback_url("http://0.0.0.0:8080"));
        assert!(is_private_network_url("http://192.168.1.20:8080"));
        assert!(is_private_network_url("http://100.101.1.2"));
        assert!(is_private_network_url("http://gpu-box.ts.net"));
        assert!(!is_private_network_url("https://api.openai.com"));
    }

    #[test]
    fn remote_servers_need_https_and_approval() {
        assert_eq!(remote_block_reason("http://localhost:1234/v1", &[]), None);
        assert!(
            remote_block_reason("http://example.com/v1", &[])
                .unwrap()
                .contains("HTTPS")
        );
        let approved = vec!["https://openrouter.ai".to_string()];
        assert_eq!(
            remote_block_reason("https://openrouter.ai/api/v1", &approved),
            None
        );
        assert!(remote_block_reason("https://api.openai.com/v1", &approved).is_some());
    }

    #[test]
    fn markers_toggle() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LibraryPaths::new(dir.path());
        assert!(!meetings_access_enabled(&paths));
        set_meetings_access(&paths, true).unwrap();
        assert!(meetings_access_enabled(&paths));
        set_meetings_access(&paths, false).unwrap();
        assert!(!meetings_access_enabled(&paths));
        set_screen_access(&paths, Some(ScreenScope::Today)).unwrap();
        assert_eq!(screen_access_scope(&paths), Some(ScreenScope::Today));
        set_screen_access(&paths, None).unwrap();
        assert_eq!(screen_access_scope(&paths), None);
    }

    #[test]
    fn screen_markers_parse_like_the_mac() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LibraryPaths::new(dir.path());
        let marker = paths.control_dir().join(SCREEN_MARKER);
        std::fs::create_dir_all(paths.control_dir()).unwrap();
        // The earlier binary gate wrote an empty marker: all retained history.
        std::fs::write(&marker, b"").unwrap();
        assert_eq!(
            screen_access_scope(&paths),
            Some(ScreenScope::RetainedHistory)
        );
        // Anything that does not decode falls back to the safe default.
        for content in [&b"\n"[..], &b"{"[..], &br#"{"scope":"forever"}"#[..]] {
            std::fs::write(&marker, content).unwrap();
            assert_eq!(screen_access_scope(&paths), Some(ScreenScope::RecentWeek));
        }
    }

    #[test]
    fn capability_tokens_authorize_until_revoked() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LibraryPaths::new(dir.path());
        assert_eq!(meetings_authorization(&paths, None), None);
        let token = issue_agent_capability(&paths, chrono::Duration::hours(1)).unwrap();
        let grant = meetings_authorization(&paths, Some(&token)).unwrap();
        assert!(grant.starts_with("capability:"));
        assert_eq!(meetings_authorization(&paths, Some("bogus.token")), None);
        revoke_agent_capability(&paths, &token).unwrap();
        assert_eq!(meetings_authorization(&paths, Some(&token)), None);
        set_meetings_access(&paths, true).unwrap();
        assert!(
            meetings_authorization(&paths, None)
                .unwrap()
                .starts_with("global:")
        );
    }
}
