use crate::{
    SyncError, generate_static_key, key_fingerprint, parse_pairing_payload, protocol_version,
    public_key_for,
};

#[test]
fn generated_keys_match_their_public_half() {
    let key = generate_static_key();
    assert_eq!(key.private_key.len(), 32);
    assert_eq!(key.public_key.len(), 32);
    assert_eq!(
        public_key_for(key.private_key.clone()).unwrap(),
        key.public_key
    );
    assert_ne!(generate_static_key().private_key, key.private_key);
}

#[test]
fn public_key_follows_rfc_7748() {
    // RFC 7748 section 6.1, Alice.
    let private =
        hex::decode("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a").unwrap();
    let public =
        hex::decode("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a").unwrap();
    assert_eq!(public_key_for(private).unwrap(), public);
}

#[test]
fn public_key_rejects_wrong_lengths() {
    assert!(matches!(
        public_key_for(vec![1; 31]),
        Err(SyncError::InvalidInput(_))
    ));
    assert!(matches!(
        public_key_for(Vec::new()),
        Err(SyncError::InvalidInput(_))
    ));
}

#[test]
fn fingerprint_is_sixteen_hex_characters_of_sha256() {
    // SHA-256 of 32 zero bytes starts 66687aadf862bd77.
    assert_eq!(key_fingerprint(vec![0; 32]), "66687aadf862bd77");
    let fingerprint = key_fingerprint(generate_static_key().public_key);
    assert_eq!(fingerprint.len(), 16);
    assert!(
        fingerprint
            .chars()
            .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
    );
}

#[test]
fn protocol_version_is_one() {
    assert_eq!(protocol_version(), 1);
}

#[test]
fn pairing_payload_round_trips_without_revealing_the_secret() {
    let host = super::Host::empty();
    let offer = host.server.begin_pairing(vec![
        "192.168.1.20".into(),
        "macbook.tail1234.ts.net".into(),
    ]);
    assert!(offer.qr_payload.starts_with("lokalbot://pair?d="));
    let info = parse_pairing_payload(offer.qr_payload.clone()).unwrap();
    assert_eq!(info.mac_name, "Test Mac");
    assert_eq!(info.addresses, ["192.168.1.20", "macbook.tail1234.ts.net"]);
    assert_eq!(info.port, host.server.bound_port());
    assert_eq!(info.expires_at, offer.expires_at);
    assert_eq!(
        crate::keys::b64url_decode(&info.mac_key_b64).unwrap(),
        host.server.public_key().to_vec()
    );

    // The JSON inside uses the documented keys.
    let data = offer.qr_payload.strip_prefix("lokalbot://pair?d=").unwrap();
    let json: serde_json::Value =
        serde_json::from_slice(&crate::keys::b64url_decode(data).unwrap()).unwrap();
    let keys: Vec<&str> = json
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    for key in [
        "v", "macName", "macKey", "addrs", "port", "pid", "psk", "exp",
    ] {
        assert!(keys.contains(&key), "missing {key}");
    }
    assert_eq!(json["v"], 1);
    assert_eq!(json["pid"].as_str().unwrap(), offer.pairing_id);
    assert_eq!(
        crate::keys::b64url_decode(json["psk"].as_str().unwrap())
            .unwrap()
            .len(),
        32
    );
}

#[test]
fn malformed_pairing_payloads_are_invalid_input() {
    for payload in [
        "",
        "https://example.com",
        "lokalbot://pair?d=",
        "lokalbot://pair?d=!!!",
        "lokalbot://pair?x=1",
    ] {
        assert!(
            matches!(
                parse_pairing_payload(payload.into()),
                Err(SyncError::InvalidInput(_))
            ),
            "{payload}"
        );
    }
    let future = serde_json::json!({
        "v": 2, "macName": "M", "macKey": crate::keys::b64url(&[1; 32]), "addrs": [], "port": 1,
        "pid": crate::keys::b64url(&[2; 16]), "psk": crate::keys::b64url(&[3; 32]), "exp": 1
    });
    let payload = format!(
        "lokalbot://pair?d={}",
        crate::keys::b64url(future.to_string().as_bytes())
    );
    assert!(matches!(
        parse_pairing_payload(payload),
        Err(SyncError::InvalidInput(_))
    ));
}
