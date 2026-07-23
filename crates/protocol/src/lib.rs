use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

pub const API_PREFIX: &str = "/api/v1";
pub const EVENTS_WS_PATH: &str = "/ws/v1/events";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CoreStatus {
    pub name: String,
    pub display_name: String,
    pub version: String,
    pub api_version: String,
    pub server_id: String,
    pub bind_address: String,
    pub discovery_service: Option<String>,
    pub started_at: DateTime<Utc>,
    pub library_revision: u64,
    pub database_path: String,
    pub counts: LibraryCounts,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct LibraryCounts {
    pub library_roots: i64,
    pub files: i64,
    pub tracks: i64,
    pub albums: i64,
    pub artists: i64,
    pub scan_problems: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LibraryRoot {
    pub id: i64,
    pub path: String,
    pub enabled: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NewLibraryRoot {
    pub path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArtistSummary {
    pub id: i64,
    pub name: String,
    pub sort_name: Option<String>,
    pub track_count: i64,
    pub album_count: i64,
    #[serde(default)]
    pub artwork_revision: i64,
    #[serde(default)]
    pub has_artwork: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ArtistProfile {
    pub display_name: Option<String>,
    pub sort_name: Option<String>,
    pub musicbrainz_id: Option<String>,
    pub artist_type: Option<String>,
    pub country: Option<String>,
    pub begin_date: Option<String>,
    pub end_date: Option<String>,
    pub disambiguation: Option<String>,
    pub biography: Option<String>,
    #[serde(default)]
    pub aliases: Vec<String>,
    #[serde(default)]
    pub genres: Vec<String>,
    #[serde(default)]
    pub links: Vec<ArtistLink>,
    pub updated_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ArtistLink {
    pub label: String,
    pub url: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct UpdateArtistProfile {
    pub display_name: Option<String>,
    pub sort_name: Option<String>,
    pub musicbrainz_id: Option<String>,
    pub artist_type: Option<String>,
    pub country: Option<String>,
    pub begin_date: Option<String>,
    pub end_date: Option<String>,
    pub disambiguation: Option<String>,
    pub biography: Option<String>,
    #[serde(default)]
    pub aliases: Vec<String>,
    #[serde(default)]
    pub genres: Vec<String>,
    #[serde(default)]
    pub links: Vec<ArtistLink>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArtistAsset {
    pub id: i64,
    pub artist_id: i64,
    pub original_filename: String,
    pub mime_type: String,
    pub width: u32,
    pub height: u32,
    pub byte_size: u64,
    pub photo_type: String,
    pub sort_order: i64,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArtistVisualRegion {
    pub position: u8,
    pub asset_id: i64,
    pub crop_x: f32,
    pub crop_y: f32,
    pub crop_width: f32,
    pub crop_height: f32,
    pub focal_x: f32,
    pub focal_y: f32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArtistVisual {
    pub slot: String,
    pub asset_id: Option<i64>,
    pub template: String,
    pub fit: String,
    pub focal_x: f32,
    pub focal_y: f32,
    pub blur: f32,
    pub brightness: f32,
    pub revision: i64,
    #[serde(default)]
    pub regions: Vec<ArtistVisualRegion>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateArtistVisual {
    pub asset_id: Option<i64>,
    pub template: String,
    pub fit: String,
    pub focal_x: f32,
    pub focal_y: f32,
    pub blur: f32,
    pub brightness: f32,
    #[serde(default)]
    pub regions: Vec<ArtistVisualRegion>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct MusicBrainzArtistPreviewRequest {
    pub musicbrainz_id: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct MusicBrainzArtistPreview {
    pub musicbrainz_id: String,
    pub name: String,
    pub sort_name: Option<String>,
    pub artist_type: Option<String>,
    pub country: Option<String>,
    pub begin_date: Option<String>,
    pub end_date: Option<String>,
    pub disambiguation: Option<String>,
    #[serde(default)]
    pub aliases: Vec<String>,
    #[serde(default)]
    pub genres: Vec<String>,
    #[serde(default)]
    pub links: Vec<ArtistLink>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct UpdateArtistAsset {
    pub photo_type: Option<String>,
    pub sort_order: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AlbumSummary {
    pub id: i64,
    pub title: String,
    pub album_artist_display: Option<String>,
    pub date: Option<String>,
    pub year: Option<i64>,
    pub total_discs: Option<i64>,
    pub track_count: i64,
    pub cover_asset_id: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AlbumDetail {
    pub album: AlbumSummary,
    pub tracks: Vec<TrackSummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArtistDetail {
    pub artist: ArtistSummary,
    pub profile: ArtistProfile,
    #[serde(default)]
    pub assets: Vec<ArtistAsset>,
    #[serde(default)]
    pub visuals: Vec<ArtistVisual>,
    pub albums: Vec<AlbumSummary>,
    pub tracks: Vec<TrackSummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrackSummary {
    pub id: i64,
    pub file_id: i64,
    pub album_id: Option<i64>,
    pub title: String,
    pub artist_display: Option<String>,
    pub album_title: Option<String>,
    pub disc_number: Option<i64>,
    pub track_number: Option<i64>,
    pub duration_ms: Option<i64>,
    pub year: Option<i64>,
    pub cover_asset_id: Option<i64>,
    pub is_favorite: bool,
    pub user_rating: Option<i64>,
    pub tag_rating: Option<i64>,
    pub tag_rating_scale: Option<i64>,
    pub effective_rating: Option<i64>,
    pub size_bytes: i64,
    pub added_at: DateTime<Utc>,
    pub play_count: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrackDetail {
    pub track: TrackSummary,
    pub file_path: String,
    pub relative_path: String,
    pub extension: String,
    pub size_bytes: i64,
    pub modified_at: DateTime<Utc>,
    pub scan_status: String,
    pub genres: Vec<String>,
    pub composers: Vec<String>,
    pub lyricists: Vec<String>,
    pub lyrics: Option<LyricPayload>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LyricPayload {
    pub kind: String,
    pub text: String,
    #[serde(default)]
    pub language: Option<String>,
    #[serde(default)]
    pub translation: Option<String>,
    #[serde(default)]
    pub pronunciation: Option<String>,
    #[serde(default)]
    pub offset_ms: i64,
    #[serde(default)]
    pub source: String,
    #[serde(default)]
    pub revision: i64,
    #[serde(default)]
    pub cues: Vec<LyricCue>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct LyricCue {
    pub start_ms: i64,
    pub end_ms: Option<i64>,
    pub text: String,
    #[serde(default)]
    pub translation: Option<String>,
    #[serde(default)]
    pub pronunciation: Option<String>,
    #[serde(default)]
    pub speaker: Option<String>,
    #[serde(default)]
    pub background: bool,
    #[serde(default)]
    pub segments: Vec<LyricSegment>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct LyricSegment {
    pub start_ms: i64,
    pub end_ms: Option<i64>,
    pub text: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TrackLyricsUpdate {
    pub kind: String,
    pub text: String,
    pub language: Option<String>,
    pub translation: Option<String>,
    pub pronunciation: Option<String>,
    #[serde(default)]
    pub offset_ms: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrackMetadataFieldUpdate {
    pub key: String,
    pub value: Value,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TrackMetadataUpdate {
    pub expected_revision: Option<i64>,
    #[serde(default)]
    pub fields: Vec<TrackMetadataFieldUpdate>,
    #[serde(default)]
    pub clear_fields: Vec<String>,
    pub lyrics: Option<TrackLyricsUpdate>,
    #[serde(default)]
    pub clear_lyrics_override: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrackMetadataField {
    pub key: String,
    pub label: String,
    pub scope: String,
    pub value_kind: String,
    pub effective_value: Value,
    pub file_value: Value,
    pub override_value: Option<Value>,
    pub source: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrackEditSnapshot {
    pub detail: TrackDetail,
    pub revision: i64,
    pub fields: Vec<TrackMetadataField>,
    pub file_lyrics: Option<LyricPayload>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScanProblem {
    pub file_id: i64,
    pub path: String,
    pub scan_status: String,
    pub message: Option<String>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchQuery {
    pub q: String,
    pub limit: Option<u32>,
    pub offset: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchResponse {
    pub query: String,
    pub tracks: Vec<TrackSummary>,
    pub albums: Vec<AlbumSummary>,
    pub artists: Vec<ArtistSummary>,
    #[serde(default)]
    pub playlists: Vec<PlaylistSummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlaylistKind {
    Manual,
    Smart,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlaylistSummary {
    pub id: i64,
    pub name: String,
    pub kind: PlaylistKind,
    pub description: Option<String>,
    pub track_count: i64,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlaylistDetail {
    pub playlist: PlaylistSummary,
    pub rules: Option<Value>,
    pub tracks: Vec<TrackSummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NewPlaylist {
    pub name: String,
    pub kind: PlaylistKind,
    pub description: Option<String>,
    pub rules: Option<Value>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct UpdatePlaylist {
    pub name: Option<String>,
    pub description: Option<String>,
    pub rules: Option<Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlaylistTrackMutation {
    pub track_id: i64,
    pub position: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrackFavoriteUpdate {
    pub is_favorite: bool,
    pub user_rating: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FavoriteSettingsUpdate {
    pub treat_max_rating_as_favorite: Option<bool>,
    pub write_rating_on_favorite: Option<bool>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct MetadataSettingsUpdate {
    pub artist_separators: Option<Vec<String>>,
    pub genre_separators: Option<Vec<String>>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ServerSettingsUpdate {
    pub alias: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OutputDevice {
    pub id: String,
    pub name: String,
    pub backend: String,
    pub is_default: bool,
    pub sample_rates: Vec<u32>,
    pub channels: Vec<u16>,
    pub node_id: Option<String>,
    pub node_name: Option<String>,
    pub is_online: bool,
    pub is_remote: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ZoneSummary {
    pub id: String,
    pub name: String,
    pub system_name: String,
    pub alias: Option<String>,
    pub output_id: Option<String>,
    pub state: PlaybackTransportState,
    pub volume: f32,
    #[serde(default)]
    pub muted: bool,
    pub track_id: Option<i64>,
    pub track_title: Option<String>,
    pub position_ms: u64,
    pub is_online: bool,
    pub is_remote: bool,
    pub node_id: Option<String>,
    pub node_name: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PlaybackTransportState {
    Stopped,
    Playing,
    Paused,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlaybackState {
    pub zone_id: String,
    pub state: PlaybackTransportState,
    pub track_id: Option<i64>,
    pub track_title: Option<String>,
    pub position_ms: u64,
    pub queue_revision: u64,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PlaybackMode {
    Single,
    RepeatOne,
    Shuffle,
    RepeatAll,
    #[default]
    Sequential,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlaybackQueueItem {
    pub id: i64,
    pub position: i64,
    pub track: TrackSummary,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlaybackQueue {
    pub zone_id: String,
    pub revision: u64,
    pub mode: PlaybackMode,
    pub current_index: Option<i64>,
    pub items: Vec<PlaybackQueueItem>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ReplacePlaybackQueue {
    pub track_ids: Vec<i64>,
    pub start_index: Option<i64>,
    pub mode: Option<PlaybackMode>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AddPlaybackQueueItems {
    pub track_ids: Vec<i64>,
    pub position: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MovePlaybackQueueItem {
    pub from: i64,
    pub to: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlaybackModeUpdate {
    pub mode: PlaybackMode,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ZoneVolumeUpdate {
    pub volume: f32,
    pub muted: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ZoneVolume {
    pub zone_id: String,
    pub volume: f32,
    pub muted: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PlayRequest {
    pub track_id: Option<i64>,
    pub position_ms: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SeekRequest {
    pub position_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ZoneAliasUpdate {
    pub alias: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ZoneTransferRequest {
    pub target_zone_id: String,
    #[serde(default = "default_true")]
    pub stop_source: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MultiZonePlayRequest {
    pub track_id: i64,
    pub zone_ids: Vec<String>,
    pub position_ms: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RendererRegistration {
    pub client_id: String,
    pub name: String,
    pub platform: String,
    pub outputs: Vec<RendererOutputRegistration>,
    #[serde(default)]
    pub reset_playback: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RendererOutputRegistration {
    pub id: String,
    pub name: String,
    pub backend: String,
    pub is_default: bool,
    pub sample_rates: Vec<u32>,
    pub channels: Vec<u16>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegisteredRenderer {
    pub client_id: String,
    pub name: String,
    pub platform: String,
    pub outputs: Vec<OutputDevice>,
    pub last_seen_at: DateTime<Utc>,
    pub is_online: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RendererCommandPayload {
    pub command_id: Uuid,
    pub target_output_id: String,
    pub action: String,
    pub track_id: Option<i64>,
    pub track_title: Option<String>,
    pub stream_path: Option<String>,
    pub position_ms: Option<u64>,
    #[serde(default)]
    pub volume: Option<f32>,
    #[serde(default)]
    pub muted: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RendererStateReport {
    pub output_id: String,
    pub state: PlaybackTransportState,
    pub track_id: Option<i64>,
    pub track_title: Option<String>,
    pub position_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlaybackEvent {
    pub id: i64,
    pub zone_id: String,
    pub event_type: String,
    pub track_id: Option<i64>,
    pub track_title: Option<String>,
    pub position_ms: Option<u64>,
    pub related_zone_id: Option<String>,
    pub reason: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlaybackSession {
    pub id: i64,
    pub zone_id: String,
    pub track_id: i64,
    pub track_title: String,
    pub started_at: DateTime<Utc>,
    pub start_position_ms: u64,
    pub ended_at: Option<DateTime<Utc>>,
    pub end_position_ms: Option<u64>,
    pub end_reason: Option<String>,
    pub played_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrackPlaybackStat {
    pub track_id: i64,
    pub title: String,
    pub artist_display: Option<String>,
    pub album_title: Option<String>,
    pub play_count: i64,
    pub total_played_ms: u64,
    pub last_played_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlaybackStats {
    pub total_events: i64,
    pub total_sessions: i64,
    pub total_played_ms: u64,
    pub completed_sessions: i64,
    pub interrupted_sessions: i64,
    pub top_tracks: Vec<TrackPlaybackStat>,
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EventEnvelope {
    pub id: Uuid,
    #[serde(rename = "type")]
    pub event_type: String,
    pub time: DateTime<Utc>,
    pub payload: Value,
}

impl EventEnvelope {
    pub fn new(event_type: impl Into<String>, payload: impl Serialize) -> Self {
        let payload = serde_json::to_value(payload).unwrap_or(Value::Null);
        Self {
            id: Uuid::now_v7(),
            event_type: event_type.into(),
            time: Utc::now(),
            payload,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LibraryChangedPayload {
    pub revision: u64,
    pub reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScanProgressPayload {
    pub scanned_files: u64,
    pub imported_tracks: u64,
    pub problem_files: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApiErrorBody {
    pub error: String,
}
