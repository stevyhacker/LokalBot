//! Bytes on the socket (protocol.md, Framing; Keys and Noise): length-prefixed
//! packets, the plaintext preface, Noise handshakes, and encrypted frames that
//! carry one JSON message each.

use std::io::{self, Read, Write};
use std::net::{Shutdown, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use parking_lot::Mutex;
use snow::{Builder, HandshakeState, TransportState};

use crate::error::{Result, SyncError};
use crate::keys::KEY_LEN;
use crate::messages::Message;

pub(crate) const PROTOCOL_VERSION: u32 = 1;
pub(crate) const SCHEMA_VERSION: u32 = 1;

pub(crate) const PROLOGUE: &[u8] = b"lokalbot-companion/1";
pub(crate) const PAIRING_PATTERN: &str = "Noise_XXpsk3_25519_ChaChaPoly_BLAKE2s";
pub(crate) const SESSION_PATTERN: &str = "Noise_IK_25519_ChaChaPoly_BLAKE2s";

pub(crate) const PREFACE_PAIRING: u8 = 0x01;
pub(crate) const PREFACE_SESSION: u8 = 0x02;
pub(crate) const PAIRING_ID_LEN: usize = 16;

pub(crate) const MAX_PACKET: usize = u16::MAX as usize;
pub(crate) const MAX_FRAME_PAYLOAD: usize = 60_000;
/// Largest message either side assembles from frames.
pub(crate) const MAX_MESSAGE: usize = 64 * 1024 * 1024;
const FLAG_MORE: u8 = 0x01;
/// ChaChaPoly's authentication tag.
const TAG_LEN: usize = 16;

/// Timings and sizes. The defaults are the protocol's; tests shorten them.
#[derive(Clone, Debug)]
pub(crate) struct Tuning {
    pub ping_interval: Duration,
    pub idle_timeout: Duration,
    pub connect_timeout: Duration,
    pub handshake_timeout: Duration,
    pub approval_timeout: Duration,
    /// How long a phone waits for the next part of an answer.
    pub ask_timeout: Duration,
    /// Seconds a pairing offer stays valid.
    pub offer_lifetime_secs: i64,
    pub batch_bytes: usize,
}

impl Default for Tuning {
    fn default() -> Self {
        Self {
            ping_interval: Duration::from_secs(20),
            idle_timeout: Duration::from_secs(60),
            connect_timeout: Duration::from_secs(2),
            handshake_timeout: Duration::from_secs(10),
            approval_timeout: Duration::from_secs(120),
            ask_timeout: Duration::from_secs(600),
            offer_lifetime_secs: 5 * 60,
            batch_bytes: 512 * 1024,
        }
    }
}

impl Tuning {
    /// How often a blocked read wakes up to send pings and check timeouts.
    pub fn tick(&self) -> Duration {
        (self.ping_interval / 4).clamp(Duration::from_millis(20), Duration::from_secs(5))
    }
}

/// A 2-byte big-endian length followed by the bytes.
pub(crate) fn encode_packet(data: &[u8]) -> io::Result<Vec<u8>> {
    let len = u16::try_from(data.len()).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "packet longer than 65535 bytes",
        )
    })?;
    let mut packet = Vec::with_capacity(2 + data.len());
    packet.extend_from_slice(&len.to_be_bytes());
    packet.extend_from_slice(data);
    Ok(packet)
}

/// Splits packets off a byte stream. A read timeout returns `None` and keeps
/// any partial packet, so callers can wake up periodically without losing
/// their place.
#[derive(Default)]
pub(crate) struct PacketReader {
    buffer: Vec<u8>,
}

impl PacketReader {
    pub fn read(&mut self, source: &mut impl Read) -> io::Result<Option<Vec<u8>>> {
        let mut chunk = [0u8; 16 * 1024];
        loop {
            if self.buffer.len() >= 2 {
                let len = usize::from(u16::from_be_bytes([self.buffer[0], self.buffer[1]]));
                if self.buffer.len() >= 2 + len {
                    let packet = self.buffer[2..2 + len].to_vec();
                    self.buffer.drain(..2 + len);
                    return Ok(Some(packet));
                }
            }
            match source.read(&mut chunk) {
                Ok(0) => {
                    return Err(io::Error::new(
                        io::ErrorKind::UnexpectedEof,
                        "the connection closed",
                    ));
                }
                Ok(n) => self.buffer.extend_from_slice(&chunk[..n]),
                Err(e)
                    if matches!(
                        e.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                    ) =>
                {
                    return Ok(None);
                }
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(e) => return Err(e),
            }
        }
    }
}

/// A message's frames: flag byte (bit 0 = more follow) plus at most
/// [`MAX_FRAME_PAYLOAD`] bytes each.
pub(crate) fn split_frames(message: &[u8]) -> Vec<Vec<u8>> {
    let chunks: Vec<&[u8]> = if message.is_empty() {
        vec![&[]]
    } else {
        message.chunks(MAX_FRAME_PAYLOAD).collect()
    };
    let last = chunks.len() - 1;
    chunks
        .into_iter()
        .enumerate()
        .map(|(i, chunk)| {
            let mut frame = Vec::with_capacity(1 + chunk.len());
            frame.push(if i < last { FLAG_MORE } else { 0 });
            frame.extend_from_slice(chunk);
            frame
        })
        .collect()
}

/// Joins frames back into messages.
#[derive(Default)]
pub(crate) struct FrameAssembler {
    pending: Vec<u8>,
}

impl FrameAssembler {
    /// The finished message once a frame without the "more" flag arrives.
    pub fn push(&mut self, frame: &[u8]) -> Result<Option<Vec<u8>>> {
        let Some((&flag, payload)) = frame.split_first() else {
            return Err(SyncError::protocol("An empty frame arrived."));
        };
        if payload.len() > MAX_FRAME_PAYLOAD {
            return Err(SyncError::protocol("A frame was larger than 60000 bytes."));
        }
        if self.pending.len() + payload.len() > MAX_MESSAGE {
            return Err(SyncError::protocol("A message was larger than the limit."));
        }
        self.pending.extend_from_slice(payload);
        if flag & FLAG_MORE != 0 {
            Ok(None)
        } else {
            Ok(Some(std::mem::take(&mut self.pending)))
        }
    }
}

pub(crate) fn parse_message(bytes: &[u8]) -> Result<Message> {
    serde_json::from_slice(bytes)
        .map_err(|e| SyncError::protocol(format!("Unreadable message: {e}")))
}

/// A connection before its Noise transport exists: the preface and the
/// handshake messages, one per packet.
pub(crate) struct RawConn {
    stream: TcpStream,
    packets: PacketReader,
    tuning: Tuning,
}

impl RawConn {
    pub fn new(stream: TcpStream, tuning: &Tuning) -> Result<Self> {
        stream.set_nonblocking(false)?;
        stream.set_nodelay(true)?;
        stream.set_read_timeout(Some(tuning.tick()))?;
        stream.set_write_timeout(Some(tuning.idle_timeout))?;
        Ok(Self {
            stream,
            packets: PacketReader::default(),
            tuning: tuning.clone(),
        })
    }

    pub fn send_packet(&mut self, data: &[u8]) -> Result<()> {
        self.stream.write_all(&encode_packet(data)?)?;
        Ok(())
    }

    /// The next packet, waiting at most the handshake timeout.
    pub fn recv_packet(&mut self) -> Result<Vec<u8>> {
        let deadline = Instant::now() + self.tuning.handshake_timeout;
        loop {
            if let Some(packet) = self.packets.read(&mut self.stream)? {
                return Ok(packet);
            }
            if Instant::now() >= deadline {
                return Err(SyncError::io(
                    "The other side stopped answering during the handshake.",
                ));
            }
        }
    }

    /// Writes the next handshake message.
    pub fn write_handshake(&mut self, handshake: &mut HandshakeState) -> Result<()> {
        let mut buffer = vec![0u8; MAX_PACKET];
        let len = handshake.write_message(&[], &mut buffer)?;
        self.send_packet(&buffer[..len])
    }

    /// Reads and processes the next handshake message.
    pub fn read_handshake(&mut self, handshake: &mut HandshakeState) -> Result<()> {
        let packet = self.recv_packet()?;
        let mut buffer = vec![0u8; MAX_PACKET];
        handshake.read_message(&packet, &mut buffer)?;
        Ok(())
    }

    pub fn into_channel(
        self,
        transport: TransportState,
    ) -> Result<(std::sync::Arc<Channel>, Inbox)> {
        let reader = self.stream.try_clone()?;
        let writer = self.stream.try_clone()?;
        let channel = std::sync::Arc::new(Channel {
            stream: self.stream,
            writer: Mutex::new(writer),
            transport: Mutex::new(transport),
            last_sent: Mutex::new(Instant::now()),
            closed: AtomicBool::new(false),
        });
        let inbox = Inbox {
            stream: reader,
            packets: self.packets,
            frames: FrameAssembler::default(),
            last_received: Instant::now(),
        };
        Ok((channel, inbox))
    }
}

pub(crate) fn pairing_handshake(
    initiator: bool,
    private_key: &[u8; KEY_LEN],
    psk: &[u8; KEY_LEN],
) -> Result<HandshakeState> {
    let builder = Builder::new(PAIRING_PATTERN.parse()?)
        .local_private_key(private_key)?
        .psk(3, psk)?
        .prologue(PROLOGUE)?;
    Ok(if initiator {
        builder.build_initiator()?
    } else {
        builder.build_responder()?
    })
}

/// The session handshake; the initiator passes the Mac's static key.
pub(crate) fn session_handshake(
    private_key: &[u8; KEY_LEN],
    mac_key: Option<&[u8; KEY_LEN]>,
) -> Result<HandshakeState> {
    let builder = Builder::new(SESSION_PATTERN.parse()?)
        .local_private_key(private_key)?
        .prologue(PROLOGUE)?;
    Ok(match mac_key {
        Some(mac_key) => builder.remote_public_key(mac_key)?.build_initiator()?,
        None => builder.build_responder()?,
    })
}

pub(crate) fn remote_static(handshake: &HandshakeState) -> Result<[u8; KEY_LEN]> {
    let key = handshake
        .get_remote_static()
        .ok_or_else(|| SyncError::crypto("The handshake did not reveal the other side's key."))?;
    crate::keys::key_array(key, "remote static key")
}

/// The sending half of an encrypted connection, shared by every thread that
/// writes to it. A message's frames are written under one lock, so messages
/// from different threads never interleave.
pub(crate) struct Channel {
    stream: TcpStream,
    writer: Mutex<TcpStream>,
    transport: Mutex<TransportState>,
    last_sent: Mutex<Instant>,
    closed: AtomicBool,
}

impl Channel {
    pub fn send(&self, message: &Message) -> Result<()> {
        let json = serde_json::to_vec(message).map_err(|e| SyncError::protocol(e.to_string()))?;
        self.send_json(&json)
    }

    pub fn send_json(&self, json: &[u8]) -> Result<()> {
        if self.is_closed() {
            return Err(SyncError::io("The connection is closed."));
        }
        let mut writer = self.writer.lock();
        let mut ciphertext = vec![0u8; MAX_FRAME_PAYLOAD + 1 + TAG_LEN];
        for frame in split_frames(json) {
            let len = self
                .transport
                .lock()
                .write_message(&frame, &mut ciphertext)?;
            let result =
                encode_packet(&ciphertext[..len]).and_then(|packet| writer.write_all(&packet));
            if let Err(error) = result {
                drop(writer);
                self.close();
                return Err(error.into());
            }
        }
        *self.last_sent.lock() = Instant::now();
        Ok(())
    }

    fn decrypt(&self, packet: &[u8]) -> Result<Vec<u8>> {
        let mut plaintext = vec![0u8; packet.len()];
        let len = self.transport.lock().read_message(packet, &mut plaintext)?;
        plaintext.truncate(len);
        Ok(plaintext)
    }

    pub fn since_last_sent(&self) -> Duration {
        self.last_sent.lock().elapsed()
    }

    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
    }

    /// Shuts the socket down, which also wakes a reader blocked on it.
    pub fn close(&self) {
        if !self.closed.swap(true, Ordering::SeqCst) {
            let _ = self.stream.shutdown(Shutdown::Both);
        }
    }
}

/// The receiving half: packets → decrypted frames → messages.
pub(crate) struct Inbox {
    stream: TcpStream,
    packets: PacketReader,
    frames: FrameAssembler,
    last_received: Instant,
}

impl Inbox {
    /// The next message, or `None` when a read tick passed without one.
    pub fn poll(&mut self, channel: &Channel) -> Result<Option<Message>> {
        loop {
            let Some(packet) = self.packets.read(&mut self.stream)? else {
                return Ok(None);
            };
            self.last_received = Instant::now();
            let frame = channel.decrypt(&packet)?;
            if let Some(message) = self.frames.push(&frame)? {
                return parse_message(&message).map(Some);
            }
        }
    }

    pub fn idle(&self) -> Duration {
        self.last_received.elapsed()
    }

    /// Waits for the next message, sending pings while idle. Fails after the
    /// idle timeout without a packet, or at `deadline`.
    pub fn recv(
        &mut self,
        channel: &Channel,
        tuning: &Tuning,
        deadline: Option<Instant>,
    ) -> Result<Message> {
        loop {
            if let Some(message) = self.poll(channel)? {
                return Ok(message);
            }
            if self.idle() >= tuning.idle_timeout {
                return Err(SyncError::io("The connection went quiet and was closed."));
            }
            if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
                return Err(SyncError::io("Timed out waiting for the other side."));
            }
            if channel.since_last_sent() >= tuning.ping_interval {
                channel.send(&Message::Ping)?;
            }
        }
    }
}
