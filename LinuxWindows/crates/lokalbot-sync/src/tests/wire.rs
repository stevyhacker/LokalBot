use std::io::Cursor;
use std::net::{TcpListener, TcpStream};
use std::time::Duration;

use serde_json::json;

use super::fast_tuning;
use crate::keys::key_array;
use crate::messages::Message;
use crate::wire::{
    FrameAssembler, MAX_FRAME_PAYLOAD, PacketReader, RawConn, encode_packet, pairing_handshake,
    parse_message, session_handshake, split_frames,
};
use crate::{SyncError, generate_static_key};

#[test]
fn packets_are_length_prefixed_and_split_from_a_stream() {
    let mut stream = Vec::new();
    stream.extend(encode_packet(b"one").unwrap());
    stream.extend(encode_packet(b"").unwrap());
    stream.extend(encode_packet(&[7u8; 65_535]).unwrap());
    assert_eq!(&stream[..5], &[0, 3, b'o', b'n', b'e']);
    let mut reader = PacketReader::default();
    let mut source = Cursor::new(stream);
    assert_eq!(reader.read(&mut source).unwrap().unwrap(), b"one");
    assert_eq!(reader.read(&mut source).unwrap().unwrap(), b"");
    assert_eq!(
        reader.read(&mut source).unwrap().unwrap(),
        vec![7u8; 65_535]
    );
    // The stream ended.
    assert!(reader.read(&mut source).is_err());
    assert!(encode_packet(&[0; 65_536]).is_err());
}

#[test]
fn a_partial_packet_survives_a_read_timeout() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let mut writer = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
    let (mut reader_stream, _) = listener.accept().unwrap();
    reader_stream
        .set_read_timeout(Some(Duration::from_millis(50)))
        .unwrap();
    let packet = encode_packet(b"hello world").unwrap();
    use std::io::Write as _;
    writer.write_all(&packet[..4]).unwrap();
    let mut reader = PacketReader::default();
    assert_eq!(reader.read(&mut reader_stream).unwrap(), None);
    writer.write_all(&packet[4..]).unwrap();
    let mut got = None;
    for _ in 0..40 {
        got = reader.read(&mut reader_stream).unwrap();
        if got.is_some() {
            break;
        }
    }
    assert_eq!(got.unwrap(), b"hello world");
}

#[test]
fn messages_split_into_frames_of_at_most_60000_bytes() {
    let small = split_frames(b"{\"type\":\"ping\"}");
    assert_eq!(small.len(), 1);
    assert_eq!(small[0][0], 0);

    let message: Vec<u8> = (0..150_000u32).map(|i| (i % 251) as u8).collect();
    let frames = split_frames(&message);
    assert_eq!(frames.len(), 3);
    assert_eq!(frames.iter().map(|f| f[0]).collect::<Vec<_>>(), [1, 1, 0]);
    assert_eq!(
        frames.iter().map(|f| f.len() - 1).collect::<Vec<_>>(),
        [MAX_FRAME_PAYLOAD, MAX_FRAME_PAYLOAD, 30_000]
    );
    let exact = split_frames(&vec![1u8; MAX_FRAME_PAYLOAD]);
    assert_eq!(exact.len(), 1);

    let mut assembler = FrameAssembler::default();
    assert_eq!(assembler.push(&frames[0]).unwrap(), None);
    assert_eq!(assembler.push(&frames[1]).unwrap(), None);
    assert_eq!(assembler.push(&frames[2]).unwrap().unwrap(), message);
    // The assembler starts over for the next message.
    assert_eq!(
        assembler.push(&small[0]).unwrap().unwrap(),
        b"{\"type\":\"ping\"}"
    );
}

#[test]
fn malformed_frames_are_protocol_errors() {
    let mut assembler = FrameAssembler::default();
    assert!(matches!(assembler.push(&[]), Err(SyncError::Protocol(_))));
    let mut oversized = vec![0u8];
    oversized.extend(vec![0u8; MAX_FRAME_PAYLOAD + 1]);
    assert!(matches!(
        assembler.push(&oversized),
        Err(SyncError::Protocol(_))
    ));
    assert!(matches!(
        parse_message(b"not json"),
        Err(SyncError::Protocol(_))
    ));
}

#[test]
fn unknown_message_types_and_fields_are_ignored() {
    assert_eq!(
        parse_message(br#"{"type":"futureThing","x":1}"#).unwrap(),
        Message::Unknown
    );
    assert_eq!(
        parse_message(br#"{"type":"ping","extra":true}"#).unwrap(),
        Message::Ping
    );
    let hello = parse_message(
        br#"{"type":"hello","protocolVersion":1,"schemaVersion":1,"deviceId":"d","cursor":7,"purpose":"ask","new":[]}"#,
    )
    .unwrap();
    assert_eq!(
        hello,
        Message::Hello {
            protocol_version: 1,
            schema_version: 1,
            device_id: "d".into(),
            cursor: 7,
            purpose: "ask".into(),
        }
    );
    let json = serde_json::to_value(Message::OpResult {
        op_id: "o".into(),
        status: "applied".into(),
        message: None,
    })
    .unwrap();
    assert_eq!(
        json,
        json!({ "type": "opResult", "opId": "o", "status": "applied" })
    );
    let json = serde_json::to_value(Message::Welcome {
        mac_name: "M".into(),
        server_time: "t".into(),
        manifest: None,
    })
    .unwrap();
    assert_eq!(
        json,
        json!({ "type": "welcome", "macName": "M", "serverTime": "t", "manifest": null })
    );
}

/// A connected pair of encrypted channels over loopback.
fn session_pair() -> (
    (std::sync::Arc<crate::wire::Channel>, crate::wire::Inbox),
    (std::sync::Arc<crate::wire::Channel>, crate::wire::Inbox),
) {
    let tuning = fast_tuning();
    let mac = generate_static_key();
    let phone = generate_static_key();
    let mac_private = key_array(&mac.private_key, "k").unwrap();
    let mac_public = key_array(&mac.public_key, "k").unwrap();
    let phone_private = key_array(&phone.private_key, "k").unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let responder = {
        let tuning = tuning.clone();
        std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut conn = RawConn::new(stream, &tuning).unwrap();
            let mut handshake = session_handshake(&mac_private, None).unwrap();
            conn.read_handshake(&mut handshake).unwrap();
            conn.write_handshake(&mut handshake).unwrap();
            conn.into_channel(handshake.into_transport_mode().unwrap())
                .unwrap()
        })
    };
    let mut conn = RawConn::new(TcpStream::connect(address).unwrap(), &tuning).unwrap();
    let mut handshake = session_handshake(&phone_private, Some(&mac_public)).unwrap();
    conn.write_handshake(&mut handshake).unwrap();
    conn.read_handshake(&mut handshake).unwrap();
    let phone_side = conn
        .into_channel(handshake.into_transport_mode().unwrap())
        .unwrap();
    (phone_side, responder.join().unwrap())
}

#[test]
fn encrypted_channels_carry_multi_frame_messages() {
    let tuning = fast_tuning();
    let ((phone, mut phone_inbox), (mac, mut mac_inbox)) = session_pair();
    let big = "x".repeat(200_000);
    let request = json!({ "requestId": "r", "question": big });
    phone
        .send(&Message::Ask {
            request: request.clone(),
        })
        .unwrap();
    phone.send(&Message::Ping).unwrap();
    assert_eq!(
        mac_inbox.recv(&mac, &tuning, None).unwrap(),
        Message::Ask { request }
    );
    assert_eq!(mac_inbox.recv(&mac, &tuning, None).unwrap(), Message::Ping);

    mac.send(&Message::Revoked).unwrap();
    assert_eq!(
        phone_inbox.recv(&phone, &tuning, None).unwrap(),
        Message::Revoked
    );

    mac.close();
    assert!(phone_inbox.recv(&phone, &tuning, None).is_err());
    assert!(mac.send(&Message::Ping).is_err());
}

#[test]
fn transport_messages_cannot_be_replayed_or_altered() {
    let mac = generate_static_key();
    let phone = generate_static_key();
    let mac_private = key_array(&mac.private_key, "k").unwrap();
    let mac_public = key_array(&mac.public_key, "k").unwrap();
    let phone_private = key_array(&phone.private_key, "k").unwrap();
    let mut initiator = session_handshake(&phone_private, Some(&mac_public)).unwrap();
    let mut responder = session_handshake(&mac_private, None).unwrap();
    let mut buffer = vec![0u8; 65_535];
    let mut scratch = vec![0u8; 65_535];
    let n = initiator.write_message(&[], &mut buffer).unwrap();
    responder.read_message(&buffer[..n], &mut scratch).unwrap();
    let n = responder.write_message(&[], &mut buffer).unwrap();
    initiator.read_message(&buffer[..n], &mut scratch).unwrap();
    let mut sender = initiator.into_transport_mode().unwrap();
    let mut receiver = responder.into_transport_mode().unwrap();

    let n = sender.write_message(b"\x00first", &mut buffer).unwrap();
    let first = buffer[..n].to_vec();
    let n = sender.write_message(b"\x00second", &mut buffer).unwrap();
    let second = buffer[..n].to_vec();

    assert!(receiver.read_message(&first, &mut scratch).is_ok());
    // A replay of the first message fails: the nonce has moved on.
    assert!(receiver.read_message(&first, &mut scratch).is_err());

    // One flipped bit fails authentication; the genuine message still reads.
    let mut tampered = second.clone();
    tampered[3] ^= 1;
    assert!(receiver.read_message(&tampered, &mut scratch).is_err());
    let n = receiver.read_message(&second, &mut scratch).unwrap();
    assert_eq!(&scratch[..n], b"\x00second");
}

#[test]
fn a_pairing_handshake_with_the_wrong_psk_fails_on_the_mac() {
    let mac = generate_static_key();
    let phone = generate_static_key();
    let mac_private = key_array(&mac.private_key, "k").unwrap();
    let phone_private = key_array(&phone.private_key, "k").unwrap();
    let mut initiator = pairing_handshake(true, &phone_private, &[1; 32]).unwrap();
    let mut responder = pairing_handshake(false, &mac_private, &[2; 32]).unwrap();
    let mut buffer = vec![0u8; 65_535];
    let mut scratch = vec![0u8; 65_535];
    let n = initiator.write_message(&[], &mut buffer).unwrap();
    responder.read_message(&buffer[..n], &mut scratch).unwrap();
    let n = responder.write_message(&[], &mut buffer).unwrap();
    initiator.read_message(&buffer[..n], &mut scratch).unwrap();
    // The phone learns the Mac's key before it sends its own.
    assert_eq!(initiator.get_remote_static().unwrap(), &mac.public_key[..]);
    let n = initiator.write_message(&[], &mut buffer).unwrap();
    assert!(responder.read_message(&buffer[..n], &mut scratch).is_err());
}
