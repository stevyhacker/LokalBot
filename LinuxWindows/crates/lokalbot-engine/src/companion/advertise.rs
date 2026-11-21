use std::net::IpAddr;

use anyhow::{Context as _, Result};
use mdns_sd::{IfKind, ServiceDaemon, ServiceInfo};

pub const SERVICE_TYPE: &str = "_lokalbot._tcp.local.";

pub fn instance_name(fingerprint: &str) -> String {
    let start: String = fingerprint.chars().take(4).collect();
    format!("LokalBot-{}", start.to_uppercase())
}

pub fn txt_value(fingerprint: &str) -> String {
    fingerprint.chars().take(16).collect()
}

pub fn service_info(port: u16, fingerprint: &str, addresses: &[IpAddr]) -> Result<ServiceInfo> {
    let instance = instance_name(fingerprint);
    ServiceInfo::new(
        SERVICE_TYPE,
        &instance,
        &format!("{instance}.local."),
        addresses,
        port,
        &[("k", txt_value(fingerprint).as_str())][..],
    )
    .context("the local network announcement is not valid")
}

pub trait Advertiser: Send {
    fn start(&mut self, port: u16, fingerprint: &str, addresses: &[String]) -> Result<()>;
    fn stop(&mut self);
}

#[derive(Default)]
pub struct MdnsAdvertiser {
    daemon: Option<ServiceDaemon>,
}

impl Advertiser for MdnsAdvertiser {
    fn start(&mut self, port: u16, fingerprint: &str, addresses: &[String]) -> Result<()> {
        anyhow::ensure!(!cfg!(test), "tests never announce on the local network");
        self.stop();
        let addresses: Vec<IpAddr> = addresses
            .iter()
            .filter_map(|address| address.parse().ok())
            .collect();
        anyhow::ensure!(
            !addresses.is_empty(),
            "this computer has no private network address to announce"
        );
        let info = service_info(port, fingerprint, &addresses)?;
        let daemon = ServiceDaemon::new().context("mDNS could not start")?;
        daemon.disable_interface(IfKind::All)?;
        for address in &addresses {
            daemon.enable_interface(IfKind::Addr(*address))?;
        }
        daemon.register(info).context("mDNS could not announce")?;
        self.daemon = Some(daemon);
        Ok(())
    }

    fn stop(&mut self) {
        if let Some(daemon) = self.daemon.take() {
            let _ = daemon.shutdown();
        }
    }
}

impl Drop for MdnsAdvertiser {
    fn drop(&mut self) {
        self.stop();
    }
}
