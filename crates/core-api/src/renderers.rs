use std::{collections::HashMap, sync::Arc};

use anyhow::{bail, Result};
use chrono::{Duration, Utc};
use protocol::{
    OutputDevice, PlaybackState, PlaybackTransportState, RegisteredRenderer, RendererRegistration,
    RendererStateReport, ZoneSummary,
};
use tokio::sync::RwLock;

const ONLINE_WINDOW_SECONDS: i64 = 35;

#[derive(Clone, Default)]
pub struct RendererRegistry {
    inner: Arc<RwLock<HashMap<String, RendererNode>>>,
}

#[derive(Debug, Clone)]
struct RendererNode {
    client_id: String,
    name: String,
    platform: String,
    outputs: Vec<OutputDevice>,
    states: HashMap<String, PlaybackState>,
    command_sequences: HashMap<String, u64>,
    last_seen_at: chrono::DateTime<Utc>,
}

impl RendererRegistry {
    pub async fn register(
        &self,
        registration: RendererRegistration,
    ) -> (RegisteredRenderer, Vec<(PlaybackState, PlaybackState)>) {
        let now = Utc::now();
        let mut guard = self.inner.write().await;
        let previous_states = guard
            .get(&registration.client_id)
            .map(|node| node.states.clone())
            .unwrap_or_default();
        let previous_command_sequences = guard
            .get(&registration.client_id)
            .map(|node| node.command_sequences.clone())
            .unwrap_or_default();
        let reset_playback = registration.reset_playback;
        let mut reset_states = Vec::new();

        let mut states = HashMap::new();
        let mut command_sequences = HashMap::new();
        let outputs = registration
            .outputs
            .into_iter()
            .map(|output| {
                let output_id = remote_output_id(&registration.client_id, &output.id);
                command_sequences.insert(
                    output_id.clone(),
                    previous_command_sequences
                        .get(&output_id)
                        .copied()
                        .unwrap_or_default(),
                );
                let previous_state = previous_states.get(&output_id).cloned();
                let state = if reset_playback {
                    if previous_state.as_ref().is_some_and(|state| {
                        state.track_id.is_some()
                            || state.state != PlaybackTransportState::Stopped
                            || state.position_ms > 0
                    }) {
                        reset_states.push((
                            previous_state.clone().expect("checked above"),
                            stopped_state(&output_id),
                        ));
                    }
                    stopped_state(&output_id)
                } else {
                    previous_state.unwrap_or_else(|| stopped_state(&output_id))
                };
                states.insert(output_id.clone(), state);
                OutputDevice {
                    id: output_id,
                    name: output.name,
                    backend: output.backend,
                    is_default: output.is_default,
                    sample_rates: output.sample_rates,
                    channels: output.channels,
                    node_id: Some(registration.client_id.clone()),
                    node_name: Some(registration.name.clone()),
                    is_online: true,
                    is_remote: true,
                    system_volume_supported: output.system_volume_supported,
                    system_volume_readable: output.system_volume_readable,
                    system_volume_writable: output.system_volume_writable,
                    system_volume_steps: output.system_volume_steps,
                }
            })
            .collect::<Vec<_>>();

        let node = RendererNode {
            client_id: registration.client_id.clone(),
            name: registration.name,
            platform: registration.platform,
            outputs,
            states,
            command_sequences,
            last_seen_at: now,
        };
        let response = node.to_protocol(now);
        guard.insert(registration.client_id, node);
        (response, reset_states)
    }

    pub async fn list_renderers(&self) -> Vec<RegisteredRenderer> {
        let now = Utc::now();
        self.inner
            .read()
            .await
            .values()
            .map(|node| node.to_protocol(now))
            .collect()
    }

    pub async fn list_outputs(&self) -> Vec<OutputDevice> {
        let now = Utc::now();
        self.inner
            .read()
            .await
            .values()
            .flat_map(|node| {
                let online = node.is_online(now);
                node.outputs.iter().cloned().map(move |mut output| {
                    output.is_online = online;
                    output
                })
            })
            .collect()
    }

    pub async fn list_zones(&self) -> Vec<ZoneSummary> {
        let now = Utc::now();
        self.inner
            .read()
            .await
            .values()
            .flat_map(|node| {
                let online = node.is_online(now);
                node.outputs.iter().map(move |output| {
                    let state = node
                        .states
                        .get(&output.id)
                        .cloned()
                        .unwrap_or_else(|| stopped_state(&output.id));
                    let system_name = format!("{} - {}", node.name, output.name);
                    ZoneSummary {
                        id: output.id.clone(),
                        name: system_name.clone(),
                        system_name,
                        alias: None,
                        output_id: Some(output.id.clone()),
                        state: if online {
                            state.state
                        } else {
                            PlaybackTransportState::Stopped
                        },
                        volume: 1.0,
                        muted: false,
                        volume_mode: protocol::VolumeControlMode::Player,
                        player_volume: 1.0,
                        player_muted: false,
                        system_volume: None,
                        system_muted: None,
                        system_volume_supported: output.system_volume_supported,
                        system_volume_readable: output.system_volume_readable,
                        system_volume_writable: output.system_volume_writable,
                        system_volume_steps: output.system_volume_steps,
                        track_id: if online { state.track_id } else { None },
                        track_title: if online { state.track_title } else { None },
                        position_ms: if online { state.position_ms } else { 0 },
                        command_sequence: if online { state.command_sequence } else { None },
                        origin_client_id: if online { state.origin_client_id } else { None },
                        intent_id: if online { state.intent_id } else { None },
                        is_online: online,
                        is_remote: true,
                        node_id: Some(node.client_id.clone()),
                        node_name: Some(node.name.clone()),
                    }
                })
            })
            .collect()
    }

    pub async fn renderer_id_for_output(&self, output_id: &str) -> Option<String> {
        let now = Utc::now();
        self.inner
            .read()
            .await
            .values()
            .filter(|node| node.is_online(now))
            .find(|node| node.outputs.iter().any(|output| output.id == output_id))
            .map(|node| node.client_id.clone())
    }

    pub async fn system_volume_writable_for_output(&self, output_id: &str) -> bool {
        let now = Utc::now();
        self.inner
            .read()
            .await
            .values()
            .filter(|node| node.is_online(now))
            .flat_map(|node| node.outputs.iter())
            .find(|output| output.id == output_id)
            .is_some_and(|output| output.system_volume_supported && output.system_volume_writable)
    }

    pub async fn update_system_volume_capability(
        &self,
        client_id: &str,
        output_id: &str,
        supported: bool,
        readable: bool,
        writable: bool,
        steps: Option<u32>,
    ) -> Result<()> {
        let mut guard = self.inner.write().await;
        let Some(node) = guard.get_mut(client_id) else {
            bail!("renderer {client_id} is not registered");
        };
        node.last_seen_at = Utc::now();
        let output_id = if output_id.starts_with("renderer:") {
            output_id.to_string()
        } else {
            remote_output_id(client_id, output_id)
        };
        let Some(output) = node
            .outputs
            .iter_mut()
            .find(|output| output.id == output_id)
        else {
            bail!("renderer output {output_id} is not registered");
        };
        output.system_volume_supported = supported;
        output.system_volume_readable = readable;
        output.system_volume_writable = writable;
        output.system_volume_steps = steps;
        Ok(())
    }

    pub async fn state_for_output(&self, output_id: &str) -> Option<PlaybackState> {
        let now = Utc::now();
        self.inner
            .read()
            .await
            .values()
            .filter(|node| node.is_online(now))
            .find(|node| node.outputs.iter().any(|output| output.id == output_id))
            .map(|node| {
                node.states
                    .get(output_id)
                    .cloned()
                    .unwrap_or_else(|| stopped_state(output_id))
            })
    }

    pub async fn next_command_sequence(&self, output_id: &str) -> Result<u64> {
        let mut guard = self.inner.write().await;
        for node in guard.values_mut() {
            if node.outputs.iter().any(|output| output.id == output_id) {
                let sequence = node
                    .command_sequences
                    .entry(output_id.to_string())
                    .or_default();
                *sequence = sequence.saturating_add(1);
                return Ok(*sequence);
            }
        }
        bail!("renderer output {output_id} is not registered")
    }

    pub async fn update_state(&self, state: PlaybackState) -> Result<PlaybackState> {
        let mut guard = self.inner.write().await;
        for node in guard.values_mut() {
            if node.outputs.iter().any(|output| output.id == state.zone_id) {
                node.states.insert(state.zone_id.clone(), state.clone());
                return Ok(state);
            }
        }
        bail!("renderer output {} is not registered", state.zone_id)
    }

    pub async fn report_state(
        &self,
        client_id: &str,
        report: RendererStateReport,
    ) -> Result<PlaybackState> {
        let mut guard = self.inner.write().await;
        let Some(node) = guard.get_mut(client_id) else {
            bail!("renderer {client_id} is not registered");
        };

        node.last_seen_at = Utc::now();
        let output_id = if report.output_id.starts_with("renderer:") {
            report.output_id
        } else {
            remote_output_id(client_id, &report.output_id)
        };

        if !node.outputs.iter().any(|output| output.id == output_id) {
            bail!("renderer output {output_id} is not registered");
        }

        let previous = node.states.get(&output_id);
        if let Some(previous) = previous {
            if previous.command_sequence.is_some()
                && report.command_sequence.is_none()
                && (report.state != previous.state
                    || report.track_id != previous.track_id
                    || report.track_title != previous.track_title)
            {
                return Ok(previous.clone());
            }
        }
        if let (Some(previous), Some(command_sequence)) = (previous, report.command_sequence) {
            if previous
                .command_sequence
                .is_some_and(|previous_sequence| command_sequence < previous_sequence)
            {
                return Ok(previous.clone());
            }
        }
        let state = PlaybackState {
            zone_id: output_id,
            state: report.state,
            track_id: report.track_id,
            track_title: report.track_title,
            position_ms: report.position_ms,
            queue_revision: 0,
            command_sequence: report
                .command_sequence
                .or_else(|| previous.and_then(|state| state.command_sequence)),
            origin_client_id: report
                .origin_client_id
                .or_else(|| previous.and_then(|state| state.origin_client_id.clone())),
            intent_id: report
                .intent_id
                .or_else(|| previous.and_then(|state| state.intent_id.clone())),
        };
        node.states.insert(state.zone_id.clone(), state.clone());
        Ok(state)
    }

    pub async fn expire_offline_playback(&self) -> Vec<(PlaybackState, PlaybackState)> {
        let now = Utc::now();
        let mut expired = Vec::new();
        let mut guard = self.inner.write().await;
        for node in guard.values_mut() {
            if node.is_online(now) {
                continue;
            }
            for output in &node.outputs {
                let state = node
                    .states
                    .entry(output.id.clone())
                    .or_insert_with(|| stopped_state(&output.id));
                if state.track_id.is_some()
                    || state.state != PlaybackTransportState::Stopped
                    || state.position_ms > 0
                {
                    let previous = state.clone();
                    *state = stopped_state(&output.id);
                    expired.push((previous, state.clone()));
                }
            }
        }
        expired
    }
}

impl RendererNode {
    fn is_online(&self, now: chrono::DateTime<Utc>) -> bool {
        now - self.last_seen_at <= Duration::seconds(ONLINE_WINDOW_SECONDS)
    }

    fn to_protocol(&self, now: chrono::DateTime<Utc>) -> RegisteredRenderer {
        let online = self.is_online(now);
        let outputs = self
            .outputs
            .iter()
            .cloned()
            .map(|mut output| {
                output.is_online = online;
                output
            })
            .collect();
        RegisteredRenderer {
            client_id: self.client_id.clone(),
            name: self.name.clone(),
            platform: self.platform.clone(),
            outputs,
            last_seen_at: self.last_seen_at,
            is_online: online,
        }
    }
}

pub fn remote_output_id(client_id: &str, output_id: &str) -> String {
    format!("renderer:{client_id}:{output_id}")
}

fn stopped_state(output_id: &str) -> PlaybackState {
    PlaybackState {
        zone_id: output_id.to_string(),
        state: PlaybackTransportState::Stopped,
        track_id: None,
        track_title: None,
        position_ms: 0,
        queue_revision: 0,
        command_sequence: None,
        origin_client_id: None,
        intent_id: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use protocol::RendererOutputRegistration;

    fn registration() -> RendererRegistration {
        RendererRegistration {
            client_id: "client-a".to_string(),
            name: "Client A".to_string(),
            platform: "windows".to_string(),
            outputs: vec![RendererOutputRegistration {
                id: "default".to_string(),
                name: "Default".to_string(),
                backend: "test".to_string(),
                is_default: true,
                sample_rates: Vec::new(),
                channels: Vec::new(),
                system_volume_supported: true,
                system_volume_readable: true,
                system_volume_writable: true,
                system_volume_steps: Some(100),
                system_volume: Some(0.5),
                system_muted: Some(false),
            }],
            reset_playback: false,
            request_playback_sync: false,
        }
    }

    #[tokio::test]
    async fn command_sequences_are_monotonic_across_registration_refreshes() {
        let registry = RendererRegistry::default();
        registry.register(registration()).await;
        let output_id = remote_output_id("client-a", "default");

        assert_eq!(registry.next_command_sequence(&output_id).await.unwrap(), 1);
        registry.register(registration()).await;
        assert_eq!(registry.next_command_sequence(&output_id).await.unwrap(), 2);
    }

    #[tokio::test]
    async fn stale_state_reports_cannot_overwrite_a_newer_command() {
        let registry = RendererRegistry::default();
        registry.register(registration()).await;
        let output_id = remote_output_id("client-a", "default");
        registry
            .update_state(PlaybackState {
                zone_id: output_id.clone(),
                state: PlaybackTransportState::Playing,
                track_id: Some(42),
                track_title: Some("Current".to_string()),
                position_ms: 1_000,
                queue_revision: 7,
                command_sequence: Some(2),
                origin_client_id: Some("client-a".to_string()),
                intent_id: Some("new-intent".to_string()),
            })
            .await
            .unwrap();

        let stale = registry
            .report_state(
                "client-a",
                RendererStateReport {
                    output_id: output_id.clone(),
                    state: PlaybackTransportState::Paused,
                    track_id: Some(42),
                    track_title: Some("Current".to_string()),
                    position_ms: 900,
                    command_sequence: Some(1),
                    origin_client_id: Some("client-a".to_string()),
                    intent_id: Some("old-intent".to_string()),
                },
            )
            .await
            .unwrap();
        assert_eq!(stale.state, PlaybackTransportState::Playing);
        assert_eq!(stale.command_sequence, Some(2));
        assert_eq!(stale.intent_id.as_deref(), Some("new-intent"));

        let current = registry
            .report_state(
                "client-a",
                RendererStateReport {
                    output_id,
                    state: PlaybackTransportState::Paused,
                    track_id: Some(42),
                    track_title: Some("Current".to_string()),
                    position_ms: 1_100,
                    command_sequence: Some(3),
                    origin_client_id: Some("client-a".to_string()),
                    intent_id: Some("latest-intent".to_string()),
                },
            )
            .await
            .unwrap();
        assert_eq!(current.state, PlaybackTransportState::Paused);
        assert_eq!(current.command_sequence, Some(3));
        assert_eq!(current.intent_id.as_deref(), Some("latest-intent"));
    }

    #[tokio::test]
    async fn unsequenced_state_cannot_reverse_a_sequenced_transport_command() {
        let registry = RendererRegistry::default();
        registry.register(registration()).await;
        let output_id = remote_output_id("client-a", "default");
        registry
            .update_state(PlaybackState {
                zone_id: output_id.clone(),
                state: PlaybackTransportState::Playing,
                track_id: Some(42),
                track_title: Some("Current".to_string()),
                position_ms: 1_000,
                queue_revision: 7,
                command_sequence: Some(2),
                origin_client_id: Some("client-a".to_string()),
                intent_id: Some("new-intent".to_string()),
            })
            .await
            .unwrap();

        let stale = registry
            .report_state(
                "client-a",
                RendererStateReport {
                    output_id,
                    state: PlaybackTransportState::Paused,
                    track_id: Some(42),
                    track_title: Some("Current".to_string()),
                    position_ms: 1_100,
                    command_sequence: None,
                    origin_client_id: None,
                    intent_id: None,
                },
            )
            .await
            .unwrap();

        assert_eq!(stale.state, PlaybackTransportState::Playing);
        assert_eq!(stale.command_sequence, Some(2));
        assert_eq!(stale.intent_id.as_deref(), Some("new-intent"));
    }
}
