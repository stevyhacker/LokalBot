//! Which peers the Mac accepts, which of its own addresses it advertises,
//! and how a phone turns stored address strings into sockets.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, TcpStream, ToSocketAddrs};
use std::time::Duration;

/// The address filter (protocol.md, Network): loopback, private LAN,
/// link-local, IPv6 ULA (Tailscale's `fd7a:115c:a1e0::/48` included) and
/// Tailscale/CGNAT `100.64.0.0/10`. IPv4-mapped IPv6 addresses are unwrapped.
pub fn is_allowed_peer(ip: IpAddr) -> bool {
    match unmap(ip) {
        IpAddr::V4(v4) => v4.is_loopback() || v4.is_private() || v4.is_link_local() || is_cgnat(v4),
        IpAddr::V6(v6) => v6.is_loopback() || is_ipv6_link_local(v6) || is_ipv6_ula(v6),
    }
}

/// `::ffff:a.b.c.d` becomes `a.b.c.d`; everything else is unchanged.
pub(crate) fn unmap(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map_or(IpAddr::V6(v6), IpAddr::V4),
        v4 => v4,
    }
}

fn is_cgnat(ip: Ipv4Addr) -> bool {
    let [a, b, ..] = ip.octets();
    a == 100 && (b & 0xc0) == 64
}

fn is_ipv6_link_local(ip: Ipv6Addr) -> bool {
    (ip.segments()[0] & 0xffc0) == 0xfe80
}

fn is_ipv6_ula(ip: Ipv6Addr) -> bool {
    (ip.segments()[0] & 0xfe00) == 0xfc00
}

/// This machine's addresses inside the filter ranges, for the pairing code:
/// private LAN first, then Tailscale/CGNAT, then IPv6 ULA, then IPv4
/// link-local. Loopback is never listed, and neither is IPv6 link-local,
/// which is unusable without the interface's zone id.
pub(crate) fn local_addresses() -> Vec<String> {
    let Ok(interfaces) = if_addrs::get_if_addrs() else {
        return Vec::new();
    };
    let mut found: Vec<IpAddr> = Vec::new();
    for interface in interfaces {
        let ip = unmap(interface.ip());
        if ip.is_loopback() || !is_allowed_peer(ip) || found.contains(&ip) {
            continue;
        }
        if let IpAddr::V6(v6) = ip
            && is_ipv6_link_local(v6)
        {
            continue;
        }
        found.push(ip);
    }
    found.sort_by_key(|ip| {
        let rank = match ip {
            IpAddr::V4(v4) if v4.is_private() => 0,
            IpAddr::V4(v4) if is_cgnat(*v4) => 1,
            IpAddr::V6(_) => 2,
            IpAddr::V4(_) => 3,
        };
        (rank, *ip)
    });
    found.iter().map(ToString::to_string).collect()
}

/// Socket addresses for one stored address: `ip`, `ip:port`, `[v6]:port`,
/// `host` or `host:port` (names resolve through DNS, e.g. MagicDNS).
pub(crate) fn resolve(address: &str, default_port: u16) -> Vec<SocketAddr> {
    let address = address.trim();
    if address.is_empty() {
        return Vec::new();
    }
    if let Ok(socket) = address.parse::<SocketAddr>() {
        return vec![socket];
    }
    if let Ok(ip) = address.parse::<IpAddr>() {
        return vec![SocketAddr::new(ip, default_port)];
    }
    if let Some(ip) = address
        .strip_prefix('[')
        .and_then(|rest| rest.strip_suffix(']'))
        .and_then(|inner| inner.parse::<IpAddr>().ok())
    {
        return vec![SocketAddr::new(ip, default_port)];
    }
    let (host, port) = match address.rsplit_once(':') {
        Some((host, port)) if !host.contains(':') => match port.parse::<u16>() {
            Ok(port) => (host, port),
            Err(_) => (address, default_port),
        },
        _ => (address, default_port),
    };
    (host, port)
        .to_socket_addrs()
        .map(|found| found.collect())
        .unwrap_or_default()
}

/// Opens a TCP connection to `socket` within `timeout`.
pub(crate) fn connect(socket: SocketAddr, timeout: Duration) -> std::io::Result<TcpStream> {
    TcpStream::connect_timeout(&socket, timeout)
}
