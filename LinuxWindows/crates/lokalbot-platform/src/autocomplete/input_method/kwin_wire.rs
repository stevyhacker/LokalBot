//! What LokalBot and its KWin input method helper say to each other.
//!
//! KWin talks `zwp_input_method_v1` only to a program it starts itself and
//! keeps that connection for as long as the program runs. So a small helper
//! (`lokalbot --kwin-input-method`) holds it for the whole session, and the app
//! connects to the helper over a socket in its private runtime folder. Quitting
//! and reopening LokalBot then leaves the desktop's input method in place.
//!
//! One JSON object per line. The helper sends text from around the caret only
//! while the app has asked for it ([`Request::Reading`]), and keeps none of it
//! once sent.

use std::io::{self, Read as _, Write as _};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

use super::super::{AcceptKeys, InterceptedKey};

/// The helper's socket, in LokalBot's private runtime folder.
pub(super) const SOCKET_NAME: &str = "kwin-input-method.sock";
/// Changes whenever a message changes meaning. An app and a helper from
/// different releases (one updated while the other kept running) do not talk.
pub(super) const VERSION: u32 = 1;
/// No message comes close: the longest carries the 4,000 bytes or so of text
/// an app reports around the caret, escaped.
const MAX_LINE: usize = 64 * 1024;
/// Unsent messages beyond this mean the other side stopped reading.
const MAX_OUTBOX: usize = 1024 * 1024;

pub(super) fn socket_path() -> io::Result<PathBuf> {
    Ok(crate::instance::private_runtime_dir()?.join(SOCKET_NAME))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum Key {
    Tab,
    Escape,
    Right,
    Backtick,
}

impl From<InterceptedKey> for Key {
    fn from(key: InterceptedKey) -> Self {
        match key {
            InterceptedKey::Tab => Self::Tab,
            InterceptedKey::Escape => Self::Escape,
            InterceptedKey::RightArrow => Self::Right,
            InterceptedKey::Backtick => Self::Backtick,
        }
    }
}

impl From<Key> for InterceptedKey {
    fn from(key: Key) -> Self {
        match key {
            Key::Tab => Self::Tab,
            Key::Escape => Self::Escape,
            Key::Right => Self::RightArrow,
            Key::Backtick => Self::Backtick,
        }
    }
}

/// From the helper to the app.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub(super) enum Event {
    Hello {
        version: u32,
    },
    /// A text field has focus, or the one in focus may be another now.
    Field,
    /// No text field has focus.
    NoField,
    /// The field's next state. The content type uses `zwp_text_input_v3`'s
    /// numbering; offsets are in bytes.
    State {
        content: Option<(u32, u32)>,
        surrounding: Option<Surrounding>,
    },
    /// An accept key or Esc, taken while a suggestion showed.
    Key {
        key: Key,
    },
    /// Another key went on to the field while a suggestion showed. The helper
    /// took the suggestion out of the field first.
    Passed,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Surrounding {
    pub text: String,
    pub cursor: u32,
    pub anchor: u32,
}

/// From the app to the helper.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "request", rename_all = "snake_case")]
pub(super) enum Request {
    Hello {
        version: u32,
    },
    /// Whether text around the caret may be sent at all.
    Reading {
        on: bool,
    },
    Keys {
        accept: Key,
        full: Option<Key>,
    },
    /// Take the keyboard while a suggestion shows; give it back after.
    Grab {
        on: bool,
    },
    /// Shows `text` as the suggestion, or nothing when empty.
    Preedit {
        text: String,
    },
    /// One accept: removes bytes around the caret, types `text`, then shows
    /// `preedit`.
    Commit {
        delete_before: u32,
        delete_after: u32,
        text: String,
        preedit: String,
    },
    /// Types a taken key after all, because it accepted nothing.
    PassThrough {
        key: Key,
    },
}

impl Request {
    pub(super) fn keys(keys: AcceptKeys) -> Self {
        Self::Keys {
            accept: keys.accept.into(),
            full: keys.full.map(Key::from),
        }
    }
}

pub(super) fn accept_keys(accept: Key, full: Option<Key>) -> AcceptKeys {
    let accept = InterceptedKey::from(accept);
    AcceptKeys {
        accept,
        full: full.map(InterceptedKey::from).filter(|key| *key != accept),
    }
}

/// Lines read from a non-blocking stream as they arrive.
#[derive(Default)]
pub(super) struct Inbox {
    buf: Vec<u8>,
}

impl Inbox {
    /// Reads what is waiting. `Ok(false)` once the other side has closed.
    pub(super) fn fill(&mut self, stream: &mut UnixStream) -> io::Result<bool> {
        let mut chunk = [0u8; 16 * 1024];
        loop {
            match stream.read(&mut chunk) {
                Ok(0) => return Ok(false),
                Ok(n) => {
                    self.buf.extend_from_slice(&chunk[..n]);
                    if self.buf.len() > MAX_LINE && !self.buf.contains(&b'\n') {
                        return Err(io::Error::new(
                            io::ErrorKind::InvalidData,
                            "a message was too long",
                        ));
                    }
                }
                Err(err) if err.kind() == io::ErrorKind::WouldBlock => return Ok(true),
                Err(err) if err.kind() == io::ErrorKind::Interrupted => {}
                Err(err) => return Err(err),
            }
        }
    }

    /// The next complete message, if one has arrived.
    pub(super) fn next<T: DeserializeOwned>(&mut self) -> Option<Result<T, serde_json::Error>> {
        let end = self.buf.iter().position(|b| *b == b'\n')?;
        let line: Vec<u8> = self.buf.drain(..=end).collect();
        Some(serde_json::from_slice(&line[..end]))
    }

    pub(super) fn clear(&mut self) {
        self.buf.clear();
    }
}

/// Messages waiting to go out on a non-blocking stream.
#[derive(Default)]
pub(super) struct Outbox {
    buf: Vec<u8>,
}

impl Outbox {
    pub(super) fn push<T: Serialize>(&mut self, message: &T) {
        if serde_json::to_writer(&mut self.buf, message).is_ok() {
            self.buf.push(b'\n');
        }
    }

    /// Writes what the stream takes now. An error means the link is gone.
    pub(super) fn flush(&mut self, stream: &mut UnixStream) -> io::Result<()> {
        while !self.buf.is_empty() {
            match stream.write(&self.buf) {
                Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
                Ok(n) => {
                    self.buf.drain(..n);
                }
                Err(err) if err.kind() == io::ErrorKind::WouldBlock => break,
                Err(err) if err.kind() == io::ErrorKind::Interrupted => {}
                Err(err) => return Err(err),
            }
        }
        if self.buf.len() > MAX_OUTBOX {
            return Err(io::Error::other("the other side stopped reading"));
        }
        Ok(())
    }

    pub(super) fn is_empty(&self) -> bool {
        self.buf.is_empty()
    }

    pub(super) fn clear(&mut self) {
        self.buf.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pair() -> (UnixStream, UnixStream) {
        let (a, b) = UnixStream::pair().unwrap();
        a.set_nonblocking(true).unwrap();
        b.set_nonblocking(true).unwrap();
        (a, b)
    }

    #[test]
    fn messages_cross_whole_even_when_they_arrive_in_pieces() {
        let (mut app, mut helper) = pair();
        let mut outbox = Outbox::default();
        let sent = Event::State {
            content: Some((0x200, 0)),
            surrounding: Some(Surrounding {
                text: "Hvala, šaljem \"danas\"\nsutra".into(),
                cursor: 7,
                anchor: 7,
            }),
        };
        outbox.push(&sent);
        outbox.push(&Event::Key { key: Key::Tab });
        let bytes = outbox.buf.clone();
        let mut inbox = Inbox::default();
        // Half a line first: nothing is complete yet.
        helper.write_all(&bytes[..10]).unwrap();
        assert!(inbox.fill(&mut app).unwrap());
        assert!(inbox.next::<Event>().is_none());
        helper.write_all(&bytes[10..]).unwrap();
        assert!(inbox.fill(&mut app).unwrap());
        assert_eq!(inbox.next::<Event>().unwrap().unwrap(), sent);
        assert_eq!(
            inbox.next::<Event>().unwrap().unwrap(),
            Event::Key { key: Key::Tab }
        );
        assert!(inbox.next::<Event>().is_none());
        drop(helper);
        assert!(
            !inbox.fill(&mut app).unwrap(),
            "a closed side reads as gone"
        );
    }

    #[test]
    fn an_endless_line_is_refused_rather_than_held() {
        let (mut app, mut helper) = pair();
        let mut inbox = Inbox::default();
        let junk = vec![b'x'; MAX_LINE + 1];
        let mut sent = 0;
        let refused = loop {
            if sent < junk.len() {
                sent += helper.write(&junk[sent..]).unwrap_or(0);
            }
            match inbox.fill(&mut app) {
                Err(err) => break err,
                Ok(_) if sent >= junk.len() => panic!("an endless line was held"),
                Ok(_) => {}
            }
        };
        assert_eq!(refused.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn requests_name_their_kind() {
        let mut outbox = Outbox::default();
        outbox.push(&Request::Commit {
            delete_before: 3,
            delete_after: 0,
            text: " up".into(),
            preedit: " on it".into(),
        });
        let line = String::from_utf8(outbox.buf.clone()).unwrap();
        // Key order is serde's business; what matters is the tag and the trip.
        assert!(line.contains("\"request\":\"commit\""), "{line}");
        assert!(line.ends_with('\n'));
        let mut inbox = Inbox {
            buf: outbox.buf.clone(),
        };
        assert_eq!(
            inbox.next::<Request>().unwrap().unwrap(),
            Request::Commit {
                delete_before: 3,
                delete_after: 0,
                text: " up".into(),
                preedit: " on it".into(),
            }
        );
    }

    #[test]
    fn accept_keys_survive_the_trip_and_a_doubled_key_counts_once() {
        let keys = AcceptKeys::default();
        let Request::Keys { accept, full } = Request::keys(keys) else {
            unreachable!()
        };
        assert_eq!(accept_keys(accept, full), keys);
        let same = accept_keys(Key::Right, Some(Key::Right));
        assert_eq!(same.accept, InterceptedKey::RightArrow);
        assert_eq!(same.full, None);
    }
}
