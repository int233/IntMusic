use std::{collections::HashMap, fs::File, path::Path, sync::Arc, time::Duration};

use anyhow::{Context, Result};
use cpal::traits::HostTrait;
use protocol::{PlaybackState, PlaybackTransportState};
use rodio::{Decoder, OutputStream, OutputStreamBuilder, Sink};
use tokio::sync::{Mutex, RwLock};

#[derive(Clone)]
pub struct PlaybackController {
    states: Arc<RwLock<HashMap<String, PlaybackState>>>,
    outputs: Arc<Mutex<HashMap<String, PlaybackOutput>>>,
}

struct PlaybackOutput {
    _stream: OutputStream,
    sink: Sink,
}

impl PlaybackController {
    pub fn new_local() -> Self {
        let mut states = HashMap::new();
        states.insert("local".to_string(), stopped_state("local"));
        Self {
            states: Arc::new(RwLock::new(states)),
            outputs: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub async fn state(&self) -> PlaybackState {
        self.state_for_zone("local").await
    }

    pub async fn state_for_zone(&self, zone_id: &str) -> PlaybackState {
        let output_state = {
            let outputs = self.outputs.lock().await;
            outputs.get(zone_id).map(|output| {
                (
                    duration_millis(output.sink.get_pos()),
                    output.sink.empty(),
                    output.sink.is_paused(),
                )
            })
        };

        let mut states = self.states.write().await;
        let state = states
            .entry(zone_id.to_string())
            .or_insert_with(|| stopped_state(zone_id));

        if let Some((position_ms, is_empty, is_paused)) = output_state {
            if is_empty {
                state.state = PlaybackTransportState::Stopped;
                state.position_ms = 0;
                state.track_id = None;
                state.track_title = None;
            } else {
                state.position_ms = position_ms;
                state.state = if is_paused {
                    PlaybackTransportState::Paused
                } else {
                    PlaybackTransportState::Playing
                };
            }
        }

        state.clone()
    }

    pub async fn play_track(
        &self,
        track_id: i64,
        title: impl Into<String>,
        path: impl AsRef<Path>,
    ) -> Result<PlaybackState> {
        self.play_track_on_zone("local", None, track_id, title, path, 0)
            .await
    }

    pub async fn play_track_on_zone(
        &self,
        zone_id: &str,
        output_id: Option<&str>,
        track_id: i64,
        title: impl Into<String>,
        path: impl AsRef<Path>,
        position_ms: u64,
    ) -> Result<PlaybackState> {
        let path = path.as_ref().to_path_buf();
        let title = title.into();
        let file = File::open(&path)
            .with_context(|| format!("failed to open audio file {}", path.display()))?;
        let source = Decoder::try_from(file)
            .with_context(|| format!("failed to decode audio file {}", path.display()))?;

        let stream = open_stream(output_id)?;
        let sink = Sink::connect_new(stream.mixer());
        sink.append(source);
        if position_ms > 0 {
            sink.try_seek(Duration::from_millis(position_ms))
                .map_err(|error| anyhow::anyhow!("failed to seek current track: {error:?}"))?;
        }
        sink.play();

        let mut outputs = self.outputs.lock().await;
        if let Some(previous) = outputs.remove(zone_id) {
            previous.sink.stop();
        }
        outputs.insert(
            zone_id.to_string(),
            PlaybackOutput {
                _stream: stream,
                sink,
            },
        );
        drop(outputs);

        let playback = PlaybackState {
            zone_id: zone_id.to_string(),
            state: PlaybackTransportState::Playing,
            track_id: Some(track_id),
            track_title: Some(title),
            position_ms,
            queue_revision: 0,
        };
        self.states
            .write()
            .await
            .insert(zone_id.to_string(), playback.clone());
        Ok(playback)
    }

    pub async fn resume(&self) -> PlaybackState {
        self.resume_zone("local").await
    }

    pub async fn resume_zone(&self, zone_id: &str) -> PlaybackState {
        let position_ms = if let Some(output) = self.outputs.lock().await.get(zone_id) {
            output.sink.play();
            Some(duration_millis(output.sink.get_pos()))
        } else {
            None
        };
        let mut states = self.states.write().await;
        let state = states
            .entry(zone_id.to_string())
            .or_insert_with(|| stopped_state(zone_id));
        state.state = PlaybackTransportState::Playing;
        if let Some(position_ms) = position_ms {
            state.position_ms = position_ms;
        }
        state.clone()
    }

    pub async fn pause(&self) -> PlaybackState {
        self.pause_zone("local").await
    }

    pub async fn pause_zone(&self, zone_id: &str) -> PlaybackState {
        let position_ms = if let Some(output) = self.outputs.lock().await.get(zone_id) {
            output.sink.pause();
            Some(duration_millis(output.sink.get_pos()))
        } else {
            None
        };
        let mut states = self.states.write().await;
        let state = states
            .entry(zone_id.to_string())
            .or_insert_with(|| stopped_state(zone_id));
        state.state = PlaybackTransportState::Paused;
        if let Some(position_ms) = position_ms {
            state.position_ms = position_ms;
        }
        state.clone()
    }

    pub async fn stop(&self) -> PlaybackState {
        self.stop_zone("local").await
    }

    pub async fn stop_zone(&self, zone_id: &str) -> PlaybackState {
        if let Some(output) = self.outputs.lock().await.remove(zone_id) {
            output.sink.stop();
        }
        let mut states = self.states.write().await;
        let state = states
            .entry(zone_id.to_string())
            .or_insert_with(|| stopped_state(zone_id));
        state.state = PlaybackTransportState::Stopped;
        state.position_ms = 0;
        state.track_id = None;
        state.track_title = None;
        state.clone()
    }

    pub async fn seek(&self, position_ms: u64) -> Result<PlaybackState> {
        self.seek_zone("local", position_ms).await
    }

    pub async fn seek_zone(&self, zone_id: &str, position_ms: u64) -> Result<PlaybackState> {
        if let Some(output) = self.outputs.lock().await.get(zone_id) {
            output
                .sink
                .try_seek(Duration::from_millis(position_ms))
                .map_err(|error| anyhow::anyhow!("failed to seek current track: {error:?}"))?;
        }
        let mut states = self.states.write().await;
        let state = states
            .entry(zone_id.to_string())
            .or_insert_with(|| stopped_state(zone_id));
        state.position_ms = position_ms;
        Ok(state.clone())
    }
}

fn open_stream(output_id: Option<&str>) -> Result<OutputStream> {
    let Some(output_id) = output_id else {
        return OutputStreamBuilder::open_default_stream()
            .context("failed to open the default audio output device");
    };

    let Some(index) = output_id.strip_prefix("cpal:") else {
        return OutputStreamBuilder::open_default_stream()
            .context("failed to open the default audio output device");
    };

    let index = index
        .parse::<usize>()
        .with_context(|| format!("invalid local output id {output_id}"))?;
    let host = cpal::default_host();
    let device = host
        .output_devices()
        .context("failed to enumerate local audio output devices")?
        .nth(index)
        .with_context(|| format!("local audio output {output_id} is not available"))?;

    OutputStreamBuilder::from_device(device)
        .context("failed to prepare local audio output device")?
        .open_stream()
        .context("failed to open local audio output stream")
}

fn stopped_state(zone_id: &str) -> PlaybackState {
    PlaybackState {
        zone_id: zone_id.to_string(),
        state: PlaybackTransportState::Stopped,
        track_id: None,
        track_title: None,
        position_ms: 0,
        queue_revision: 0,
    }
}

fn duration_millis(duration: Duration) -> u64 {
    duration.as_millis().min(u128::from(u64::MAX)) as u64
}
