mod artist_routes;
mod artwork_routes;
mod distribution_routes;
mod events;
mod library_management_routes;
mod playback_service;
mod playlist_routes;
mod renderer_routes;
mod renderers;
mod router;
mod server;
mod settings_routes;
mod sync_routes;
mod track_routes;

pub(crate) use artist_routes::*;
pub(crate) use artwork_routes::*;
pub(crate) use distribution_routes::*;
pub(crate) use events::*;
pub(crate) use library_management_routes::*;
pub(crate) use playback_service::*;
pub(crate) use playlist_routes::*;
pub(crate) use renderer_routes::*;
pub use router::build_router;
pub use server::{serve, serve_with_shutdown};
pub(crate) use settings_routes::*;
pub(crate) use sync_routes::*;
pub(crate) use track_routes::*;

use std::{
    collections::HashMap,
    future::{Future, IntoFuture},
    io::{Cursor, SeekFrom},
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    path::{Path as FsPath, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, RwLock,
    },
    time::{Duration, UNIX_EPOCH},
};

use anyhow::{Context, Result};
use axum::{
    body::Body,
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        DefaultBodyLimit, Multipart, Path, Query, State,
    },
    http::{header, HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::{delete, get, post, put},
    Json, Router,
};
use chrono::Utc;
use core_config::{CoreConfig, CorePaths, FavoritesConfig};
use core_db::DbPool;
use discovery::DiscoveryPublisher;
use futures_util::{SinkExt, StreamExt};
use image::{
    codecs::jpeg::JpegEncoder,
    imageops::{self, FilterType},
    DynamicImage, GenericImageView, ImageFormat, RgbaImage,
};
use library_scanner::{ScannerConfig, ScannerEvent};
use lofty::{
    file::TaggedFileExt,
    picture::{MimeType, PictureType},
    probe::Probe,
};
use playback::PlaybackController;
use protocol::{
    AddPlaybackQueueItems, ApiErrorBody, ClientLibraryManifestRequest, ClientMutationBatchRequest,
    ClientSyncChanges, ClientSyncSnapshot, CoreStatus, CreateDistributionRequest,
    DistributionTaskProgress, EventEnvelope, FavoriteSettingsUpdate, LibraryChangedPayload,
    LinkTrackRecordingRequest, MetadataSettingsUpdate, MovePlaybackQueueItem, MultiZonePlayRequest,
    MusicBrainzArtistPreview, MusicBrainzArtistPreviewRequest, NewLibraryRoot, NewPlaylist,
    PlaybackEvent, PlaybackMode, PlaybackModeUpdate, PlaybackQueue, PlaybackSession, PlaybackState,
    PlaybackStats, PlaybackTransportState, PlaylistDetail, PlaylistTrackMutation,
    RendererCommandPayload, RendererRegistration, RendererStateReport, RendererVolumeStateReport,
    ReplacePlaybackQueue, ResolveClientLibraryFileRequest, ScanProgressPayload, SearchResponse,
    ServerSettingsUpdate, TrackFavoriteUpdate, TrackMetadataUpdate, UpdateArtistAsset,
    UpdateArtistProfile, UpdateArtistVisual, UpdatePlaylist, VolumeControlMode, ZoneAliasUpdate,
    ZoneTransferRequest, ZoneVolume, API_PREFIX, EVENTS_WS_PATH,
};
use serde::Deserialize;
use serde_json::json;
use sha2::{Digest, Sha256};
use tokio::{
    io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt},
    sync::{broadcast, mpsc},
};
use tokio_util::io::ReaderStream;
use tower_http::{compression::CompressionLayer, cors::CorsLayer, trace::TraceLayer};
use tracing::{error, info, warn};
use transcoder::{TranscodeProfile, Transcoder, TranscoderSettings};
use uuid::Uuid;

use renderers::RendererRegistry;

#[derive(Clone)]
pub struct AppState {
    inner: Arc<AppStateInner>,
}

struct AppStateInner {
    config: RwLock<CoreConfig>,
    paths: CorePaths,
    pool: DbPool,
    started_at: chrono::DateTime<Utc>,
    library_revision: AtomicU64,
    events: broadcast::Sender<EventEnvelope>,
    renderer_commands: broadcast::Sender<EventEnvelope>,
    playback: PlaybackController,
    renderers: RendererRegistry,
    playback_control_gates: tokio::sync::Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>,
    server_id: Uuid,
    bind_address: SocketAddr,
    discovery_service: Option<String>,
    musicbrainz_gate: tokio::sync::Mutex<tokio::time::Instant>,
    distribution_claim_gate: tokio::sync::Mutex<()>,
    waveform_cache: tokio::sync::RwLock<HashMap<String, Vec<f32>>>,
    transcoder: Transcoder,
}

impl AppState {
    pub fn new(
        config: CoreConfig,
        paths: CorePaths,
        pool: DbPool,
        server_id: Uuid,
        bind_address: SocketAddr,
        discovery_service: Option<String>,
        transcoder: Transcoder,
    ) -> Self {
        let (events, _) = broadcast::channel(1024);
        let (renderer_commands, _) = broadcast::channel(256);
        Self {
            inner: Arc::new(AppStateInner {
                config: RwLock::new(config),
                paths,
                pool,
                started_at: Utc::now(),
                library_revision: AtomicU64::new(1),
                events,
                renderer_commands,
                playback: PlaybackController::new_local(),
                renderers: RendererRegistry::default(),
                playback_control_gates: tokio::sync::Mutex::new(HashMap::new()),
                server_id,
                bind_address,
                discovery_service,
                musicbrainz_gate: tokio::sync::Mutex::new(
                    tokio::time::Instant::now() - Duration::from_secs(1),
                ),
                distribution_claim_gate: tokio::sync::Mutex::new(()),
                waveform_cache: tokio::sync::RwLock::new(HashMap::new()),
                transcoder,
            }),
        }
    }

    pub fn pool(&self) -> &DbPool {
        &self.inner.pool
    }

    fn config(&self) -> CoreConfig {
        self.inner
            .config
            .read()
            .map(|config| config.clone())
            .unwrap_or_default()
    }

    fn emit(&self, event_type: impl Into<String>, payload: impl serde::Serialize) {
        let _ = self
            .inner
            .events
            .send(EventEnvelope::new(event_type, payload));
    }

    fn emit_renderer_command(&self, renderer_id: &str, command: &RendererCommandPayload) {
        let _ = self.inner.renderer_commands.send(EventEnvelope::new(
            "renderer.command",
            json!({ "renderer_id": renderer_id, "command": command }),
        ));
    }

    async fn playback_control_gate(&self, zone_id: &str) -> Arc<tokio::sync::Mutex<()>> {
        let mut gates = self.inner.playback_control_gates.lock().await;
        gates
            .entry(zone_id.to_string())
            .or_insert_with(|| Arc::new(tokio::sync::Mutex::new(())))
            .clone()
    }

    async fn bump_library_revision(&self, reason: &str) -> u64 {
        let scope = sync_scope_for_reason(reason);
        let revision = match core_db::append_sync_change(self.pool(), scope, reason).await {
            Ok(cursor) => cursor,
            Err(error) => {
                error!(%error, reason, "failed to persist Client sync change");
                self.inner.library_revision.fetch_add(1, Ordering::SeqCst) + 1
            }
        };
        self.inner
            .library_revision
            .fetch_max(revision, Ordering::SeqCst);
        self.emit(
            "library.changed",
            LibraryChangedPayload {
                revision,
                reason: reason.to_string(),
            },
        );
        revision
    }
}

fn sync_scope_for_reason(reason: &str) -> &'static str {
    let normalized = reason.to_ascii_lowercase();
    if normalized.contains("artist") {
        "artists"
    } else if normalized.contains("playlist") {
        "playlists"
    } else if normalized.contains("track")
        || normalized.contains("favorite")
        || normalized.contains("recording")
        || normalized.contains("metadata")
        || normalized.contains("mutation")
    {
        "tracks"
    } else {
        "library"
    }
}

#[derive(Debug, Deserialize)]
struct Paging {
    limit: Option<u32>,
    offset: Option<u32>,
}

#[derive(Debug, Clone, Default, Deserialize)]
struct PlaybackCommandContext {
    #[serde(default)]
    origin_client_id: Option<String>,
    #[serde(default)]
    intent_id: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct PlaybackControlRequest {
    #[serde(flatten)]
    command: PlaybackCommandContext,
}

#[derive(Debug, Default, Deserialize)]
struct PlayControlRequest {
    track_id: Option<i64>,
    position_ms: Option<u64>,
    #[serde(flatten)]
    command: PlaybackCommandContext,
}

#[derive(Debug, Deserialize)]
struct PlayCollectionControlRequest {
    track_ids: Vec<i64>,
    start_index: Option<i64>,
    mode: Option<PlaybackMode>,
    #[serde(flatten)]
    command: PlaybackCommandContext,
}

impl PlayCollectionControlRequest {
    fn queue_request(&self) -> ReplacePlaybackQueue {
        ReplacePlaybackQueue {
            track_ids: self.track_ids.clone(),
            start_index: self.start_index,
            mode: self.mode,
        }
    }
}

#[derive(Debug, Deserialize)]
struct SeekControlRequest {
    position_ms: u64,
    #[serde(flatten)]
    command: PlaybackCommandContext,
}

#[derive(Debug, Deserialize)]
struct VolumeControlRequest {
    volume: f32,
    muted: Option<bool>,
    #[serde(default)]
    mode: VolumeControlMode,
    #[serde(flatten)]
    command: PlaybackCommandContext,
}

const TRANSPORT_COMMAND_TTL_MS: u64 = 6_000;
const VOLUME_COMMAND_TTL_MS: u64 = 4_000;

#[allow(clippy::too_many_arguments)]
fn parse_range(headers: &HeaderMap, file_len: u64) -> Option<(u64, u64)> {
    if file_len == 0 {
        return None;
    }

    let range = headers.get(header::RANGE)?.to_str().ok()?;
    let range = range.strip_prefix("bytes=")?;
    let (start, end) = range.split_once('-')?;

    if start.is_empty() {
        let suffix_len = end.parse::<u64>().ok()?.min(file_len);
        let start = file_len.saturating_sub(suffix_len);
        return Some((start, file_len - 1));
    }

    let start = start.parse::<u64>().ok()?;
    let end = if end.is_empty() {
        file_len - 1
    } else {
        end.parse::<u64>().ok()?.min(file_len - 1)
    };

    (start <= end && start < file_len).then_some((start, end))
}

fn content_type_for_extension(extension: &str) -> &'static str {
    match extension.to_ascii_lowercase().as_str() {
        "flac" => "audio/flac",
        "mp3" => "audio/mpeg",
        "m4a" | "mp4" => "audio/mp4",
        "ogg" | "oga" => "audio/ogg",
        "wav" => "audio/wav",
        _ => "application/octet-stream",
    }
}

type ApiResult<T> = Result<Json<T>, ApiError>;

#[derive(Debug)]
struct ApiError(anyhow::Error);

impl From<anyhow::Error> for ApiError {
    fn from(error: anyhow::Error) -> Self {
        Self(error)
    }
}

impl From<std::io::Error> for ApiError {
    fn from(error: std::io::Error) -> Self {
        Self(error.into())
    }
}

impl From<reqwest::Error> for ApiError {
    fn from(error: reqwest::Error) -> Self {
        Self(error.into())
    }
}

impl From<axum::extract::multipart::MultipartError> for ApiError {
    fn from(error: axum::extract::multipart::MultipartError) -> Self {
        Self(error.into())
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        error!(error = %self.0, "api error");
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiErrorBody {
                error: self.0.to_string(),
            }),
        )
            .into_response()
    }
}

pub async fn initialize_database(paths: &CorePaths, config: &CoreConfig) -> Result<DbPool> {
    core_config::ensure_runtime_dirs(paths)?;
    let pool = core_db::connect(&paths.database_file).await?;
    core_db::migrate(&pool).await?;
    core_db::sync_configured_roots(&pool, &config.library.roots).await?;
    Ok(pool)
}

pub async fn run_until_shutdown(bind_addr: SocketAddr, router: Router) -> Result<()> {
    let listener = tokio::net::TcpListener::bind(bind_addr).await?;
    axum::serve(listener, router)
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    Ok(())
}

#[cfg(test)]
mod tests;
