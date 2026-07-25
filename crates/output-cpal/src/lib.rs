use anyhow::Result;
use cpal::traits::{DeviceTrait, HostTrait};
use protocol::OutputDevice;

pub fn list_output_devices() -> Result<Vec<OutputDevice>> {
    let host = cpal::default_host();
    let default_name = host
        .default_output_device()
        .and_then(|device| device.name().ok());
    let mut devices = Vec::new();

    for (index, device) in host.output_devices()?.enumerate() {
        let name = device.name().unwrap_or_else(|_| format!("Output {index}"));
        let mut sample_rates = Vec::new();
        let mut channels = Vec::new();

        if let Ok(configs) = device.supported_output_configs() {
            for config in configs {
                sample_rates.push(config.min_sample_rate().0);
                sample_rates.push(config.max_sample_rate().0);
                channels.push(config.channels());
            }
        }

        sample_rates.sort_unstable();
        sample_rates.dedup();
        channels.sort_unstable();
        channels.dedup();

        devices.push(OutputDevice {
            id: format!("cpal:{index}"),
            name: name.clone(),
            backend: "cpal".to_string(),
            is_default: default_name.as_deref() == Some(name.as_str()),
            sample_rates,
            channels,
            node_id: Some("core".to_string()),
            node_name: Some("Core local".to_string()),
            is_online: true,
            is_remote: false,
            system_volume_supported: false,
            system_volume_readable: false,
            system_volume_writable: false,
            system_volume_steps: None,
        });
    }

    Ok(devices)
}
