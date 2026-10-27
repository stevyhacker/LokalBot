//! SHA-256 of files and of whole folders (`SHA256Verifier` in
//! `AgentRuntime.swift`). The tree digest uses the macOS record format, so a
//! digest computed here means the same thing as one computed by the Mac app.

use std::fs::File;
use std::io::Read as _;
use std::path::Path;

use anyhow::{Context as _, Result, bail};
use sha2::{Digest as _, Sha256};

const KIND_SYMLINK: u8 = 0x6C;
const KIND_DIRECTORY: u8 = 0x64;
const KIND_FILE: u8 = 0x66;

/// Streaming digest so the ~80 MB Bun binary never lands in memory at once.
pub fn file_hex(path: &Path) -> Result<String> {
    Ok(hex::encode(file_digest(path)?))
}

fn file_digest(path: &Path) -> Result<[u8; 32]> {
    let mut file = File::open(path).with_context(|| format!("opening {}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 1 << 20];
    loop {
        let read = file
            .read(&mut buffer)
            .with_context(|| format!("reading {}", path.display()))?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hasher.finalize().into())
}

/// Deterministic digest of a folder's complete shape and contents. Records
/// are ordered by raw UTF-8 name within each folder, length-delimited, and
/// tagged by type. Symlinks hash their link text and are never followed;
/// regular files hash their bytes; folders are recorded so empty or extra
/// folders change the digest. Metadata and absolute paths are left out, so
/// identical installs hash identically.
pub fn tree_hex(root: &Path) -> Result<String> {
    let metadata =
        std::fs::symlink_metadata(root).with_context(|| format!("reading {}", root.display()))?;
    if !metadata.is_dir() {
        bail!("{} is not a folder", root.display());
    }
    let mut hasher = Sha256::new();
    hash_directory(root, "", &mut hasher)?;
    Ok(hex::encode(hasher.finalize()))
}

fn hash_directory(directory: &Path, relative: &str, hasher: &mut Sha256) -> Result<()> {
    let mut entries: Vec<(Vec<u8>, std::path::PathBuf)> = Vec::new();
    for entry in
        std::fs::read_dir(directory).with_context(|| format!("listing {}", directory.display()))?
    {
        let entry = entry?;
        let name = entry
            .file_name()
            .into_string()
            .map_err(|name| anyhow::anyhow!("{name:?} is not valid UTF-8"))?;
        entries.push((name.into_bytes(), entry.path()));
    }
    entries.sort_by(|a, b| a.0.cmp(&b.0));
    for (name, path) in entries {
        let name = String::from_utf8(name)?;
        let relative_path = if relative.is_empty() {
            name
        } else {
            format!("{relative}/{name}")
        };
        let metadata = std::fs::symlink_metadata(&path)?;
        let kind = metadata.file_type();
        if kind.is_symlink() {
            let target = std::fs::read_link(&path)?;
            let text = target.to_string_lossy().replace('\\', "/");
            record(hasher, KIND_SYMLINK, &relative_path, text.as_bytes());
        } else if kind.is_dir() {
            record(hasher, KIND_DIRECTORY, &relative_path, &[]);
            hash_directory(&path, &relative_path, hasher)?;
        } else if kind.is_file() {
            record(hasher, KIND_FILE, &relative_path, &file_digest(&path)?);
        } else {
            bail!("{} is not a file, folder or link", path.display());
        }
    }
    Ok(())
}

fn record(hasher: &mut Sha256, kind: u8, path: &str, payload: &[u8]) {
    hasher.update([kind]);
    length_prefixed(hasher, path.as_bytes());
    length_prefixed(hasher, payload);
}

fn length_prefixed(hasher: &mut Sha256, bytes: &[u8]) {
    hasher.update((bytes.len() as u64).to_be_bytes());
    hasher.update(bytes);
}

/// Lowercase 64-character hex, as every receipt field must be.
pub fn is_hex_digest(value: &str) -> bool {
    value.len() == 64 && value.chars().all(|c| c.is_ascii_hexdigit())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_digest_of_known_data() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("abc.txt");
        std::fs::write(&file, b"abc").unwrap();
        assert_eq!(
            file_hex(&file).unwrap(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn tree_digest_is_deterministic_and_covers_hidden_files_and_folders() {
        let make = |root: &Path| {
            std::fs::create_dir_all(root.join("a/b")).unwrap();
            std::fs::write(root.join("a/b/file.txt"), b"one").unwrap();
            std::fs::write(root.join(".hidden"), b"two").unwrap();
        };
        let first = tempfile::tempdir().unwrap();
        let second = tempfile::tempdir().unwrap();
        make(first.path());
        make(second.path());
        let digest = tree_hex(first.path()).unwrap();
        assert_eq!(digest, tree_hex(second.path()).unwrap());

        std::fs::write(second.path().join(".hidden"), b"changed").unwrap();
        assert_ne!(digest, tree_hex(second.path()).unwrap());
        std::fs::write(second.path().join(".hidden"), b"two").unwrap();
        std::fs::create_dir(second.path().join("empty")).unwrap();
        assert_ne!(digest, tree_hex(second.path()).unwrap());
    }

    /// Matches `SHA256Verifier.treeHexDigest` on macOS for the same layout:
    /// one folder `d` holding `f` = "x". Computed by hand from the record
    /// format (kind, u64 big-endian length + path, u64 length + payload).
    #[test]
    fn tree_digest_uses_the_macos_record_format() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir(dir.path().join("d")).unwrap();
        std::fs::write(dir.path().join("d/f"), b"x").unwrap();
        let mut expected = Sha256::new();
        record(&mut expected, KIND_DIRECTORY, "d", &[]);
        let file: [u8; 32] = Sha256::digest(b"x").into();
        record(&mut expected, KIND_FILE, "d/f", &file);
        assert_eq!(
            tree_hex(dir.path()).unwrap(),
            hex::encode(expected.finalize())
        );
    }

    #[cfg(unix)]
    #[test]
    fn tree_digest_hashes_link_text_without_following_links() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("target"), b"x").unwrap();
        std::os::unix::fs::symlink("target", dir.path().join("link")).unwrap();
        let before = tree_hex(dir.path()).unwrap();
        std::fs::remove_file(dir.path().join("link")).unwrap();
        std::os::unix::fs::symlink("elsewhere", dir.path().join("link")).unwrap();
        assert_ne!(before, tree_hex(dir.path()).unwrap());
    }
}
