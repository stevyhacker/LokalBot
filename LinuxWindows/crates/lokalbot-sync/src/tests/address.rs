use std::net::{IpAddr, SocketAddr};

use crate::net::{is_allowed_peer, local_addresses, resolve};

#[test]
fn address_filter_table() {
    let cases = [
        // Loopback, for tests.
        ("127.0.0.1", true),
        ("127.255.0.9", true),
        ("::1", true),
        // Private LAN.
        ("10.0.0.1", true),
        ("10.255.255.255", true),
        ("172.16.0.1", true),
        ("172.31.255.254", true),
        ("172.15.255.255", false),
        ("172.32.0.1", false),
        ("192.168.1.20", true),
        ("192.169.0.1", false),
        // Link-local.
        ("169.254.10.10", true),
        ("fe80::1", true),
        ("febf::1", true),
        ("fec0::1", false),
        // IPv6 ULA, Tailscale's range included.
        ("fc00::1", true),
        ("fd7a:115c:a1e0::1", true),
        ("fdff:ffff::1", true),
        ("fe00::1", false),
        // Tailscale and CGNAT.
        ("100.64.0.1", true),
        ("100.101.102.103", true),
        ("100.127.255.255", true),
        ("100.63.255.255", false),
        ("100.128.0.0", false),
        // IPv4-mapped IPv6 is unwrapped first.
        ("::ffff:192.168.1.20", true),
        ("::ffff:100.100.1.1", true),
        ("::ffff:8.8.8.8", false),
        ("::ffff:127.0.0.1", true),
        // Public and special addresses.
        ("8.8.8.8", false),
        ("1.1.1.1", false),
        ("145.239.232.15", false),
        ("0.0.0.0", false),
        ("255.255.255.255", false),
        ("224.0.0.1", false),
        ("2001:4860:4860::8888", false),
        ("::", false),
        ("ff02::1", false),
        // IPv4-compatible (not mapped) addresses are not unwrapped.
        ("::192.168.1.20", false),
    ];
    for (address, allowed) in cases {
        let ip: IpAddr = address.parse().unwrap();
        assert_eq!(is_allowed_peer(ip), allowed, "{address}");
    }
}

#[test]
fn local_addresses_never_include_loopback() {
    let addresses = local_addresses();
    for address in &addresses {
        let ip: IpAddr = address.parse().expect("an IP address");
        assert!(!ip.is_loopback(), "{address}");
        assert!(is_allowed_peer(ip), "{address}");
        if let IpAddr::V6(v6) = ip {
            assert_ne!(
                v6.segments()[0] & 0xffc0,
                0xfe80,
                "IPv6 link-local {address}"
            );
        }
    }
    let mut unique = addresses.clone();
    unique.dedup();
    assert_eq!(unique, addresses);
}

#[test]
fn stored_addresses_resolve_to_sockets() {
    let socket = |s: &str| s.parse::<SocketAddr>().unwrap();
    assert_eq!(
        resolve("192.168.1.20", 17890),
        [socket("192.168.1.20:17890")]
    );
    assert_eq!(
        resolve(" 192.168.1.20:9 ", 17890),
        [socket("192.168.1.20:9")]
    );
    assert_eq!(
        resolve("fd7a:115c:a1e0::1", 17890),
        [socket("[fd7a:115c:a1e0::1]:17890")]
    );
    assert_eq!(
        resolve("[fd7a:115c:a1e0::1]", 17890),
        [socket("[fd7a:115c:a1e0::1]:17890")]
    );
    assert_eq!(
        resolve("[fd7a:115c:a1e0::1]:4", 17890),
        [socket("[fd7a:115c:a1e0::1]:4")]
    );
    assert!(resolve("", 17890).is_empty());
    assert!(resolve("no-such-host.invalid", 17890).is_empty());
    let localhost = resolve("localhost:5", 17890);
    assert!(
        localhost
            .iter()
            .all(|s| s.port() == 5 && s.ip().is_loopback())
    );
}
