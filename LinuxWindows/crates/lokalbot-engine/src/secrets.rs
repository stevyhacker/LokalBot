//! API keys, private calendar links and the keys that seal screen images and
//! recent dictations live in the system credential store (Windows Credential
//! Manager, the Secret Service on Linux), never in `settings.json` or the
//! library.

use anyhow::{Context as _, Result};

const SERVICE: &str = "com.lokalbot.LokalBot";
const OPENAI_COMPATIBLE: &str = "openai-compatible-api-key";

fn entry(account: &str) -> Result<keyring::Entry> {
    keyring::Entry::new(SERVICE, account).context("the system credential store is not available")
}

/// Saves (or, when blank, removes) the key for the OpenAI-compatible server.
pub fn save_openai_api_key(key: &str) -> Result<()> {
    let entry = entry(OPENAI_COMPATIBLE)?;
    if key.trim().is_empty() {
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(err) => Err(err).context("removing the API key"),
        }
    } else {
        entry.set_password(key.trim()).context("saving the API key")
    }
}

pub fn openai_api_key() -> Option<String> {
    entry(OPENAI_COMPATIBLE)
        .ok()?
        .get_password()
        .ok()
        .filter(|k| !k.trim().is_empty())
}

const REMOTE_TRANSCRIPTION: &str = "remote-transcription-api-key";

/// Saves (or, when blank, removes) the transcription server's own key, under
/// the Mac's Keychain account name.
pub fn save_remote_transcription_api_key(key: &str) -> Result<()> {
    let entry = entry(REMOTE_TRANSCRIPTION)?;
    if key.trim().is_empty() {
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(err) => Err(err).context("removing the API key"),
        }
    } else {
        entry.set_password(key.trim()).context("saving the API key")
    }
}

pub fn remote_transcription_api_key() -> Option<String> {
    entry(REMOTE_TRANSCRIPTION)
        .ok()?
        .get_password()
        .ok()
        .filter(|k| !k.trim().is_empty())
}

/// The ChatGPT plan's session, registration and per-install id, under the
/// account names the Mac uses in its Keychain (`chatgpt-plan-*`). They are
/// kept nowhere else: without a credential store the sign-in fails.
pub struct PlanStore;

impl lokalbot_ai::plans::chatgpt::Store for PlanStore {
    fn get(&self, account: &str) -> Result<Option<String>> {
        match entry(account)?.get_password() {
            Ok(value) => Ok(Some(value)),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(err) => Err(err).context("reading the ChatGPT sign-in"),
        }
    }

    fn set(&self, account: &str, value: Option<&str>) -> Result<()> {
        let entry = entry(account)?;
        match value {
            Some(value) => entry
                .set_password(value)
                .context("saving the ChatGPT sign-in"),
            None => match entry.delete_credential() {
                Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
                Err(err) => Err(err).context("removing the ChatGPT sign-in"),
            },
        }
    }
}

/// Lets Think and Settings keep the ChatGPT plan in the credential store.
/// Tokens are split across items: Credential Manager keeps at most 1,280
/// characters in one.
pub fn install_plan_store() {
    lokalbot_ai::plans::chatgpt::install_store(std::sync::Arc::new(
        lokalbot_ai::plans::chatgpt::Chunked::new(PlanStore),
    ));
}

const SCREENSHOT_KEY: &str = "screenshot-key";
const RECENT_DICTATIONS_KEY: &str = "recent-dictations-key";
const SPEAKER_IDENTITY_KEY: &str = "speaker-identity-key";

/// The per-install key that seals screen images (`ScreenshotService.encryptionKey`,
/// Keychain account `screenshot-key`). It is created on first use when
/// `create` is set, kept only in the credential store, and cached for the
/// life of the process so captures do not ask the store each time. A store
/// that cannot be reached never leads to a new key: images are then not kept.
pub fn screen_image_key(create: bool) -> Result<[u8; lokalbot_core::screen::IMAGE_KEY_BYTES]> {
    sealing_key(SCREENSHOT_KEY, "screen image key", create)
}

/// The per-install key that seals recent dictations, kept like the screen
/// image key. Without a reachable store they stay in memory only.
pub fn recent_dictations_key(
    create: bool,
) -> Result<[u8; lokalbot_core::dictation_history::KEY_BYTES]> {
    sealing_key(RECENT_DICTATIONS_KEY, "recent dictations key", create)
}

/// The per-install key that seals remembered voices and speaker evidence
/// (`KeychainSecrets`, account `speaker-identity-key`). Without a reachable
/// store nothing about a voice is kept.
pub fn speaker_identity_key(create: bool) -> Result<[u8; KEY_BYTES]> {
    sealing_key(SPEAKER_IDENTITY_KEY, "speaker identity key", create)
}

const CHAT_KEY: &str = "chat-key";

/// The per-install key that seals Ask conversations, Personal Context and the
/// dictation learning log, under the Mac's account name. It is created on first
/// use when `create` is set. A store that can't be reached never leads to a new
/// key: those stay unsaved, or kept as they are, until it can.
pub fn chat_key(create: bool) -> Result<[u8; KEY_BYTES]> {
    sealing_key(CHAT_KEY, "key for saved conversations", create)
}

const COTYPING_LEARNING_KEY: &str = "cotyping-learning-key";

/// The per-install key that seals autocomplete's learned examples, under the
/// Mac's account name, kept like the screen image key.
pub fn cotyping_learning_key(create: bool) -> Result<[u8; KEY_BYTES]> {
    sealing_key(COTYPING_LEARNING_KEY, "autocomplete learning key", create)
}

/// Saves (or, when blank, removes) the key for autocomplete's own server.
pub fn save_autocomplete_server_api_key(key: &str) -> Result<()> {
    let entry = entry(lokalbot_ai::autocomplete::server::API_KEY_ACCOUNT)?;
    if key.trim().is_empty() {
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(err) => Err(err).context("removing the API key"),
        }
    } else {
        entry.set_password(key.trim()).context("saving the API key")
    }
}

pub fn autocomplete_server_api_key() -> Option<String> {
    entry(lokalbot_ai::autocomplete::server::API_KEY_ACCOUNT)
        .ok()?
        .get_password()
        .ok()
        .filter(|k| !k.trim().is_empty())
}

const KEY_BYTES: usize = 32;
const _: () = assert!(
    KEY_BYTES == lokalbot_core::screen::IMAGE_KEY_BYTES
        && KEY_BYTES == lokalbot_core::dictation_history::KEY_BYTES
);

fn sealing_key(account: &'static str, what: &str, create: bool) -> Result<[u8; KEY_BYTES]> {
    static CACHE: parking_lot::Mutex<Vec<(&'static str, [u8; KEY_BYTES])>> =
        parking_lot::Mutex::new(Vec::new());
    let mut cache = CACHE.lock();
    if let Some((_, key)) = cache.iter().find(|(cached, _)| *cached == account) {
        return Ok(*key);
    }
    let entry = entry(account)?;
    let key = match entry.get_password() {
        Ok(stored) => {
            decode_key(&stored).with_context(|| format!("the stored {what} is not readable"))?
        }
        Err(keyring::Error::NoEntry) if create => {
            let key = lokalbot_core::screen::new_image_key();
            entry
                .set_password(&hex::encode(key))
                .with_context(|| format!("saving the {what}"))?;
            // Read it back: a store that silently drops secrets must not
            // leave files that nothing can open.
            let stored = entry
                .get_password()
                .with_context(|| format!("reading the {what} back"))?;
            anyhow::ensure!(
                decode_key(&stored) == Some(key),
                "the credential store did not keep the {what}"
            );
            key
        }
        Err(keyring::Error::NoEntry) => anyhow::bail!("no {what} has been created"),
        Err(err) => return Err(err).with_context(|| format!("reading the {what}")),
    };
    cache.push((account, key));
    Ok(key)
}

fn decode_key(stored: &str) -> Option<[u8; KEY_BYTES]> {
    hex::decode(stored.trim()).ok()?.try_into().ok()
}

const COMPANION_STATIC_KEY: &str = "companion-static-key";

/// This computer's long-term key for paired phones and tablets, under the
/// Mac's account name, kept like the screen image key. Created when sharing
/// first starts, never written anywhere else: with no reachable store,
/// sharing stays off and says why.
pub fn companion_static_key() -> Result<[u8; KEY_BYTES]> {
    sealing_key(COMPANION_STATIC_KEY, "sharing key", true)
}

const CALENDAR_LINKS: &str = "calendar-links";

/// Private calendar links (iCal feeds and CalDAV collections), one per line.
/// They grant read access to the user's calendar, so like API keys they live
/// only in the credential store.
pub fn calendar_links() -> Result<Vec<String>> {
    match entry(CALENDAR_LINKS)?.get_password() {
        Ok(stored) => Ok(stored
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .map(str::to_string)
            .collect()),
        Err(keyring::Error::NoEntry) => Ok(Vec::new()),
        Err(err) => Err(err).context("reading the calendar links"),
    }
}

/// Saves the links, or removes the entry when there are none.
pub fn save_calendar_links(links: &[String]) -> Result<()> {
    let entry = entry(CALENDAR_LINKS)?;
    let joined = links
        .iter()
        .map(|link| link.trim())
        .filter(|link| !link.is_empty())
        .collect::<Vec<_>>()
        .join("\n");
    if joined.is_empty() {
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(err) => Err(err).context("removing the calendar links"),
        }
    } else {
        entry
            .set_password(&joined)
            .context("saving the calendar links")
    }
}
