//! Splits pi's stdout into JSONL records (`PiJSONLFrameSplitter.swift`).
//!
//! pi's RPC framing (docs/rpc.md): LF (0x0A) is the only record delimiter;
//! one trailing CR is stripped; U+2028/U+2029 inside JSON strings must not
//! split records. That is why this works on raw bytes and why the process
//! reader never uses a string-based line reader.

/// The largest record (and the largest command written to stdin).
pub const MAX_FRAME_BYTES: usize = 4 * 1024 * 1024;

const OVERSIZED: &str =
    r#"{"type":"extension_error","error":"pi RPC frame exceeded the 4 MiB safety limit"}"#;
const INVALID_UTF8: &str =
    r#"{"type":"extension_error","error":"pi RPC frame was not valid UTF-8"}"#;

#[derive(Debug)]
pub struct FrameSplitter {
    buffer: Vec<u8>,
    discarding_oversized: bool,
    maximum: usize,
}

impl Default for FrameSplitter {
    fn default() -> Self {
        Self::new(MAX_FRAME_BYTES)
    }
}

impl FrameSplitter {
    pub fn new(maximum_frame_bytes: usize) -> Self {
        Self {
            buffer: Vec::new(),
            discarding_oversized: false,
            maximum: maximum_frame_bytes.max(1024),
        }
    }

    /// Feeds a chunk; returns every complete record it terminates.
    pub fn append(&mut self, chunk: &[u8]) -> Vec<String> {
        self.buffer.extend_from_slice(chunk);
        let mut lines = Vec::new();
        if self.discarding_oversized {
            let Some(lf) = self.buffer.iter().position(|b| *b == b'\n') else {
                self.buffer.clear();
                return lines;
            };
            self.buffer.drain(..=lf);
            self.discarding_oversized = false;
        }
        let mut start = 0;
        while let Some(offset) = self.buffer[start..].iter().position(|b| *b == b'\n') {
            let end = start + offset;
            let mut record = &self.buffer[start..end];
            if record.last() == Some(&b'\r') {
                record = &record[..record.len() - 1];
            }
            if record.len() > self.maximum {
                lines.push(OVERSIZED.to_string());
            } else if !record.is_empty() {
                match std::str::from_utf8(record) {
                    Ok(line) => lines.push(line.to_string()),
                    Err(_) => lines.push(INVALID_UTF8.to_string()),
                }
            }
            start = end + 1;
        }
        self.buffer.drain(..start);
        if self.buffer.len() > self.maximum {
            self.buffer.clear();
            self.discarding_oversized = true;
            lines.push(OVERSIZED.to_string());
        }
        lines
    }

    /// Drains an unterminated final record (call on EOF).
    pub fn flush(&mut self) -> Option<String> {
        let buffer = std::mem::take(&mut self.buffer);
        if std::mem::take(&mut self.discarding_oversized) {
            return None;
        }
        if buffer.len() > self.maximum {
            return Some(OVERSIZED.to_string());
        }
        if buffer.is_empty() {
            return None;
        }
        Some(match String::from_utf8(buffer) {
            Ok(line) => line,
            Err(_) => INVALID_UTF8.to_string(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_on_lf_only() {
        let mut splitter = FrameSplitter::default();
        assert_eq!(
            splitter.append(b"{\"a\":1}\n{\"b\":2}\n"),
            vec!["{\"a\":1}", "{\"b\":2}"]
        );
    }

    #[test]
    fn does_not_split_on_unicode_line_separators() {
        let mut splitter = FrameSplitter::default();
        let record = "{\"text\":\"one\u{2028}two\u{2029}three\"}";
        assert_eq!(
            splitter.append(format!("{record}\n").as_bytes()),
            vec![record]
        );
    }

    #[test]
    fn strips_single_trailing_cr() {
        let mut splitter = FrameSplitter::default();
        assert_eq!(splitter.append(b"{\"a\":1}\r\n"), vec!["{\"a\":1}"]);
    }

    #[test]
    fn reassembles_records_across_chunks() {
        let mut splitter = FrameSplitter::default();
        // Split mid-record and mid-UTF-8 sequence (é is two bytes).
        let full = "{\"text\":\"café\"}\n".as_bytes();
        let mut collected = Vec::new();
        collected.extend(splitter.append(&full[..5]));
        collected.extend(splitter.append(&full[5..14]));
        collected.extend(splitter.append(&full[14..]));
        assert_eq!(collected, vec!["{\"text\":\"café\"}"]);
    }

    #[test]
    fn flush_returns_unterminated_remainder() {
        let mut splitter = FrameSplitter::default();
        assert!(splitter.append(b"{\"a\":1}").is_empty());
        assert_eq!(splitter.flush().as_deref(), Some("{\"a\":1}"));
        assert_eq!(splitter.flush(), None);
    }

    #[test]
    fn skips_empty_lines() {
        let mut splitter = FrameSplitter::default();
        assert_eq!(splitter.append(b"\n\n{\"a\":1}\n\n"), vec!["{\"a\":1}"]);
    }

    #[test]
    fn oversized_frame_is_discarded_and_following_frame_survives() {
        let mut splitter = FrameSplitter::new(1024);
        let oversized = "x".repeat(2000);
        let lines = splitter.append(format!("{oversized}\n{{\"ok\":true}}\n").as_bytes());
        assert_eq!(lines.len(), 2);
        assert!(lines[0].contains("safety limit"));
        assert_eq!(lines[1], r#"{"ok":true}"#);
    }

    #[test]
    fn oversized_unterminated_frame_is_dropped_until_its_end() {
        let mut splitter = FrameSplitter::new(1024);
        let lines = splitter.append("y".repeat(1500).as_bytes());
        assert_eq!(lines.len(), 1);
        assert!(splitter.append(b"tail of the big one\n{\"ok\":1}\n") == vec![r#"{"ok":1}"#]);
    }

    #[test]
    fn invalid_utf8_becomes_protocol_error_frame() {
        let mut splitter = FrameSplitter::default();
        assert!(splitter.append(&[0xFF, 0x0A])[0].contains("valid UTF-8"));
    }
}
