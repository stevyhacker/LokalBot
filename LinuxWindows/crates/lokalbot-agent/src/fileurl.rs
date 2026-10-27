//! `file://` URLs as Swift's `JSONEncoder` writes `URL` values, so task
//! metadata written by the Mac app reads here and the other way round.

use std::path::{Path, PathBuf};

/// `file:///home/me/Work%20Folder/` (directories end in `/`, like
/// `URL(fileURLWithPath:)` for an existing folder).
pub fn to_file_url(path: &Path, is_directory: bool) -> String {
    let text = path.to_string_lossy().replace('\\', "/");
    let mut encoded = String::with_capacity(text.len() + 8);
    encoded.push_str("file://");
    if !text.starts_with('/') {
        encoded.push('/'); // `C:/…` on Windows
    }
    for byte in text.bytes() {
        let keep = byte.is_ascii_alphanumeric() || b"-._~/!$&'()*+,;=:@".contains(&byte);
        if keep {
            encoded.push(byte as char);
        } else {
            encoded.push_str(&format!("%{byte:02X}"));
        }
    }
    if is_directory && !encoded.ends_with('/') {
        encoded.push('/');
    }
    encoded
}

/// The path of a `file://` URL; a plain absolute path is accepted too.
pub fn from_file_url(value: &str) -> Option<PathBuf> {
    let Some(rest) = value.strip_prefix("file://") else {
        let path = PathBuf::from(value);
        return path.is_absolute().then_some(path);
    };
    // `file://localhost/…` is the same as `file:///…`.
    let rest = rest.strip_prefix("localhost").unwrap_or(rest);
    let decoded = percent_decode(rest)?;
    let mut text = decoded;
    if text.len() > 1 && text.ends_with('/') {
        text.pop();
    }
    if cfg!(windows) {
        // `/C:/Users/…` → `C:\Users\…`
        let bytes = text.as_bytes();
        if bytes.len() >= 3 && bytes[0] == b'/' && bytes[2] == b':' {
            text.remove(0);
        }
        return Some(PathBuf::from(text.replace('/', "\\")));
    }
    Some(PathBuf::from(text))
}

fn percent_decode(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let hex = text.get(index + 1..index + 3)?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            index += 3;
        } else {
            out.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(out).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn round_trips_unix_paths_like_swift() {
        let url = to_file_url(Path::new("/home/me/Work Folder/é"), true);
        assert_eq!(url, "file:///home/me/Work%20Folder/%C3%A9/");
        assert_eq!(
            from_file_url(&url).unwrap(),
            PathBuf::from("/home/me/Work Folder/é")
        );
        assert_eq!(
            from_file_url("file:///Users/me/LokalBot/agent/sessions/a.jsonl").unwrap(),
            PathBuf::from("/Users/me/LokalBot/agent/sessions/a.jsonl")
        );
        assert_eq!(
            from_file_url("/plain/path").unwrap(),
            PathBuf::from("/plain/path")
        );
        assert_eq!(from_file_url("relative"), None);
        assert_eq!(from_file_url("file:///bad%zz"), None);
    }

    #[cfg(windows)]
    #[test]
    fn round_trips_windows_paths() {
        let url = to_file_url(Path::new(r"C:\Users\me\Work Folder"), true);
        assert_eq!(url, "file:///C:/Users/me/Work%20Folder/");
        assert_eq!(
            from_file_url(&url).unwrap(),
            PathBuf::from(r"C:\Users\me\Work Folder")
        );
    }
}
