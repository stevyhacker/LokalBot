use std::sync::atomic::Ordering;
use std::time::Duration;

use serde_json::Value;

use super::{Host, Phone};
use crate::keys::{b64url, b64url_decode};
use crate::{SyncError, parse_pairing_payload};

/// The payload with one JSON field replaced.
fn tampered(payload: &str, field: &str, value: Value) -> String {
    let data = payload.strip_prefix("lokalbot://pair?d=").unwrap();
    let mut json: Value = serde_json::from_slice(&b64url_decode(data).unwrap()).unwrap();
    json[field] = value;
    format!("lokalbot://pair?d={}", b64url(json.to_string().as_bytes()))
}

#[test]
fn pairing_over_loopback() {
    let host = Host::new();
    let phone = Phone::new();
    let payload = host.offer();
    let paired = phone.client.pair(payload.clone()).unwrap();
    assert_eq!(paired.mac_name, "Test Mac");
    assert_eq!(paired.mac_key_b64, b64url(&host.server.public_key()));
    assert_eq!(paired.addresses, ["127.0.0.1"]);
    assert_eq!(paired.port, host.server.bound_port());
    assert_eq!(phone.client.paired_mac().unwrap(), Some(paired));
    assert!(phone.client.status().unwrap().paired);

    let devices = host.server.paired_devices().unwrap();
    assert_eq!(devices.len(), 1);
    assert_eq!(devices[0].device_id, phone.device_id);
    assert_eq!(devices[0].name, "Test iPad");
    assert_eq!(devices[0].platform, "ipados");
    assert_eq!(
        *host.delegate.approvals.lock(),
        [("Test iPad".to_owned(), "ipados".to_owned())]
    );
    assert!(host.delegate.device_changes.load(Ordering::SeqCst) >= 1);

    // The code worked once.
    let again = Phone::new();
    assert!(matches!(
        again.client.pair(payload),
        Err(SyncError::PairingExpired(_))
    ));
    assert_eq!(host.server.paired_devices().unwrap().len(), 1);
}

#[test]
fn a_wrong_secret_fails_and_leaves_the_offer_open() {
    let host = Host::new();
    let payload = host.offer();
    let wrong = tampered(&payload, "psk", Value::String(b64url(&[9; 32])));
    let phone = Phone::new();
    assert!(matches!(
        phone.client.pair(wrong),
        Err(SyncError::PairingExpired(_))
    ));
    assert!(host.server.paired_devices().unwrap().is_empty());
    assert!(host.delegate.approvals.lock().is_empty());
    assert!(!phone.client.status().unwrap().paired);
    // The real code still works.
    phone.client.pair(payload).unwrap();
    assert_eq!(host.server.paired_devices().unwrap().len(), 1);
}

#[test]
fn an_expired_offer_fails() {
    let host = Host::new();
    let payload = host.offer();
    host.server.expire_offer();
    let phone = Phone::new();
    assert!(matches!(
        phone.client.pair(payload),
        Err(SyncError::PairingExpired(_))
    ));
    assert!(host.server.paired_devices().unwrap().is_empty());

    // A code long past its expiry is refused before connecting.
    let mut tuning = super::fast_tuning();
    tuning.offer_lifetime_secs = -600;
    host.server.set_tuning(tuning);
    let payload = host.offer();
    assert!(matches!(
        phone.client.pair(payload),
        Err(SyncError::PairingExpired(_))
    ));
    assert!(host.delegate.approvals.lock().is_empty());
}

#[test]
fn a_cancelled_or_replaced_offer_fails() {
    let host = Host::new();
    let first = host.offer();
    let second = host.offer();
    let phone = Phone::new();
    assert!(matches!(
        phone.client.pair(first),
        Err(SyncError::PairingExpired(_))
    ));
    host.server.cancel_pairing();
    assert!(matches!(
        phone.client.pair(second),
        Err(SyncError::PairingExpired(_))
    ));
}

#[test]
fn a_mismatched_mac_key_fails_before_the_phone_reveals_itself() {
    let host = Host::new();
    let payload = host.offer();
    let other_mac = crate::generate_static_key().public_key;
    let wrong = tampered(&payload, "macKey", Value::String(b64url(&other_mac)));
    let phone = Phone::new();
    assert!(matches!(
        phone.client.pair(wrong),
        Err(SyncError::Crypto(_))
    ));
    assert!(host.server.paired_devices().unwrap().is_empty());
    assert!(!phone.client.status().unwrap().paired);
    // The phone aborted after the Mac's message, so the offer is still open.
    phone.client.pair(payload).unwrap();
}

#[test]
fn a_denied_approval_fails() {
    let host = Host::new();
    host.delegate.approve.store(false, Ordering::SeqCst);
    let phone = Phone::new();
    assert!(matches!(
        phone.client.pair(host.offer()),
        Err(SyncError::PairingRejected(_))
    ));
    assert!(host.server.paired_devices().unwrap().is_empty());
    assert!(phone.client.paired_mac().unwrap().is_none());
}

#[test]
fn no_answer_within_the_approval_timeout_is_a_refusal() {
    let host = Host::new();
    let mut tuning = super::fast_tuning();
    tuning.approval_timeout = Duration::from_millis(800);
    host.server.set_tuning(tuning);
    *host.delegate.approval_delay.lock() = Duration::from_secs(3);
    let phone = Phone::new();
    let started = std::time::Instant::now();
    assert!(matches!(
        phone.client.pair(host.offer()),
        Err(SyncError::PairingRejected(_))
    ));
    assert!(started.elapsed() < Duration::from_secs(3));
    assert!(host.server.paired_devices().unwrap().is_empty());
}

#[test]
fn a_slow_approval_keeps_the_connection_alive_with_pings() {
    let host = Host::new();
    // Longer than the phone's idle timeout; pings carry it.
    let mut tuning = super::fast_tuning();
    tuning.idle_timeout = Duration::from_millis(900);
    tuning.approval_timeout = Duration::from_secs(5);
    host.server.set_tuning(tuning.clone());
    *host.delegate.approval_delay.lock() = Duration::from_millis(2000);
    let phone = Phone::new();
    phone.client.set_tuning(tuning);
    phone.client.pair(host.offer()).unwrap();
}

#[test]
fn an_unreachable_mac_is_reported() {
    let host = Host::new();
    let payload = host.offer();
    drop(host);
    let phone = Phone::new();
    assert!(matches!(
        phone.client.pair(payload),
        Err(SyncError::Unreachable(_))
    ));
}

#[test]
fn pairing_tries_addresses_in_order() {
    let host = Host::new();
    let offer = host.server.begin_pairing(vec![
        // Nothing listens on this port of this loopback address.
        "127.0.0.2:9".into(),
        "127.0.0.1".into(),
    ]);
    let info = parse_pairing_payload(offer.qr_payload.clone()).unwrap();
    assert_eq!(info.addresses.len(), 2);
    let phone = Phone::new();
    phone.client.pair(offer.qr_payload).unwrap();
    let status = phone.client.status().unwrap();
    assert_eq!(
        status.last_address.unwrap(),
        format!("127.0.0.1:{}", host.server.bound_port())
    );
}

#[test]
fn pairing_replaces_sample_data() {
    let host = Host::new();
    let phone = Phone::sample();
    assert!(phone.client.is_sample().unwrap());
    phone.client.pair(host.offer()).unwrap();
    assert!(!phone.client.is_sample().unwrap());
    assert!(phone.client.meetings(None, None, 0).unwrap().is_empty());
    assert!(matches!(
        phone.client.import_records(super::FIXTURE.into()),
        Err(SyncError::InvalidInput(_))
    ));
}
