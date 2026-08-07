use std::{
    collections::HashMap,
    fs::File,
    path::{Path, PathBuf},
    sync::{mpsc, Arc, Mutex as StdMutex},
    time::Duration,
};

use anyhow::{Context, Result};
use cpal::traits::HostTrait;
use protocol::{PlaybackState, PlaybackTransportState};
use rodio::{Decoder, OutputStream, OutputStreamBuilder, Sink};
use tokio::sync::{oneshot, RwLock};

pub mod session_v3;

#[derive(Clone)]
pub struct PlaybackController {
    states: Arc<RwLock<HashMap<String, PlaybackState>>>,
    worker: PlaybackWorker,
}

struct PlaybackOutput {
    _stream: OutputStream,
    sink: Sink,
}

#[derive(Clone)]
struct PlaybackWorker {
    tx: Arc<StdMutex<mpsc::Sender<PlaybackCommand>>>,
}

enum PlaybackCommand {
    Snapshot {
        zone_id: String,
        response: oneshot::Sender<Option<OutputSnapshot>>,
    },
    Play {
        zone_id: String,
        output_id: Option<String>,
        path: PathBuf,
        position_ms: u64,
        response: oneshot::Sender<Result<OutputSnapshot>>,
    },
    Resume {
        zone_id: String,
        response: oneshot::Sender<Option<OutputSnapshot>>,
    },
    Pause {
        zone_id: String,
        response: oneshot::Sender<Option<OutputSnapshot>>,
    },
    Stop {
        zone_id: String,
        response: oneshot::Sender<()>,
    },
    Seek {
        zone_id: String,
        position_ms: u64,
        response: oneshot::Sender<Result<Option<OutputSnapshot>>>,
    },
    Volume {
        zone_id: String,
        volume: f32,
        response: oneshot::Sender<bool>,
    },
}

#[derive(Clone, Copy)]
struct OutputSnapshot {
    position_ms: u64,
    is_empty: bool,
    is_paused: bool,
}

impl PlaybackController {
    pub fn new_local() -> Self {
        let mut states = HashMap::new();
        states.insert("local".to_string(), stopped_state("local"));
        Self {
            states: Arc::new(RwLock::new(states)),
            worker: PlaybackWorker::start(),
        }
    }

    pub async fn state(&self) -> PlaybackState {
        self.state_for_zone("local").await
    }

    pub async fn cached_states(&self) -> Vec<PlaybackState> {
        self.states.read().await.values().cloned().collect()
    }

    pub async fn state_for_zone(&self, zone_id: &str) -> PlaybackState {
        let output_state = self.worker.snapshot(zone_id).await;

        let mut states = self.states.write().await;
        let state = states
            .entry(zone_id.to_string())
            .or_insert_with(|| stopped_state(zone_id));

        if let Some(snapshot) = output_state {
            if snapshot.is_empty {
                state.state = PlaybackTransportState::Stopped;
                state.position_ms = 0;
                state.track_id = None;
                state.track_title = None;
            } else {
                state.position_ms = snapshot.position_ms;
                state.state = if snapshot.is_paused {
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
        let snapshot = self
            .worker
            .play(zone_id, output_id, path, position_ms)
            .await?;

        let playback = PlaybackState {
            zone_id: zone_id.to_string(),
            state: PlaybackTransportState::Playing,
            track_id: Some(track_id),
            track_title: Some(title),
            position_ms: snapshot.position_ms,
            queue_revision: 0,
            command_sequence: None,
            origin_client_id: None,
            intent_id: None,
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
        let snapshot = self.worker.resume(zone_id).await;
        let mut states = self.states.write().await;
        let state = states
            .entry(zone_id.to_string())
            .or_insert_with(|| stopped_state(zone_id));
        state.state = PlaybackTransportState::Playing;
        if let Some(snapshot) = snapshot {
            state.position_ms = snapshot.position_ms;
        }
        state.clone()
    }

    pub async fn pause(&self) -> PlaybackState {
        self.pause_zone("local").await
    }

    pub async fn pause_zone(&self, zone_id: &str) -> PlaybackState {
        let snapshot = self.worker.pause(zone_id).await;
        let mut states = self.states.write().await;
        let state = states
            .entry(zone_id.to_string())
            .or_insert_with(|| stopped_state(zone_id));
        state.state = PlaybackTransportState::Paused;
        if let Some(snapshot) = snapshot {
            state.position_ms = snapshot.position_ms;
        }
        state.clone()
    }

    pub async fn stop(&self) -> PlaybackState {
        self.stop_zone("local").await
    }

    pub async fn stop_zone(&self, zone_id: &str) -> PlaybackState {
        self.worker.stop(zone_id).await;
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
        let snapshot = self.worker.seek(zone_id, position_ms).await?;
        let mut states = self.states.write().await;
        let state = states
            .entry(zone_id.to_string())
            .or_insert_with(|| stopped_state(zone_id));
        state.position_ms = snapshot.map_or(position_ms, |snapshot| snapshot.position_ms);
        Ok(state.clone())
    }

    pub async fn set_volume_zone(&self, zone_id: &str, volume: f32) -> bool {
        self.worker
            .set_volume(zone_id, volume.clamp(0.0, 1.0))
            .await
    }
}

impl PlaybackWorker {
    fn start() -> Self {
        let (tx, rx) = mpsc::channel();
        std::thread::Builder::new()
            .name("intmusic-playback".to_string())
            .spawn(move || playback_worker_loop(rx))
            .expect("failed to start playback worker thread");
        Self {
            tx: Arc::new(StdMutex::new(tx)),
        }
    }

    async fn snapshot(&self, zone_id: &str) -> Option<OutputSnapshot> {
        let (response, rx) = oneshot::channel();
        if self
            .send(PlaybackCommand::Snapshot {
                zone_id: zone_id.to_string(),
                response,
            })
            .is_err()
        {
            return None;
        }
        rx.await.ok().flatten()
    }

    async fn play(
        &self,
        zone_id: &str,
        output_id: Option<&str>,
        path: PathBuf,
        position_ms: u64,
    ) -> Result<OutputSnapshot> {
        let (response, rx) = oneshot::channel();
        self.send(PlaybackCommand::Play {
            zone_id: zone_id.to_string(),
            output_id: output_id.map(ToOwned::to_owned),
            path,
            position_ms,
            response,
        })?;
        rx.await
            .map_err(|_| anyhow::anyhow!("playback worker stopped before play completed"))?
    }

    async fn resume(&self, zone_id: &str) -> Option<OutputSnapshot> {
        let (response, rx) = oneshot::channel();
        if self
            .send(PlaybackCommand::Resume {
                zone_id: zone_id.to_string(),
                response,
            })
            .is_err()
        {
            return None;
        }
        rx.await.ok().flatten()
    }

    async fn pause(&self, zone_id: &str) -> Option<OutputSnapshot> {
        let (response, rx) = oneshot::channel();
        if self
            .send(PlaybackCommand::Pause {
                zone_id: zone_id.to_string(),
                response,
            })
            .is_err()
        {
            return None;
        }
        rx.await.ok().flatten()
    }

    async fn stop(&self, zone_id: &str) {
        let (response, rx) = oneshot::channel();
        if self
            .send(PlaybackCommand::Stop {
                zone_id: zone_id.to_string(),
                response,
            })
            .is_ok()
        {
            let _ = rx.await;
        }
    }

    async fn seek(&self, zone_id: &str, position_ms: u64) -> Result<Option<OutputSnapshot>> {
        let (response, rx) = oneshot::channel();
        self.send(PlaybackCommand::Seek {
            zone_id: zone_id.to_string(),
            position_ms,
            response,
        })?;
        rx.await
            .map_err(|_| anyhow::anyhow!("playback worker stopped before seek completed"))?
    }

    async fn set_volume(&self, zone_id: &str, volume: f32) -> bool {
        let (response, rx) = oneshot::channel();
        if self
            .send(PlaybackCommand::Volume {
                zone_id: zone_id.to_string(),
                volume,
                response,
            })
            .is_err()
        {
            return false;
        }
        rx.await.unwrap_or(false)
    }

    fn send(&self, command: PlaybackCommand) -> Result<()> {
        let tx = self
            .tx
            .lock()
            .map_err(|_| anyhow::anyhow!("playback worker channel lock is poisoned"))?;
        tx.send(command)
            .map_err(|_| anyhow::anyhow!("playback worker is not running"))
    }
}

fn playback_worker_loop(rx: mpsc::Receiver<PlaybackCommand>) {
    let mut outputs = HashMap::new();
    while let Ok(command) = rx.recv() {
        match command {
            PlaybackCommand::Snapshot { zone_id, response } => {
                let _ = response.send(outputs.get(&zone_id).map(output_snapshot));
            }
            PlaybackCommand::Play {
                zone_id,
                output_id,
                path,
                position_ms,
                response,
            } => {
                let result = play_output(&mut outputs, zone_id, output_id, path, position_ms);
                let _ = response.send(result);
            }
            PlaybackCommand::Resume { zone_id, response } => {
                let snapshot = outputs.get(&zone_id).map(|output| {
                    output.sink.play();
                    output_snapshot(output)
                });
                let _ = response.send(snapshot);
            }
            PlaybackCommand::Pause { zone_id, response } => {
                let snapshot = outputs.get(&zone_id).map(|output| {
                    output.sink.pause();
                    output_snapshot(output)
                });
                let _ = response.send(snapshot);
            }
            PlaybackCommand::Stop { zone_id, response } => {
                if let Some(output) = outputs.remove(&zone_id) {
                    output.sink.stop();
                }
                let _ = response.send(());
            }
            PlaybackCommand::Seek {
                zone_id,
                position_ms,
                response,
            } => {
                let result = seek_output(&mut outputs, &zone_id, position_ms);
                let _ = response.send(result);
            }
            PlaybackCommand::Volume {
                zone_id,
                volume,
                response,
            } => {
                let changed = outputs.get(&zone_id).is_some_and(|output| {
                    output.sink.set_volume(volume);
                    true
                });
                let _ = response.send(changed);
            }
        }
    }
}

fn play_output(
    outputs: &mut HashMap<String, PlaybackOutput>,
    zone_id: String,
    output_id: Option<String>,
    path: PathBuf,
    position_ms: u64,
) -> Result<OutputSnapshot> {
    let file = File::open(&path)
        .with_context(|| format!("failed to open audio file {}", path.display()))?;
    let source = Decoder::try_from(file)
        .with_context(|| format!("failed to decode audio file {}", path.display()))?;

    let stream = open_stream(output_id.as_deref())?;
    let sink = Sink::connect_new(stream.mixer());
    sink.append(source);
    if position_ms > 0 {
        sink.try_seek(Duration::from_millis(position_ms))
            .map_err(|error| anyhow::anyhow!("failed to seek current track: {error:?}"))?;
    }
    sink.play();

    if let Some(previous) = outputs.remove(&zone_id) {
        previous.sink.stop();
    }
    outputs.insert(
        zone_id.clone(),
        PlaybackOutput {
            _stream: stream,
            sink,
        },
    );
    Ok(outputs
        .get(&zone_id)
        .map(output_snapshot)
        .unwrap_or(OutputSnapshot {
            position_ms,
            is_empty: false,
            is_paused: false,
        }))
}

fn seek_output(
    outputs: &mut HashMap<String, PlaybackOutput>,
    zone_id: &str,
    position_ms: u64,
) -> Result<Option<OutputSnapshot>> {
    let Some(output) = outputs.get(zone_id) else {
        return Ok(None);
    };
    output
        .sink
        .try_seek(Duration::from_millis(position_ms))
        .map_err(|error| anyhow::anyhow!("failed to seek current track: {error:?}"))?;
    Ok(Some(output_snapshot(output)))
}

fn output_snapshot(output: &PlaybackOutput) -> OutputSnapshot {
    OutputSnapshot {
        position_ms: duration_millis(output.sink.get_pos()),
        is_empty: output.sink.empty(),
        is_paused: output.sink.is_paused(),
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
        command_sequence: None,
        origin_client_id: None,
        intent_id: None,
    }
}

fn duration_millis(duration: Duration) -> u64 {
    duration.as_millis().min(u128::from(u64::MAX)) as u64
}
