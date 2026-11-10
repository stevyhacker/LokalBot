//! The host's listeners. A loopback host hands out 127.0.0.1, so it must
//! serve it, even though IPv4 and IPv6 ephemeral ports are picked
//! separately and the port `[::1]` gets may already be taken on 127.0.0.1.

use std::io::ErrorKind;
use std::net::{Ipv6Addr, SocketAddr, TcpListener, TcpStream};
use std::time::{Duration, Instant};

use crate::SyncError;
use crate::server::{LOOPBACK_PORT_ATTEMPTS, bind_with};

use super::{Host, Phone};

fn socket(address: &str) -> SocketAddr {
    address.parse().unwrap()
}

/// A listener on 127.0.0.1 that isn't the host's, and one on `[::1]` at the
/// same port: what the kernel can hand a host whose two binds collide.
/// None where this machine has no IPv6 loopback.
fn collision() -> Option<(TcpListener, TcpListener)> {
    for _ in 0..32 {
        let other = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = other.local_addr().unwrap().port();
        match TcpListener::bind((Ipv6Addr::LOCALHOST, port)) {
            Ok(ipv6) => return Some((other, ipv6)),
            Err(e) if e.kind() == ErrorKind::AddrInUse => continue,
            Err(e) => {
                eprintln!("no IPv6 loopback here ({e}); nothing to collide with");
                return None;
            }
        }
    }
    panic!("32 ports taken on 127.0.0.1 were all taken on [::1] too");
}

/// Whether `listener` has a connection waiting, or gets one within `wait`.
fn accepts(listener: &TcpListener, wait: Duration) -> bool {
    listener.set_nonblocking(true).unwrap();
    let deadline = Instant::now() + wait;
    loop {
        match listener.accept() {
            Ok(_) => return true,
            Err(e) if e.kind() == ErrorKind::WouldBlock => {
                if Instant::now() >= deadline {
                    return false;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(e) => panic!("accept failed: {e}"),
        }
    }
}

#[test]
fn a_loopback_host_moves_off_a_port_taken_on_ipv4() {
    let Some((other, ipv6)) = collision() else {
        return;
    };
    let taken = other.local_addr().unwrap().port();
    let mut first = Some(ipv6);
    let mut asked = Vec::new();
    let listeners = bind_with(0, true, &mut |address| {
        asked.push(address);
        if address.is_ipv6()
            && let Some(listener) = first.take()
        {
            return Ok(listener);
        }
        TcpListener::bind(address)
    })
    .unwrap();

    let port = listeners[0].local_addr().unwrap().port();
    assert_ne!(port, taken);
    let bound: Vec<SocketAddr> = listeners.iter().map(|l| l.local_addr().unwrap()).collect();
    assert_eq!(
        bound,
        [
            socket(&format!("[::1]:{port}")),
            socket(&format!("127.0.0.1:{port}"))
        ]
    );
    // It asked for a fresh port after the clash, and kept the IPv4 one.
    assert_eq!(
        asked[..3],
        [
            socket("[::1]:0"),
            socket(&format!("127.0.0.1:{taken}")),
            socket("[::1]:0"),
        ]
    );
    assert_eq!(asked.last(), Some(&socket(&format!("127.0.0.1:{port}"))));

    // What a pairing code names reaches this host, not the other socket.
    let _phone = TcpStream::connect(("127.0.0.1", port)).unwrap();
    assert!(accepts(&listeners[1], Duration::from_secs(1)));
    assert!(!accepts(&other, Duration::ZERO));
}

#[test]
fn a_loopback_host_gives_up_when_every_port_is_taken_on_ipv4() {
    let Some((other, ipv6)) = collision() else {
        return;
    };
    let mut ipv6_binds = 0;
    let error = bind_with(0, true, &mut |address| {
        if address.is_ipv6() {
            ipv6_binds += 1;
            return ipv6.try_clone();
        }
        TcpListener::bind(address)
    })
    .unwrap_err();
    assert_eq!(ipv6_binds, LOOPBACK_PORT_ATTEMPTS);
    let taken = other.local_addr().unwrap().port();
    assert!(
        matches!(&error, SyncError::Io(message)
            if message.contains("127.0.0.1") && message.contains(&taken.to_string())),
        "{error:?}"
    );
}

#[test]
fn a_loopback_host_without_ipv6_serves_ipv4_alone() {
    let listeners = bind_with(0, true, &mut |address| {
        if address.is_ipv6() {
            return Err(ErrorKind::AddrNotAvailable.into());
        }
        TcpListener::bind(address)
    })
    .unwrap();
    assert_eq!(listeners.len(), 1);
    let address = listeners[0].local_addr().unwrap();
    assert_eq!(address.ip().to_string(), "127.0.0.1");
    assert_ne!(address.port(), 0);
}

/// A fixed port is what the person chose, so the host doesn't move; it
/// reports the clash instead of listening where its codes don't point.
#[test]
fn a_loopback_host_does_not_start_on_a_port_taken_on_ipv4() {
    let other = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = other.local_addr().unwrap().port();
    let error = Host::on_port(port)
        .err()
        .expect("the host refused a port taken on 127.0.0.1");
    assert!(
        matches!(&error, SyncError::Io(message) if message.contains("127.0.0.1")),
        "{error:?}"
    );
}

#[test]
fn a_loopback_host_on_a_free_fixed_port_pairs() {
    let port = TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let Ok(host) = Host::on_port(port) else {
        // Another socket took it on 127.0.0.1 in between.
        return;
    };
    assert_eq!(host.server.bound_port(), port);
    Phone::paired(&host);
}
