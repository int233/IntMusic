use std::collections::HashMap;

use anyhow::{Context, Result};
use mdns_sd::{ServiceDaemon, ServiceInfo};
use serde::{Deserialize, Serialize};

pub const SERVICE_TYPE: &str = "_intmusic-core._tcp.local.";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CoreAnnouncement {
    pub instance_id: String,
    pub name: String,
    pub api_base_url: String,
}

pub struct DiscoveryPublisher {
    daemon: ServiceDaemon,
    fullname: String,
}

impl DiscoveryPublisher {
    pub fn publish_core(
        server_id: &str,
        display_name: &str,
        port: u16,
        api_version: &str,
        api_prefix: &str,
    ) -> Result<Self> {
        let daemon = ServiceDaemon::new().context("failed to start mDNS daemon")?;
        let short_id = server_id.chars().take(8).collect::<String>();
        let instance_name = format!("IntMusic-{short_id}");
        let host_name = format!("intmusic-{short_id}.local.");
        let mut properties = HashMap::new();
        properties.insert("server_id".to_string(), server_id.to_string());
        properties.insert("name".to_string(), display_name.to_string());
        properties.insert("api_version".to_string(), api_version.to_string());
        properties.insert("api_prefix".to_string(), api_prefix.to_string());

        let service_info = ServiceInfo::new(
            SERVICE_TYPE,
            &instance_name,
            &host_name,
            "",
            port,
            properties,
        )
        .context("failed to create mDNS service info")?
        .enable_addr_auto();
        let fullname = service_info.get_fullname().to_string();
        daemon
            .register(service_info)
            .context("failed to register mDNS service")?;

        Ok(Self { daemon, fullname })
    }

    pub fn fullname(&self) -> &str {
        &self.fullname
    }
}

impl Drop for DiscoveryPublisher {
    fn drop(&mut self) {
        let _ = self.daemon.unregister(&self.fullname);
        let _ = self.daemon.shutdown();
    }
}

pub fn service_name() -> &'static str {
    SERVICE_TYPE
}
