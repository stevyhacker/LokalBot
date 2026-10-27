//! Release tool: signs a Linux or Windows archive with the Sparkle key and
//! writes its update feed, or checks a feed and archive against a public key.
//! The release workflow builds it with `--no-default-features`.
//!
//! ```text
//! lokalbot-update-feed sign --archive DIST/LokalBot-0.10.11-linux-x86_64.tar.gz \
//!     --platform linux-x86_64 --version 0.10.11 --tag v0.10.11 --key-file KEY \
//!     [--expect-public-key BASE64] [--minimum-version 0.10.10] [--repo owner/name] \
//!     [--download-base URL] [--notes-url URL] --output linux-x86_64.json
//! lokalbot-update-feed verify --feed linux-x86_64.json --archive FILE [--public-key BASE64]
//! lokalbot-update-feed public-key --key-file KEY
//! ```
//!
//! The private key is read from a file and never printed.

use std::collections::HashMap;
use std::path::Path;
use std::process::ExitCode;

use anyhow::{Context as _, Result, bail};
use lokalbot_update::feed::{self, Feed};
use lokalbot_update::{PLATFORMS, PublicKey, REPOSITORY, SecretKey, Version};
use sha2::Digest as _;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(message) => {
            println!("{message}");
            ExitCode::SUCCESS
        }
        Err(err) => {
            eprintln!("lokalbot-update-feed: {err:#}");
            ExitCode::FAILURE
        }
    }
}

fn run(args: &[String]) -> Result<String> {
    let Some((command, rest)) = args.split_first() else {
        bail!("usage: lokalbot-update-feed sign|verify|public-key [options]");
    };
    let options = Options::parse(rest)?;
    match command.as_str() {
        "sign" => sign(&options),
        "verify" => verify(&options),
        "public-key" => {
            let key = read_key(options.required("key-file")?)?;
            Ok(key.public_key().to_base64())
        }
        other => bail!("unknown command {other:?}"),
    }
}

struct Options(HashMap<String, String>);

impl Options {
    fn parse(args: &[String]) -> Result<Self> {
        let mut values = HashMap::new();
        let mut iter = args.iter();
        while let Some(arg) = iter.next() {
            let Some(name) = arg.strip_prefix("--") else {
                bail!("unexpected argument {arg:?}");
            };
            let value = iter
                .next()
                .with_context(|| format!("--{name} needs a value"))?;
            if values.insert(name.to_string(), value.clone()).is_some() {
                bail!("--{name} was given twice");
            }
        }
        Ok(Self(values))
    }

    fn required(&self, name: &str) -> Result<&str> {
        self.0
            .get(name)
            .map(String::as_str)
            .with_context(|| format!("--{name} is required"))
    }

    fn optional(&self, name: &str) -> Option<&str> {
        self.0.get(name).map(String::as_str)
    }
}

fn read_key(path: &str) -> Result<SecretKey> {
    let text = std::fs::read_to_string(path).with_context(|| format!("reading {path}"))?;
    Ok(SecretKey::from_sparkle(&text)?)
}

fn sign(options: &Options) -> Result<String> {
    let platform = options.required("platform")?;
    if !PLATFORMS.contains(&platform) {
        bail!("--platform must be one of {}", PLATFORMS.join(", "));
    }
    let version: Version = options.required("version")?.parse()?;
    let tag = options.required("tag")?;
    if tag.trim_start_matches('v').split('-').next() != Some(version.to_string().as_str()) {
        bail!("tag {tag} does not name version {version}");
    }
    let key = read_key(options.required("key-file")?)?;
    if let Some(expected) = options.optional("expect-public-key")
        && key.public_key() != PublicKey::from_base64(expected)?
    {
        bail!("the signing key does not belong to the expected public key {expected}");
    }
    let archive = Path::new(options.required("archive")?);
    let name = feed::archive_name(&version.to_string(), platform);
    if archive.file_name().and_then(|n| n.to_str()) != Some(name.as_str()) {
        bail!("the archive must be named {name}");
    }
    let bytes = std::fs::read(archive).with_context(|| format!("reading {}", archive.display()))?;
    let repo = options.optional("repo").unwrap_or(REPOSITORY);
    let download_base = options
        .optional("download-base")
        .map(|base| base.trim_end_matches('/').to_string())
        .unwrap_or_else(|| format!("https://github.com/{repo}/releases/download/{tag}"));
    let notes = options
        .optional("notes-url")
        .map(str::to_string)
        .unwrap_or_else(|| format!("https://github.com/{repo}/releases/tag/{tag}"));
    let minimum: Version = options
        .optional("minimum-version")
        .unwrap_or("0.0.0")
        .parse()?;
    let feed = Feed {
        platform: platform.into(),
        version: version.to_string(),
        minimum_version: minimum.to_string(),
        url: format!("{download_base}/{name}"),
        size: bytes.len() as u64,
        sha256: hex::encode(sha2::Sha256::digest(&bytes)),
        signature: key.sign(&bytes),
        release_notes_url: notes,
    };
    feed.validate(platform, is_loopback(&feed.url))?;
    key.public_key().verify(&bytes, &feed.signature)?;
    let output = options.required("output")?;
    let mut json = serde_json::to_string_pretty(&feed)?;
    json.push('\n');
    std::fs::write(output, json).with_context(|| format!("writing {output}"))?;
    Ok(format!(
        "Signed {name} ({} bytes) for {platform} {version} into {output}",
        feed.size
    ))
}

fn verify(options: &Options) -> Result<String> {
    let path = options.required("feed")?;
    let text = std::fs::read(path).with_context(|| format!("reading {path}"))?;
    let raw: Feed = serde_json::from_slice(&text).context("the feed is not valid JSON")?;
    let feed = Feed::parse(&text, &raw.platform, is_loopback(&raw.url))?;
    if !PLATFORMS.contains(&feed.platform.as_str()) {
        bail!("unknown platform {}", feed.platform);
    }
    let archive = Path::new(options.required("archive")?);
    if archive.file_name().and_then(|n| n.to_str()) != Some(feed.archive_name().as_str()) {
        bail!("the feed names {}", feed.archive_name());
    }
    let bytes = std::fs::read(archive).with_context(|| format!("reading {}", archive.display()))?;
    if bytes.len() as u64 != feed.size {
        bail!(
            "the archive is {} bytes; the feed says {}",
            bytes.len(),
            feed.size
        );
    }
    if !hex::encode(sha2::Sha256::digest(&bytes)).eq_ignore_ascii_case(&feed.sha256) {
        bail!("the archive's SHA-256 does not match the feed");
    }
    let key = match options.optional("public-key") {
        Some(key) => PublicKey::from_base64(key)?,
        None => PublicKey::embedded(),
    };
    key.verify(&bytes, &feed.signature)?;
    Ok(format!(
        "{} {} verifies against {}",
        feed.archive_name(),
        feed.version,
        key.to_base64()
    ))
}

fn is_loopback(url: &str) -> bool {
    feed::allowed_url(url, true) && !feed::allowed_url(url, false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine as _;

    fn args(text: &str) -> Vec<String> {
        text.split_whitespace().map(str::to_string).collect()
    }

    #[test]
    fn signs_and_verifies_a_feed() {
        let temp = tempfile::tempdir().unwrap();
        let key_file = temp.path().join("key");
        // A throwaway seed in Sparkle's file format, with a trailing newline.
        std::fs::write(
            &key_file,
            format!(
                "{}\n",
                base64::engine::general_purpose::STANDARD.encode([5u8; 32])
            ),
        )
        .unwrap();
        let public = run(&args(&format!(
            "public-key --key-file {}",
            key_file.display()
        )))
        .unwrap();
        let archive = temp.path().join("LokalBot-0.10.11-windows-x86_64.zip");
        std::fs::write(&archive, b"zip bytes").unwrap();
        let output = temp.path().join("windows-x86_64.json");
        let message = run(&args(&format!(
            "sign --archive {} --platform windows-x86_64 --version 0.10.11 --tag v0.10.11 --key-file {} --expect-public-key {public} --minimum-version 0.10.10 --output {}",
            archive.display(),
            key_file.display(),
            output.display()
        )))
        .unwrap();
        assert!(
            !message.contains(
                &std::fs::read_to_string(&key_file)
                    .unwrap()
                    .trim()
                    .to_string()
            )
        );
        let feed: Feed = serde_json::from_slice(&std::fs::read(&output).unwrap()).unwrap();
        assert_eq!(
            feed.url,
            "https://github.com/stevyhacker/lokalbot/releases/download/v0.10.11/LokalBot-0.10.11-windows-x86_64.zip"
        );
        assert_eq!(
            feed.release_notes_url,
            "https://github.com/stevyhacker/lokalbot/releases/tag/v0.10.11"
        );
        assert_eq!(feed.minimum_version, "0.10.10");
        let verify = format!(
            "verify --feed {} --archive {}",
            output.display(),
            archive.display()
        );
        assert!(run(&args(&format!("{verify} --public-key {public}"))).is_ok());
        // The release key did not sign this.
        assert!(run(&args(&verify)).is_err());
        std::fs::write(&archive, b"zip bytez").unwrap();
        assert!(run(&args(&format!("{verify} --public-key {public}"))).is_err());
    }

    #[test]
    fn refuses_a_key_mismatch_and_misnamed_archives() {
        let temp = tempfile::tempdir().unwrap();
        let key_file = temp.path().join("key");
        std::fs::write(
            &key_file,
            base64::engine::general_purpose::STANDARD.encode([5u8; 32]),
        )
        .unwrap();
        let archive = temp.path().join("LokalBot-0.10.11-linux-x86_64.tar.gz");
        std::fs::write(&archive, b"tar bytes").unwrap();
        let output = temp.path().join("feed.json");
        let sign = |extra: &str, version: &str| {
            run(&args(&format!(
                "sign --archive {} --platform linux-x86_64 --version {version} --tag v{version} --key-file {} --output {} {extra}",
                archive.display(),
                key_file.display(),
                output.display()
            )))
        };
        let error = sign(
            &format!("--expect-public-key {}", lokalbot_update::PUBLIC_KEY),
            "0.10.11",
        )
        .unwrap_err();
        assert!(error.to_string().contains("does not belong"), "{error}");
        assert!(
            sign("", "0.10.12")
                .unwrap_err()
                .to_string()
                .contains("must be named")
        );
        assert!(!output.exists());
        assert!(sign("", "0.10.11").is_ok());
    }
}
