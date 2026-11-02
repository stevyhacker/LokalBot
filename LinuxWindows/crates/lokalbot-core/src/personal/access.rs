//! The Personal context grant (`PersonalContextAccessGate`,
//! `PersonalContextAccessManager`): a marker under `control/` plus a plaintext
//! copy of only the claims the person shared, so the CLI and MCP can answer
//! without the app running and without reading the encrypted model. Every
//! failure removes the shared copy rather than leaving a stale one.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::{Claim, ContextItem, Sharing};
use crate::access::{PERSONAL_MARKER, PERSONAL_PROJECTION, personal_context_enabled};
use crate::ids::uuid_upper_serde;
use crate::library::write_json;
use crate::paths::LibraryPaths;
use crate::time::iso_seconds;

pub const PROJECTION_VERSION: u32 = 1;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SharedClaim {
    #[serde(with = "uuid_upper_serde")]
    pub id: Uuid,
    pub kind: String,
    pub text: String,
    #[serde(default)]
    pub always_use: bool,
    pub source: String,
    #[serde(with = "iso_seconds")]
    pub created_at: DateTime<Utc>,
    #[serde(with = "iso_seconds")]
    pub updated_at: DateTime<Utc>,
}

impl ContextItem for SharedClaim {
    fn id(&self) -> Uuid {
        self.id
    }
    fn kind(&self) -> &str {
        &self.kind
    }
    fn text(&self) -> &str {
        &self.text
    }
    fn updated_at(&self) -> DateTime<Utc> {
        self.updated_at
    }
    fn always_use(&self) -> bool {
        self.always_use
    }
}

impl From<&Claim> for SharedClaim {
    fn from(claim: &Claim) -> Self {
        Self {
            id: claim.id,
            kind: claim.kind.as_str().to_string(),
            text: claim.text.clone(),
            always_use: claim.always_use,
            source: claim.projection_source().to_string(),
            created_at: claim.created_at,
            updated_at: claim.updated_at,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Projection {
    #[serde(default = "one")]
    pub version: u32,
    #[serde(
        default,
        with = "iso_seconds::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub generated_at: Option<DateTime<Utc>>,
    pub claims: Vec<SharedClaim>,
}

fn one() -> u32 {
    1
}

/// The shared claims, or `None` when the grant is off or nothing readable was
/// written.
pub fn read_projection(paths: &LibraryPaths) -> Option<Projection> {
    if !personal_context_enabled(paths) {
        return None;
    }
    let bytes = std::fs::read(paths.control_dir().join(PERSONAL_PROJECTION)).ok()?;
    serde_json::from_slice::<Projection>(&bytes)
        .ok()
        .filter(|p| p.version <= PROJECTION_VERSION)
}

pub fn remove_projection(paths: &LibraryPaths) {
    let _ = std::fs::remove_file(paths.control_dir().join(PERSONAL_PROJECTION));
}

/// Turns the grant on (and leaves the copy to [`refresh`]) or off, which removes
/// the shared copy too, so nothing lingers on disk.
pub fn set_enabled(paths: &LibraryPaths, enabled: bool) -> std::io::Result<()> {
    if enabled {
        crate::access::ensure_private_dir(&paths.control_dir())?;
        crate::library::write_atomic(
            &paths.control_dir().join(PERSONAL_MARKER),
            Uuid::new_v4().to_string().as_bytes(),
        )
    } else {
        remove_projection(paths);
        match std::fs::remove_file(paths.control_dir().join(PERSONAL_MARKER)) {
            Err(err) if err.kind() != std::io::ErrorKind::NotFound => Err(err),
            _ => Ok(()),
        }
    }
}

/// Rewrites the shared copy from `current`; `None` means the personal model
/// couldn't be read, so nothing is shared until it can be. Returns what went
/// wrong, for Settings.
pub fn refresh(paths: &LibraryPaths, current: Option<&[Claim]>) -> Option<String> {
    if !personal_context_enabled(paths) {
        remove_projection(paths);
        return None;
    }
    let Some(current) = current else {
        remove_projection(paths);
        return Some(
            lokalbot_i18n::tr(
                "LokalBot couldn't read what it remembers about you, so agents get nothing until it can.",
            )
            .to_string(),
        );
    };
    let shared: Vec<SharedClaim> = current
        .iter()
        .filter(|claim| claim.sharing == Sharing::Agents)
        .map(SharedClaim::from)
        .collect();
    // Answers stamp the last-used time, which agents never see.
    if read_projection(paths).is_some_and(|existing| existing.claims == shared) {
        return None;
    }
    let projection = Projection {
        version: PROJECTION_VERSION,
        generated_at: Some(crate::time::now_seconds()),
        claims: shared,
    };
    let result = crate::access::ensure_private_dir(&paths.control_dir())
        .map_err(anyhow::Error::from)
        .and_then(|()| write_json(&paths.control_dir().join(PERSONAL_PROJECTION), &projection));
    match result {
        Ok(()) => None,
        Err(err) => {
            remove_projection(paths);
            Some(lokalbot_i18n::format(
                "LokalBot couldn't update what agents can read, so it removed the shared copy: {0}",
                &[("0", format!("{err:#}"))],
            ))
        }
    }
}
