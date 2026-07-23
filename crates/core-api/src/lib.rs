mod renderers;

use std::{
    future::Future,
    io::SeekFrom,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    path::{Path as FsPath, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, RwLock,
    },
    time::UNIX_EPOCH,
};

use anyhow::Result;
use axum::{
    body::Body,
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        Path, Query, State,
    },
    http::{header, HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::{delete, get, post},
    Json, Router,
};
use chrono::Utc;
use core_config::{CoreConfig, CorePaths, FavoritesConfig};
use core_db::DbPool;
use discovery::DiscoveryPublisher;
use library_scanner::{ScannerConfig, ScannerEvent};
use lofty::{
    file::TaggedFileExt,
    picture::{MimeType, PictureType},
    probe::Probe,
};
use playback::PlaybackController;
use protocol::{
    AddPlaybackQueueItems, ApiErrorBody, CoreStatus, EventEnvelope, FavoriteSettingsUpdate,
    LibraryChangedPayload, MetadataSettingsUpdate, MovePlaybackQueueItem, MultiZonePlayRequest,
    NewLibraryRoot, NewPlaylist, PlayRequest, PlaybackEvent, PlaybackModeUpdate, PlaybackQueue,
    PlaybackSession, PlaybackState, PlaybackStats, PlaybackTransportState, PlaylistDetail,
    PlaylistTrackMutation, RendererCommandPayload, RendererRegistration, RendererStateReport,
    ReplacePlaybackQueue, ScanProgressPayload, SearchResponse, SeekRequest, ServerSettingsUpdate,
    TrackFavoriteUpdate, UpdatePlaylist, ZoneAliasUpdate, ZoneTransferRequest, ZoneVolume,
    ZoneVolumeUpdate, API_PREFIX, EVENTS_WS_PATH,
};
use serde::Deserialize;
use serde_json::json;
use sha2::{Digest, Sha256};
use tokio::{
    io::{AsyncReadExt, AsyncSeekExt},
    sync::{broadcast, mpsc},
};
use tokio_util::io::ReaderStream;
use tower_http::{cors::CorsLayer, trace::TraceLayer};
use tracing::{error, info};
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
    playback: PlaybackController,
    renderers: RendererRegistry,
    server_id: Uuid,
    bind_address: SocketAddr,
    discovery_service: Option<String>,
}

impl AppState {
    pub fn new(
        config: CoreConfig,
        paths: CorePaths,
        pool: DbPool,
        server_id: Uuid,
        bind_address: SocketAddr,
        discovery_service: Option<String>,
    ) -> Self {
        let (events, _) = broadcast::channel(1024);
        Self {
            inner: Arc::new(AppStateInner {
                config: RwLock::new(config),
                paths,
                pool,
                started_at: Utc::now(),
                library_revision: AtomicU64::new(1),
                events,
                playback: PlaybackController::new_local(),
                renderers: RendererRegistry::default(),
                server_id,
                bind_address,
                discovery_service,
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

    fn bump_library_revision(&self, reason: &str) -> u64 {
        let revision = self.inner.library_revision.fetch_add(1, Ordering::SeqCst) + 1;
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

pub async fn serve(config: CoreConfig, paths: CorePaths, pool: DbPool) -> Result<()> {
    serve_with_shutdown(config, paths, pool, std::future::pending()).await
}

pub async fn serve_with_shutdown<S>(
    config: CoreConfig,
    paths: CorePaths,
    pool: DbPool,
    shutdown: S,
) -> Result<()>
where
    S: Future<Output = ()> + Send + 'static,
{
    let (listener, bind_addr) = bind_core_listener(&config).await?;
    let server_id = Uuid::new_v4();
    let runtime_endpoint_file = write_runtime_endpoint(&paths, bind_addr, server_id).await?;
    let discovery_name = core_display_name(&config);
    let discovery_publisher = if config.server.advertise_mdns {
        match DiscoveryPublisher::publish_core(
            &server_id.to_string(),
            &discovery_name,
            bind_addr.port(),
            "v1",
            API_PREFIX,
        ) {
            Ok(publisher) => {
                info!(service = publisher.fullname(), "mDNS discovery published");
                Some(publisher)
            }
            Err(error) => {
                error!(%error, "failed to publish mDNS discovery");
                None
            }
        }
    } else {
        None
    };
    let discovery_service = discovery_publisher
        .as_ref()
        .map(|publisher| publisher.fullname().to_string());
    let state = AppState::new(config, paths, pool, server_id, bind_addr, discovery_service);
    state.emit("core.ready", json!({ "api_prefix": API_PREFIX }));
    start_renderer_expiry_monitor(state.clone());
    start_local_playback_monitor(state.clone());
    let router = build_router(state);
    info!(address = %bind_addr, "local music core listening");
    let _discovery_publisher = discovery_publisher;
    let serve_result = axum::serve(listener, router)
        .with_graceful_shutdown(shutdown)
        .await;
    if let Err(error) = tokio::fs::remove_file(&runtime_endpoint_file).await {
        if error.kind() != std::io::ErrorKind::NotFound {
            error!(
                path = %runtime_endpoint_file.display(),
                %error,
                "failed to remove the runtime endpoint file"
            );
        }
    }
    serve_result?;
    Ok(())
}

async fn write_runtime_endpoint(
    paths: &CorePaths,
    bind_addr: SocketAddr,
    server_id: Uuid,
) -> Result<PathBuf> {
    let local_ip = match bind_addr.ip() {
        IpAddr::V4(ip) if ip.is_unspecified() => IpAddr::V4(Ipv4Addr::LOCALHOST),
        IpAddr::V6(ip) if ip.is_unspecified() => IpAddr::V6(Ipv6Addr::LOCALHOST),
        ip => ip,
    };
    let local_addr = SocketAddr::new(local_ip, bind_addr.port());
    let endpoint_file = paths.data_dir.join("core-endpoint.json");
    let endpoint = serde_json::to_vec_pretty(&json!({
        "base_url": format!("http://{local_addr}"),
        "bind_address": bind_addr.to_string(),
        "server_id": server_id,
        "pid": std::process::id(),
    }))?;
    tokio::fs::write(&endpoint_file, endpoint).await?;
    Ok(endpoint_file)
}

fn start_renderer_expiry_monitor(state: AppState) {
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(5));
        loop {
            interval.tick().await;
            expire_offline_renderer_playback(&state).await;
        }
    });
}

fn start_local_playback_monitor(state: AppState) {
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_millis(750));
        loop {
            interval.tick().await;
            for previous in state.inner.playback.cached_states().await {
                if previous.state != PlaybackTransportState::Playing || previous.track_id.is_none()
                {
                    continue;
                }
                let current = state.inner.playback.state_for_zone(&previous.zone_id).await;
                if current.state != PlaybackTransportState::Stopped {
                    continue;
                }
                record_playback_finish(&state, &previous, "completed", "completed", None).await;
                state.emit("playback.state_changed", &current);
                match step_playback_queue_and_emit(&state, &previous.zone_id, false, true).await {
                    Ok(Some(track_id)) => {
                        if let Err(error) =
                            play_track_on_zone(&state, &previous.zone_id, track_id, 0).await
                        {
                            error!(
                                zone_id = previous.zone_id,
                                %error,
                                "failed to advance the local playback queue"
                            );
                        }
                    }
                    Ok(None) => {}
                    Err(error) => {
                        error!(
                            zone_id = previous.zone_id,
                            %error,
                            "failed to resolve the next local queue item"
                        );
                    }
                }
            }
        }
    });
}

async fn bind_core_listener(config: &CoreConfig) -> Result<(tokio::net::TcpListener, SocketAddr)> {
    let configured_addr = config.bind_addr()?;
    if !config.server.auto_port {
        let listener = tokio::net::TcpListener::bind(configured_addr).await?;
        return Ok((listener, configured_addr));
    }

    let ports = shuffled_ports(config.server.port_range_start, config.server.port_range_end);
    let mut last_error = None;
    for port in ports {
        let addr = SocketAddr::new(configured_addr.ip(), port);
        match tokio::net::TcpListener::bind(addr).await {
            Ok(listener) => return Ok((listener, addr)),
            Err(error) => {
                last_error = Some(error);
            }
        }
    }

    let error = last_error
        .map(|error| error.to_string())
        .unwrap_or_else(|| "empty port range".to_string());
    anyhow::bail!(
        "no available core port in {}-{} on {}: {}",
        config.server.port_range_start,
        config.server.port_range_end,
        configured_addr.ip(),
        error
    )
}

fn shuffled_ports(start: u16, end: u16) -> Vec<u16> {
    if start > end {
        return Vec::new();
    }
    let mut ports = (start..=end).collect::<Vec<_>>();
    let mut seed = u128::from_le_bytes(*Uuid::new_v4().as_bytes());
    for index in (1..ports.len()).rev() {
        seed = seed
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        ports.swap(index, (seed as usize) % (index + 1));
    }
    ports
}

pub fn build_router(state: AppState) -> Router {
    let api = Router::new()
        .route("/status", get(status))
        .route("/library/roots", get(list_roots).post(add_root))
        .route("/library/roots/{id}", delete(remove_root))
        .route("/scan/start", post(start_scan))
        .route("/scan/problems", get(scan_problems))
        .route("/albums", get(list_albums))
        .route("/albums/{album_id}", get(album_detail))
        .route("/artists", get(list_artists))
        .route("/artists/{artist_id}", get(artist_detail))
        .route("/tracks", get(list_tracks))
        .route("/tracks/{track_id}", get(track_detail))
        .route("/tracks/{track_id}/favorite", post(update_track_favorite))
        .route("/tracks/{track_id}/lyrics", get(track_lyrics))
        .route("/tracks/{track_id}/stream", get(track_stream))
        .route("/artwork/albums/{album_id}", get(album_artwork))
        .route("/artwork/tracks/{track_id}", get(track_artwork))
        .route("/search", get(search))
        .route("/playlists", get(list_playlists).post(create_playlist))
        .route(
            "/playlists/{playlist_id}",
            get(get_playlist)
                .post(update_playlist)
                .delete(delete_playlist),
        )
        .route("/playlists/{playlist_id}/tracks", post(add_playlist_track))
        .route(
            "/playlists/{playlist_id}/tracks/{track_id}",
            delete(remove_playlist_track),
        )
        .route("/outputs", get(list_outputs))
        .route("/renderers", get(list_renderers))
        .route("/renderers/register", post(register_renderer))
        .route("/renderers/{client_id}/state", post(report_renderer_state))
        .route("/zones", get(list_zones))
        .route("/zones/play-many", post(play_many_zones))
        .route("/zones/{zone_id}/play", post(play_zone))
        .route("/zones/{zone_id}/pause", post(pause_zone))
        .route("/zones/{zone_id}/stop", post(stop_zone))
        .route("/zones/{zone_id}/seek", post(seek_zone))
        .route(
            "/zones/{zone_id}/queue",
            get(get_zone_queue).post(replace_zone_queue),
        )
        .route("/zones/{zone_id}/queue/items", post(add_zone_queue_items))
        .route(
            "/zones/{zone_id}/queue/items/{item_id}",
            delete(remove_zone_queue_item),
        )
        .route("/zones/{zone_id}/queue/move", post(move_zone_queue_item))
        .route("/zones/{zone_id}/queue/mode", post(update_zone_queue_mode))
        .route("/zones/{zone_id}/next", post(next_zone_track))
        .route("/zones/{zone_id}/previous", post(previous_zone_track))
        .route(
            "/zones/{zone_id}/volume",
            get(get_zone_volume).post(update_zone_volume),
        )
        .route("/zones/{zone_id}/alias", post(update_zone_alias))
        .route("/zones/{zone_id}/transfer", post(transfer_zone))
        .route("/playback/history", get(playback_history))
        .route("/playback/sessions", get(playback_sessions))
        .route("/playback/stats", get(playback_stats))
        .route("/settings", get(settings))
        .route(
            "/settings/server",
            get(server_settings).post(update_server_settings),
        )
        .route(
            "/settings/favorites",
            get(favorite_settings).post(update_favorite_settings),
        )
        .route(
            "/settings/metadata",
            get(metadata_settings).post(update_metadata_settings),
        )
        .route("/diagnostics", get(diagnostics));

    Router::new()
        .nest(API_PREFIX, api)
        .route(EVENTS_WS_PATH, get(events_ws))
        .layer(CorsLayer::permissive())
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

async fn status(State(state): State<AppState>) -> ApiResult<CoreStatus> {
    let counts = core_db::library_counts(state.pool()).await?;
    Ok(Json(CoreStatus {
        name: "IntMusic Local Music Core".to_string(),
        display_name: core_display_name(&state.config()),
        version: env!("CARGO_PKG_VERSION").to_string(),
        api_version: "v1".to_string(),
        server_id: state.inner.server_id.to_string(),
        bind_address: state.inner.bind_address.to_string(),
        discovery_service: state.inner.discovery_service.clone(),
        started_at: state.inner.started_at,
        library_revision: state.inner.library_revision.load(Ordering::SeqCst),
        database_path: state.inner.paths.database_file.display().to_string(),
        counts,
    }))
}

fn core_display_name(config: &CoreConfig) -> String {
    config
        .server
        .alias
        .as_deref()
        .map(str::trim)
        .filter(|alias| !alias.is_empty())
        .unwrap_or("Core local")
        .to_string()
}

async fn list_roots(State(state): State<AppState>) -> ApiResult<Vec<protocol::LibraryRoot>> {
    Ok(Json(core_db::list_library_roots(state.pool()).await?))
}

async fn add_root(
    State(state): State<AppState>,
    Json(payload): Json<NewLibraryRoot>,
) -> ApiResult<protocol::LibraryRoot> {
    let root = core_db::add_library_root(state.pool(), payload.path.as_ref()).await?;
    state.bump_library_revision("library_root_added");
    Ok(Json(root))
}

async fn remove_root(
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> ApiResult<serde_json::Value> {
    core_db::remove_library_root(state.pool(), id).await?;
    state.bump_library_revision("library_root_removed");
    Ok(Json(json!({ "removed": true })))
}

async fn start_scan(State(state): State<AppState>) -> ApiResult<serde_json::Value> {
    let (tx, mut rx) = mpsc::unbounded_channel();
    let config = state.config();
    let scanner_config = ScannerConfig {
        extensions: config.library.extensions.clone(),
        artist_separators: config.metadata.artist_separators.clone(),
        genre_separators: config.metadata.genre_separators.clone(),
    };
    let scan_state = state.clone();
    let event_state = state.clone();

    tokio::spawn(async move {
        while let Some(event) = rx.recv().await {
            match event {
                ScannerEvent::Started => event_state.emit("scan.started", json!({})),
                ScannerEvent::Progress(summary) => {
                    event_state.emit("scan.progress", ScanProgressPayload::from(&summary))
                }
                ScannerEvent::Finished(summary) => {
                    event_state.emit("scan.finished", ScanProgressPayload::from(&summary));
                    event_state.bump_library_revision("scan_finished");
                }
                ScannerEvent::Problem { path, message } => event_state.emit(
                    "scan.problem_found",
                    json!({ "path": path, "message": message }),
                ),
            }
        }
    });

    tokio::spawn(async move {
        if let Err(error) =
            library_scanner::scan_all_roots(scan_state.pool().clone(), scanner_config, Some(tx))
                .await
        {
            error!(error = %error, "scan failed");
            scan_state.emit("scan.finished", json!({ "error": error.to_string() }));
        }
    });

    Ok(Json(json!({ "status": "started" })))
}

async fn scan_problems(
    State(state): State<AppState>,
    Query(paging): Query<Paging>,
) -> ApiResult<Vec<protocol::ScanProblem>> {
    Ok(Json(
        core_db::scan_problems(state.pool(), paging.limit(), paging.offset()).await?,
    ))
}

async fn list_albums(
    State(state): State<AppState>,
    Query(paging): Query<Paging>,
) -> ApiResult<Vec<protocol::AlbumSummary>> {
    Ok(Json(
        core_db::list_albums(state.pool(), paging.limit(), paging.offset()).await?,
    ))
}

async fn album_detail(
    State(state): State<AppState>,
    Path(album_id): Path<i64>,
) -> ApiResult<protocol::AlbumDetail> {
    let mut detail = core_db::album_detail(state.pool(), album_id).await?;
    apply_favorite_settings_to_tracks(&state.config().favorites, &mut detail.tracks);
    Ok(Json(detail))
}

async fn list_artists(
    State(state): State<AppState>,
    Query(paging): Query<Paging>,
) -> ApiResult<Vec<protocol::ArtistSummary>> {
    Ok(Json(
        core_db::list_artists(state.pool(), paging.limit(), paging.offset()).await?,
    ))
}

async fn artist_detail(
    State(state): State<AppState>,
    Path(artist_id): Path<i64>,
) -> ApiResult<protocol::ArtistDetail> {
    let config = state.config();
    let mut detail = core_db::artist_detail(state.pool(), artist_id).await?;
    apply_favorite_settings_to_tracks(&config.favorites, &mut detail.tracks);
    Ok(Json(detail))
}

async fn list_tracks(
    State(state): State<AppState>,
    Query(paging): Query<Paging>,
) -> ApiResult<Vec<protocol::TrackSummary>> {
    let mut tracks = core_db::list_tracks(state.pool(), paging.limit(), paging.offset()).await?;
    apply_favorite_settings_to_tracks(&state.config().favorites, &mut tracks);
    Ok(Json(tracks))
}

async fn track_detail(
    State(state): State<AppState>,
    Path(track_id): Path<i64>,
) -> ApiResult<protocol::TrackDetail> {
    let mut detail = core_db::track_detail(state.pool(), track_id).await?;
    fill_missing_lyrics_from_file(&mut detail).await;
    apply_favorite_settings_to_track(&state.config().favorites, &mut detail.track);
    Ok(Json(detail))
}

async fn track_lyrics(
    State(state): State<AppState>,
    Path(track_id): Path<i64>,
) -> ApiResult<Option<protocol::LyricPayload>> {
    let mut detail = core_db::track_detail(state.pool(), track_id).await?;
    fill_missing_lyrics_from_file(&mut detail).await;
    Ok(Json(detail.lyrics))
}

async fn fill_missing_lyrics_from_file(detail: &mut protocol::TrackDetail) {
    if detail
        .lyrics
        .as_ref()
        .is_some_and(|lyrics| !lyrics.text.trim().is_empty())
    {
        return;
    }
    let path = PathBuf::from(&detail.file_path);
    match tokio::task::spawn_blocking(move || library_scanner::extract_lyrics_from_path(&path))
        .await
    {
        Ok(Ok(Some((kind, text)))) if !text.trim().is_empty() => {
            detail.lyrics = Some(protocol::LyricPayload { kind, text });
        }
        _ => {}
    }
}

async fn track_stream(
    State(state): State<AppState>,
    Path(track_id): Path<i64>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let detail = core_db::track_detail(state.pool(), track_id).await?;
    let path = std::path::PathBuf::from(&detail.file_path);
    let mut file = tokio::fs::File::open(&path)
        .await
        .map_err(anyhow::Error::from)?;
    let file_len = file.metadata().await.map_err(anyhow::Error::from)?.len();
    if file_len == 0 {
        let mut response = Response::new(Body::empty());
        response.headers_mut().insert(
            header::CONTENT_TYPE,
            HeaderValue::from_static(content_type_for_extension(&detail.extension)),
        );
        response
            .headers_mut()
            .insert(header::CONTENT_LENGTH, HeaderValue::from_static("0"));
        return Ok(response);
    }

    let (status, start, end) = match parse_range(&headers, file_len) {
        Some((start, end)) => (StatusCode::PARTIAL_CONTENT, start, end),
        None => (StatusCode::OK, 0, file_len.saturating_sub(1)),
    };
    let content_len = end.saturating_sub(start).saturating_add(1);

    file.seek(SeekFrom::Start(start))
        .await
        .map_err(anyhow::Error::from)?;
    let body = Body::from_stream(ReaderStream::new(file.take(content_len)));
    let mut response = Response::new(body);
    *response.status_mut() = status;
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static(content_type_for_extension(&detail.extension)),
    );
    response
        .headers_mut()
        .insert(header::ACCEPT_RANGES, HeaderValue::from_static("bytes"));
    response.headers_mut().insert(
        header::CONTENT_LENGTH,
        HeaderValue::from_str(&content_len.to_string()).map_err(anyhow::Error::from)?,
    );
    if status == StatusCode::PARTIAL_CONTENT {
        response.headers_mut().insert(
            header::CONTENT_RANGE,
            HeaderValue::from_str(&format!("bytes {start}-{end}/{file_len}"))
                .map_err(anyhow::Error::from)?,
        );
    }
    Ok(response)
}

async fn album_artwork(
    State(state): State<AppState>,
    Path(album_id): Path<i64>,
) -> Result<Response, ApiError> {
    let detail = core_db::album_detail(state.pool(), album_id).await?;
    let Some(track_id) = detail.tracks.first().map(|track| track.id) else {
        return Ok(empty_response(StatusCode::NOT_FOUND));
    };
    artwork_response_for_track(&state, track_id).await
}

async fn track_artwork(
    State(state): State<AppState>,
    Path(track_id): Path<i64>,
) -> Result<Response, ApiError> {
    artwork_response_for_track(&state, track_id).await
}

async fn artwork_response_for_track(state: &AppState, track_id: i64) -> Result<Response, ApiError> {
    let source_path = PathBuf::from(core_db::track_file_path(state.pool(), track_id).await?);
    let Some(artwork) =
        cached_artwork_for_source(&state.inner.paths.cache_dir, source_path).await?
    else {
        return Ok(empty_response(StatusCode::NOT_FOUND));
    };

    let file = tokio::fs::File::open(&artwork.path)
        .await
        .map_err(anyhow::Error::from)?;
    let body = Body::from_stream(ReaderStream::new(file));
    let mut response = Response::new(body);
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_str(&artwork.mime_type).map_err(anyhow::Error::from)?,
    );
    response.headers_mut().insert(
        header::CONTENT_LENGTH,
        HeaderValue::from_str(&artwork.len.to_string()).map_err(anyhow::Error::from)?,
    );
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("public, max-age=86400"),
    );
    Ok(response)
}

fn empty_response(status: StatusCode) -> Response {
    let mut response = Response::new(Body::empty());
    *response.status_mut() = status;
    response
}

#[derive(Debug, Clone)]
struct CachedArtwork {
    path: PathBuf,
    mime_type: String,
    len: u64,
}

#[derive(Debug)]
struct ExtractedArtwork {
    bytes: Vec<u8>,
    mime_type: String,
    extension: String,
}

async fn cached_artwork_for_source(
    cache_dir: &FsPath,
    source_path: PathBuf,
) -> Result<Option<CachedArtwork>> {
    let metadata = tokio::fs::metadata(&source_path)
        .await
        .map_err(anyhow::Error::from)?;
    let key = artwork_cache_key(&source_path, &metadata);
    let artwork_dir = cache_dir.join("artwork");
    tokio::fs::create_dir_all(&artwork_dir)
        .await
        .map_err(anyhow::Error::from)?;

    if let Some(cached) = find_cached_artwork(&artwork_dir, &key).await? {
        return Ok(Some(cached));
    }

    let extracted = tokio::task::spawn_blocking(move || extract_embedded_artwork(&source_path))
        .await
        .map_err(anyhow::Error::from)??;
    let Some(extracted) = extracted else {
        return Ok(None);
    };

    let path = artwork_dir.join(format!("{key}.{}", extracted.extension));
    tokio::fs::write(&path, &extracted.bytes)
        .await
        .map_err(anyhow::Error::from)?;
    Ok(Some(CachedArtwork {
        path,
        mime_type: extracted.mime_type,
        len: extracted.bytes.len() as u64,
    }))
}

fn artwork_cache_key(source_path: &FsPath, metadata: &std::fs::Metadata) -> String {
    let modified = metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|duration| format!("{}:{}", duration.as_secs(), duration.subsec_nanos()))
        .unwrap_or_default();
    let mut hasher = Sha256::new();
    hasher.update(source_path.to_string_lossy().as_bytes());
    hasher.update(b"|");
    hasher.update(metadata.len().to_string().as_bytes());
    hasher.update(b"|");
    hasher.update(modified.as_bytes());
    hex::encode(hasher.finalize())
}

async fn find_cached_artwork(artwork_dir: &FsPath, key: &str) -> Result<Option<CachedArtwork>> {
    for (extension, mime_type) in [
        ("jpg", "image/jpeg"),
        ("jpeg", "image/jpeg"),
        ("png", "image/png"),
        ("gif", "image/gif"),
        ("bmp", "image/bmp"),
        ("tif", "image/tiff"),
        ("tiff", "image/tiff"),
    ] {
        let path = artwork_dir.join(format!("{key}.{extension}"));
        let Ok(metadata) = tokio::fs::metadata(&path).await else {
            continue;
        };
        if metadata.is_file() {
            return Ok(Some(CachedArtwork {
                path,
                mime_type: mime_type.to_string(),
                len: metadata.len(),
            }));
        }
    }
    Ok(None)
}

fn extract_embedded_artwork(source_path: &FsPath) -> Result<Option<ExtractedArtwork>> {
    let tagged_file = Probe::open(source_path)?.read()?;
    let picture = tagged_file
        .tags()
        .iter()
        .find_map(|tag| tag.get_picture_type(PictureType::CoverFront))
        .or_else(|| {
            tagged_file
                .tags()
                .iter()
                .find_map(|tag| tag.pictures().first())
        });
    let Some(picture) = picture else {
        return Ok(None);
    };
    if picture.data().is_empty() {
        return Ok(None);
    }
    let (mime_type, extension) = picture_mime_and_extension(picture.mime_type(), picture.data());
    Ok(Some(ExtractedArtwork {
        bytes: picture.data().to_vec(),
        mime_type,
        extension,
    }))
}

fn picture_mime_and_extension(mime_type: Option<&MimeType>, data: &[u8]) -> (String, String) {
    if let Some(mime_type) = mime_type {
        if let Some(extension) = mime_type.ext() {
            return (mime_type.as_str().to_string(), extension.to_string());
        }
    }
    if data.starts_with(&[0xff, 0xd8, 0xff]) {
        return ("image/jpeg".to_string(), "jpg".to_string());
    }
    if data.starts_with(b"\x89PNG\r\n\x1a\n") {
        return ("image/png".to_string(), "png".to_string());
    }
    if data.starts_with(b"GIF87a") || data.starts_with(b"GIF89a") {
        return ("image/gif".to_string(), "gif".to_string());
    }
    if data.starts_with(b"BM") {
        return ("image/bmp".to_string(), "bmp".to_string());
    }
    ("application/octet-stream".to_string(), "bin".to_string())
}

async fn search(
    State(state): State<AppState>,
    Query(query): Query<SearchParams>,
) -> ApiResult<SearchResponse> {
    let limit = query.limit.unwrap_or(25).clamp(1, 100);
    let config = state.config();
    let mut response = SearchResponse {
        query: query.q.clone(),
        tracks: core_db::search_tracks(state.pool(), &query.q, limit).await?,
        albums: core_db::search_albums(state.pool(), &query.q, limit).await?,
        artists: core_db::search_artists(state.pool(), &query.q, limit).await?,
    };
    apply_favorite_settings_to_tracks(&config.favorites, &mut response.tracks);
    Ok(Json(response))
}

async fn list_playlists(
    State(state): State<AppState>,
) -> ApiResult<Vec<protocol::PlaylistSummary>> {
    let config = state.config();
    Ok(Json(
        core_db::list_playlists(state.pool(), config.favorites.treat_max_rating_as_favorite)
            .await?,
    ))
}

async fn create_playlist(
    State(state): State<AppState>,
    Json(payload): Json<NewPlaylist>,
) -> ApiResult<PlaylistDetail> {
    let config = state.config();
    let mut detail = core_db::create_playlist(
        state.pool(),
        payload,
        config.favorites.treat_max_rating_as_favorite,
    )
    .await?;
    apply_favorite_settings_to_playlist(&config.favorites, &mut detail);
    state.bump_library_revision("playlist_created");
    Ok(Json(detail))
}

async fn get_playlist(
    State(state): State<AppState>,
    Path(playlist_id): Path<i64>,
) -> ApiResult<PlaylistDetail> {
    let config = state.config();
    let mut detail = core_db::playlist_detail(
        state.pool(),
        playlist_id,
        config.favorites.treat_max_rating_as_favorite,
    )
    .await?;
    apply_favorite_settings_to_playlist(&config.favorites, &mut detail);
    Ok(Json(detail))
}

async fn update_playlist(
    State(state): State<AppState>,
    Path(playlist_id): Path<i64>,
    Json(payload): Json<UpdatePlaylist>,
) -> ApiResult<PlaylistDetail> {
    let config = state.config();
    let mut detail = core_db::update_playlist(
        state.pool(),
        playlist_id,
        payload,
        config.favorites.treat_max_rating_as_favorite,
    )
    .await?;
    apply_favorite_settings_to_playlist(&config.favorites, &mut detail);
    state.bump_library_revision("playlist_updated");
    Ok(Json(detail))
}

async fn delete_playlist(
    State(state): State<AppState>,
    Path(playlist_id): Path<i64>,
) -> ApiResult<serde_json::Value> {
    core_db::delete_playlist(state.pool(), playlist_id).await?;
    state.bump_library_revision("playlist_deleted");
    Ok(Json(json!({ "deleted": true })))
}

async fn add_playlist_track(
    State(state): State<AppState>,
    Path(playlist_id): Path<i64>,
    Json(payload): Json<PlaylistTrackMutation>,
) -> ApiResult<PlaylistDetail> {
    let config = state.config();
    let mut detail = core_db::add_playlist_track(
        state.pool(),
        playlist_id,
        payload,
        config.favorites.treat_max_rating_as_favorite,
    )
    .await?;
    apply_favorite_settings_to_playlist(&config.favorites, &mut detail);
    state.bump_library_revision("playlist_track_added");
    Ok(Json(detail))
}

async fn remove_playlist_track(
    State(state): State<AppState>,
    Path((playlist_id, track_id)): Path<(i64, i64)>,
) -> ApiResult<PlaylistDetail> {
    let config = state.config();
    let mut detail = core_db::remove_playlist_track(
        state.pool(),
        playlist_id,
        track_id,
        config.favorites.treat_max_rating_as_favorite,
    )
    .await?;
    apply_favorite_settings_to_playlist(&config.favorites, &mut detail);
    state.bump_library_revision("playlist_track_removed");
    Ok(Json(detail))
}

async fn update_track_favorite(
    State(state): State<AppState>,
    Path(track_id): Path<i64>,
    Json(mut payload): Json<TrackFavoriteUpdate>,
) -> ApiResult<protocol::TrackDetail> {
    let config = state.config();
    if payload.is_favorite && config.favorites.write_rating_on_favorite {
        payload.user_rating = payload.user_rating.or(Some(100));
        let path = core_db::track_file_path(state.pool(), track_id).await?;
        let path_for_write = std::path::PathBuf::from(path);
        tokio::task::spawn_blocking(move || {
            library_scanner::write_rating_tag(&path_for_write, 100, 100)
        })
        .await
        .map_err(anyhow::Error::from)??;
        core_db::update_track_tag_rating(state.pool(), track_id, 100, 100).await?;
    }

    let mut detail = core_db::set_track_favorite(state.pool(), track_id, payload).await?;
    apply_favorite_settings_to_track(&config.favorites, &mut detail.track);
    state.bump_library_revision("track_favorite_updated");
    Ok(Json(detail))
}

async fn list_outputs(State(state): State<AppState>) -> ApiResult<Vec<protocol::OutputDevice>> {
    let core_name = core_display_name(&state.config());
    let mut outputs = output_cpal::list_output_devices()?;
    for output in &mut outputs {
        output.node_name = Some(core_name.clone());
    }
    outputs.extend(state.inner.renderers.list_outputs().await);
    Ok(Json(outputs))
}

async fn list_renderers(
    State(state): State<AppState>,
) -> ApiResult<Vec<protocol::RegisteredRenderer>> {
    Ok(Json(state.inner.renderers.list_renderers().await))
}

async fn register_renderer(
    State(state): State<AppState>,
    Json(payload): Json<RendererRegistration>,
) -> ApiResult<protocol::RegisteredRenderer> {
    let (renderer, reset_states) = state.inner.renderers.register(payload).await;
    for (previous, current) in reset_states {
        record_playback_finish(
            &state,
            &previous,
            "renderer_restarted",
            "renderer_reset",
            None,
        )
        .await;
        state.emit("playback.state_changed", &current);
    }
    state.emit("renderer.registered", &renderer);
    Ok(Json(renderer))
}

async fn report_renderer_state(
    State(state): State<AppState>,
    Path(client_id): Path<String>,
    Json(payload): Json<RendererStateReport>,
) -> ApiResult<PlaybackState> {
    let output_id = if payload.output_id.starts_with("renderer:") {
        payload.output_id.clone()
    } else {
        renderers::remote_output_id(&client_id, &payload.output_id)
    };
    let previous = state.inner.renderers.state_for_output(&output_id).await;
    let completed = previous.as_ref().is_some_and(|previous| {
        previous.track_id.is_some()
            && previous.state == PlaybackTransportState::Playing
            && payload.state == PlaybackTransportState::Stopped
    });
    let playback = state
        .inner
        .renderers
        .report_state(&client_id, payload)
        .await?;
    record_renderer_state_transition(&state, previous, &playback).await;
    state.emit("playback.state_changed", &playback);
    if completed {
        if let Some(track_id) =
            step_playback_queue_and_emit(&state, &output_id, false, true).await?
        {
            return Ok(Json(
                play_track_on_zone(&state, &output_id, track_id, 0).await?,
            ));
        }
    }
    Ok(Json(playback))
}

async fn list_zones(State(state): State<AppState>) -> ApiResult<Vec<protocol::ZoneSummary>> {
    let core_name = core_display_name(&state.config());
    let mut zones = core_db::list_zones(state.pool()).await?;
    for zone in &mut zones {
        zone.node_name = Some(core_name.clone());
        if zone.id == "local" {
            zone.system_name = core_name.clone();
            zone.name = core_name.clone();
        }
        let playback = state.inner.playback.state_for_zone(&zone.id).await;
        apply_playback_to_zone(zone, playback);
    }

    for mut output in output_cpal::list_output_devices()? {
        output.node_name = Some(core_name.clone());
        let zone_id = output.id.clone();
        let playback = state.inner.playback.state_for_zone(&zone_id).await;
        let system_name = format!(
            "{} - {}",
            output
                .node_name
                .clone()
                .unwrap_or_else(|| core_name.clone()),
            output.name
        );
        let mut zone = protocol::ZoneSummary {
            id: zone_id.clone(),
            name: system_name.clone(),
            system_name,
            alias: None,
            output_id: Some(zone_id),
            state: playback.state,
            volume: 1.0,
            muted: false,
            track_id: None,
            track_title: None,
            position_ms: 0,
            is_online: output.is_online,
            is_remote: output.is_remote,
            node_id: output.node_id,
            node_name: output.node_name,
        };
        apply_playback_to_zone(&mut zone, playback);
        zones.push(zone);
    }
    zones.extend(state.inner.renderers.list_zones().await);
    apply_zone_aliases(&state, &mut zones).await?;
    apply_zone_preferences(&state, &mut zones).await?;
    Ok(Json(zones))
}

async fn update_zone_alias(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
    Json(payload): Json<ZoneAliasUpdate>,
) -> ApiResult<serde_json::Value> {
    let alias = core_db::set_zone_alias(state.pool(), &zone_id, payload.alias.as_deref()).await?;
    state.emit(
        "zone.alias_updated",
        json!({
            "zone_id": zone_id,
            "alias": alias,
        }),
    );
    Ok(Json(json!({ "alias": alias })))
}

async fn apply_zone_aliases(state: &AppState, zones: &mut [protocol::ZoneSummary]) -> Result<()> {
    let aliases = core_db::list_zone_aliases(state.pool()).await?;
    for zone in zones {
        if let Some(alias) = aliases.get(&zone.id) {
            zone.alias = Some(alias.clone());
            zone.name = alias.clone();
        }
    }
    Ok(())
}

async fn apply_zone_preferences(
    state: &AppState,
    zones: &mut [protocol::ZoneSummary],
) -> Result<()> {
    for zone in zones {
        let preference = core_db::zone_volume(state.pool(), &zone.id).await?;
        zone.volume = preference.volume;
        zone.muted = preference.muted;
    }
    Ok(())
}

fn apply_playback_to_zone(zone: &mut protocol::ZoneSummary, playback: PlaybackState) {
    zone.state = playback.state;
    zone.track_id = playback.track_id;
    zone.track_title = playback.track_title;
    zone.position_ms = playback.position_ms;
}

async fn play_zone(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
    payload: Option<Json<PlayRequest>>,
) -> ApiResult<PlaybackState> {
    let request = payload.map(|Json(payload)| payload).unwrap_or_default();
    let playback = if let Some(track_id) = request.track_id {
        play_track_on_zone(&state, &zone_id, track_id, request.position_ms.unwrap_or(0)).await?
    } else {
        resume_zone_internal(&state, &zone_id).await?
    };
    Ok(Json(playback))
}

async fn play_many_zones(
    State(state): State<AppState>,
    Json(payload): Json<MultiZonePlayRequest>,
) -> ApiResult<Vec<PlaybackState>> {
    let mut states = Vec::new();
    for zone_id in payload.zone_ids {
        states.push(
            play_track_on_zone(
                &state,
                &zone_id,
                payload.track_id,
                payload.position_ms.unwrap_or(0),
            )
            .await?,
        );
    }
    Ok(Json(states))
}

async fn transfer_zone(
    State(state): State<AppState>,
    Path(source_zone_id): Path<String>,
    Json(payload): Json<ZoneTransferRequest>,
) -> ApiResult<Vec<PlaybackState>> {
    if source_zone_id == payload.target_zone_id {
        return Ok(Json(vec![
            playback_state_for_zone(&state, &source_zone_id).await?,
        ]));
    }

    let source = playback_state_for_zone(&state, &source_zone_id).await?;
    let track_id = source
        .track_id
        .ok_or_else(|| anyhow::anyhow!("source zone {source_zone_id} has no active track"))?;

    let mut states = vec![
        play_track_on_zone(
            &state,
            &payload.target_zone_id,
            track_id,
            source.position_ms,
        )
        .await?,
    ];
    if payload.stop_source {
        states.push(
            stop_zone_internal_with_reason(
                &state,
                &source_zone_id,
                "transferred",
                Some(payload.target_zone_id.as_str()),
            )
            .await?,
        );
    }

    Ok(Json(states))
}

async fn pause_zone(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
) -> ApiResult<PlaybackState> {
    let playback = pause_zone_internal(&state, &zone_id).await?;
    Ok(Json(playback))
}

async fn stop_zone(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
) -> ApiResult<PlaybackState> {
    let playback = stop_zone_internal(&state, &zone_id).await?;
    Ok(Json(playback))
}

async fn seek_zone(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
    Json(payload): Json<SeekRequest>,
) -> ApiResult<PlaybackState> {
    let playback = seek_zone_internal(&state, &zone_id, payload.position_ms).await?;
    Ok(Json(playback))
}

async fn get_zone_queue(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
) -> ApiResult<PlaybackQueue> {
    Ok(Json(core_db::playback_queue(state.pool(), &zone_id).await?))
}

async fn replace_zone_queue(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
    Json(payload): Json<ReplacePlaybackQueue>,
) -> ApiResult<PlaybackQueue> {
    let queue = core_db::replace_playback_queue(state.pool(), &zone_id, payload).await?;
    state.emit("playback.queue_changed", &queue);
    Ok(Json(queue))
}

async fn add_zone_queue_items(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
    Json(payload): Json<AddPlaybackQueueItems>,
) -> ApiResult<PlaybackQueue> {
    let queue = core_db::add_playback_queue_items(
        state.pool(),
        &zone_id,
        payload.track_ids,
        payload.position,
    )
    .await?;
    state.emit("playback.queue_changed", &queue);
    Ok(Json(queue))
}

async fn remove_zone_queue_item(
    State(state): State<AppState>,
    Path((zone_id, item_id)): Path<(String, i64)>,
) -> ApiResult<PlaybackQueue> {
    let queue = core_db::remove_playback_queue_item(state.pool(), &zone_id, item_id).await?;
    state.emit("playback.queue_changed", &queue);
    Ok(Json(queue))
}

async fn move_zone_queue_item(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
    Json(payload): Json<MovePlaybackQueueItem>,
) -> ApiResult<PlaybackQueue> {
    let queue =
        core_db::move_playback_queue_item(state.pool(), &zone_id, payload.from, payload.to).await?;
    state.emit("playback.queue_changed", &queue);
    Ok(Json(queue))
}

async fn update_zone_queue_mode(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
    Json(payload): Json<PlaybackModeUpdate>,
) -> ApiResult<PlaybackQueue> {
    let queue = core_db::set_playback_mode(state.pool(), &zone_id, payload.mode).await?;
    state.emit("playback.queue_changed", &queue);
    Ok(Json(queue))
}

async fn next_zone_track(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
) -> ApiResult<PlaybackState> {
    Ok(Json(play_queue_step(&state, &zone_id, false, false).await?))
}

async fn previous_zone_track(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
) -> ApiResult<PlaybackState> {
    Ok(Json(play_queue_step(&state, &zone_id, true, false).await?))
}

async fn get_zone_volume(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
) -> ApiResult<ZoneVolume> {
    Ok(Json(core_db::zone_volume(state.pool(), &zone_id).await?))
}

async fn update_zone_volume(
    State(state): State<AppState>,
    Path(zone_id): Path<String>,
    Json(payload): Json<ZoneVolumeUpdate>,
) -> ApiResult<ZoneVolume> {
    let volume =
        core_db::set_zone_volume(state.pool(), &zone_id, payload.volume, payload.muted).await?;
    apply_zone_volume(&state, &volume).await?;
    state.emit("zone.volume_changed", &volume);
    Ok(Json(volume))
}

async fn settings(State(state): State<AppState>) -> ApiResult<CoreConfig> {
    Ok(Json(state.config()))
}

async fn server_settings(State(state): State<AppState>) -> ApiResult<core_config::ServerConfig> {
    Ok(Json(state.config().server))
}

async fn update_server_settings(
    State(state): State<AppState>,
    Json(payload): Json<ServerSettingsUpdate>,
) -> ApiResult<core_config::ServerConfig> {
    let mut config = state
        .inner
        .config
        .write()
        .map_err(|_| anyhow::anyhow!("config lock is poisoned"))?;
    if let Some(alias) = payload.alias {
        let cleaned = alias.trim();
        config.server.alias = if cleaned.is_empty() {
            None
        } else {
            Some(cleaned.to_string())
        };
    }
    config.save(&state.inner.paths)?;
    let server = config.server.clone();
    let display_name = core_display_name(&config);
    drop(config);
    state.emit(
        "core.settings_changed",
        json!({ "section": "server", "display_name": display_name }),
    );
    Ok(Json(server))
}

async fn favorite_settings(State(state): State<AppState>) -> ApiResult<FavoritesConfig> {
    Ok(Json(state.config().favorites))
}

async fn metadata_settings(
    State(state): State<AppState>,
) -> ApiResult<core_config::MetadataConfig> {
    Ok(Json(state.config().metadata))
}

async fn update_favorite_settings(
    State(state): State<AppState>,
    Json(payload): Json<FavoriteSettingsUpdate>,
) -> ApiResult<FavoritesConfig> {
    let mut config = state
        .inner
        .config
        .write()
        .map_err(|_| anyhow::anyhow!("config lock is poisoned"))?;
    if let Some(value) = payload.treat_max_rating_as_favorite {
        config.favorites.treat_max_rating_as_favorite = value;
    }
    if let Some(value) = payload.write_rating_on_favorite {
        config.favorites.write_rating_on_favorite = value;
    }
    config.save(&state.inner.paths)?;
    Ok(Json(config.favorites.clone()))
}

async fn update_metadata_settings(
    State(state): State<AppState>,
    Json(payload): Json<MetadataSettingsUpdate>,
) -> ApiResult<core_config::MetadataConfig> {
    let mut config = state
        .inner
        .config
        .write()
        .map_err(|_| anyhow::anyhow!("config lock is poisoned"))?;
    if let Some(values) = payload.artist_separators {
        config.metadata.artist_separators = normalize_separators(values);
    }
    if let Some(values) = payload.genre_separators {
        config.metadata.genre_separators = normalize_separators(values);
    }
    config.save(&state.inner.paths)?;
    Ok(Json(config.metadata.clone()))
}

fn normalize_separators(values: Vec<String>) -> Vec<String> {
    let mut separators = values
        .into_iter()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .collect::<Vec<_>>();
    separators.sort();
    separators.dedup();
    if separators.is_empty() {
        vec![",".to_string(), ";".to_string()]
    } else {
        separators
    }
}

async fn diagnostics(State(state): State<AppState>) -> ApiResult<serde_json::Value> {
    Ok(Json(json!({
        "config_file": state.inner.paths.config_file,
        "data_dir": state.inner.paths.data_dir,
        "cache_dir": state.inner.paths.cache_dir,
        "database_file": state.inner.paths.database_file,
        "library_revision": state.inner.library_revision.load(Ordering::SeqCst),
    })))
}

async fn playback_history(
    State(state): State<AppState>,
    Query(query): Query<HistoryQuery>,
) -> ApiResult<Vec<PlaybackEvent>> {
    Ok(Json(
        core_db::list_playback_events(
            state.pool(),
            query.limit(),
            query.offset(),
            query.from,
            query.to,
        )
        .await?,
    ))
}

async fn playback_sessions(
    State(state): State<AppState>,
    Query(query): Query<HistoryQuery>,
) -> ApiResult<Vec<PlaybackSession>> {
    Ok(Json(
        core_db::list_playback_sessions(
            state.pool(),
            query.limit(),
            query.offset(),
            query.from,
            query.to,
        )
        .await?,
    ))
}

async fn playback_stats(
    State(state): State<AppState>,
    Query(query): Query<StatsQuery>,
) -> ApiResult<PlaybackStats> {
    Ok(Json(
        core_db::playback_stats(
            state.pool(),
            query.from,
            query.to,
            query.top_limit.unwrap_or(25),
        )
        .await?,
    ))
}

async fn events_ws(State(state): State<AppState>, ws: WebSocketUpgrade) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_ws(socket, state))
}

async fn handle_ws(mut socket: WebSocket, state: AppState) {
    let mut rx = state.inner.events.subscribe();
    while let Ok(event) = rx.recv().await {
        match serde_json::to_string(&event) {
            Ok(text) => {
                if socket.send(Message::Text(text.into())).await.is_err() {
                    break;
                }
            }
            Err(error) => error!(error = %error, "failed to serialize event"),
        }
    }
}

#[derive(Debug, Deserialize)]
struct Paging {
    limit: Option<u32>,
    offset: Option<u32>,
}

impl Paging {
    fn limit(&self) -> u32 {
        self.limit.unwrap_or(50).clamp(1, 500)
    }

    fn offset(&self) -> u32 {
        self.offset.unwrap_or(0)
    }
}

#[derive(Debug, Deserialize)]
struct SearchParams {
    q: String,
    limit: Option<u32>,
}

#[derive(Debug, Deserialize)]
struct HistoryQuery {
    limit: Option<u32>,
    offset: Option<u32>,
    from: Option<String>,
    to: Option<String>,
}

impl HistoryQuery {
    fn limit(&self) -> u32 {
        self.limit.unwrap_or(100).clamp(1, 500)
    }

    fn offset(&self) -> u32 {
        self.offset.unwrap_or(0)
    }
}

#[derive(Debug, Deserialize)]
struct StatsQuery {
    from: Option<String>,
    to: Option<String>,
    top_limit: Option<u32>,
}

fn apply_favorite_settings_to_playlist(settings: &FavoritesConfig, playlist: &mut PlaylistDetail) {
    apply_favorite_settings_to_tracks(settings, &mut playlist.tracks);
}

fn apply_favorite_settings_to_tracks(
    settings: &FavoritesConfig,
    tracks: &mut [protocol::TrackSummary],
) {
    for track in tracks {
        apply_favorite_settings_to_track(settings, track);
    }
}

fn apply_favorite_settings_to_track(
    settings: &FavoritesConfig,
    track: &mut protocol::TrackSummary,
) {
    if settings.treat_max_rating_as_favorite && has_max_tag_rating(track) {
        track.is_favorite = true;
    }
}

fn has_max_tag_rating(track: &protocol::TrackSummary) -> bool {
    matches!(
        (track.tag_rating, track.tag_rating_scale),
        (Some(rating), Some(scale)) if scale > 0 && rating >= scale
    )
}

async fn remote_state_from_current(
    renderers: &RendererRegistry,
    zone_id: &str,
    transport_state: PlaybackTransportState,
) -> Result<PlaybackState> {
    let mut playback = renderers
        .state_for_output(zone_id)
        .await
        .ok_or_else(|| anyhow::anyhow!("playback zone {zone_id} is not registered"))?;
    playback.state = transport_state;
    renderers.update_state(playback).await
}

async fn playback_state_for_zone(state: &AppState, zone_id: &str) -> Result<PlaybackState> {
    let mut playback = if is_core_zone(zone_id) {
        state.inner.playback.state_for_zone(zone_id).await
    } else {
        state
            .inner
            .renderers
            .state_for_output(zone_id)
            .await
            .ok_or_else(|| anyhow::anyhow!("playback zone {zone_id} is not registered"))?
    };
    playback.queue_revision = core_db::playback_queue(state.pool(), zone_id)
        .await?
        .revision;
    Ok(playback)
}

async fn play_queue_step(
    state: &AppState,
    zone_id: &str,
    previous: bool,
    automatic: bool,
) -> Result<PlaybackState> {
    match step_playback_queue_and_emit(state, zone_id, previous, automatic).await? {
        Some(track_id) => play_track_on_zone(state, zone_id, track_id, 0).await,
        None => stop_zone_internal_with_reason(state, zone_id, "queue_completed", None).await,
    }
}

async fn step_playback_queue_and_emit(
    state: &AppState,
    zone_id: &str,
    previous: bool,
    automatic: bool,
) -> Result<Option<i64>> {
    let track_id = core_db::step_playback_queue(state.pool(), zone_id, previous, automatic).await?;
    let queue = core_db::playback_queue(state.pool(), zone_id).await?;
    state.emit("playback.queue_changed", &queue);
    Ok(track_id)
}

async fn apply_zone_volume(state: &AppState, volume: &ZoneVolume) -> Result<()> {
    let effective_volume = if volume.muted { 0.0 } else { volume.volume };
    if is_core_zone(&volume.zone_id) {
        state
            .inner
            .playback
            .set_volume_zone(&volume.zone_id, effective_volume)
            .await;
        return Ok(());
    }
    let renderer_id = state
        .inner
        .renderers
        .renderer_id_for_output(&volume.zone_id)
        .await
        .ok_or_else(|| anyhow::anyhow!("playback zone {} is not registered", volume.zone_id))?;
    let playback = state
        .inner
        .renderers
        .state_for_output(&volume.zone_id)
        .await;
    state.emit(
        "renderer.command",
        json!({
            "renderer_id": renderer_id,
            "command": RendererCommandPayload {
                command_id: Uuid::now_v7(),
                target_output_id: volume.zone_id.clone(),
                action: "volume".to_string(),
                track_id: playback.as_ref().and_then(|state| state.track_id),
                track_title: playback.and_then(|state| state.track_title),
                stream_path: None,
                position_ms: None,
                volume: Some(volume.volume),
                muted: Some(volume.muted),
            }
        }),
    );
    Ok(())
}

async fn expire_offline_renderer_playback(state: &AppState) {
    for (previous, current) in state.inner.renderers.expire_offline_playback().await {
        record_playback_finish(
            state,
            &previous,
            "renderer_offline",
            "renderer_offline",
            None,
        )
        .await;
        state.emit("playback.state_changed", &current);
    }
}

async fn play_track_on_zone(
    state: &AppState,
    zone_id: &str,
    track_id: i64,
    position_ms: u64,
) -> Result<PlaybackState> {
    let previous = playback_state_for_zone(state, zone_id).await.ok();
    let queue = core_db::set_playback_queue_current_track(state.pool(), zone_id, track_id).await?;
    state.emit("playback.queue_changed", &queue);
    let detail = core_db::track_detail(state.pool(), track_id).await?;
    let track_title = detail.track.title.clone();

    let mut playback = if is_core_zone(zone_id) {
        let output_id = zone_id.starts_with("cpal:").then_some(zone_id);
        let playback = state
            .inner
            .playback
            .play_track_on_zone(
                zone_id,
                output_id,
                detail.track.id,
                detail.track.title,
                detail.file_path,
                position_ms,
            )
            .await?;
        if zone_id == "local" {
            core_db::set_zone_state(state.pool(), zone_id, "playing").await?;
        }
        playback
    } else {
        let renderer_id = state
            .inner
            .renderers
            .renderer_id_for_output(zone_id)
            .await
            .ok_or_else(|| anyhow::anyhow!("playback zone {zone_id} is not registered"))?;
        let command = RendererCommandPayload {
            command_id: Uuid::now_v7(),
            target_output_id: zone_id.to_string(),
            action: "play".to_string(),
            track_id: Some(detail.track.id),
            track_title: Some(track_title.clone()),
            stream_path: Some(format!("/tracks/{track_id}/stream")),
            position_ms: Some(position_ms),
            volume: None,
            muted: None,
        };
        let playback = state
            .inner
            .renderers
            .update_state(PlaybackState {
                zone_id: zone_id.to_string(),
                state: PlaybackTransportState::Playing,
                track_id: Some(detail.track.id),
                track_title: Some(track_title),
                position_ms,
                queue_revision: queue.revision,
            })
            .await?;
        state.emit(
            "renderer.command",
            json!({ "renderer_id": renderer_id, "command": command }),
        );
        playback
    };
    playback.queue_revision = queue.revision;
    let volume = core_db::zone_volume(state.pool(), zone_id).await?;
    apply_zone_volume(state, &volume).await?;

    if let Some(previous) = previous.as_ref() {
        if previous.track_id.is_some() {
            record_playback_finish(state, previous, "replaced", "cut_out", None).await;
        }
    }
    record_playback_start(state, &playback).await;
    state.emit("playback.state_changed", &playback);
    Ok(playback)
}

async fn resume_zone_internal(state: &AppState, zone_id: &str) -> Result<PlaybackState> {
    let playback = if is_core_zone(zone_id) {
        if zone_id == "local" {
            core_db::set_zone_state(state.pool(), zone_id, "playing").await?;
        }
        state.inner.playback.resume_zone(zone_id).await
    } else {
        let renderer_id = state
            .inner
            .renderers
            .renderer_id_for_output(zone_id)
            .await
            .ok_or_else(|| anyhow::anyhow!("playback zone {zone_id} is not registered"))?;
        let playback = remote_state_from_current(
            &state.inner.renderers,
            zone_id,
            PlaybackTransportState::Playing,
        )
        .await?;
        let command = RendererCommandPayload {
            command_id: Uuid::now_v7(),
            target_output_id: zone_id.to_string(),
            action: "resume".to_string(),
            track_id: playback.track_id,
            track_title: playback.track_title.clone(),
            stream_path: playback
                .track_id
                .map(|track_id| format!("/tracks/{track_id}/stream")),
            position_ms: Some(playback.position_ms),
            volume: None,
            muted: None,
        };
        state.emit(
            "renderer.command",
            json!({ "renderer_id": renderer_id, "command": command }),
        );
        playback
    };
    record_playback_update(state, &playback, "resume").await;
    state.emit("playback.state_changed", &playback);
    Ok(playback)
}

async fn pause_zone_internal(state: &AppState, zone_id: &str) -> Result<PlaybackState> {
    let playback = if is_core_zone(zone_id) {
        if zone_id == "local" {
            core_db::set_zone_state(state.pool(), zone_id, "paused").await?;
        }
        state.inner.playback.pause_zone(zone_id).await
    } else {
        let renderer_id = state
            .inner
            .renderers
            .renderer_id_for_output(zone_id)
            .await
            .ok_or_else(|| anyhow::anyhow!("playback zone {zone_id} is not registered"))?;
        let playback = remote_state_from_current(
            &state.inner.renderers,
            zone_id,
            PlaybackTransportState::Paused,
        )
        .await?;
        let command = RendererCommandPayload {
            command_id: Uuid::now_v7(),
            target_output_id: zone_id.to_string(),
            action: "pause".to_string(),
            track_id: playback.track_id,
            track_title: playback.track_title.clone(),
            stream_path: None,
            position_ms: None,
            volume: None,
            muted: None,
        };
        state.emit(
            "renderer.command",
            json!({ "renderer_id": renderer_id, "command": command }),
        );
        playback
    };
    record_playback_update(state, &playback, "pause").await;
    state.emit("playback.state_changed", &playback);
    Ok(playback)
}

async fn stop_zone_internal(state: &AppState, zone_id: &str) -> Result<PlaybackState> {
    stop_zone_internal_with_reason(state, zone_id, "stopped", None).await
}

async fn stop_zone_internal_with_reason(
    state: &AppState,
    zone_id: &str,
    reason: &str,
    related_zone_id: Option<&str>,
) -> Result<PlaybackState> {
    let previous = playback_state_for_zone(state, zone_id).await.ok();
    let playback = if is_core_zone(zone_id) {
        if zone_id == "local" {
            core_db::set_zone_state(state.pool(), zone_id, "stopped").await?;
        }
        state.inner.playback.stop_zone(zone_id).await
    } else {
        let renderer_id = state
            .inner
            .renderers
            .renderer_id_for_output(zone_id)
            .await
            .ok_or_else(|| anyhow::anyhow!("playback zone {zone_id} is not registered"))?;
        let playback = state
            .inner
            .renderers
            .update_state(PlaybackState {
                zone_id: zone_id.to_string(),
                state: PlaybackTransportState::Stopped,
                track_id: None,
                track_title: None,
                position_ms: 0,
                queue_revision: 0,
            })
            .await?;
        let command = RendererCommandPayload {
            command_id: Uuid::now_v7(),
            target_output_id: zone_id.to_string(),
            action: "stop".to_string(),
            track_id: None,
            track_title: None,
            stream_path: None,
            position_ms: None,
            volume: None,
            muted: None,
        };
        state.emit(
            "renderer.command",
            json!({ "renderer_id": renderer_id, "command": command }),
        );
        playback
    };
    if let Some(previous) = previous.as_ref() {
        record_playback_finish(state, previous, reason, "stop", related_zone_id).await;
    }
    state.emit("playback.state_changed", &playback);
    Ok(playback)
}

async fn seek_zone_internal(
    state: &AppState,
    zone_id: &str,
    position_ms: u64,
) -> Result<PlaybackState> {
    let playback = if is_core_zone(zone_id) {
        state.inner.playback.seek_zone(zone_id, position_ms).await?
    } else {
        let renderer_id = state
            .inner
            .renderers
            .renderer_id_for_output(zone_id)
            .await
            .ok_or_else(|| anyhow::anyhow!("playback zone {zone_id} is not registered"))?;
        let playback = remote_state_from_current(
            &state.inner.renderers,
            zone_id,
            PlaybackTransportState::Playing,
        )
        .await?;
        let playback = state
            .inner
            .renderers
            .update_state(PlaybackState {
                position_ms,
                ..playback
            })
            .await?;
        let command = RendererCommandPayload {
            command_id: Uuid::now_v7(),
            target_output_id: zone_id.to_string(),
            action: "seek".to_string(),
            track_id: playback.track_id,
            track_title: playback.track_title.clone(),
            stream_path: playback
                .track_id
                .map(|track_id| format!("/tracks/{track_id}/stream")),
            position_ms: Some(position_ms),
            volume: None,
            muted: None,
        };
        state.emit(
            "renderer.command",
            json!({ "renderer_id": renderer_id, "command": command }),
        );
        playback
    };
    record_playback_update(state, &playback, "seek").await;
    state.emit("playback.position", &playback);
    Ok(playback)
}

async fn record_renderer_state_transition(
    state: &AppState,
    previous: Option<PlaybackState>,
    current: &PlaybackState,
) {
    match current.state {
        PlaybackTransportState::Stopped => {
            if let Some(previous) = previous.as_ref().filter(|state| state.track_id.is_some()) {
                record_playback_finish(state, previous, "completed", "completed", None).await;
            }
        }
        PlaybackTransportState::Paused => {
            record_playback_update(state, current, "pause").await;
        }
        PlaybackTransportState::Playing => {
            record_playback_update(state, current, "progress").await;
        }
    }
}

async fn record_playback_start(state: &AppState, playback: &PlaybackState) {
    let Some(track_id) = playback.track_id else {
        return;
    };
    let track_title = playback
        .track_title
        .clone()
        .unwrap_or_else(|| format!("Track {track_id}"));
    if let Err(error) = core_db::finish_open_playback_session(
        state.pool(),
        &playback.zone_id,
        playback.position_ms,
        "replaced",
    )
    .await
    {
        error!(error = %error, zone_id = %playback.zone_id, "failed to close previous playback session");
    }
    if let Err(error) = core_db::start_playback_session(
        state.pool(),
        &playback.zone_id,
        track_id,
        &track_title,
        playback.position_ms,
    )
    .await
    {
        error!(error = %error, zone_id = %playback.zone_id, "failed to start playback session");
    }
    record_playback_event(state, playback, "play_start", None, None).await;
}

async fn record_playback_update(state: &AppState, playback: &PlaybackState, event_type: &str) {
    if playback.track_id.is_none() {
        return;
    }
    if let Err(error) = core_db::update_open_playback_session_position(
        state.pool(),
        &playback.zone_id,
        playback.position_ms,
    )
    .await
    {
        error!(error = %error, zone_id = %playback.zone_id, "failed to update playback session");
    }
    if event_type != "progress" {
        record_playback_event(state, playback, event_type, None, None).await;
    }
}

async fn record_playback_finish(
    state: &AppState,
    playback: &PlaybackState,
    reason: &str,
    event_type: &str,
    related_zone_id: Option<&str>,
) {
    if playback.track_id.is_none() {
        return;
    }
    if let Err(error) = core_db::finish_open_playback_session(
        state.pool(),
        &playback.zone_id,
        playback.position_ms,
        reason,
    )
    .await
    {
        error!(error = %error, zone_id = %playback.zone_id, "failed to finish playback session");
    }
    record_playback_event(state, playback, event_type, related_zone_id, Some(reason)).await;
}

async fn record_playback_event(
    state: &AppState,
    playback: &PlaybackState,
    event_type: &str,
    related_zone_id: Option<&str>,
    reason: Option<&str>,
) {
    if let Err(error) = core_db::record_playback_event(
        state.pool(),
        core_db::PlaybackEventIngest {
            zone_id: playback.zone_id.clone(),
            event_type: event_type.to_string(),
            track_id: playback.track_id,
            track_title: playback.track_title.clone(),
            position_ms: Some(playback.position_ms),
            related_zone_id: related_zone_id.map(ToOwned::to_owned),
            reason: reason.map(ToOwned::to_owned),
        },
    )
    .await
    {
        error!(error = %error, zone_id = %playback.zone_id, "failed to record playback event");
    }
}

fn is_core_zone(zone_id: &str) -> bool {
    zone_id == "local" || zone_id.starts_with("cpal:")
}

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
