//! Ask conversations on disk (`ChatStore`): one sealed file per conversation,
//! `chats/<UUID>.json.enc`, under the per-install `chat-key`.
//!
//! Plaintext `chats/<UUID>.json`, which earlier versions of this app and the
//! Mac's first versions wrote, still opens and is then re-sealed, and the
//! plaintext goes only once its sealed copy has landed. An encrypted copy wins
//! over a leftover plaintext one. A sealed file that can't be opened (the key is
//! missing, or the library came from another computer) is reported and left
//! alone: it is never overwritten or replaced by a plaintext copy beside it.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context as _, Result, anyhow};
use uuid::Uuid;

use crate::ids;
use crate::library::{Library, write_atomic};
use crate::model::Conversation;
use crate::sealed;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LoadFailure {
    DirectoryUnavailable,
    KeyUnavailable,
    UnreadableEncryptedFile(String),
    UnreadablePlaintextFile(String),
    PlaintextMigrationFailed(String),
}

impl LoadFailure {
    fn is_unreadable_file(&self) -> bool {
        matches!(
            self,
            Self::UnreadableEncryptedFile(_) | Self::UnreadablePlaintextFile(_)
        )
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ChatLoad {
    /// Newest first.
    pub conversations: Vec<Conversation>,
    pub failures: Vec<LoadFailure>,
    /// Conversations held in memory because they couldn't be saved.
    pub unsaved: Vec<Uuid>,
}

impl ChatLoad {
    /// `ChatViewModel.updatePersistenceError`, with this platform's credential
    /// store in place of the Keychain.
    pub fn problem(&self) -> Option<String> {
        if !self.unsaved.is_empty() {
            return Some(
                lokalbot_i18n::tr(
                    "Conversation changes are not saved. Keep LokalBot open and retry after checking disk space and your system's credential store.",
                )
                .to_string(),
            );
        }
        if self.failures.is_empty() {
            return None;
        }
        let unreadable = self
            .failures
            .iter()
            .filter(|f| f.is_unreadable_file())
            .count();
        let only_unsealed = self
            .failures
            .iter()
            .all(|f| matches!(f, LoadFailure::PlaintextMigrationFailed(_)));
        Some(if only_unsealed {
            lokalbot_i18n::tr(
                "Some saved conversations couldn't be encrypted yet, so they stay as they are. Retry after checking your system's credential store.",
            )
            .to_string()
        } else if unreadable == 1 {
            lokalbot_i18n::tr(
                "1 saved conversation file could not be opened. The file was preserved; retry after checking your system's credential store and disk access.",
            )
            .to_string()
        } else if unreadable > 1 {
            lokalbot_i18n::format(
                "{0} saved conversation files could not be opened. The files were preserved; retry after checking your system's credential store and disk access.",
                &[("0", unreadable.to_string())],
            )
        } else {
            lokalbot_i18n::tr(
                "Saved conversation history could not be read. Retry after checking your system's credential store and disk access.",
            )
            .to_string()
        })
    }
}

fn sealed_name(id: Uuid) -> String {
    format!("{}.json.enc", ids::uuid_upper(&id))
}

/// Both spellings: the Mac names files in upper case, earlier versions of this
/// app in lower case.
fn plaintext_names(id: Uuid) -> [String; 2] {
    [
        format!("{}.json", ids::uuid_upper(&id)),
        format!("{}.json", id.hyphenated()),
    ]
}

fn encode(conversation: &Conversation) -> Result<Vec<u8>> {
    let value = serde_json::to_value(conversation)?;
    Ok(serde_json::to_vec_pretty(&crate::library::sort_keys(
        value,
    ))?)
}

impl Library {
    /// Lets this library seal and open chats. Installed by the engine at start.
    pub fn set_chat_key_source(&self, source: sealed::KeySource) {
        *self.chat_key_slot().write() = Some(source);
    }

    /// The `chat-key`; `create` makes one when none exists.
    pub(crate) fn chat_key(&self, create: bool) -> Result<sealed::SealingKey> {
        let source = self.chat_key_slot().read().clone();
        match source {
            Some(source) => source(create),
            None => Err(anyhow!("the key for saved conversations is not available")),
        }
    }

    pub fn load_conversations(&self) -> ChatLoad {
        let dir = self.paths().chats_dir();
        let mut load = ChatLoad::default();
        let entries = match fs::read_dir(&dir) {
            Ok(entries) => entries,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                self.merge_unsaved(&mut load);
                return load;
            }
            Err(err) => {
                log::warn!("reading {}: {err}", dir.display());
                load.failures.push(LoadFailure::DirectoryUnavailable);
                self.merge_unsaved(&mut load);
                return load;
            }
        };
        let mut plaintext: Vec<PathBuf> = Vec::new();
        let mut encrypted: Vec<PathBuf> = Vec::new();
        for path in entries.flatten().map(|entry| entry.path()) {
            match path.extension().and_then(|e| e.to_str()) {
                Some("enc") => encrypted.push(path),
                Some("json") => plaintext.push(path),
                _ => {}
            }
        }
        let key = if encrypted.is_empty() {
            None
        } else {
            match self.chat_key(false) {
                Ok(key) => Some(key),
                Err(err) => {
                    log::warn!("chat key unavailable: {err:#}");
                    load.failures.push(LoadFailure::KeyUnavailable);
                    None
                }
            }
        };

        let mut conversations: HashMap<Uuid, Conversation> = HashMap::new();
        let mut legacy: Vec<(Uuid, PathBuf)> = Vec::new();
        for path in &plaintext {
            match fs::read(path)
                .ok()
                .and_then(|bytes| serde_json::from_slice::<Conversation>(&bytes).ok())
            {
                Some(conversation) => {
                    legacy.push((conversation.id, path.clone()));
                    conversations.insert(conversation.id, conversation);
                }
                None => load
                    .failures
                    .push(LoadFailure::UnreadablePlaintextFile(file_name(path))),
            }
        }
        // Encrypted copies win if an earlier migration left both files.
        let mut sealed_unopened: Vec<PathBuf> = Vec::new();
        for path in &encrypted {
            let opened = key
                .as_ref()
                .zip(fs::read(path).ok())
                .and_then(|(key, bytes)| sealed::open(key, &bytes))
                .and_then(|clear| serde_json::from_slice::<Conversation>(&clear).ok());
            match opened {
                Some(conversation) => {
                    conversations.insert(conversation.id, conversation);
                }
                None => {
                    load.failures
                        .push(LoadFailure::UnreadableEncryptedFile(file_name(path)));
                    sealed_unopened.push(path.clone());
                }
            }
        }

        if !self.is_read_only() {
            for (id, path) in legacy {
                // Re-sealing here would replace a store that can't be opened.
                if sealed_unopened
                    .iter()
                    .any(|sealed| file_name(sealed).eq_ignore_ascii_case(&sealed_name(id)))
                {
                    continue;
                }
                let moved = conversations
                    .get(&id)
                    .ok_or_else(|| anyhow!("missing"))
                    .and_then(|conversation| self.write_sealed(conversation))
                    .and_then(|()| fs::remove_file(&path).map_err(Into::into));
                if let Err(err) = moved {
                    log::warn!("could not seal chat {}: {err:#}", path.display());
                    load.failures
                        .push(LoadFailure::PlaintextMigrationFailed(file_name(&path)));
                }
            }
        }

        load.conversations = conversations.into_values().collect();
        self.merge_unsaved(&mut load);
        load.conversations
            .sort_by_key(|c| std::cmp::Reverse(c.updated_at));
        load
    }

    fn merge_unsaved(&self, load: &mut ChatLoad) {
        let unsaved = self.unsaved_chats().lock();
        for (id, conversation) in unsaved.iter() {
            load.unsaved.push(*id);
            load.conversations.retain(|c| c.id != *id);
            load.conversations.push(conversation.clone());
        }
    }

    pub fn conversations(&self) -> Result<Vec<Conversation>> {
        Ok(self.load_conversations().conversations)
    }

    fn write_sealed(&self, conversation: &Conversation) -> Result<()> {
        let key = self.chat_key(true)?;
        let path = self.paths().chats_dir().join(sealed_name(conversation.id));
        if let Ok(existing) = fs::read(&path)
            && sealed::open(&key, &existing).is_none()
        {
            return Err(anyhow!(
                "the saved copy of this conversation can't be opened here, so it was kept as is"
            ));
        }
        let bytes = sealed::seal(&key, &encode(conversation)?)?;
        write_atomic(&path, &bytes).with_context(|| format!("writing {}", path.display()))
    }

    /// Seals and saves. When that isn't possible the conversation stays in
    /// memory for this run instead of being written as plaintext, and the error
    /// says so.
    pub fn save_conversation(&self, conversation: &Conversation) -> Result<()> {
        match self.write_sealed(conversation) {
            Ok(()) => {
                self.unsaved_chats().lock().remove(&conversation.id);
                let dir = self.paths().chats_dir();
                for name in plaintext_names(conversation.id) {
                    remove_if_present(&dir.join(name))?;
                }
                Ok(())
            }
            Err(err) => {
                self.unsaved_chats()
                    .lock()
                    .insert(conversation.id, conversation.clone());
                Err(err)
            }
        }
    }

    /// The legacy copy goes first: if that fails the sealed copy is still there
    /// and the conversation can be deleted again. What was learned from the
    /// questions in it goes too.
    /// Whether the conversation is still kept, on disk or held unsaved. An answer
    /// still being written never brings back one deleted meanwhile.
    pub fn conversation_exists(&self, id: Uuid) -> bool {
        let dir = self.paths().chats_dir();
        self.unsaved_chats().lock().contains_key(&id)
            || dir.join(sealed_name(id)).exists()
            || dir.join(format!("{}.json.enc", id.hyphenated())).exists()
            || plaintext_names(id)
                .into_iter()
                .any(|name| dir.join(name).exists())
    }

    pub fn delete_conversation(&self, id: Uuid) -> Result<()> {
        let dir = self.paths().chats_dir();
        for name in plaintext_names(id) {
            remove_if_present(&dir.join(name))?;
        }
        remove_if_present(&dir.join(sealed_name(id)))?;
        remove_if_present(&dir.join(format!("{}.json.enc", id.hyphenated())))?;
        self.unsaved_chats().lock().remove(&id);
        self.personal().retract_learned_from_conversation(id);
        Ok(())
    }

    /// For the demo library, which is built before any key exists. The app
    /// seals it the first time it loads conversations.
    pub(crate) fn write_plaintext_conversation(&self, conversation: &Conversation) -> Result<()> {
        let path = self
            .paths()
            .chats_dir()
            .join(format!("{}.json", conversation.id.hyphenated()));
        write_atomic(&path, &encode(conversation)?)?;
        Ok(())
    }
}

fn remove_if_present(path: &Path) -> Result<()> {
    match fs::remove_file(path) {
        Err(err) if err.kind() != std::io::ErrorKind::NotFound => {
            Err(err).with_context(|| format!("removing {}", path.display()))
        }
        _ => Ok(()),
    }
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("")
        .to_string()
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;
    use crate::LibraryPaths;
    use crate::model::{ChatMessage, ChatRole};

    const KEY: sealed::SealingKey = [3u8; sealed::KEY_BYTES];
    const OTHER: sealed::SealingKey = [4u8; sealed::KEY_BYTES];

    fn library() -> (tempfile::TempDir, Library) {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(LibraryPaths::new(dir.path())).unwrap();
        fs::create_dir_all(library.paths().chats_dir()).unwrap();
        (dir, library)
    }

    fn with_key(library: &Library, key: sealed::SealingKey) {
        library.set_chat_key_source(Arc::new(move |_| Ok(key)));
    }

    fn conversation(id: &str) -> Conversation {
        serde_json::from_value(serde_json::json!({
            "id": id,
            "title": "Pricing",
            "createdAt": "2026-10-19T09:00:00Z",
            "updatedAt": "2026-10-19T09:01:00Z",
            "messages": [
                {"id": "11111111-1111-4111-8111-111111111111", "role": "user",
                 "text": "What did we decide?", "createdAt": "2026-10-19T09:00:00Z"},
                {"id": "22222222-2222-4222-8222-222222222222", "role": "assistant",
                 "text": "Redis.", "createdAt": "2026-10-19T09:01:00Z",
                 "usedClaimIDs": ["33333333-3333-4333-8333-333333333333"]}
            ]
        }))
        .unwrap()
    }

    const ID: &str = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA";

    #[test]
    fn an_old_plaintext_chat_opens_and_is_then_sealed() {
        let (_dir, library) = library();
        with_key(&library, KEY);
        let chats = library.paths().chats_dir();
        let old = chats.join(format!("{}.json", ID.to_lowercase()));
        fs::write(&old, serde_json::to_vec(&conversation(ID)).unwrap()).unwrap();

        let load = library.load_conversations();
        assert_eq!(load.conversations.len(), 1);
        assert!(load.failures.is_empty(), "{:?}", load.failures);
        assert!(!old.exists());
        let sealed_path = chats.join(format!("{ID}.json.enc"));
        let bytes = fs::read(&sealed_path).unwrap();
        assert!(!String::from_utf8_lossy(&bytes).contains("Redis"));
        let clear = sealed::open(&KEY, &bytes).unwrap();
        let reopened: Conversation = serde_json::from_slice(&clear).unwrap();
        assert_eq!(reopened, conversation(ID));
        assert_eq!(library.load_conversations().conversations.len(), 1);
    }

    #[test]
    fn without_a_key_plaintext_stays_readable_and_stays_put() {
        let (_dir, library) = library();
        let old = library.paths().chats_dir().join(format!("{ID}.json"));
        fs::write(&old, serde_json::to_vec(&conversation(ID)).unwrap()).unwrap();
        let load = library.load_conversations();
        assert_eq!(load.conversations.len(), 1);
        assert!(old.exists());
        assert!(matches!(
            load.failures[..],
            [LoadFailure::PlaintextMigrationFailed(_)]
        ));
        assert!(
            load.problem()
                .unwrap()
                .contains("couldn't be encrypted yet")
        );
    }

    #[test]
    fn a_file_sealed_elsewhere_is_reported_and_never_overwritten() {
        let (_dir, library) = library();
        let chats = library.paths().chats_dir();
        let foreign = sealed::seal(&OTHER, b"{\"from\":\"the Mac\"}").unwrap();
        let path = chats.join(format!("{ID}.json.enc"));
        fs::write(&path, &foreign).unwrap();
        // A plaintext copy beside it mustn't replace it either.
        let plain = chats.join(format!("{ID}.json"));
        fs::write(&plain, serde_json::to_vec(&conversation(ID)).unwrap()).unwrap();

        // No key at all: "key unavailable".
        let load = library.load_conversations();
        assert!(load.failures.contains(&LoadFailure::KeyUnavailable));
        assert_eq!(fs::read(&path).unwrap(), foreign);

        // Another key: unreadable, with a message saying the file was kept.
        with_key(&library, KEY);
        let load = library.load_conversations();
        assert!(load.failures.iter().any(|f| f.is_unreadable_file()));
        assert!(load.problem().unwrap().contains("preserved"));
        assert_eq!(fs::read(&path).unwrap(), foreign);
        assert!(plain.exists());

        // Saving over it is refused, and the answer stays in memory.
        let mut updated = conversation(ID);
        updated.title = "New title".into();
        assert!(library.save_conversation(&updated).is_err());
        assert_eq!(fs::read(&path).unwrap(), foreign);
        let load = library.load_conversations();
        assert_eq!(load.unsaved, vec![updated.id]);
        assert_eq!(load.conversations[0].title, "New title");
    }

    #[test]
    fn saved_chats_are_sealed_and_delete_removes_every_copy() {
        let (_dir, library) = library();
        with_key(&library, KEY);
        let chats = library.paths().chats_dir();
        let plain = chats.join(format!("{}.json", ID.to_lowercase()));
        fs::write(&plain, b"{}").unwrap();
        let chat = conversation(ID);
        library.save_conversation(&chat).unwrap();
        assert!(!plain.exists());
        assert!(chats.join(format!("{ID}.json.enc")).is_file());
        assert_eq!(library.conversations().unwrap(), vec![chat.clone()]);
        library.delete_conversation(chat.id).unwrap();
        assert!(library.conversations().unwrap().is_empty());
        assert_eq!(fs::read_dir(&chats).unwrap().count(), 0);
    }

    #[test]
    fn without_a_key_new_chats_stay_in_memory_not_on_disk_as_plaintext() {
        let (_dir, library) = library();
        let chat = conversation(ID);
        assert!(library.save_conversation(&chat).is_err());
        assert_eq!(
            fs::read_dir(library.paths().chats_dir()).unwrap().count(),
            0
        );
        let load = library.load_conversations();
        assert_eq!(load.conversations, vec![chat]);
        assert!(load.problem().unwrap().contains("not saved"));
    }

    #[test]
    fn a_receipt_and_used_claims_round_trip() {
        let mut chat = conversation(ID);
        chat.messages.push(ChatMessage {
            remember_receipt: Some(crate::model::RememberReceipt { claim_id: None }),
            ..ChatMessage::new(ChatRole::Assistant, "Maya is my manager.")
        });
        let json = serde_json::to_value(&chat).unwrap();
        assert_eq!(
            json["messages"][1]["usedClaimIDs"][0],
            "33333333-3333-4333-8333-333333333333"
        );
        assert_eq!(
            json["messages"][2]["rememberReceipt"],
            serde_json::json!({})
        );
        let back: Conversation = serde_json::from_value(json).unwrap();
        assert_eq!(back, chat);
    }
}
