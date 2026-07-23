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
        let reset_playback = registration.reset_playback;
        let mut reset_states = Vec::new();

        let mut states = HashMap::new();
        let outputs = registration
            .outputs
            .into_iter()
            .map(|output| {
                let output_id = remote_output_id(&registration.client_id, &output.id);
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
                }
            })
            .collect::<Vec<_>>();

        let node = RendererNode {
            client_id: registration.client_id.clone(),
            name: registration.name,
            platform: registration.platform,
            outputs,
            states,
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
                        track_id: if online { state.track_id } else { None },
                        track_title: if online { state.track_title } else { None },
                        position_ms: if online { state.position_ms } else { 0 },
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

        let state = PlaybackState {
            zone_id: output_id,
            state: report.state,
            track_id: report.track_id,
            track_title: report.track_title,
            position_ms: report.position_ms,
            queue_revision: 0,
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
    }
}
