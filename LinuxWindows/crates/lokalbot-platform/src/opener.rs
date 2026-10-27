//! Opening files, folders and links with the user's default apps, and showing
//! a file in the file manager ("Show in Files" / "Show in Explorer").

use std::path::Path;

use anyhow::Context as _;

/// Opens a file or folder in its default app.
pub fn open_path(path: &Path) -> anyhow::Result<()> {
    open::that_detached(path).with_context(|| format!("could not open {}", path.display()))
}

/// Opens a web or mail link in the default browser or mail app. Other
/// schemes are refused, so text from meetings or models cannot launch
/// arbitrary handlers.
pub fn open_url(url: &str) -> anyhow::Result<()> {
    let parsed = url::Url::parse(url).context("not a link")?;
    anyhow::ensure!(
        matches!(parsed.scheme(), "http" | "https" | "mailto"),
        "LokalBot only opens web and mail links"
    );
    open::that_detached(parsed.as_str()).context("could not open the link")
}

/// Shows `path` selected in the file manager, or opens its folder when the
/// file manager cannot select items.
pub fn reveal_in_file_manager(path: &Path) -> anyhow::Result<()> {
    anyhow::ensure!(path.exists(), "{} does not exist", path.display());
    if reveal(path).is_ok() {
        return Ok(());
    }
    let folder = if path.is_dir() {
        path
    } else {
        path.parent().unwrap_or(path)
    };
    open_path(folder)
}

#[cfg(target_os = "linux")]
fn reveal(path: &Path) -> anyhow::Result<()> {
    let absolute = std::path::absolute(path)?;
    let uri = url::Url::from_file_path(&absolute)
        .map_err(|()| anyhow::anyhow!("not a local path"))?
        .to_string();
    let bus = zbus::blocking::connection::Builder::session()?
        .method_timeout(std::time::Duration::from_secs(3))
        .build()?;
    bus.call_method(
        Some("org.freedesktop.FileManager1"),
        "/org/freedesktop/FileManager1",
        Some("org.freedesktop.FileManager1"),
        "ShowItems",
        &(vec![uri], ""),
    )?;
    Ok(())
}

#[cfg(windows)]
fn reveal(path: &Path) -> anyhow::Result<()> {
    use std::os::windows::process::CommandExt as _;

    let absolute = std::path::absolute(path)?;
    // explorer.exe parses its own command line: the path must follow
    // "/select," inside quotes, so the argument is passed verbatim.
    std::process::Command::new("explorer.exe")
        .raw_arg(format!("/select,\"{}\"", absolute.display()))
        .spawn()?;
    Ok(())
}

#[cfg(not(any(windows, target_os = "linux")))]
fn reveal(_: &Path) -> anyhow::Result<()> {
    anyhow::bail!("no file manager integration")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_web_and_mail_links_open() {
        assert!(open_url("file:///etc/passwd").is_err());
        assert!(open_url("javascript:alert(1)").is_err());
        assert!(open_url("not a url").is_err());
    }
}
